import Foundation
import Testing
@testable import MacGamesCore

/// After Play, Steam takes half a minute or more to start a game. The wait keeps the game
/// shown as starting until its own process runs, and gives up with a reason.
@Suite(.serialized) struct GameStartWaitTests {
    /// Hands out one snapshot per look at the processes, then keeps the last one.
    final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [ProcessSnapshot]
        private(set) var looks = 0
        init(_ snapshots: [ProcessSnapshot]) { remaining = snapshots }
        func next() -> ProcessSnapshot {
            lock.lock(); defer { lock.unlock() }
            looks += 1
            return remaining.count > 1 ? remaining.removeFirst() : remaining[0]
        }
    }

    func installedGame(_ profile: GameProfile) throws -> FakeEnvironment {
        let env = try FakeEnvironment(profile)
        let p = env.runtime.paths
        try env.installSteam()
        try write("""
        "AppState"
        {
        \t"appid"\t\t"\(profile.steamAppID)"
        \t"installdir"\t\t"\(profile.installFolder)"
        \t"StateFlags"\t\t"4"
        }
        """, to: p.appManifest)
        try write("exe", to: p.gameExe)
        env.runtime.gameStartPoll = 0.01
        return env
    }

    func follow(_ env: FakeEnvironment, _ snapshots: [ProcessSnapshot]) -> Timeline {
        let timeline = Timeline(snapshots)
        env.runtime.processes = { _ in timeline.next() }
        return timeline
    }

    @Test func returnsOnceTheGameProcessRuns() throws {
        let env = try installedGame(.aoe4); defer { env.cleanUp() }
        let steamOnly = env.snapshot(["steam.exe"])
        let timeline = follow(env, [steamOnly, steamOnly, steamOnly, env.snapshot(["steam.exe", env.runtime.profile.executableName])])
        try env.runtime.waitForGameStart()
        #expect(timeline.looks == 4)
        #expect(env.runtime.state(using: env.snapshot([env.runtime.profile.executableName])) == .running)
        #expect(env.events.all.contains { $0.contains("Waiting for Steam to start Age of Empires IV") })
    }

    @Test func endsWhenSteamClosesBeforeTheGameStarts() throws {
        let env = try installedGame(.aoe4); defer { env.cleanUp() }
        env.runtime.sessionGoneGrace = 0.05
        _ = follow(env, [env.snapshot(["steam.exe"]), ProcessSnapshot(entries: [])])
        let error = #expect(throws: SetupError.self) { try env.runtime.waitForGameStart() }
        #expect(String(describing: error).contains("Steam closed before Age of Empires IV started"))
    }

    @Test func aSessionThatIsBrieflyAbsentIsNotTakenForClosed() throws {
        let env = try installedGame(.aoe4); defer { env.cleanUp() }
        env.runtime.sessionGoneGrace = 5
        let game = env.snapshot([env.runtime.profile.executableName])
        _ = follow(env, [ProcessSnapshot(entries: []), ProcessSnapshot(entries: []), game])
        try env.runtime.waitForGameStart()
    }

    @Test func givesUpWithAReasonAfterTheTimeout() throws {
        let env = try installedGame(.aoe4); defer { env.cleanUp() }
        env.runtime.gameStartTimeout = 0.1
        env.live(["steam.exe"])
        let error = #expect(throws: SetupError.self) { try env.runtime.waitForGameStart() }
        #expect(String(describing: error).contains("has not started"))
    }

    @Test func gamesThatSteamDoesNotStartAreNotAwaited() throws {
        let env = try installedGame(.diablo4BattleNet); defer { env.cleanUp() }
        let timeline = follow(env, [ProcessSnapshot(entries: [])])
        try env.runtime.waitForGameStart()
        #expect(timeline.looks == 0)
    }
}
