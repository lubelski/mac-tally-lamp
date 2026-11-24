import Foundation

/// Who has the screen and who waits, as one session sees it. Sent to the MCP helper with every
/// reply, and drawn by the lamp and the menu.
public struct ScreenStatus: Codable, Sendable, Equatable {
    public struct Party: Codable, Sendable, Equatable {
        /// The agent's name, or `operatorName` for the person at the Mac.
        public var name: String
        public var isOperator: Bool
        /// What the agent said it will do on screen.
        public var purpose: String?
        /// When it got the screen, or when it started waiting.
        public var since: Date
        /// Whether this is the session the status was made for.
        public var isYou: Bool
        /// The agent's MCP client, such as `claude-code 2.1.0`.
        public var client: String?

        public init(
            name: String, isOperator: Bool, purpose: String?, since: Date, isYou: Bool, client: String? = nil
        ) {
            self.name = name
            self.isOperator = isOperator
            self.purpose = purpose
            self.since = since
            self.isYou = isYou
            self.client = client
        }
    }

    public static let operatorName = "the person at the Mac"

    public var holder: Party?
    public var waiting: [Party]
    /// When the holding agent's hold lapses, while someone waits.
    public var holdEnds: Date?

    public init(holder: Party?, waiting: [Party], holdEnds: Date?) {
        self.holder = holder
        self.waiting = waiting
        self.holdEnds = holdEnds
    }

    public var youHold: Bool { holder?.isYou == true }

    /// Your place in line, from 1, or nil when you are not waiting.
    public var yourPosition: Int? { waiting.firstIndex { $0.isYou }.map { $0 + 1 } }
}

/// A message from the MCP helper to the app, one JSON object per line.
public struct LampMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Says who the session is. Sent first on every connection, and again when it changes.
        case hello
        /// Asks for the screen, or renews a hold.
        case request
        /// Lets go of the screen, or stops waiting.
        case leave
        /// Asks who has the screen.
        case status
    }

    public var id: Int
    public var kind: Kind
    /// For `hello`.
    public var identity: AgentIdentity?
    /// For `request`: what the agent will do on screen.
    public var purpose: String?
    /// For `request`: join the line when someone else has the screen.
    public var wait: Bool?

    public init(id: Int = 0, kind: Kind, identity: AgentIdentity? = nil, purpose: String? = nil, wait: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.identity = identity
        self.purpose = purpose
        self.wait = wait
    }

    public static func hello(_ identity: AgentIdentity) -> LampMessage { LampMessage(kind: .hello, identity: identity) }
    public static func request(purpose: String, wait: Bool) -> LampMessage {
        LampMessage(kind: .request, purpose: purpose, wait: wait)
    }
    public static let leave = LampMessage(kind: .leave)
    public static let status = LampMessage(kind: .status)
}

/// The app's answer to one `LampMessage`, with the same `id`.
public struct LampReply: Codable, Sendable, Equatable {
    public var id: Int
    /// For `request`.
    public var outcome: RequestOutcome?
    public var status: ScreenStatus?
    /// Why the session lost the screen or its place since its last call.
    public var notice: Notice?
    public var error: String?

    public init(id: Int, outcome: RequestOutcome? = nil, status: ScreenStatus? = nil, notice: Notice? = nil, error: String? = nil) {
        self.id = id
        self.outcome = outcome
        self.status = status
        self.notice = notice
        self.error = error
    }
}

/// Turns messages into lines and back. Both ends use this, so the format has one definition.
public enum LampWire {
    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSON escapes newlines inside strings, so the output is one line.
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(line.utf8))
    }
}
