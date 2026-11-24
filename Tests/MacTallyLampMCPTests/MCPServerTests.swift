import Foundation
import Testing
@testable import MacTallyLampCore
@testable import MacTallyLampMCP

/// Stands in for the socket: passes each message straight to a service, as one session.
struct ServiceLamp: LampConnecting {
    let service: LampService
    let session: SessionID

    func send(_ message: LampMessage) async throws -> LampReply {
        await MainActor.run { service.handle(message, from: session) }
    }

    func setClient(_ client: String?) async {
        await MainActor.run {
            var identity = service.claims.sessions[session] ?? AgentIdentity(name: "agent")
            identity.client = client
            _ = service.handle(.hello(identity), from: session)
        }
    }

    func setName(_ name: String) async {
        await MainActor.run {
            var identity = service.claims.sessions[session] ?? AgentIdentity(name: "agent")
            identity.name = name
            _ = service.handle(.hello(identity), from: session)
        }
    }
}

/// A lamp that is never there.
struct MissingLamp: LampConnecting {
    func send(_ message: LampMessage) async throws -> LampReply { throw LampUnavailable("Tally Lamp is not running.") }
    func setClient(_ client: String?) async {}
    func setName(_ name: String) async {}
}

/// Collects what the server writes to stdout.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [JSONValue] = []

    func append(_ line: String) {
        lock.withLock { lines.append(try! JSONValue.parse(line)) }
    }

    var all: [JSONValue] { lock.withLock { lines } }

    /// The response to request `id`, waiting up to five seconds for it.
    func response(_ id: Int) async throws -> JSONValue {
        for _ in 0..<500 {
            if let found = all.first(where: { $0["id"] == .number(Double(id)) }) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no response to request \(id)")
        return .null
    }
}

@MainActor
@Suite struct MCPServerTests {
    let service = LampService()
    let lines = Lines()

    func server(as name: String = "acme-web", lamp: LampConnecting? = nil) -> (MCPServer, SessionID) {
        let session = service.connect(AgentIdentity(name: name))
        let server = MCPServer(
            lamp: lamp ?? ServiceLamp(service: service, session: session), version: "1.0",
            output: { [lines] in lines.append($0) }, pollInterval: .milliseconds(10))
        return (server, session)
    }

    func call(_ server: MCPServer, id: Int, tool: String, _ arguments: JSONValue = [:]) async throws -> (text: String, isError: Bool) {
        let request: JSONValue = [
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
            "params": ["name": .string(tool), "arguments": arguments],
        ]
        await server.receive(request.line())
        let response = try await lines.response(id)
        let text = response["result"]?["content"].flatMap { if case .array(let items) = $0 { items.first } else { nil } }?["text"]?.string
        return (text ?? "", response["result"]?["isError"] == .bool(true))
    }

