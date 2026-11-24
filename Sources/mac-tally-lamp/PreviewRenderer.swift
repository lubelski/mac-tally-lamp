import AppKit
import MacTallyLampCore
import SwiftUI

/// `--render-previews <folder>`: draws each key view offscreen with sample sessions, writes PNG
/// files, and exits. It never shows a window, never takes focus, never opens the socket, and
/// never reads or writes the real data folder or preferences. The sessions, folders, and people
/// in it are stand-ins.
@MainActor
enum PreviewRenderer {
    static let argument = "--render-previews"

    static func render(to folder: URL) {
        let app = NSApplication.shared
        // No Dock icon, no menu bar, and no activation.
        app.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("Could not create \(folder.path): \(error.localizedDescription)")
            exit(1)
        }

        let suite = "dev.lubelski.mac-tally-lamp.preview"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let calendar = Calendar.current
        let ten = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        func at(_ minutes: Double) -> Date { ten.addingTimeInterval(minutes * 60) }

        var written: [URL] = []
        func save(_ name: String, _ image: NSBitmapImageRep?) {
            guard let image, let data = image.representation(using: .png, properties: [:]) else {
                print("Could not render \(name)")
                return
            }
            let url = folder.appending(path: "\(name).png")
            do {
                try data.write(to: url)
                written.append(url)
            } catch {
                print("Could not write \(url.path): \(error.localizedDescription)")
            }
        }
        let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        // The lamp, as it shows while an agent has the screen: alone, and with two waiting.
        for (look, appearance) in looks {
            let alone = Sample.service(at: ten, waiting: 0)
            save("lamp-alone-\(look)", window(
                LampOnBackdrop(status: alone.claims.status(for: nil), now: at(3)),
                size: CGSize(width: LampCard.width + 80, height: 300), now: at(3), defaults: defaults,
                appearance: appearance))
            let busy = Sample.service(at: ten, waiting: 2)
            save("lamp-with-line-\(look)", window(
                LampOnBackdrop(status: busy.claims.status(for: nil), now: at(4)),
                size: CGSize(width: LampCard.width + 80, height: 300), now: at(4), defaults: defaults,
                appearance: appearance))
        }

        // Settings, each section, with two agents waiting behind one that has the screen.
        let service = Sample.service(at: ten, waiting: 2)
        let controller = LampController(
            service: service, dataFolder: Sample.dataFolder, helperPath: Sample.helperPath, updater: .unavailable())
        for section in SettingsSection.allCases {
            defaults.set(section.rawValue, forKey: SettingsRootView.selectedSectionKey)
            for (look, appearance) in looks {
                save("settings-\(section.rawValue)-\(look)", window(
                    SettingsRootView(controller: controller),
                    size: SettingsRootView.size, now: at(4), defaults: defaults, appearance: appearance))
            }
        }

        // General as a release build shows it, with the Updates group.
        save("settings-general-release-build", window(
            GeneralSettingsView(updater: .unavailable(), showsUpdatesForPreview: true)
                .frame(width: SettingsRootView.size.width - SettingsRootView.sidebarWidth),
            size: CGSize(width: SettingsRootView.size.width - SettingsRootView.sidebarWidth, height: 300),
            now: at(0), defaults: defaults))

        for url in written { print(url.path) }
    }

    /// A view drawn in a window that is never put on screen.
    private static func window(
        _ view: some View, size: CGSize, now: Date, defaults: UserDefaults, appearance: NSAppearance.Name = .aqua
    ) -> NSBitmapImageRep? {
        let root = view
            .environment(\.frozenNow, now)
            .environment(\.isRenderingPreview, true)
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            // A real window draws its background behind the content. This one is never on
            // screen, so draw it here, or areas without a background come out transparent.
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        // Give SwiftUI a moment to lay out and fill the lists. The window stays off screen.
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        return rep
    }
}

/// The lamp over a stand-in desktop, so the glass has something behind it.
private struct LampOnBackdrop: View {
    let status: ScreenStatus
    let now: Date

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [Color(red: 0.24, green: 0.36, blue: 0.52), Color(red: 0.52, green: 0.38, blue: 0.46)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            LampCard(status: status, now: now, takeScreen: {})
                .padding(LampPanelController.margin * 2)
        }
    }
}

/// Stand-in sessions for previews. No real people, folders, or projects.
@MainActor
private enum Sample {
    static let dataFolder = URL(filePath: "/Users/rchen/Library/Application Support/mac-tally-lamp", directoryHint: .isDirectory)
    static let helperPath = "/Users/rchen/Applications/mac-tally-lamp.app/Contents/MacOS/mac-tally-lamp-mcp"

    /// `acme-web (wt-02)` has had the screen since `start`, and `waiting` others wait behind it.
    static func service(at start: Date, waiting: Int) -> LampService {
        let clock = Clock(start)
        let service = LampService(clock: { clock.now })
        let holder = service.connect(AgentIdentity(
            name: "acme-web (wt-02)", client: "claude-code 2.1.0", folder: "/Users/rchen/dev/acme-web/.wt/wt-02"))
        _ = service.handle(.request(purpose: "check that the Settings window draws", wait: true), from: holder)
        let others = [
            ("docs-site", "codex 0.9.2", "/Users/rchen/dev/docs-site", "screenshot the new landing page"),
            ("jlin-agent", "claude-code 2.1.0", "/Users/rchen/dev/jlin-agent", "click through the onboarding"),
        ]
        for (index, other) in others.prefix(waiting).enumerated() {
            clock.now = start.addingTimeInterval(Double(index + 1) * 60)
            let session = service.connect(AgentIdentity(name: other.0, client: other.1, folder: other.2))
            _ = service.handle(.request(purpose: other.3, wait: true), from: session)
        }
        // One connected session that is not asking for anything.
        _ = service.connect(AgentIdentity(name: "acme-api", client: "claude-code 2.1.0", folder: "/Users/rchen/dev/acme-api"))
        return service
    }

    /// A clock the sample moves by hand.
    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }
}
