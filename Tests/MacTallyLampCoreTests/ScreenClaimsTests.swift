import Foundation
import Testing
@testable import MacTallyLampCore

@Suite struct ScreenClaimsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Claims with three agents connected: web, docs, and api.
    func three() -> (ScreenClaims, SessionID, SessionID, SessionID) {
        var claims = ScreenClaims()
        let web = claims.connect(AgentIdentity(name: "acme-web"))
        let docs = claims.connect(AgentIdentity(name: "docs-site"))
        let api = claims.connect(AgentIdentity(name: "acme-api"))
        return (claims, web, docs, api)
    }

    @Test func aFreeScreenGoesToTheFirstToAsk() {
        var (claims, web, _, _) = three()
        do { let value = claims.request(web, purpose: "check Settings", wait: true, now: at(0)); #expect(value == .granted) }
        #expect(claims.holder == .agent(web, purpose: "check Settings", since: at(0), renewedAt: at(0)))
    }

    @Test func othersWaitInTheOrderTheyAsked() {
        var (claims, web, docs, api) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        do { let value = claims.request(docs, purpose: "b", wait: true, now: at(1)); #expect(value == .waiting) }
        do { let value = claims.request(api, purpose: "c", wait: true, now: at(2)); #expect(value == .waiting) }
        #expect(claims.position(of: docs) == 1)
        #expect(claims.position(of: api) == 2)
        #expect(claims.position(of: web) == nil)
    }

    @Test func askingWithoutWaitingDoesNotJoinTheLine() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        do { let value = claims.request(docs, purpose: "b", wait: false, now: at(1)); #expect(value == .busy) }
        #expect(claims.waiting.isEmpty)
    }

    @Test func askingAgainWhileWaitingKeepsTheSamePlace() {
        var (claims, web, docs, api) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.request(api, purpose: "c", wait: true, now: at(2))
        do { let value = claims.request(docs, purpose: "b, again", wait: false, now: at(3)); #expect(value == .waiting) }
        #expect(claims.position(of: docs) == 1)
        #expect(claims.waiting.first?.purpose == "b, again")
    }

    @Test func lettingGoHandsTheScreenToTheFirstInLine() {
        var (claims, web, docs, api) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.request(api, purpose: "c", wait: true, now: at(2))
        claims.leave(web, now: at(5))
        #expect(claims.holder == .agent(docs, purpose: "b", since: at(5), renewedAt: at(5)))
        #expect(claims.waiting.map(\.session) == [api])
    }

    @Test func disconnectingWhileHoldingHandsTheScreenOn() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.disconnect(web, now: at(2))
        #expect(claims.holdingSession == docs)
        #expect(claims.sessions[web] == nil)
    }

    @Test func disconnectingWhileWaitingLeavesTheLine() {
        var (claims, web, docs, api) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.request(api, purpose: "c", wait: true, now: at(2))
        claims.disconnect(docs, now: at(3))
        #expect(claims.waiting.map(\.session) == [api])
        #expect(claims.holdingSession == web)
    }

    @Test func leavingTheLineIsNotLettingGo() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.leave(docs, now: at(2))
        #expect(claims.holdingSession == web)
        #expect(claims.waiting.isEmpty)
    }

    @Test func askingWhileHoldingRenewsAndKeepsTheStart() {
        var (claims, web, _, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        do { let value = claims.request(web, purpose: "", wait: true, now: at(4)); #expect(value == .renewed) }
        #expect(claims.holder == .agent(web, purpose: "a", since: at(0), renewedAt: at(4)))
    }

    @Test func theOperatorTakesTheScreenAndTheAgentIsTold() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.operatorClaim(now: at(2))
        #expect(claims.holder == .operator(since: at(2)))
        do { let value = claims.takeNotice(for: web); #expect(value == .takenByOperator) }
        do { let value = claims.takeNotice(for: web); #expect(value == nil, "a notice is told once") }
        // The agent that lost the screen is not put back in line. It asks again if it still wants it.
        #expect(claims.waiting.map(\.session) == [docs])
    }

    @Test func agentsWaitBehindTheOperatorUntilTheyLetGo() {
        var (claims, web, docs, _) = three()
        claims.operatorClaim(now: at(0))
        do { let value = claims.request(web, purpose: "a", wait: true, now: at(1)); #expect(value == .waiting) }
        do { let value = claims.request(docs, purpose: "b", wait: false, now: at(1)); #expect(value == .busy) }
        claims.operatorRelease(now: at(9))
        #expect(claims.holdingSession == web)
    }

    @Test func theOperatorsHoldNeverLapses() {
        var (claims, web, _, _) = three()
        claims.operatorClaim(now: at(0))
        claims.request(web, purpose: "a", wait: true, now: at(1))
        #expect(claims.holdEnds == nil)
        do { let value = claims.expireHold(now: at(600)); #expect(!value) }
        #expect(claims.holder == .operator(since: at(0)))
    }

    @Test func skippingTheHolderHandsTheScreenOn() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.skipHolder(now: at(2))
        #expect(claims.holdingSession == docs)
        do { let value = claims.takeNotice(for: web); #expect(value == .skippedByOperator) }
    }

    @Test func removingFromTheLineTellsTheAgent() {
        var (claims, web, docs, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.removeFromLine(docs)
        #expect(claims.waiting.isEmpty)
        do { let value = claims.takeNotice(for: docs); #expect(value == .removedByOperator) }
    }

    @Test func aHoldDoesNotLapseWhileNobodyWaits() {
        var (claims, web, _, _) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        #expect(claims.holdEnds == nil)
        do { let value = claims.expireHold(now: at(120)); #expect(!value) }
        #expect(claims.holdingSession == web)
    }

    @Test func aHoldLapsesTheLimitAfterSomeoneStartsWaiting() {
        var (claims, web, docs, _) = three()
        claims.holdLimit = 10 * 60
        claims.request(web, purpose: "a", wait: true, now: at(0))
        // web has held it alone for 30 minutes. Its time runs from when docs starts waiting.
        claims.request(docs, purpose: "b", wait: true, now: at(30))
        #expect(claims.holdEnds == at(40))
        do { let value = claims.expireHold(now: at(39)); #expect(!value) }
        do { let value = claims.expireHold(now: at(40)); #expect(value) }
        #expect(claims.holdingSession == docs)
        do { let value = claims.takeNotice(for: web); #expect(value == .holdLapsed) }
    }

    @Test func renewingPushesTheLapseBack() {
        var (claims, web, docs, _) = three()
        claims.holdLimit = 10 * 60
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.request(web, purpose: "a", wait: true, now: at(8))
        #expect(claims.holdEnds == at(18))
        do { let value = claims.expireHold(now: at(12)); #expect(!value) }
    }

    @Test func unknownSessionsChangeNothing() {
        var (claims, _, _, _) = three()
        do { let value = claims.request(SessionID(99), purpose: "a", wait: true, now: at(0)); #expect(value == .busy) }
        #expect(claims.holder == nil)
    }

    @Test func twinsAreToldApartByNumber() {
        var claims = ScreenClaims()
        let first = claims.connect(AgentIdentity(name: "acme-web"))
        let second = claims.connect(AgentIdentity(name: "acme-web"))
        let other = claims.connect(AgentIdentity(name: "docs-site"))
        #expect(claims.displayName(of: first) == "acme-web #1")
        #expect(claims.displayName(of: second) == "acme-web #2")
        #expect(claims.displayName(of: other) == "docs-site")
    }

    @Test func statusIsFromTheAskersPointOfView() {
        var (claims, web, docs, api) = three()
        claims.request(web, purpose: "a", wait: true, now: at(0))
        claims.request(docs, purpose: "b", wait: true, now: at(1))
        claims.request(api, purpose: "", wait: true, now: at(2))
        let fromDocs = claims.status(for: docs)
        #expect(!fromDocs.youHold)
        #expect(fromDocs.yourPosition == 1)
        #expect(fromDocs.holder?.name == "acme-web")
        #expect(fromDocs.waiting.map(\.purpose) == ["b", nil])
        #expect(claims.status(for: web).youHold)
        #expect(claims.status(for: nil).waiting.allSatisfy { !$0.isYou })
    }

    @Test func anUpdateWaitsWhileAnyoneHoldsOrWaits() {
        var (claims, web, _, _) = three()
        #expect(AppUpdates.mayRelaunch(claims))
        claims.request(web, purpose: "a", wait: true, now: at(0))
        #expect(!AppUpdates.mayRelaunch(claims))
        claims.leave(web, now: at(1))
        claims.operatorClaim(now: at(2))
        #expect(!AppUpdates.mayRelaunch(claims))
    }
}

@Suite struct AgentIdentityTests {
    @Test(arguments: [
        ("/Users/rchen/dev/acme-web", "acme-web"),
        ("/Users/rchen/dev/acme-web/.wt/wt-03", "acme-web (wt-03)"),
        ("/Users/rchen/dev/acme-web/.wt/wt-03/Sources", "acme-web (wt-03)"),
        ("/Users/rchen/dev/tau/.claude/worktrees/fix-x", "tau (fix-x)"),
        ("/Users/rchen/dev/acme-web/Sources/", "Sources"),
        ("/", "agent"),
        ("", "agent"),
    ])
    func namesComeFromTheFolder(folder: String, name: String) {
        #expect(AgentIdentity.name(forFolder: folder) == name)
    }

    @Test func noFolderIsAnAgent() {
        #expect(AgentIdentity.name(forFolder: nil) == "agent")
    }
}

@Suite struct TimeFormatTests {
    @Test(arguments: [
        (0, "0 s"), (44.6, "45 s"), (60, "1 min"), (59 * 60 + 59, "59 min"), (3600, "1 h"), (3900, "1 h 5 min"), (-5, "0 s"),
    ] as [(Double, String)])
    func durations(seconds: Double, text: String) {
        #expect(TimeFormat.duration(seconds) == text)
    }
}

@Suite struct LampWireTests {
    @Test func messagesSurviveTheTrip() throws {
        let message = LampMessage(
            id: 7, kind: .hello,
            identity: AgentIdentity(name: "acme-web", client: "claude-code 2.1.0", folder: "/tmp/a", processID: 42))
        let line = try LampWire.encode(message)
        #expect(!line.contains("\n"))
        #expect(try LampWire.decode(LampMessage.self, from: line) == message)
    }

    @Test func repliesSurviveTheTrip() throws {
        var claims = ScreenClaims()
        let web = claims.connect(AgentIdentity(name: "acme-web"))
        claims.request(web, purpose: "two\nlines", wait: true, now: Date(timeIntervalSince1970: 1_800_000_000))
        let reply = LampReply(id: 3, outcome: .granted, status: claims.status(for: web), notice: .holdLapsed)
        let line = try LampWire.encode(reply)
        #expect(!line.contains("\n"))
        #expect(try LampWire.decode(LampReply.self, from: line) == reply)
    }
}
