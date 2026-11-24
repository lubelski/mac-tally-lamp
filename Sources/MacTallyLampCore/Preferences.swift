import Foundation

/// A feature being tried, behind a switch in Settings, Experiments. Every experiment is off
/// until the owner turns it on, and may change or go. Kept in the app's preferences.
///
/// There are none yet. A new one is a case here with a key, a title, and a description, and
/// its four lines in `planning/decided.md` under Experiments.
public enum Experiment: CaseIterable, Sendable, Identifiable {
    public var id: String { key }

    public var key: String {
        switch self {}
    }

    public var title: String {
        switch self {}
    }

    public var description: String {
        switch self {}
    }

    public func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// The settings people change, as keys and defaults, so views and the app read them the same way.
public enum LampPreference {
    /// How long an agent may keep the screen while others wait, in minutes.
    public static let holdLimitMinutesKey = "HoldLimitMinutes"
    public static let holdLimitMinutesDefault = 10
    public static let holdLimitChoices = [5, 10, 15, 30]

    public static func holdLimit(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = defaults.object(forKey: holdLimitMinutesKey) as? Int ?? holdLimitMinutesDefault
        return TimeInterval(max(1, minutes) * 60)
    }

    /// Whether the app opens at login. Only the switch in Settings changes it.
    public static let openAtLoginKey = "OpenAtLogin"
}

/// The rules for updating the app, kept apart from Sparkle so they can be tested.
public enum AppUpdates {
    /// Whether a bundle with this Info.plist has a feed to update from. Only a release does.
    public static func hasFeed(_ info: [String: Any]?) -> Bool {
        guard let feed = info?["SUFeedURL"] as? String, let key = info?["SUPublicEDKey"] as? String else {
            return false
        }
        return !feed.isEmpty && !key.isEmpty
    }

    /// Whether the app may quit and relaunch into an update now. The claims live only in
    /// memory, so a relaunch would drop whoever has the screen and everyone waiting.
    public static func mayRelaunch(_ claims: ScreenClaims) -> Bool {
        claims.isIdle
    }
}
