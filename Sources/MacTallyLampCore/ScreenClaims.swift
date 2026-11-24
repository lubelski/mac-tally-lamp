import Foundation

/// One connected agent session. The app numbers them in the order they connect.
public struct SessionID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "#\(rawValue)" }
}

/// Who has the screen.
public enum Holder: Sendable, Equatable {
    /// The person at the Mac. They claim it from the menu bar or the lamp and keep it until
    /// they let it go.
    case `operator`(since: Date)
    /// An agent session, for the purpose it gave. `renewedAt` is its last `request_screen`.
    case agent(SessionID, purpose: String, since: Date, renewedAt: Date)
}

/// An agent session waiting for the screen.
public struct Waiter: Sendable, Equatable {
    public let session: SessionID
    public var purpose: String
    public let since: Date
}

/// Why an agent lost the screen, or its place in line, without asking. The agent hears it once,
/// on its next call.
public enum Notice: String, Codable, Sendable, Equatable {
    case takenByOperator
    case skippedByOperator
    case removedByOperator
    case holdLapsed

    public var text: String {
        switch self {
        case .takenByOperator: "The person at the Mac took the screen from you."
        case .skippedByOperator: "The person at the Mac ended your turn with the screen."
        case .removedByOperator: "The person at the Mac took you out of the line."
        case .holdLapsed: "Your hold on the screen lapsed: others were waiting and you did not renew it in time."
        }
    }
}

/// What `request` did.
public enum RequestOutcome: String, Codable, Sendable, Equatable {
    /// The screen was free, and now the session has it.
    case granted
    /// The session already had it. Its hold limit starts over.
    case renewed
    /// Someone else has it, and the session is in line.
    case waiting
    /// Someone else has it, and the session asked not to wait.
    case busy
}

/// Who has the screen, who waits for it, and the rules that move it between them.
///
/// The rules:
/// - A free screen goes to the first session that asks.
/// - Anyone else who asks to wait joins the end of the line.
/// - When the holder lets go, disconnects, or loses it, the first in line gets it at once.
/// - The person at the Mac can take the screen at any time and keeps it until they let go.
///   The agent that had it is told, and must ask again.
/// - An agent's hold lapses `holdLimit` after its last renewal, but only while someone waits,
///   and never sooner than `holdLimit` after the first of them started waiting.
/// - Nobody waits while nobody holds the screen.
public struct ScreenClaims: Sendable, Equatable {
    public static let defaultHoldLimit: TimeInterval = 10 * 60

    public private(set) var sessions: [SessionID: AgentIdentity] = [:]
    public private(set) var holder: Holder?
    public private(set) var waiting: [Waiter] = []
    public var holdLimit: TimeInterval
    private var notices: [SessionID: Notice] = [:]
    private var nextID = 1

    public init(holdLimit: TimeInterval = ScreenClaims.defaultHoldLimit) {
        self.holdLimit = holdLimit
    }

    // MARK: Sessions

    public mutating func connect(_ identity: AgentIdentity) -> SessionID {
        let session = SessionID(nextID)
        nextID += 1
        sessions[session] = identity
        return session
    }

    public mutating func identify(_ session: SessionID, as identity: AgentIdentity) {
        guard sessions[session] != nil else { return }
        sessions[session] = identity
    }

    /// The session is gone: its helper quit, or the agent ended. It lets go of the screen and
    /// leaves the line.
    public mutating func disconnect(_ session: SessionID, now: Date) {
        leave(session, now: now)
        sessions[session] = nil
        notices[session] = nil
    }

    // MARK: Agents

    /// A session asks for the screen. Unknown sessions get `.busy` and change nothing.
    @discardableResult
    public mutating func request(_ session: SessionID, purpose: String, wait: Bool, now: Date) -> RequestOutcome {
        guard sessions[session] != nil else { return .busy }
        let purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        switch holder {
        case .agent(let id, let old, let since, _) where id == session:
            holder = .agent(id, purpose: purpose.isEmpty ? old : purpose, since: since, renewedAt: now)
            return .renewed
        case nil:
            holder = .agent(session, purpose: purpose, since: now, renewedAt: now)
            return .granted
        default:
            if let index = waiting.firstIndex(where: { $0.session == session }) {
                if !purpose.isEmpty { waiting[index].purpose = purpose }
                return .waiting
            }
            guard wait else { return .busy }
            waiting.append(Waiter(session: session, purpose: purpose, since: now))
            return .waiting
        }
    }

