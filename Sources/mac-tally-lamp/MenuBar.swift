import AppKit
import MacTallyLampCore
import SwiftUI

/// The menu bar icon: a bulb, lit while an agent has the screen, a person while you have it,
/// and the number waiting beside it. A slashed bulb means agents cannot reach the app.
struct MenuBarLabel: View {
    let service: LampService

    var body: some View {
        let claims = service.claims
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(claims, serving: service.serving))
            if !claims.waiting.isEmpty {
                Text("\(claims.waiting.count)").monospacedDigit()
            }
        }
        .accessibilityLabel(Self.description(claims, serving: service.serving))
        .help(Self.description(claims, serving: service.serving))
    }

    static func symbol(_ claims: ScreenClaims, serving: LampService.Serving) -> String {
        if case .failed = serving { return "lightbulb.slash" }
        switch claims.holder {
        case nil: return "lightbulb"
        case .operator: return "person.fill"
        case .agent: return "lightbulb.max.fill"
        }
    }

    static func description(_ claims: ScreenClaims, serving: LampService.Serving) -> String {
        if case .failed = serving { return "Tally Lamp: agents cannot reach it" }
        let waiting = claims.waiting.isEmpty ? "" : ", \(claims.waiting.count) waiting"
        switch claims.holder {
        case nil: return "Tally Lamp: the screen is free"
        case .operator: return "Tally Lamp: you have the screen\(waiting)"
        case .agent(let session, _, _, _): return "Tally Lamp: \(claims.displayName(of: session)) has the screen\(waiting)"
        }
    }
}

/// The menu bar item's menu: who has the screen, who waits, and the controls for the person
/// at the Mac.
struct MenuBarMenu: View {
    let controller: LampController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let service = controller.service
        let claims = service.claims
        let now = service.now

        switch claims.holder {
        case nil:
            Text("The screen is free")
        case .operator(let since):
            Text("You have the screen")
            Text("For \(TimeFormat.duration(now.timeIntervalSince(since)))")
        case .agent(let session, let purpose, let since, _):
            Text("\(claims.displayName(of: session)) has the screen")
            Text(purpose.isEmpty
                ? "For \(TimeFormat.duration(now.timeIntervalSince(since)))"
                : "\(purpose) · \(TimeFormat.duration(now.timeIntervalSince(since)))")
        }

        if !claims.waiting.isEmpty {
            Divider()
            Text("Waiting")
            ForEach(Array(claims.waiting.enumerated()), id: \.element.session) { index, waiter in
                Menu("\(index + 1). \(claims.displayName(of: waiter.session))") {
                    if !waiter.purpose.isEmpty { Text(waiter.purpose) }
                    Text("Waiting \(TimeFormat.duration(now.timeIntervalSince(waiter.since)))")
                    Divider()
                    Button("Remove from Line") { service.removeFromLine(waiter.session) }
                }
            }
        }

        Divider()
        switch claims.holder {
        case nil:
            Button("Claim the Screen") { service.claimForOperator() }
        case .operator:
            Button("Release the Screen") { service.releaseForOperator() }
        case .agent(let session, _, _, _):
            Button("Take the Screen") { service.claimForOperator() }
            Button("End \(claims.displayName(of: session))’s Turn") { service.skipHolder() }
        }

        if case .failed(let reason) = service.serving {
            Divider()
            Text("Agents cannot reach Tally Lamp")
            Text(reason)
        }

        Divider()
        if controller.updater.isAvailable {
            Button("Check for Updates…") {
                NSApp.activate()
                controller.updater.checkForUpdates()
            }
            .disabled(!controller.updater.canCheck)
        }
        Button("Settings…") {
            // A menu bar app is not active, and Settings would open behind the app in front.
            // The person asked for the window, so bring the app forward.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Tally Lamp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
