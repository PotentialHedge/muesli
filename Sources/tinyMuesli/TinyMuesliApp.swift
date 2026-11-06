import AppKit
import TinyMuesliCore
import SwiftUI

struct TinyMuesliApp: App {
    @State private var model: AppModel
    @State private var updater: Updater

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _updater = State(initialValue: Updater { model.isBusy })
        OngoingPill.install()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, updater: updater)
        } label: {
            Image(systemName: model.statusSymbol)
        }
    }
}

private struct MenuContent: View {
    let model: AppModel
    let updater: Updater

    var body: some View {
        @Bindable var model = model
        @Bindable var updater = updater
        Text(model.statusText)
        if let ended = model.endedText {
            Text(ended)
        }
        if let processing = model.processingText {
            Text(processing)
        }
        if let moving = model.movingText {
            Text(moving)
        }

        switch model.status {
        case .idle:
            Button("Start Recording") { model.startRecording(app: nil) }
        case .detected(let app):
            Button("Record \(app.name) Meeting") { model.startRecording(app: app) }
        case .recording:
            Button("Stop Recording") { model.stopRecording() }
            Button("Start New Meeting") { model.startNewMeeting() }
        }
        if let ended = model.ended {
            Button("Continue \(AppModel.title(of: ended.session))") { model.continueMeeting() }
            Button("Finish \(AppModel.title(of: ended.session)) Now") { model.finishEndedMeeting() }
        }

        if let app = model.currentApp {
            Toggle("Always Record \(app.name)", isOn: Binding(
                get: { model.alwaysRecord.contains(app.id) },
                set: { model.setAlwaysRecord(app.id, $0) }
            ))
        }

        if let error = model.lastError {
            let summary = AppModel.menuSummary(of: error)
            if summary == error {
                Text(error)
            } else {
                Button(summary) { model.showLastError() }
            }
        }

        Divider()

        ForEach(model.recentDays) { day in
            Section(day.title) {
                ForEach(day.meetings, id: \.folder) { meeting in
                    Button(meeting.title) { NSWorkspace.shared.open(meeting.folder) }
                        .badge(meeting.isOngoing ? Text(OngoingPill.label) : meeting.length.map { Text($0) })
                }
            }
        }
        Button("Open Meetings Folder") { model.openMeetingsFolder() }
        Button("Copy Prompt for Agent") { model.copyAgentPrompt() }
        Button("Add to Claude Desktop…") { model.addToClaudeDesktop() }

        Divider()

        Picker("Language", selection: $model.language) {
            Text("System Default").tag(String?.none)
            ForEach(model.languageChoices, id: \.self) { choice in
                Text(choice.name).tag(Optional(choice.tag))
            }
        }
        if !model.languageVariants.isEmpty {
            Picker("Variant", selection: $model.language) {
                ForEach(model.languageVariants, id: \.self) { variant in
                    Text(variant.name).tag(Optional(variant.tag))
                }
            }
        }
        Menu("Settings") {
            Toggle("Keep Audio After Transcribing", isOn: $model.keepAudio)
            Toggle("Skip Silence While Recording", isOn: $model.skipSilence)
            Button("Meetings Folder: \(model.meetingsFolderName)…") { model.chooseMeetingsFolder() }
            Divider()
            Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
        }
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit tinyMuesli") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// NSMenu draws `.badge` as a gray pill and can't color it. When a menu opens, the "Ongoing" badge
/// is swapped for a red pill drawn at the end of the item's title.
@MainActor
enum OngoingPill {
    static let label = "Ongoing"
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            // Posted on the main thread (queue: .main), where the menu lives.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                if let menu { restyle(menu) }
            }
        }
    }

    private static func restyle(_ menu: NSMenu) {
        let font = menu.font ?? NSFont.menuFont(ofSize: 0)
        for item in menu.items where item.badge?.stringValue == label {
            let title = NSMutableAttributedString(string: item.title + "  ", attributes: [.font: font])
            title.append(NSAttributedString(attachment: pill(font: font)))
            item.badge = nil
            item.attributedTitle = title
        }
    }

    private static func pill(font: NSFont) -> NSTextAttachment {
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize - 2, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = text.size()
        let size = NSSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Centre the pill on the title's capitals.
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return attachment
    }
}