    /// The session lets go of the screen, or stops waiting for it.
    public mutating func leave(_ session: SessionID, now: Date) {
        waiting.removeAll { $0.session == session }
        if holdingSession == session {
            holder = nil
            promote(now: now)
        }
    }

    // MARK: The person at the Mac

    public mutating func operatorClaim(now: Date) {
        if case .operator = holder { return }
        if let session = holdingSession { notices[session] = .takenByOperator }
        holder = .operator(since: now)
    }

    public mutating func operatorRelease(now: Date) {
        guard case .operator = holder else { return }
        holder = nil
        promote(now: now)
    }

    /// Ends the holding agent's turn. The next in line gets the screen.
    public mutating func skipHolder(now: Date) {
        guard let session = holdingSession else { return }
        notices[session] = .skippedByOperator
        holder = nil
        promote(now: now)
    }

    public mutating func removeFromLine(_ session: SessionID) {
        guard waiting.contains(where: { $0.session == session }) else { return }
        waiting.removeAll { $0.session == session }
        notices[session] = .removedByOperator
    }

    // MARK: Time

    /// When the holding agent's hold lapses. Nil while nobody waits, or while the person at the
    /// Mac has the screen, since neither lapses then.
    public var holdEnds: Date? {
        guard case .agent(_, _, _, let renewedAt) = holder, let first = waiting.first else { return nil }
        return max(renewedAt, first.since).addingTimeInterval(holdLimit)
    }

    /// Ends the holding agent's turn if its hold has lapsed. Returns whether it did.
    @discardableResult
    public mutating func expireHold(now: Date) -> Bool {
        guard let ends = holdEnds, now >= ends, let session = holdingSession else { return false }
        notices[session] = .holdLapsed
        holder = nil
        promote(now: now)
        return true
    }

    // MARK: Reading

    public var holdingSession: SessionID? {
        if case .agent(let session, _, _, _) = holder { return session }
        return nil
    }

    /// The session's place in line, from 1. Nil when it is not waiting.
    public func position(of session: SessionID) -> Int? {
        waiting.firstIndex { $0.session == session }.map { $0 + 1 }
    }

    /// The session's name as people see it. Two sessions with the same name get their numbers.
    public func displayName(of session: SessionID) -> String {
        let name = sessions[session]?.name ?? AgentIdentity.unnamed
        let twins = sessions.values.filter { $0.name == name }.count
        return twins > 1 ? "\(name) \(session)" : name
    }

    /// Why the session lost the screen or its place, once. Taking it clears it.
    public mutating func takeNotice(for session: SessionID) -> Notice? {
        notices.removeValue(forKey: session)
    }

    /// Nobody holds or waits, so restarting the app would cut nobody off.
    public var isIdle: Bool { holder == nil && waiting.isEmpty }

    /// The state as one session sees it, or as the person at the Mac sees it when `session`
    /// is nil.
    public func status(for session: SessionID?) -> ScreenStatus {
        let holderParty: ScreenStatus.Party? = switch holder {
        case nil: nil
        case .operator(let since):
            ScreenStatus.Party(name: ScreenStatus.operatorName, isOperator: true, purpose: nil, since: since, isYou: false)
        case .agent(let id, let purpose, let since, _):
            ScreenStatus.Party(
                name: displayName(of: id), isOperator: false, purpose: purpose.isEmpty ? nil : purpose,
                since: since, isYou: id == session, client: sessions[id]?.client)
        }
        let line = waiting.map {
            ScreenStatus.Party(
                name: displayName(of: $0.session), isOperator: false, purpose: $0.purpose.isEmpty ? nil : $0.purpose,
                since: $0.since, isYou: $0.session == session, client: sessions[$0.session]?.client)
        }
        return ScreenStatus(holder: holderParty, waiting: line, holdEnds: holdEnds)
    }

    // MARK: Private

    private mutating func promote(now: Date) {
        guard holder == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        holder = .agent(next.session, purpose: next.purpose, since: now, renewedAt: now)
    }
}
