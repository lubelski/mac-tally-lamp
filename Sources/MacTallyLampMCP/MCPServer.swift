import Foundation
import MacTallyLampCore

/// The MCP server an agent starts: JSON-RPC 2.0, one message per line, over stdin and stdout.
///
/// It offers three tools, `request_screen`, `release_screen`, and `screen_status`, and passes
/// each to the running app over `lamp`. Each request runs as its own task, so an agent waiting
/// for the screen does not hold up its other calls, and a cancelled call stops waiting and
/// leaves the line.
public actor MCPServer {
    public typealias Output = @Sendable (String) -> Void

    /// The protocol versions this server speaks, newest first.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// How long `request_screen` waits when the agent does not say, and the most it may ask for.
    public static let defaultWait = 300
    public static let longestWait = 1800

    private let lamp: LampConnecting
    private let version: String
    private let output: Output
    private let pollInterval: Duration
    private let progressInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private var running: [JSONValue: Task<Void, Never>] = [:]

    public init(
        lamp: LampConnecting, version: String, output: @escaping Output,
        pollInterval: Duration = .seconds(1), progressInterval: TimeInterval = 10,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lamp = lamp
        self.version = version
        self.output = output
        self.pollInterval = pollInterval
        self.progressInterval = progressInterval
        self.clock = clock
    }

    /// Handles one line from the client.
    public func receive(_ line: String) {
        guard let message = try? JSONValue.parse(line), case .object = message else {
            send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        guard let method = message["method"]?.string else { return } // A response to us. We send no requests.
        let params = message["params"] ?? [:]
        guard let id = message["id"], id != .null else {
            notified(method, params: params)
            return
        }
        running[id] = Task { await self.respond(to: method, params: params, id: id) }
    }

    /// Waits for every request in progress, for tests.
    public func finishRunning() async {
        while let task = running.values.first {
            await task.value
        }
    }

    // MARK: Requests

    private func respond(to method: String, params: JSONValue, id: JSONValue) async {
        defer { running[id] = nil }
        let result: JSONValue
        switch method {
        case "initialize":
            result = await initialize(params)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(Self.tools)]
        case "tools/call":
            guard let called = await callTool(params) else { return } // Cancelled: no answer.
            result = called
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("Method not found: \(method)")]])
            return
        }
        guard !Task.isCancelled else { return }
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func notified(_ method: String, params: JSONValue) {
        if method == "notifications/cancelled", let id = params["requestId"] {
            running[id]?.cancel()
        }
    }

    private func initialize(_ params: JSONValue) async -> JSONValue {
        if let info = params["clientInfo"], let name = info["name"]?.string {
            await lamp.setClient([name, info["version"]?.string].compactMap(\.self).joined(separator: " "))
        }
        let asked = params["protocolVersion"]?.string ?? ""
        let chosen = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
        return [
            "protocolVersion": .string(chosen),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "mac-tally-lamp", "title": "Tally Lamp", "version": .string(version)],
            "instructions": .string(Self.instructions),
        ]
    }

    // MARK: Tools

    /// What the agent reads about the server as a whole, when it connects.
    public static let instructions = """
        This Mac's screen, keyboard, and mouse are shared by several agents and the person at the Mac. Tally Lamp keeps track of whose turn it is.
        - Call request_screen before anything that takes the screen or focus: clicking, typing, opening, activating, or moving apps and windows, and driving the interface with tools such as computer use or Peekaboo. Reading files, running commands that open nothing, and capturing the whole screen do not need it.
        - Do that work only while you have the screen. Call release_screen as soon as you finish, even if the work failed.
        - When someone else has the screen, wait in line or do other work first. Never use the screen while someone else has it.
        - While others wait, your hold lapses after a while. During long work, call request_screen again to renew it.
        """

    static let tools: [JSONValue] = [
        [
            "name": "request_screen",
            "title": "Request the screen",
            "description": "Ask for this Mac's screen, keyboard, and mouse before you click, type, open or bring forward an app or window, or do anything else that takes focus. If the screen is free you get it at once. If someone else has it, you wait in line for up to wait_seconds. Calling it while you have the screen renews your hold. Call release_screen as soon as you finish.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "purpose": [
                        "type": "string",
                        "description": "What you will do on screen, in a few words, such as \"check that the Settings window draws\". The person at the Mac sees it.",
                    ],
                    "wait_seconds": [
                        "type": "integer", "minimum": 0, "maximum": .number(Double(longestWait)),
                        "default": .number(Double(defaultWait)),
                        "description": "How long to wait in line when someone else has the screen. 0 asks without waiting.",
                    ],
                    "name": [
                        "type": "string",
                        "description": "How to show you. Leave it out to be shown by your project folder's name.",
                    ],
                ],
                "required": ["purpose"],
            ],
        ],
        [
            "name": "release_screen",
            "title": "Release the screen",
            "description": "Give the screen back, or leave the line if you are waiting. Call it as soon as you finish with the screen, even if your work failed.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "screen_status",
            "title": "Screen status",
            "description": "See who has this Mac's screen, who is waiting for it, and whether you have it. Changes nothing.",
            "inputSchema": ["type": "object", "properties": [:]],
            "annotations": ["readOnlyHint": true],
        ],
    ]

    /// The result of `tools/call`, or nil when the call was cancelled.
    private func callTool(_ params: JSONValue) async -> JSONValue? {
        let arguments = params["arguments"] ?? [:]
        do {
            switch params["name"]?.string {
            case "request_screen":
                return try await requestScreen(arguments, progressToken: params["_meta"]?["progressToken"])
                    .map { Self.text($0) }
            case "release_screen":
                return Self.text(try await releaseScreen())
            case "screen_status":
                let reply = try await lamp.send(.status)
                return Self.text(Self.prefix(reply.notice) + ScreenWords.status(reply.status ?? .empty, now: clock()))
            default:
                return Self.text("There is no tool named \(params["name"]?.string ?? "(none)").", isError: true)
            }
        } catch let error as LampUnavailable {
            return Self.text(ScreenWords.unavailable(error), isError: true)
        } catch {
            return Self.text("Tally Lamp failed: \(error.localizedDescription)", isError: true)
        }
    }

    /// Asks for the screen, and waits in line for it when the agent asked to. Nil when the call
    /// was cancelled while it waited.
    private func requestScreen(_ arguments: JSONValue, progressToken: JSONValue?) async throws -> String? {
        if let name = arguments["name"]?.string { await lamp.setName(name) }
        let purpose = arguments["purpose"]?.string ?? ""
        let wait = min(max(arguments["wait_seconds"]?.int ?? Self.defaultWait, 0), Self.longestWait)
        let started = clock()

        let first = try await lamp.send(.request(purpose: purpose, wait: wait > 0))
        var notices = Self.prefix(first.notice)
        var status = first.status ?? .empty
        switch first.outcome {
        case .granted: return notices + ScreenWords.granted(status, waited: nil, now: clock())
        case .renewed: return notices + ScreenWords.renewed(status, now: clock())
        case .busy, nil: return notices + ScreenWords.busy(status, now: clock())
        case .waiting: break
        }

        let deadline = started.addingTimeInterval(TimeInterval(wait))
        var lastProgress = started
        while true {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancelled. Leave the line, or let go if the screen came in the meantime,
                // since nobody will use it.
                _ = try? await lamp.send(.leave)
                return nil
            }
            let reply = try await lamp.send(.status)
            notices += Self.prefix(reply.notice)
            status = reply.status ?? .empty
            let now = clock()
            if status.youHold {
                return notices + ScreenWords.granted(status, waited: now.timeIntervalSince(started), now: now)
            }
            if status.yourPosition == nil {
                return notices + ScreenWords.leftLine(status, now: now)
            }
            if now >= deadline {
                let left = try await lamp.send(.leave)
                return notices + ScreenWords.timedOut(left.status ?? status, waited: now.timeIntervalSince(started), now: now)
            }
            if let progressToken, now.timeIntervalSince(lastProgress) >= progressInterval {
                lastProgress = now
                send([
                    "jsonrpc": "2.0", "method": "notifications/progress",
                    "params": [
                        "progressToken": progressToken,
                        "progress": .number(now.timeIntervalSince(started).rounded()),
                        "total": .number(Double(wait)),
                        "message": .string(ScreenWords.waitingProgress(status)),
                    ],
                ])
            }
        }
    }

    private func releaseScreen() async throws -> String {
        let before = try await lamp.send(.status)
        let after = try await lamp.send(.leave)
        let notices = Self.prefix(before.notice) + Self.prefix(after.notice)
        return notices + ScreenWords.released(before: before.status ?? .empty, after: after.status ?? .empty, now: clock())
    }

    // MARK: Output

    private func send(_ message: JSONValue) {
        output(message.line())
    }

    static func text(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private static func prefix(_ notice: Notice?) -> String {
        notice.map { $0.text + " " } ?? ""
    }
}

extension ScreenStatus {
    static let empty = ScreenStatus(holder: nil, waiting: [], holdEnds: nil)
}
