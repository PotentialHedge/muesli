import Foundation
import Testing
@testable import MuesliCore

private let zoom = MeetingApps.match(bundleID: "us.zoom.xos")!
private let chrome = MeetingApps.match(bundleID: "com.google.Chrome")!
private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Suite struct MeetingDetectorTests {
    @Test func startsWhenMeetingAppTakesMic() {
        var d = MeetingDetector(gracePeriod: 20)
        #expect(d.update(activeApps: [], now: t0) == [])
        #expect(d.update(activeApps: [zoom], now: t0 + 2) == [.started(zoom)])
        #expect(d.update(activeApps: [zoom], now: t0 + 4) == [])
    }

    @Test func briefMicDropDoesNotEndMeeting() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [], now: t0 + 10) == [])
        #expect(d.update(activeApps: [zoom], now: t0 + 15) == [])
        #expect(d.update(activeApps: [], now: t0 + 30) == [])  // only 15s since last seen
        #expect(d.current == zoom)
    }

    @Test func endsAfterGracePeriod() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [], now: t0 + 19) == [])
        #expect(d.update(activeApps: [], now: t0 + 20) == [.ended(zoom)])
        #expect(d.current == nil)
        #expect(d.update(activeApps: [], now: t0 + 40) == [])
    }

    @Test func switchingAppsEndsThenStarts() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [zoom], now: t0)
        #expect(d.update(activeApps: [chrome], now: t0 + 5) == [])
        #expect(d.update(activeApps: [chrome], now: t0 + 25) == [.ended(zoom), .started(chrome)])
    }

    @Test func otherAppJoiningDoesNotInterrupt() {
        var d = MeetingDetector(gracePeriod: 20)
        _ = d.update(activeApps: [chrome], now: t0)
        #expect(d.update(activeApps: [zoom, chrome], now: t0 + 2) == [])
        #expect(d.current == chrome)
    }
}

@Suite struct MeetingAppsTests {
    @Test func helperProcessesMatchTheirApp() {
        #expect(MeetingApps.match(bundleID: "com.google.Chrome.helper")?.name == "Chrome")
        #expect(MeetingApps.match(bundleID: "com.microsoft.teams2.helper")?.name == "Teams")
        #expect(MeetingApps.match(bundleID: "us.zoom.CptHost")?.name == "Zoom")
        #expect(MeetingApps.match(bundleID: "com.apple.WebKit.GPU")?.name == "Safari")
    }

    @Test func prefixMustEndAtComponentBoundary() {
        #expect(MeetingApps.match(bundleID: "com.google.Chromeish") == nil)
        #expect(MeetingApps.match(bundleID: "com.apple.Music") == nil)
    }

    @Test func nativeAppsRankAboveBrowsersAndDeduplicate() {
        let processes = [
            AudioProcess(pid: 1, bundleID: "com.google.Chrome.helper", name: "", isRunningInput: true, isRunningOutput: false),
            AudioProcess(pid: 2, bundleID: "com.google.Chrome", name: "", isRunningInput: true, isRunningOutput: false),
            AudioProcess(pid: 3, bundleID: "us.zoom.xos", name: "", isRunningInput: true, isRunningOutput: false),
        ]
        #expect(MeetingApps.active(in: processes).map(\.name) == ["Zoom", "Chrome"])
    }
}

@Suite struct MeetingStoreTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return c
    }()

    @Test func folderNameIsSortableTimestampPlusApp() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 5))!
        #expect(MeetingStore.folderName(start: date, appName: "Zoom", calendar: calendar) == "2026-11-04 0905 Zoom")
        #expect(MeetingStore.folderName(start: date, appName: nil, calendar: calendar) == "2026-11-04 0905 Meeting")
        #expect(MeetingStore.folderName(start: date, appName: "A/B: C", calendar: calendar) == "2026-11-04 0905 A-B- C")
    }

    @Test func createsYearMonthFoldersAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 10, minute: 30))!

        let first = try store.makeMeetingFolder(start: date, appName: "Zoom", calendar: calendar)
        let second = try store.makeMeetingFolder(start: date, appName: "Zoom", calendar: calendar)

        #expect(first.path.hasSuffix("2026/11/2026-11-04 1030 Zoom"))
        #expect(second.lastPathComponent == "2026-11-04 1030 Zoom (2)")
        #expect(store.recentMeetings().map(\.lastPathComponent) == ["2026-11-04 1030 Zoom (2)", "2026-11-04 1030 Zoom"])
    }

    @Test func frontmatterIncludesDurationOnceEnded() {
        let meta = MeetingMetadata(start: t0, end: t0 + 3725, app: "Zoom", status: .recorded)
        let text = meta.frontmatter()
        #expect(text.hasPrefix("---\ndate: "))
        #expect(text.contains("duration: 01:02:05"))
        #expect(text.contains("app: Zoom"))
        #expect(text.hasSuffix("status: recorded\n---\n"))
    }
}

import AVFAudio

@Suite struct MixdownTests {
    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!

    @Test func averagesDeinterleavedChannels() throws {
        // Like the voice-processing mic input: 3 channels, deinterleaved.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        for ch in 0..<3 { buffer.floatChannelData![ch][0] = 0.3; buffer.floatChannelData![ch][1] = Float(ch) }

        let out = try TrackWriter.mixdown(buffer, to: mono)
        #expect(out.frameLength == 2)
        #expect(abs(out.floatChannelData![0][0] - 0.3) < 1e-6)
        #expect(abs(out.floatChannelData![0][1] - 1.0) < 1e-6)
    }

    @Test func averagesInterleavedStereo() throws {
        // Like the system audio tap: stereo, interleaved.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        samples[0] = 0.2; samples[1] = 0.4; samples[2] = -1; samples[3] = 1

        let out = try TrackWriter.mixdown(buffer, to: mono)
        #expect(abs(out.floatChannelData![0][0] - 0.3) < 1e-6)
        #expect(out.floatChannelData![0][1] == 0)
    }
}
