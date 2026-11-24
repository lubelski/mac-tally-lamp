import Foundation
import MacTallyLampCore

/// The sentences the tools answer with. An agent reads them, so they say plainly who has the
/// screen and what the agent should do next.
public enum ScreenWords {
    /// Who has the screen, who waits, and when a hold lapses.
    public static func status(_ status: ScreenStatus, now: Date) -> String {
        var sentences: [String] = []
        if let holder = status.holder {
            let length = TimeFormat.duration(now.timeIntervalSince(holder.since))
            if holder.isYou {
                sentences.append("You have the screen\(purpose(holder)), and have had it for \(length).")
            } else {
                sentences.append("\(capitalized(holder.name)) has the screen\(purpose(holder)), and has had it for \(length).")
            }
        } else {
            sentences.append("The screen is free.")
        }
        sentences.append(line(status))
        if let ends = status.holdEnds, let holder = status.holder {
            let left = TimeFormat.duration(ends.timeIntervalSince(now))
            if holder.isYou {
                sentences.append("Others are waiting, so your hold lapses in \(left) unless you call request_screen again to renew it.")
            } else {
                sentences.append("Others are waiting, so its hold lapses in \(left) unless it renews.")
            }
        }
        return sentences.joined(separator: " ")
    }

    public static func granted(_ status: ScreenStatus, waited: TimeInterval?, now: Date) -> String {
        var text = "You have the screen"
        if let waited, waited >= 1 { text += ", after waiting \(TimeFormat.duration(waited))" }
        text += ". Do your work on screen, then call release_screen right away, even if the work fails."
        return text + " " + line(status) + lapse(status, now: now)
    }

    public static func renewed(_ status: ScreenStatus, now: Date) -> String {
        "You still have the screen, and your time starts over. " + line(status) + lapse(status, now: now)
    }

    /// Someone else has the screen, and the agent asked not to wait.
    public static func busy(_ status: ScreenStatus, now: Date) -> String {
        Self.status(status, now: now)
            + " You did not ask to wait, so you are not in line. Do not use the screen. Call request_screen with wait_seconds when you need it, or do other work first."
    }

    public static func timedOut(_ status: ScreenStatus, waited: TimeInterval, now: Date) -> String {
        "You waited \(TimeFormat.duration(waited)) and did not get the screen. "
            + Self.status(status, now: now)
            + " You are out of the line now. Do not use the screen. Call request_screen again to wait longer, or do other work first."
    }

    /// The agent was waiting and is not any more, without getting the screen.
    public static func leftLine(_ status: ScreenStatus, now: Date) -> String {
        "You are out of the line, and do not have the screen. " + Self.status(status, now: now)
            + " Do not use the screen. Call request_screen again when you need it."
    }

    public static func released(before: ScreenStatus, after: ScreenStatus, now: Date) -> String {
        if before.youHold {
            if let next = after.holder {
                return "You let go of the screen. \(capitalized(next.name)) has it now."
            }
            return "You let go of the screen. It is free."
        }
        if before.yourPosition != nil {
            return "You left the line. " + status(after, now: now)
        }
        return "You did not have the screen or a place in line. " + status(after, now: now)
    }

    /// What progress notifications say while an agent waits.
    public static func waitingProgress(_ status: ScreenStatus) -> String {
        let place = status.yourPosition.map { "Number \($0) in line." } ?? "In line."
        guard let holder = status.holder else { return place }
        return place + " \(capitalized(holder.name)) has the screen."
    }

    public static func unavailable(_ error: LampUnavailable) -> String {
        "\(error.reason) Nobody is keeping track of who uses this Mac's screen, so ask the person at the Mac before you use it."
    }

    // MARK: Pieces

    private static func line(_ status: ScreenStatus) -> String {
        guard !status.waiting.isEmpty else { return "Nobody is waiting." }
        let names = status.waiting.enumerated().map { index, party in
            "\(index + 1). \(party.isYou ? "you" : party.name)\(purpose(party))"
        }
        return "Waiting, in order: \(names.joined(separator: ", "))."
    }

    private static func lapse(_ status: ScreenStatus, now: Date) -> String {
        guard status.youHold, let ends = status.holdEnds else { return "" }
        return " Your hold lapses in \(TimeFormat.duration(ends.timeIntervalSince(now))) unless you call request_screen again to renew it."
    }

    private static func purpose(_ party: ScreenStatus.Party) -> String {
        guard let purpose = party.purpose, !purpose.isEmpty else { return "" }
        return " (\u{201C}\(purpose)\u{201D})"
    }

    private static func capitalized(_ name: String) -> String {
        guard let first = name.first, first.isLowercase, name == ScreenStatus.operatorName else { return name }
        return first.uppercased() + name.dropFirst()
    }
}
