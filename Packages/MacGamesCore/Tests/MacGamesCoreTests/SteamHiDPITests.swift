import Foundation
import Testing
@testable import MacGamesCore

@Suite(.serialized) struct SteamHiDPITests {
    func fixture() throws -> FakeEnvironment {
        let fixture = try FakeEnvironment(.cs2)
        try fixture.installSteam()
        fixture.runtime.settings = LaunchSettings(optimized: false)
        try EnvironmentSettings(hiDPI: false).save(to: fixture.runtime.paths)
        let env = try fixture.runtime.launchEnvironment()
        try SteamSession.begin(fingerprint: SteamLaunch.fingerprint(env), paths: fixture.runtime.paths, environment: env)
        try EnvironmentSettings(hiDPI: true).save(to: fixture.runtime.paths)
        return fixture
    }

    @Test func changedDisplayPreferenceRestartsSteamBeforeRegistryImport() throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.live()
        try f.runtime.startSteam(.play([]))
        let stop = try #require(f.calls.firstIndex(of: "wineserver -k"))
        let registry = try #require(f.calls.firstIndex { $0.hasPrefix("wine reg import") })
        let launch = try #require(f.calls.firstIndex { $0.contains("-applaunch 730") })
        #expect(stop < registry && registry < launch)
        #expect(try f.runtime.launchEnvironment()["MACGAMES_HIDPI"] == "1")
    }

    @Test func anotherRunningGamePreventsBothRestartAndRegistryMutation() throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.live(["RelicCardinal.exe"])
        #expect(throws: SetupError.self) { try f.runtime.startSteam(.play([])) }
        #expect(!f.calls.contains("wineserver -k"))
        #expect(!f.calls.contains { $0.hasPrefix("wine reg import") })
    }

    @Test func openingSteamDefersTheChangeAndPreservesDownloads() throws {
        let f = try fixture(); defer { f.cleanUp() }
        f.live()
        try f.runtime.startSteam(.open)
        #expect(!f.calls.contains("wineserver -k"))
        #expect(!f.calls.contains { $0.hasPrefix("wine reg import") })
    }

    @Test func battleNetAlsoRestartsForHiDPIBeforeStartingClient() throws {
        let f = try FakeEnvironment(.diablo4BattleNet); defer { f.cleanUp() }
        try write("", to: f.runtime.paths.battleNetExe)
        try write("0", to: f.runtime.sessionHiDPI)
        f.runtime.settings = LaunchSettings(optimized: false)
        try EnvironmentSettings(hiDPI: true).save(to: f.runtime.paths)
        f.live(["Battle.net.exe"])
        try f.runtime.openBattleNet(play: true)
        let stop = try #require(f.calls.firstIndex(of: "wineserver -k"))
        let registry = try #require(f.calls.firstIndex { $0.hasPrefix("wine reg import") })
        let client = try #require(f.calls.firstIndex { $0.contains("Battle.net.exe") })
        #expect(stop < registry && registry < client)
        #expect(read(f.runtime.sessionHiDPI) == "1")
    }

    @Test func battleNetDoesNotApplyTheChangeWhileItsGameRuns() throws {
        let f = try FakeEnvironment(.diablo4BattleNet); defer { f.cleanUp() }
        try write("", to: f.runtime.paths.battleNetExe)
        try write("0", to: f.runtime.sessionHiDPI)
        f.runtime.settings = LaunchSettings(optimized: false)
        try EnvironmentSettings(hiDPI: true).save(to: f.runtime.paths)
        f.live(["Battle.net.exe", f.runtime.profile.executableName])
        #expect(throws: SetupError.self) { try f.runtime.openBattleNet(play: true) }
        #expect(!f.calls.contains("wineserver -k"))
        #expect(!f.calls.contains { $0.hasPrefix("wine reg import") })
    }
}
