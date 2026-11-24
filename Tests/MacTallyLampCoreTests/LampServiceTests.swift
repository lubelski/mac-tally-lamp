import Foundation
import Testing
@testable import MacTallyLampCore

/// The service over a real socket: two helpers connect, one gets the screen, and the other gets
/// it when the first one's connection closes.
@MainActor
@Suite(.serialized) struct LampServiceTests {
    /// A short socket path in the temporary folder. macOS allows about 100 bytes.
    func socketPath() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "mtl-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            .appending(path: "lamp.sock")
    }

    /// A helper's end of the socket, used off the main actor so the service can answer.
    actor Helper {
        let client: LineSocketClient
        var nextID = 1

        init(path: String) throws {
            client = try LineSocketClient(path: path, timeout: 5)
        }

        func send(_ message: LampMessage) throws -> LampReply {
            var message = message
            message.id = nextID
            nextID += 1
            try client.send(LampWire.encode(message))
            return try LampWire.decode(LampReply.self, from: client.readLine())
        }

        func close() { client.close() }
    }

    /// Waits for the main queue to deliver what the socket received.
    func settle(until condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func theScreenPassesWhenAHelperGoesAway() async throws {
        let socket = socketPath()
        let service = LampService()
        service.start(socket: socket)
        defer {
            service.stop()
            try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        }
        #expect(service.serving == .serving(path: socket.path))

        let web = try Helper(path: socket.path)
        let docs = try Helper(path: socket.path)
        _ = try await web.send(.hello(AgentIdentity(name: "acme-web")))
        _ = try await docs.send(.hello(AgentIdentity(name: "docs-site")))

        let first = try await web.send(.request(purpose: "check Settings", wait: true))
        #expect(first.outcome == .granted)
        let second = try await docs.send(.request(purpose: "screenshot", wait: true))
        #expect(second.outcome == .waiting)
        #expect(second.status?.yourPosition == 1)
        #expect(second.status?.holder?.name == "acme-web")

        await web.close()
        try await settle { service.claims.sessions.count == 1 }
        let after = try await docs.send(.status)
        #expect(after.status?.youHold == true)
    }

    @Test func aSecondCopyDoesNotTakeTheSocket() async throws {
        let socket = socketPath()
        let first = LampService()
        first.start(socket: socket)
        defer {
            first.stop()
            try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        }
        let second = LampService()
        second.start(socket: socket)
        defer { second.stop() }
        guard case .failed = second.serving else {
            Issue.record("the second copy should not serve, but is \(second.serving)")
            return
        }
        #expect(first.serving == .serving(path: socket.path))
    }

    @Test func aLeftoverSocketFileIsReplaced() async throws {
        let socket = socketPath()
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: socket)
        let service = LampService()
        service.start(socket: socket)
        defer {
            service.stop()
            try? FileManager.default.removeItem(at: socket.deletingLastPathComponent())
        }
        #expect(service.serving == .serving(path: socket.path))
        let helper = try Helper(path: socket.path)
        let reply = try await helper.send(.status)
        #expect(reply.status?.holder == nil)
    }

    @Test func aNoticeArrivesWithTheNextReply() {
        let service = LampService()
        let web = service.connect(AgentIdentity(name: "acme-web"))
        _ = service.handle(.request(purpose: "a", wait: true), from: web)
        service.claimForOperator()
        let reply = service.handle(.status, from: web)
        #expect(reply.notice == .takenByOperator)
        #expect(reply.status?.holder?.isOperator == true)
        #expect(service.handle(.status, from: web).notice == nil)
    }
}
