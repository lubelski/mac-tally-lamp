import Foundation
import Observation

/// The running app's state: the claims on the screen, and the socket agents reach it on.
///
/// Every change happens on the main actor. Lines from the socket arrive on its own queue and
/// are passed to the main queue in order, so a connection's messages and its closing are
/// handled in the order they happened.
@MainActor
@Observable
public final class LampService {
    public enum Serving: Equatable, Sendable {
        case stopped
        case serving(path: String)
        case failed(String)
    }

    public private(set) var claims: ScreenClaims
    public private(set) var serving: Serving = .stopped

    public var holdLimit: TimeInterval {
        get { claims.holdLimit }
        set {
            claims.holdLimit = newValue
            changed()
        }
    }

    /// Called after every change, for what cannot observe: the lamp's panel, the updater.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var server: LineSocketServer?
    @ObservationIgnored private var sessions: [LineSocketServer.ConnectionID: SessionID] = [:]
    @ObservationIgnored private var timer: Timer?

    public init(holdLimit: TimeInterval = ScreenClaims.defaultHoldLimit, clock: @escaping @Sendable () -> Date = { Date() }) {
        claims = ScreenClaims(holdLimit: holdLimit)
        self.clock = clock
    }

    public var now: Date { clock() }

    // MARK: Serving

    /// Listens on `socket`, and checks every few seconds for a hold that has lapsed.
    public func start(socket: URL) {
        guard server == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            server = try LineSocketServer(path: socket.path, handlers: .init(
                opened: { id in DispatchQueue.main.async { MainActor.assumeIsolated { self.opened(id) } } },
                line: { id, line in DispatchQueue.main.async { MainActor.assumeIsolated { self.received(line, on: id) } } },
                closed: { id in DispatchQueue.main.async { MainActor.assumeIsolated { self.closed(id) } } }))
            serving = .serving(path: socket.path)
        } catch {
            serving = .failed(error.localizedDescription)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        changed()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        server?.close()
        server = nil
        serving = .stopped
    }

    private func opened(_ id: LineSocketServer.ConnectionID) {
        sessions[id] = claims.connect(AgentIdentity(name: AgentIdentity.unnamed))
        changed()
    }

    private func received(_ line: String, on id: LineSocketServer.ConnectionID) {
        guard let session = sessions[id] else { return }
        let reply: LampReply
        do {
            reply = handle(try LampWire.decode(LampMessage.self, from: line), from: session)
        } catch {
            reply = LampReply(id: 0, error: "Could not read the message: \(error.localizedDescription)")
        }
        if let text = try? LampWire.encode(reply) { server?.send(text, to: id) }
    }

    private func closed(_ id: LineSocketServer.ConnectionID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        claims.disconnect(session, now: now)
        changed()
    }

    // MARK: Messages

    /// Answers one message from a session. Called for each line from the socket, and by tests.
    public func handle(_ message: LampMessage, from session: SessionID) -> LampReply {
        var outcome: RequestOutcome?
        switch message.kind {
        case .hello:
            if let identity = message.identity { claims.identify(session, as: identity) }
        case .request:
            claims.expireHold(now: now)
            outcome = claims.request(session, purpose: message.purpose ?? "", wait: message.wait ?? true, now: now)
        case .leave:
            claims.leave(session, now: now)
        case .status:
            claims.expireHold(now: now)
        }
        let notice = claims.takeNotice(for: session)
        changed()
        return LampReply(id: message.id, outcome: outcome, status: claims.status(for: session), notice: notice)
    }

    /// Adds a session as a connection does, for tests and previews.
    public func connect(_ identity: AgentIdentity) -> SessionID {
        let session = claims.connect(identity)
        changed()
        return session
    }

    /// Removes a session as a closed connection does, for tests and previews.
    public func disconnect(_ session: SessionID) {
        claims.disconnect(session, now: now)
        changed()
    }

    // MARK: The person at the Mac

    public func claimForOperator() {
        claims.operatorClaim(now: now)
        changed()
    }

    public func releaseForOperator() {
        claims.operatorRelease(now: now)
        changed()
    }

    public func skipHolder() {
        claims.skipHolder(now: now)
        changed()
    }

    public func removeFromLine(_ session: SessionID) {
        claims.removeFromLine(session)
        changed()
    }

    // MARK: Time

    public func tick() {
        if claims.expireHold(now: now) { changed() }
    }

    private func changed() {
        onChange?()
    }
}
