import AppKit
import MacTallyLampCore
import SwiftUI

/// The lamp: a card in the bottom-right corner of the main screen that says which agent is
/// using the screen, for anyone who walks up to the Mac. It shows while an agent has the
/// screen and hides otherwise.
///
/// AppKit, because SwiftUI has no window that floats above other apps without taking focus.
/// The panel never becomes key or main, so showing it, or clicking its button, never takes
/// focus from the app the agent is driving.
@MainActor
final class LampPanelController {
    private var service: LampService?
    private var panel: LampPanel?

    /// The gap between the card and the edges of the screen's visible area.
    static let margin: CGFloat = 20

    func attach(to service: LampService) {
        self.service = service
        update()
    }

    /// Shows or hides the lamp to match who has the screen.
    func update() {
        guard let service else { return }
        if service.claims.holdingSession != nil {
            show(service)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func show(_ service: LampService) {
        let panel = self.panel ?? makePanel(service)
        self.panel = panel
        if let hosting = panel.contentView {
            hosting.layoutSubtreeIfNeeded()
            panel.setContentSize(hosting.fittingSize)
        }
        place(panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ service: LampService) -> LampPanel {
        let panel = LampPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: LampCard.width, height: 160)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        let hosting = NSHostingView(rootView: LampView(service: service))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        return panel
    }

    private func place(_ panel: NSPanel) {
        // The first screen is the one with the menu bar.
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin))
    }
}

/// A panel that never takes keyboard focus or becomes the main window.
final class LampPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The lamp's content, kept up to date by the service.
struct LampView: View {
    let service: LampService

    var body: some View {
        Ticking { now in
            LampCard(status: service.claims.status(for: nil), now: now) {
                service.claimForOperator()
            }
        }
    }
}
