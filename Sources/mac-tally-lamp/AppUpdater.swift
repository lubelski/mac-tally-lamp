import Foundation
import MacTallyLampCore
import Sparkle

/// Keeps the app up to date with Sparkle. The only file that imports Sparkle.
///
/// Only a release build updates itself. `scripts/release.sh` writes the feed address and the
/// public signing key into Info.plist. A build without them, such as one from
/// `scripts/bundle.sh` alone, has no updater, so a development copy is never replaced.
@MainActor
final class AppUpdater {
    /// Whether this build can update itself.
    let isAvailable: Bool

    private let controller: SPUStandardUpdaterController?
    private let delegate: Delegate

    /// `claims` says who has the screen and who waits, to decide whether the app may quit and
    /// relaunch now.
    init(info: [String: Any]? = Bundle.main.infoDictionary, claims: @escaping @MainActor () -> ScreenClaims) {
        delegate = Delegate(claims: claims)
        guard AppUpdates.hasFeed(info) else {
            isAvailable = false
            controller = nil
            return
        }
        isAvailable = true
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    /// A build with no feed, for previews.
    static func unavailable() -> AppUpdater {
        AppUpdater(info: nil, claims: { ScreenClaims() })
    }

    /// False while a check is already running.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Whether Sparkle looks for, downloads, and installs updates without asking.
    var updatesAutomatically: Bool {
        get {
            guard let updater = controller?.updater else { return false }
            return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Checks now and shows Sparkle's own windows with the result.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Installs an update that was held back because someone had the screen or was waiting.
    /// Called after every change to the claims.
    func installPendingUpdate() {
        delegate.installPendingUpdate()
    }

    private final class Delegate: NSObject, SPUUpdaterDelegate {
        private let claims: @MainActor () -> ScreenClaims
        private var pendingInstall: (() -> Void)?

        init(claims: @escaping @MainActor () -> ScreenClaims) {
            self.claims = claims
        }

        /// Sparkle normally installs a downloaded update when the app quits. A menu bar app
        /// stays open for weeks, so install and relaunch as soon as the update is ready. The
        /// claims live only in memory, so while anyone has the screen or waits, the install
        /// waits until nobody does.
        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
        ) -> Bool {
            // Sparkle calls its delegate on the main thread.
            MainActor.assumeIsolated {
                if AppUpdates.mayRelaunch(claims()) {
                    immediateInstallHandler()
                } else {
                    pendingInstall = immediateInstallHandler
                }
            }
            return true
        }

        @MainActor
        func installPendingUpdate() {
            guard let install = pendingInstall, AppUpdates.mayRelaunch(claims()) else { return }
            pendingInstall = nil
            install()
        }
    }
}