    @Test func initializeAgreesOnAVersionAndTellsTheRules() async throws {
        let (server, session) = server()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2.1.0"}}}"#)
        let response = try await lines.response(1)
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        #expect(response["result"]?["serverInfo"]?["name"] == "mac-tally-lamp")
        #expect(response["result"]?["instructions"]?.string?.contains("request_screen") == true)
        #expect(service.claims.sessions[session]?.client == "claude-code 2.1.0")

        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(try await lines.response(2)["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test func listsTheThreeTools() async throws {
        let (server, _) = server()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        guard case .array(let tools) = try await lines.response(1)["result"]?["tools"] else {
            Issue.record("no tools")
            return
        }
        #expect(tools.compactMap { $0["name"]?.string } == ["request_screen", "release_screen", "screen_status"])
    }

    @Test func unknownMethodsAreErrors() async throws {
        let (server, _) = server()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        #expect(try await lines.response(1)["error"]?["code"] == .number(-32601))
    }

    @Test func aFreeScreenIsGrantedAtOnce() async throws {
        let (server, session) = server()
        let result = try await call(server, id: 1, tool: "request_screen", ["purpose": "check Settings"])
        #expect(result.text.hasPrefix("You have the screen."))
        #expect(!result.isError)
        #expect(service.claims.holdingSession == session)
    }

    @Test func aWaitingAgentGetsTheScreenWhenItIsLetGo() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, session) = server()

        let request: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "request_screen", "arguments": ["purpose": "check Settings", "wait_seconds": 30]],
        ]
        await server.receive(request.line())
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.claims.position(of: session) == 1)
        service.disconnect(other)

        let response = try await lines.response(1)
        let text = response["result"]?["content"]?.firstText ?? ""
        // The wait was under a second, which the answer leaves out.
        #expect(text.hasPrefix("You have the screen. Do your work"))
        #expect(service.claims.holdingSession == session)
    }

    @Test func notWaitingLeavesTheAgentOutOfLine() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, _) = server()
        let result = try await call(server, id: 1, tool: "request_screen", ["purpose": "check", "wait_seconds": 0])
        #expect(result.text.contains("docs-site has the screen"))
        #expect(result.text.contains("you are not in line"))
        #expect(service.claims.waiting.isEmpty)
    }

    @Test func waitingTooLongLeavesTheLine() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, _) = server()
        let result = try await call(server, id: 1, tool: "request_screen", ["purpose": "check", "wait_seconds": 1])
        #expect(result.text.hasPrefix("You waited 1 s and did not get the screen."))
        #expect(service.claims.waiting.isEmpty)
    }

    @Test func aCancelledWaitLeavesTheLineAndGetsNoAnswer() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, session) = server()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"request_screen","arguments":{"purpose":"check"}}}"#)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.claims.position(of: session) == 1)

        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        await server.finishRunning()
        #expect(service.claims.position(of: session) == nil)
        #expect(lines.all.allSatisfy { $0["id"] != .number(1) })
    }

    @Test func removedFromTheLineSaysSo() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, session) = server()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"request_screen","arguments":{"purpose":"check"}}}"#)
        try await Task.sleep(for: .milliseconds(100))
        service.removeFromLine(session)
        let text = try await lines.response(1)["result"]?["content"]?.firstText ?? ""
        #expect(text.hasPrefix(Notice.removedByOperator.text))
        #expect(text.contains("You are out of the line"))
    }

    @Test func releasingSaysWhoHasItNext() async throws {
        let (server, _) = server()
        _ = try await call(server, id: 1, tool: "request_screen", ["purpose": "check"])
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let result = try await call(server, id: 2, tool: "release_screen")
        #expect(result.text == "You let go of the screen. docs-site has it now.")
        #expect(service.claims.holdingSession == other)
    }

    @Test func aGivenNameIsShown() async throws {
        let (server, session) = server()
        _ = try await call(server, id: 1, tool: "request_screen", ["purpose": "check", "name": "release checker"])
        #expect(service.claims.displayName(of: session) == "release checker")
    }

    @Test func statusDescribesTheLine() async throws {
        let other = service.connect(AgentIdentity(name: "docs-site"))
        _ = service.handle(.request(purpose: "screenshot", wait: true), from: other)
        let (server, _) = server()
        let result = try await call(server, id: 1, tool: "screen_status")
        #expect(result.text.hasPrefix("docs-site has the screen (\u{201C}screenshot\u{201D}), and has had it for"))
        #expect(result.text.hasSuffix("Nobody is waiting."))
    }

    @Test func withoutTheAppTheAgentIsToldToAsk() async throws {
        let (server, _) = server(lamp: MissingLamp())
        let result = try await call(server, id: 1, tool: "request_screen", ["purpose": "check"])
        #expect(result.isError)
        #expect(result.text.contains("ask the person at the Mac"))
    }
}

@Suite struct AppLauncherTests {
    @Test func findsTheAppAroundTheHelper() {
        let helper = URL(filePath: "/Users/rchen/Applications/mac-tally-lamp.app/Contents/MacOS/mac-tally-lamp-mcp")
        #expect(AppLauncher.containingApp(of: helper)?.path == "/Users/rchen/Applications/mac-tally-lamp.app")
        #expect(AppLauncher.containingApp(of: URL(filePath: "/tmp/build/debug/mac-tally-lamp-mcp")) == nil)
    }
}

extension JSONValue {
    /// The text of the first item in a tool result's `content`.
    var firstText: String? {
        if case .array(let items) = self { return items.first?["text"]?.string }
        return nil
    }
}
