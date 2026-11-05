import AppKit
import MuesliCore
import SwiftUI

struct MuesliApp: App {
    @State private var model: AppModel
    @State private var updater: Updater

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _updater = State(initialValue: Updater { model.isBusy })
        PlainMenuBadges.install()
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
                        .badge(meeting.length.map { Text($0) })
                }
            }
        }
        Button("Open Meetings Folder") { model.openMeetingsFolder() }
        Button("Copy Prompt for Agent") { model.copyAgentPrompt() }

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

        Button("Quit Muesli") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// SwiftUI draws a menu item's `.badge` as a pill. We want plain gray text at the right edge, so
/// when a menu opens, each badge becomes a right-aligned tab in the item's title instead.
@MainActor
enum PlainMenuBadges {
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
        let badged = menu.items.compactMap { item in
            item.badge?.stringValue.flatMap { $0.isEmpty ? nil : (item, $0) }
        }
        guard !badged.isEmpty else { return }
        let items = badged.map(\.0), badges = badged.map(\.1)
        let font = menu.font ?? NSFont.menuFont(ofSize: 0)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let titles = items.map { $0.title }
        let tab = (titles.map(width).max() ?? 0) + 24 + (badges.map(width).max() ?? 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tab)]
        for (item, (title, badge)) in zip(items, zip(titles, badges)) {
            let text = NSMutableAttributedString(string: title + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
            text.append(NSAttributedString(string: badge, attributes: [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.badge = nil
            item.attributedTitle = text
        }
    }
}
