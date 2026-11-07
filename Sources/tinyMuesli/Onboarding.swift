import AppKit
import SwiftUI
import TinyMuesliCore

/// The welcome window: how tinyMuesli works, the permissions it needs, and which apps to record
/// without asking. Shows on first launch; "Welcome Guide…" in the menu opens it again.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let permissions: Permissions
    private var window: NSWindow?

    init(model: AppModel, permissions: Permissions) {
        self.model = model
        self.permissions = permissions
    }

    /// On first launch. Someone upgrading from a version without onboarding already has meetings and
    /// permissions; for them the menu shows anything that's missing.
    func showIfNeeded() {
        guard !Settings.completedOnboarding else { return }
        if !model.store.allMeetings().isEmpty {
            Settings.completedOnboarding = true
            return
        }
        show()
    }

    func show() {
        if window == nil {
            let view = OnboardingView(model: model, permissions: permissions) { [weak self] in self?.window?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to tinyMuesli"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // A menu bar app isn't frontmost, so the window would open behind others.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Activation is refused if the app wasn't opened by the user (e.g. at login): show it anyway.
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing early counts too: the menu shows what's still missing and can reopen this.
        Settings.completedOnboarding = true
        window = nil
    }
}

private struct OnboardingView: View {
    let model: AppModel
    let permissions: Permissions
    let finish: () -> Void

    enum Step: Int, CaseIterable {
        case welcome, permissions, apps, ready
    }

    @State private var step = Step.welcome
    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .frame(width: 560, height: 580)
    }

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: WelcomePage(meetingsFolder: model.meetingsFolderName)
        case .permissions: PermissionsPage(permissions: permissions)
        case .apps: AppsPage(model: model)
        case .ready: ReadyPage(model: model)
        }
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            HStack {
                if step != .welcome {
                    Button("Back") { go(by: -1) }
                        .controlSize(.large)
                }
                Spacer()
                Button(nextTitle) {
                    if step == .ready { finish() } else { go(by: 1) }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var nextTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .permissions: permissions.allGranted ? "Continue" : "Skip for Now"
        case .apps: "Continue"
        case .ready: "Done"
        }
    }

    private func go(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        forward = offset > 0
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }
}

// MARK: - Pages

/// Big symbol, title and subtitle at the top of each page.
private struct PageHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.bottom, 4)
            Text(title)
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 44)
        .padding(.bottom, 24)
        .padding(.horizontal, 40)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct WelcomePage: View {
    let meetingsFolder: String

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "waveform", title: "Welcome to tinyMuesli",
                       subtitle: "Notes from every meeting, so you remember what was said.")
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "bell.and.waveform", title: "Notices your meetings",
                        text: "When Zoom, Teams or another meeting app starts using your microphone, tinyMuesli asks whether to record.")
                Feature(symbol: "lock.fill", title: "Transcribes on your Mac",
                        text: "You and the other participants are recorded separately and transcribed on-device. Nothing leaves your Mac.")
                Feature(symbol: "doc.text", title: "Plain files you own",
                        text: "Each meeting becomes a Markdown transcript in \(meetingsFolder), ready for you or your AI agent.")
            }
            .padding(.horizontal, 56)
        }
    }

    private struct Feature: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PermissionsPage: View {
    let permissions: Permissions

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "hand.raised.fill", title: "A few permissions",
                       subtitle: "tinyMuesli only uses these while it's recording a meeting.")
            VStack(spacing: 10) {
                ForEach(Permissions.Kind.allCases) { kind in
                    PermissionRow(kind: kind, permissions: permissions)
                }
            }
            .padding(.horizontal, 40)
        }
        // Pick up changes made in System Settings while this page is open.
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let permissions: Permissions

    var body: some View {
        let state = permissions.state(kind)
        Card {
            HStack(spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(detail(state))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switch state {
                case .granted:
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                case .notDetermined:
                    Button("Allow") { Task { await permissions.request(kind) } }
                        .buttonStyle(.borderedProminent)
                case .denied, .unknown:
                    Button("Open Settings…") { permissions.openSettings(kind) }
                }
            }
        }
    }

    private func detail(_ state: Permissions.State) -> String {
        switch state {
        case .denied:
            "\(kind.purpose) Turn on tinyMuesli in System Settings."
        case .granted where kind == .notifications && permissions.notificationsAreTemporary:
            "\(kind.purpose) Tip: choose Persistent in System Settings so prompts stay until you answer."
        default:
            kind.purpose
        }
    }
}

private struct AppsPage: View {
    let model: AppModel

    /// Meeting apps on this Mac, with their icons.
    private let installed: [(app: MeetingApp, icon: NSImage)] = MeetingApps.known.compactMap { app in
        let url = ([app.id] + app.bundleIDs).lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        return url.map { (app, NSWorkspace.shared.icon(forFile: $0.path)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "record.circle", title: "Always record",
                       subtitle: "Pick apps to record without asking. For the others, tinyMuesli sends a notification first.")
            if installed.isEmpty {
                Card {
                    Text("No meeting apps found. When one uses your microphone, the notification can set it to always record.")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        group("Meeting apps", apps: installed.filter { $0.app.kind == .native })
                        group("Browsers", note: "Records whenever a website uses the mic, not only meetings.",
                              apps: installed.filter { $0.app.kind == .browser })
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, note: String? = nil, apps: [(app: MeetingApp, icon: NSImage)]) -> some View {
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Card {
                    VStack(spacing: 10) {
                        ForEach(Array(apps.enumerated()), id: \.element.app.id) { index, entry in
                            if index > 0 { Divider() }
                            HStack(spacing: 10) {
                                Image(nsImage: entry.icon).resizable().frame(width: 26, height: 26)
                                Text(entry.app.name)
                                Spacer()
                                Toggle(entry.app.name, isOn: Binding(
                                    get: { model.alwaysRecord.contains(entry.app.id) },
                                    set: { model.setAlwaysRecord(entry.app.id, $0) }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ReadyPage: View {
    let model: AppModel
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "checkmark", title: "You're all set",
                       subtitle: "tinyMuesli lives in your menu bar and waits for your next meeting.")
            VStack(spacing: 10) {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "menubar.rectangle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find it in the menu bar").font(.headline)
                            Text("Click \(Image(systemName: "waveform")) to start a recording, open recent meetings or change settings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            Image(systemName: "power")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open at Login").font(.headline)
                                Text("So tinyMuesli is always there to notice a meeting.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { enabled in
                                loginError = LoginItem.set(enabled)
                                openAtLogin = LoginItem.isEnabled
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                        if let loginError {
                            Text(loginError).font(.callout).foregroundStyle(.red)
                        }
                    }
                }
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ask your agent").font(.headline)
                            Text("Add to Claude Desktop or Copy Prompt for Agent in the menu let an AI agent search your meetings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 40)
        }
    }
}
