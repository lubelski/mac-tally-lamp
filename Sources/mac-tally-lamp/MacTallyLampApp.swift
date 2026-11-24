import AppKit
import MacTallyLampCore
import SwiftUI

/// The app's scenes: the menu bar item and Settings. The lamp itself is an AppKit panel that
/// `LampController` shows while an agent has the screen. Started from `main.swift`, which
/// handles `--render-previews` first.
struct MacTallyLampApp: App {
    @State private var controller = LampController.live()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(controller: controller)
        } label: {
            MenuBarLabel(service: controller.service)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsRootView(controller: controller)
        }
    }
}

/// Owns the running parts: the claims and their socket, the lamp's panel, and the updater.
@MainActor
@Observable
final class LampController {
    let service: LampService
    let updater: AppUpdater
    let dataFolder: URL
    /// The MCP helper agents start, for the instructions in Settings.
    let helperPath: String
    @ObservationIgnored private let panel = LampPanelController()

    init(service: LampService, dataFolder: URL, helperPath: String, updater: AppUpdater) {
        self.service = service
        self.dataFolder = dataFolder
        self.helperPath = helperPath
        self.updater = updater
    }

    /// The app as it runs: serving the socket in the data folder, with the lamp showing
    /// whenever an agent has the screen.
    static func live() -> LampController {
        let service = LampService(holdLimit: LampPreference.holdLimit())
        let controller = LampController(
            service: service,
            dataFolder: AppPaths.dataFolder(),
            helperPath: helperPath(in: Bundle.main),
            updater: AppUpdater(claims: { service.claims }))
        service.onChange = { [weak controller] in controller?.changed() }
        controller.panel.attach(to: service)
        service.start(socket: AppPaths.socket(in: controller.dataFolder))
        // Remove the socket file on the way out, so a helper does not find a dead one.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { service.stop() }
        }
        return controller
    }

    /// The helper inside this app's bundle. Outside a bundle, such as in a preview, where a
    /// copy installed in `~/Applications` would have it.
    static func helperPath(in bundle: Bundle) -> String {
        let app = bundle.bundleURL.pathExtension == "app"
            ? bundle.bundleURL
            : URL.homeDirectory.appending(path: "Applications/mac-tally-lamp.app", directoryHint: .isDirectory)
        return app.appending(path: "Contents/MacOS/\(AppPaths.helperName)").path
    }

    private func changed() {
        panel.update()
        updater.installPendingUpdate()
    }
}
