import AppKit
import MacTallyLampCore
import ServiceManagement
import SwiftUI

/// The sections of the Settings window, in sidebar order.
///
/// Debugging is always last and Experiments just above it. A new section goes above
/// Experiments, with its view in `SettingsRootView.detail`.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case agents
    case experiments
    case debugging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .agents: "Agents"
        case .experiments: "Experiments"
        case .debugging: "Debugging"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .agents: "person.2.wave.2"
        case .experiments: "flask"
        case .debugging: "ladybug"
        }
    }
}

/// The Settings window's content: a fixed-width sidebar of sections, and the section beside it.
struct SettingsRootView: View {
    static let sidebarWidth: CGFloat = 180
    static let size = CGSize(width: 720, height: 560)
    static let selectedSectionKey = "SettingsSelectedSection"

    let controller: LampController
    @AppStorage(Self.selectedSectionKey) private var section: SettingsSection = .general
    @Environment(\.isRenderingPreview) private var rendering

    var body: some View {
        // A plain row rather than a split view, so the sidebar keeps its width: it cannot be
        // dragged or collapsed, and there is no sidebar button.
        HStack(spacing: 0) {
            List(selection: Binding<SettingsSection?>(
                get: { rendering ? nil : section },
                set: { if let new = $0 { section = new } }
            )) {
                ForEach(SettingsSection.allCases) { section in
                    // The sidebar draws the selected row's title heavier, which widens it. A
                    // weight on the title's own Text overrides that, so the row keeps one
                    // weight across hover and selection.
                    Label {
                        Text(section.title).fontWeight(.regular)
                    } icon: {
                        Image(systemName: section.symbolName)
                    }
                    .tag(section)
                    .previewSelection(self.section == section, rendering: rendering)
                }
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)
            Divider()
            detail
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .standardTitleBar()
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .general: GeneralSettingsView(updater: controller.updater)
        case .agents: AgentsSettingsView(service: controller.service, helperPath: controller.helperPath)
        case .experiments: ExperimentsSettingsView()
        case .debugging: DebuggingSettingsView(service: controller.service, dataFolder: controller.dataFolder)
        }
    }
}

struct GeneralSettingsView: View {
    let updater: AppUpdater
    /// Shows the Updates group as a release build would, for `--render-previews`.
    var showsUpdatesForPreview = false
    @State private var updatesAutomatically = false
    @AppStorage(LampPreference.openAtLoginKey) private var openAtLogin = false
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $openAtLogin) {
                    Text("Open at login")
                    if let loginProblem {
                        Text(loginProblem)
                    } else {
                        Text("Tally Lamp starts when you log in, so agents can reach it from the first session.")
                    }
                }
                // Only the person flipping the switch registers or removes the login item.
                .onChange(of: openAtLogin) { _, on in applyOpenAtLogin(on) }
            }
            if updater.isAvailable || showsUpdatesForPreview {
                Section {
                    Toggle(isOn: Binding(
                        get: { updatesAutomatically },
                        set: {
                            updatesAutomatically = $0
                            updater.updatesAutomatically = $0
                        })) {
                        Text("Update automatically")
                        Text("Checks about once a day and installs a newer release when nobody has the screen or is waiting for it. Check for Updates is also in the menu bar menu.")
                    }
                    HStack {
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheck)
                    }
                } header: {
                    Text("Updates")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { updatesAutomatically = showsUpdatesForPreview || updater.updatesAutomatically }
    }

    private func applyOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginProblem = SMAppService.mainApp.status == .requiresApproval
                ? "Allow it in System Settings, General, Login Items."
                : nil
        } catch {
            loginProblem = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}

/// How to connect an agent, how long an agent may keep the screen, and who is connected.
struct AgentsSettingsView: View {
    let service: LampService
    let helperPath: String
    @AppStorage(LampPreference.holdLimitMinutesKey) private var holdLimitMinutes = LampPreference.holdLimitMinutesDefault

    private var claudeCommand: String {
        "claude mcp add --scope user tally-lamp -- \(Self.shellQuoted(helperPath))"
    }

    private var serverJSON: String {
        """
        "tally-lamp": { "command": "\(helperPath)" }
        """
    }

    var body: some View {
        Form {
            Section {
                Text("An agent reaches Tally Lamp through its MCP server. Add it once per agent, and every new session can ask for the screen, wait its turn, and give it back.")
                    .foregroundStyle(.secondary)
                CopyableSnippet(title: "Claude Code", text: claudeCommand)
                CopyableSnippet(title: "Other agents, in their mcpServers settings", text: serverJSON)
            } header: {
                Text("Connect an agent")
            }
            Section {
                Picker(selection: $holdLimitMinutes) {
                    ForEach(LampPreference.holdLimitChoices, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                } label: {
                    Text("An agent keeps the screen")
                    Text("While others wait. An agent renews its time by asking again. With nobody waiting, it keeps the screen until it lets go.")
                }
                .onChange(of: holdLimitMinutes) { _, minutes in
                    service.holdLimit = TimeInterval(minutes * 60)
                }
            }
            Section {
                let claims = service.claims
                if claims.sessions.isEmpty {
                    Text("No agent sessions are connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(claims.sessions.keys.sorted(), id: \.self) { session in
                        SessionRow(claims: claims, session: session)
                    }
                }
            } header: {
                Text("Connected now")
            }
        }
        .formStyle(.grouped)
    }

    static func shellQuoted(_ path: String) -> String {
        path.contains(where: { " '\"$\\".contains($0) }) ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
    }
}

private struct SessionRow: View {
    let claims: ScreenClaims
    let session: SessionID

    var body: some View {
        let identity = claims.sessions[session]
        LabeledContent {
            Text(role).foregroundStyle(.secondary)
        } label: {
            Text(claims.displayName(of: session))
            Text([identity?.client, identity?.folder].compactMap(\.self).joined(separator: " · "))
        }
    }

    private var role: String {
        if claims.holdingSession == session { return "Has the screen" }
        if let position = claims.position(of: session) { return "Waiting, number \(position)" }
        return "Connected"
    }
}

/// A line of text to copy, such as a command, with a button that copies it.
private struct CopyableSnippet: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        }
    }
}

/// Features being tried, each a switch, off until the owner turns it on. See `Experiment`.
///
/// There are none yet, so this says so. With the first one, list `Experiment.allCases` here with
/// a toggle each, as `meeting-agenda-clock`'s `ExperimentsSettingsView` does. (A list of an empty
/// enum's cases compiles to code that never runs, which the compiler warns about.)
struct ExperimentsSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("Nothing is being tried right now.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Features being tried. They may change or go.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .formStyle(.grouped)
    }
}

struct DebuggingSettingsView: View {
    let service: LampService
    let dataFolder: URL
    private let build = BuildInfo.current()

    var body: some View {
        Form {
            Section("Socket") {
                switch service.serving {
                case .serving(let path):
                    LabeledContent("Listening on") {
                        Text(path).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                case .failed(let reason):
                    LabeledContent("Not listening") {
                        Text(reason).multilineTextAlignment(.trailing)
                    }
                case .stopped:
                    LabeledContent("Not listening", value: "Stopped")
                }
                LabeledContent("Sessions connected", value: "\(service.claims.sessions.count)")
            }
            Section("Data") {
                LabeledContent("Data folder") {
                    Text(dataFolder.path)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dataFolder])
                    }
                }
            }
            Section("Build") {
                LabeledContent("Version", value: "\(build.version) (\(build.build))")
                LabeledContent("Commit", value: build.commit)
                LabeledContent("Signing") {
                    Text(build.signing).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}
