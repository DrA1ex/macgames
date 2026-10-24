import Foundation
import Testing
@testable import MacGamesCore

@Suite struct SharedLocalEnvironmentTests {
    @Test func groupingMatchesUpstreamForEveryProfile() {
        let layout = RuntimeLayout(resources: URL(fileURLWithPath: "/runtime"), helpers: URL(fileURLWithPath: "/helpers"))
        for profile in GameProfile.all {
            let direct = GameRuntime(profile: profile, runtime: layout, localLaunch: true)
            let launcher = GameRuntime(profile: profile, runtime: layout)
            #expect(direct.paths.root == launcher.paths.root)
            #expect(direct.paths.environment == launcher.paths.environment)
        }
        let aoe = GameRuntime(profile: .aoe4, runtime: layout, localLaunch: true)
        let cs = GameRuntime(profile: .cs2, runtime: layout, localLaunch: true)
        let skyrim = GameRuntime(profile: .skyrim, runtime: layout, localLaunch: true)
        #expect(aoe.paths.prefix == cs.paths.prefix)
        #expect(aoe.paths.gameData != cs.paths.gameData)
        #expect(aoe.paths.prefix != skyrim.paths.prefix)
    }

    @Test func anotherSelectedGameBlocksLaunchBeforeAnySharedSessionMutation() throws {
        let f = try FakeEnvironment(.aoe4, localLaunch: true); defer { f.cleanUp() }
        let own = f.dir.appendingPathComponent("external/RelicCardinal.exe")
        let custom = f.dir.appendingPathComponent("external/custom-cs2.exe")
        try write("MZ own", to: own); try write("MZ other", to: custom)
        try f.runtime.selectLocalExecutable(own)
        let other = GameRuntime(profile: .cs2, root: f.runtime.paths.root, runtime: f.runtime.runtime, localLaunch: true)
        try other.selectLocalExecutable(custom)
        f.live(["custom-cs2.exe"])
        let playing = try #require(f.runtime.runningGameTitle())
        #expect(playing == GameProfile.cs2.title)
        #expect(throws: SetupError.self) { try f.runtime.play(LaunchContext(width: 1920, height: 1080)) }
        #expect(f.calls.isEmpty, "do not kill the shared wineserver or change recipes while another game runs")
    }

    @Test func legacySelectionsPreferencesAndSavesAreCopiedWithoutOverwritingOrDeleting() throws {
        let f = try FakeEnvironment(.aoe4, localLaunch: true); defer { f.cleanUp() }
        let paths = f.runtime.paths
        let old = GamePaths(profile: .aoe4, root: paths.legacyLocalRoot, localLaunch: true)
        let executable = f.dir.appendingPathComponent("external/RelicCardinal.exe")
        try write("MZ external", to: executable)
        try LocalGameSelection(executable: executable).save(to: old)
        try write(#"{"optimized":true,"hud":true,"aoePerformance":true}"#, to: LaunchSettings.url(old))
        try EnvironmentSettings(hiDPI: true).save(to: old)
        let relative = "prefix/drive_c/users/crossover/Documents/My Games/Age of Empires IV/save.bin"
        try write("saved match", to: old.root.appendingPathComponent(relative))
        try write("old setting", to: old.gameData.appendingPathComponent("home/settings.ini"))
        try write("current setting", to: paths.gameData.appendingPathComponent("home/settings.ini"))
        #expect(f.runtime.localExecutable == executable.resolvingSymlinksInPath(), "selection is visible even before the first launch")
        #expect(f.runtime.settings.optimized && f.runtime.settings.hud)
        #expect(f.runtime.environmentSettings.hiDPI)
        let notices = try LocalEnvironmentMigration.migrate(paths)
        #expect(notices.count == 1)
        #expect(read(paths.root.appendingPathComponent(relative)) == "saved match")
        #expect(read(paths.gameData.appendingPathComponent("home/settings.ini")) == "current setting")
        #expect(read(old.gameData.appendingPathComponent("home/settings.ini")) == "old setting")
        #expect(read(old.root.appendingPathComponent(relative)) == "saved match")
        #expect(FileManager.default.fileExists(atPath: LocalGameSelection.url(paths).path))
        #expect(try LocalEnvironmentMigration.migrate(paths).isEmpty, "migration is performed once")
        #expect(f.calls.isEmpty)
    }

    @Test func migrationDoesNotFollowUserFolderSymlinks() throws {
        let f = try FakeEnvironment(.aoe4, localLaunch: true); defer { f.cleanUp() }
        let paths = f.runtime.paths
        let oldUsers = paths.legacyLocalRoot.appendingPathComponent("prefix/drive_c/users/crossover")
        let external = f.dir.appendingPathComponent("outside/private.txt")
        try write("private", to: external)
        try FileManager.default.createDirectory(at: oldUsers, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: oldUsers.appendingPathComponent("Documents"), withDestinationURL: external.deletingLastPathComponent())
        _ = try LocalEnvironmentMigration.migrate(paths)
        #expect(!FileManager.default.fileExists(atPath: paths.prefix.appendingPathComponent("drive_c/users/crossover/Documents/private.txt").path))
        #expect(read(external) == "private")
    }
}
