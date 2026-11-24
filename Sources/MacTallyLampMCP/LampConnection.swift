import Foundation
import MacTallyLampCore

/// The MCP server's way to the running app. A protocol so tests can stand in for the app.
public protocol LampConnecting: Sendable {
    func send(_ message: LampMessage) async throws -> LampReply
    /// The MCP client's name and version, from `initialize`.
    func setClient(_ client: String?) async
    /// A name the agent chose for itself, in place of its folder's.
    func setName(_ name: String) async
}

/// The app could not be reached, so nobody is keeping track of the screen.
public struct LampUnavailable: Error, LocalizedError, Equatable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// One connection to the app for the life of this helper, which is the life of the agent
/// session that started it. The app takes the connection's closing as the session ending.
///
/// If the app is not running when the first call comes, the connection starts it in the
/// background once, without bringing it forward. If the person at the Mac quits it later, it
/// stays quit for this session.
public actor LampConnection: LampConnecting {
    private let socketPath: String
    private var identity: AgentIdentity
    private let launchApp: @Sendable () -> Bool
    private var client: LineSocketClient?
    /// The identity the app has, so a changed one is sent again.
    private var sentIdentity: AgentIdentity?
    private var triedLaunching = false
    private var nextID = 1

    public init(socketPath: String, identity: AgentIdentity, launchApp: @escaping @Sendable () -> Bool) {
        self.socketPath = socketPath
        self.identity = identity
        self.launchApp = launchApp
    }

    public func setClient(_ client: String?) {
        identity.client = client
    }

    public func setName(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { identity.name = name }
    }

    public func send(_ message: LampMessage) throws -> LampReply {
        do {
            return try exchange(message)
        } catch let error as LampUnavailable {
            throw error
        } catch let error as LineSocketError where error == .closed || error.isBrokenConnection {
            // The app may have restarted, after an update for one. Connect again, once.
            drop()
            do {
                return try exchange(message)
            } catch {
                throw unavailable(error)
            }
        } catch {
            throw unavailable(error)
        }
    }

    private func exchange(_ message: LampMessage) throws -> LampReply {
        let connection = try connected()
        if sentIdentity != identity {
            _ = try roundTrip(.hello(identity), on: connection)
            sentIdentity = identity
        }
        return try roundTrip(message, on: connection)
    }

    private func roundTrip(_ message: LampMessage, on connection: LineSocketClient) throws -> LampReply {
        var message = message
        message.id = nextID
        nextID += 1
        try connection.send(LampWire.encode(message))
        while true {
            let reply = try LampWire.decode(LampReply.self, from: connection.readLine())
            if reply.id == message.id { return reply }
        }
    }

    private func connected() throws -> LineSocketClient {
        if let client { return client }
        if let made = try? LineSocketClient(path: socketPath) { return use(made) }
        guard !triedLaunching else {
            throw LampUnavailable("Tally Lamp is not running.")
        }
        triedLaunching = true
        guard launchApp() else {
            throw LampUnavailable("Tally Lamp is not running, and this helper could not start it.")
        }
        // Give the app a few seconds to start listening.
        for _ in 0..<50 {
            usleep(100_000)
            if let made = try? LineSocketClient(path: socketPath) { return use(made) }
        }
        throw LampUnavailable("Tally Lamp was started but did not answer.")
    }

    private func use(_ made: LineSocketClient) -> LineSocketClient {
        client = made
        sentIdentity = nil
        return made
    }

    private func drop() {
        client?.close()
        client = nil
        sentIdentity = nil
    }

    private func unavailable(_ error: Error) -> LampUnavailable {
        drop()
        if let error = error as? LampUnavailable { return error }
        return LampUnavailable("Lost the connection to Tally Lamp: \(error.localizedDescription)")
    }
}

extension LineSocketError {
    var isBrokenConnection: Bool {
        if case .system(_, let code) = self { return code == EPIPE || code == ECONNRESET }
        return false
    }
}

/// Starts the app that holds this helper.
public enum AppLauncher {
    /// The app bundle the helper at `executable` sits in, as `<app>.app/Contents/MacOS/<helper>`.
    /// Nil for a helper outside a bundle, such as one from `swift build`.
    public static func containingApp(of executable: URL) -> URL? {
        let app = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Opens the app in the background, without bringing it forward. Returns whether `open`
    /// succeeded.
    public static func launch(_ app: URL, arguments: [String] = []) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-g", app.path] + (arguments.isEmpty ? [] : ["--args"] + arguments)
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
