import Foundation
import Testing
@testable import MacGamesCore
import BridgeKit

@Suite struct LocalGameTests {
    func exe(in dir: URL, folder: String = "Игры with spaces") throws -> URL {
        let url = dir.appendingPathComponent("\(folder)/RelicCardinal.exe")
        try write("MZ test executable", to: url)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test func selectedExeSurvivesRestartAndNeedsNoSteamManifest() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        #expect(game.state() == .needsGame)
        #expect(!game.settings.optimized)
        let selected = try exe(in: fixture.dir)
        try game.selectLocalExecutable(selected)
        let reopened = GameRuntime(profile: .aoe4, root: game.paths.root, runtime: game.runtime, localLaunch: true)
        #expect(reopened.localExecutable == selected)
        #expect(reopened.paths.gameExe == selected)
        #expect(reopened.paths.installDir == selected.deletingLastPathComponent())
        #expect(game.state() == .ready)
        #expect(!FileManager.default.fileExists(atPath: game.paths.steamExe.path))
        #expect(!FileManager.default.fileExists(atPath: game.paths.appManifest.path))
        try FileManager.default.removeItem(at: selected)
        #expect(game.state() == .needsGame)
        #expect(throws: SetupError.self) { try game.play(LaunchContext(width: 1280, height: 720)) }
    }

    @Test func rejectsOtherFilesAndGamesInsideDisposablePrefix() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let wrong = fixture.dir.appendingPathComponent("other.txt")
        try write("MZ", to: wrong)
        #expect(throws: SetupError.self) { try fixture.runtime.selectLocalExecutable(wrong) }
        let invalid = try exe(in: fixture.dir)
        try write("not a binary", to: invalid)
        #expect(throws: SetupError.self) { try fixture.runtime.selectLocalExecutable(invalid) }
        #expect(throws: SetupError.self) { try fixture.runtime.selectLocalExecutable(exe(in: fixture.runtime.paths.root)) }
        #expect(fixture.runtime.localExecutable == nil)
    }

    @Test func localSetupNeverInstallsSteamAndKeepsRendererSeparation() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        for helper in [game.runtime.rosettaProbe, game.runtime.sidecar] {
            try write("#!/bin/sh\nexit 0\n", to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }
        try FileManager.default.createDirectory(at: game.paths.frameworks, withIntermediateDirectories: true)
        for copy in PrefixSetup.graphicsCopies(for: game.paths) { try write("dll", to: copy.from) }
        try game.prepare()
        try game.installLauncher()
        #expect(game.state() == .needsGame)
        #expect(!fixture.calls.contains { $0.lowercased().contains("steam") })
        #expect(!FileManager.default.fileExists(atPath: game.paths.steamExe.path))
        #expect(game.paths.environment.mixesRenderers)
        #expect(game.paths.environment.engineOverlays == GameEnvironment.steam.engineOverlays)
    }

    @Test func allLauncherEntryPointsAreBlockedAndExternalFilesCannotBeUninstalled() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let selected = try exe(in: fixture.dir)
        try fixture.runtime.selectLocalExecutable(selected)
        #expect(throws: SetupError.self) { try fixture.runtime.installSteam() }
        #expect(throws: SetupError.self) { try fixture.runtime.startSteam(.open) }
        #expect(throws: SetupError.self) { try fixture.runtime.openLauncher() }
        #expect(throws: SetupError.self) { try fixture.runtime.openForInstall() }
        #expect(throws: SetupError.self) { try fixture.runtime.uninstall() }
        #expect(fixture.calls.isEmpty)
        #expect(read(selected) == "MZ test executable")
    }

    @Test func directLaunchUsesTheSelectedExeAndItsWorkingDirectoryWithoutSteamOrUnsafePatches() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        let selected = try exe(in: fixture.dir)
        try game.selectLocalExecutable(selected)
        game.settings = LaunchSettings(optimized: false)
        // A stand-in Wine records the actual argv, cwd and environment passed to Process.
        try write(#"""
        #!/bin/sh
        /usr/bin/printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$PWD" "$WINEMSYNC" "$WINEDLLPATH" "${AOELAB_SIDECAR_PATH-unset}" > "$WINEPREFIX/launch.txt"
        """#, to: game.paths.wine)
        try game.play(LaunchContext(width: 1280, height: 720))
        let recordURL = game.paths.prefix.appendingPathComponent("launch.txt")
        let deadline = Date().addingTimeInterval(3)
        while (read(recordURL)?.split(separator: "\n").count ?? 0) < 5 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let record = try #require(read(recordURL), "Wine output: \(read(game.paths.logs.appendingPathComponent("aoe4-local.log")) ?? "none")")
        let lines = record.split(separator: "\n").map(String.init)
        try #require(lines.count == 5, "Expected the completed launch record")
        #expect(lines[0] == selected.path)
        #expect(URL(fileURLWithPath: lines[1]).resolvingSymlinksInPath() == selected.deletingLastPathComponent())
        #expect(lines[2] == "1")
        #expect(lines[3].contains("d3dmetal"))
        #expect(lines[4] == "unset")
        #expect(!fixture.events.all.contains { $0.contains("SHA-256") })
        #expect(!fixture.calls.contains { $0.lowercased().contains("steam") })
        #expect(read(selected) == "MZ test executable")
        fixture.live(["RelicCardinal.exe"])
        try game.waitForGameStart()
        #expect(game.state() == .running)
    }

    @Test func missingLocalProcessReportsALaunchFailureInsteadOfSuccess() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        fixture.runtime.gameStartTimeout = 0.02
        fixture.runtime.gameStartPoll = 0.01
        #expect(throws: SetupError.self) { try fixture.runtime.waitForGameStart() }
    }

    @Test func inheritedSteamAndOptimizationVariablesAreClearedButGraphicsAndMSyncRemain() {
        let paths = GamePaths(profile: .aoe4, root: URL(fileURLWithPath: "/local"), localLaunch: true)
        let env = WineEnvironment.make(profile: .aoe4, paths: paths,
                                      inherited: ["SteamAppId": "bad", "SteamGameId": "bad", "SteamOverlayGameId": "bad",
                                                  "AOELAB_SIDECAR_PATH": "/bad", "X87_BAD": "1"],
                                      optimized: false, hud: false, bridge: URL(fileURLWithPath: "/bridge"))
        #expect(env["WINEPREFIX"] == "/local/prefix")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEDLLPATH"]?.contains("d3dmetal") == true)
        #expect(!env.keys.contains { $0.hasPrefix("AOELAB_") || $0.hasPrefix("X87_") || $0.hasPrefix("Steam") })
    }

    @Test func localRootIsSeparateAndTheSteamCatalogIsUnchanged() {
        let layout = RuntimeLayout(resources: URL(fileURLWithPath: "/runtime"), helpers: URL(fileURLWithPath: "/helpers"))
        let local = GameRuntime(profile: .aoe4, runtime: layout, localLaunch: true)
        let steam = GameRuntime(profile: .aoe4, runtime: layout)
        #expect(local.paths.root != steam.paths.root)
        #expect(local.paths.root.lastPathComponent == "aoe4-local")
        #expect(steam.paths.environment == .steam)
        #expect(GameProfile.aoe4.launch == .steam)
        #expect(GameEnvironment.steam.games.contains(.aoe4))
    }

    @Test func bridgeChecksTheActualExternalExeAndFallsBackOnMismatch() {
        let path = "/Volumes/Игры with spaces/RelicCardinal.exe"
        let args = ["/helpers/MacGamesBridge", "--cooperative", "/local/engine/bin/wine", path]
        let env = ["WINEPREFIX": "/local/prefix", "MACGAMES_OPTIMIZED_SHA256": "pinned", "AOELAB_SOFTFAULT_GAME": "1"]
        let matched = Bridge.decide(arguments: args, environment: env, cwd: "/other", isExecutable: { _ in true }) { actual in
            #expect(actual == path); return "pinned"
        }
        #expect(matched == .exec(path: "/helpers/x87sidecar", argv: ["/helpers/x87sidecar"] + args.dropFirst(), unset: []))
        let mismatch = Bridge.decide(arguments: args, environment: env, cwd: "/other", isExecutable: { _ in true }) { _ in "other" }
        guard case let .exec(loader, argv, unset) = mismatch else { Issue.record("Expected plain Wine"); return }
        #expect(loader == "/local/engine/bin/wine")
        #expect(argv == [loader, path])
        #expect(unset.contains("AOELAB_SOFTFAULT_GAME"))
    }
}

@Suite struct TemporaryWineLoaderTests {
    @Test func aTemporaryLoaderBelongsOnlyToItsOwnWinePrefix() {
        let snapshot = ProcessSnapshot(entries: [
            .init(pid: 1, path: "/private/tmp/winetemp-123/wine", argv0: "/external/RelicCardinal.exe", winePrefix: "/local/prefix")
        ])
        #expect(snapshot.isRunning(executable: "RelicCardinal.exe", under: URL(fileURLWithPath: "/local/engine")))
        #expect(!snapshot.isRunning(executable: "RelicCardinal.exe", under: URL(fileURLWithPath: "/other/engine")))
    }

    @Test func readsArgvAndPrefixFromKernelProcessArguments() throws {
        var bytes = withUnsafeBytes(of: Int32(2).littleEndian, Array.init)
        bytes += Array("/private/tmp/winetemp/wine\0\0\0/external/RelicCardinal.exe\0\0OTHER=ignore\0WINEPREFIX=/local/prefix\0\0".utf8)
        let info = try #require(LiveProcesses.parseLaunchInfo(bytes))
        #expect(info.argv0 == "/external/RelicCardinal.exe")
        #expect(info.winePrefix == "/local/prefix")
        #expect(LiveProcesses.parseLaunchInfo([1, 2]) == nil)
    }
}

@Suite struct GenericLocalLibraryTests {
    @Test(arguments: GameProfile.all)
    func everyCatalogGameHasItsOwnLocalEnvironment(_ profile: GameProfile) throws {
        let fixture = try FakeEnvironment(profile, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        let file = fixture.dir.appendingPathComponent("external/\(profile.executableRelativePath)")
        try write("MZ external game", to: file)
        try game.selectLocalExecutable(file)
        #expect(game.state() == .ready)
        #expect(game.paths.environment.launcher == .none)
        #expect(game.paths.environment.games == [profile])
        #expect(game.paths.environment.engineOverlays == profile.gameEnvironment.engineOverlays)
        #expect(game.paths.environment.packs == profile.gameEnvironment.packs)
        #expect(game.paths.environment.enginePack == profile.gameEnvironment.enginePack)
        #expect(game.paths.installDir.resolvingSymlinksInPath() == fixture.dir.appendingPathComponent("external").resolvingSymlinksInPath())
        try game.installLauncher()
        #expect(throws: SetupError.self) { try game.openLauncher() }
        #expect(throws: SetupError.self) { try game.startSteam(.open) }
        #expect(!fixture.calls.contains { $0.contains("steam.exe") || $0.contains("Battle.net.exe") })
    }

    @Test func customExeAndWorkingFolderAreSavedAndTracked() throws {
        let fixture = try FakeEnvironment(.cs2, localLaunch: true); defer { fixture.cleanUp() }
        let selected = fixture.dir.appendingPathComponent("alternate.exe")
        try write("MZ game", to: selected)
        try fixture.runtime.selectLocalExecutable(selected)
        try fixture.runtime.setLocalWorkingDirectory(fixture.dir)
        #expect(fixture.runtime.paths.workingDirectory == fixture.dir.resolvingSymlinksInPath())
        fixture.live(["alternate.exe"])
        #expect(fixture.runtime.state() == .running)
        fixture.runtime.processes = { _ in ProcessSnapshot(entries: []) }
        try fixture.runtime.setLocalWorkingDirectory(nil)
        #expect(fixture.runtime.paths.workingDirectory == selected.deletingLastPathComponent().resolvingSymlinksInPath())
    }

    @Test func genericX87HasNoGameBuildAddressFlags() {
        let paths = GamePaths(profile: .aoe4, root: URL(fileURLWithPath: "/local"), localLaunch: true)
        let env = WineEnvironment.make(profile: .aoe4, paths: paths, inherited: [:], optimized: true, hud: false,
                                      bridge: URL(fileURLWithPath: "/helpers/MacGamesBridge"))
        #expect(env["MACGAMES_X87_MODE"] == "generic")
        #expect(env["X87_LOGS"] == "1")
        #expect(!env.keys.contains { $0.hasPrefix("AOELAB_") || $0.hasPrefix("AOE_SOFTFAULT_") || $0 == Bridge.pinKey })
        let args = ["/helpers/MacGamesBridge", "--generic-x87", "--cooperative", "/engine/wine", "/external/modified.exe"]
        let decision = Bridge.decide(arguments: args,
                                    environment: env.merging(["AOELAB_SOFTFAULT_GAME": "1", "AOE_SOFTFAULT_PC": "0xBAD", "X87_ALWAYS_NONE": "1"], uniquingKeysWith: { _, new in new }),
                                    cwd: "/external", isExecutable: { _ in true }) { _ in
            Issue.record("Generic x87 must never hash the game EXE"); return ""
        }
        guard case let .exec(path, argv, unset) = decision else { Issue.record("Expected generic sidecar"); return }
        #expect(path == "/helpers/x87sidecar")
        #expect(argv == ["/helpers/x87sidecar", "--cooperative", "/engine/wine", "/external/modified.exe"])
        #expect(unset.contains("AOELAB_SOFTFAULT_GAME"))
        #expect(unset.contains("AOE_SOFTFAULT_PC"))
        #expect(unset.contains("X87_ALWAYS_NONE"))
        #expect(!unset.contains("X87_LOGS"))
    }
}

@Suite struct LocalOptimizationHooksTests {
    @Test func localWatcherStartsWithoutAClientSession() throws {
        let fixture = try FakeEnvironment(.aomRetold, localLaunch: true); defer { fixture.cleanUp() }
        try write("watcher", to: fixture.runtime.helper("gpu-sync"))
        let watchers = WindowsHelper.watchers(for: .aomRetold, paths: fixture.runtime.paths,
                                             context: LaunchContext(width: 1920, height: 1080))
        try fixture.runtime.startWatchers(watchers)
        let deadline = Date().addingTimeInterval(3)
        while !fixture.calls.contains(where: { $0.contains("gpu-sync") }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(fixture.calls.contains { $0.contains("gpu-sync") })
        #expect(!fixture.calls.contains { $0.lowercased().contains("steam") })
    }

    @Test func localCS2KeepsItsFirstLaunchDisplayArguments() throws {
        let fixture = try FakeEnvironment(.cs2, localLaunch: true); defer { fixture.cleanUp() }
        let selected = fixture.dir.appendingPathComponent("external/cs2.exe")
        try write("MZ game", to: selected)
        try fixture.runtime.selectLocalExecutable(selected)
        try write("pending", to: fixture.runtime.cs2DisplayPending)
        try fixture.runtime.play(LaunchContext(width: 1600, height: 1000))
        let deadline = Date().addingTimeInterval(3)
        while !fixture.calls.contains(where: { $0.contains("-noborder") }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(fixture.calls.contains { $0.contains("cs2.exe -windowed -noborder -w 1600 -h 1000") })
        #expect(!FileManager.default.fileExists(atPath: fixture.runtime.cs2DisplayPending.path))
        #expect(!fixture.calls.contains { $0.lowercased().contains("steam") })
    }
}

@Suite struct DiagnosticImageTests {
    @Test func reads64BitGuestBoundsAndRejectsTruncatedFiles() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("game.exe")
        var bytes = Data(repeating: 0, count: 256)
        func put(_ value: UInt64, at offset: Int, count: Int) {
            for i in 0..<count { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(0x5a4d, at: 0, count: 2); put(64, at: 60, count: 4)
        put(0x4550, at: 64, count: 4); put(0x20b, at: 88, count: 2)
        put(0x140000000, at: 112, count: 8); put(0x8000000, at: 144, count: 4)
        try bytes.write(to: file)
        #expect(PEImage.addressRange(of: file) == 0x140000000..<0x148000000)
        try bytes.prefix(70).write(to: file)
        #expect(PEImage.addressRange(of: file) == nil)
    }

    @Test func normalLaunchHasNoProfilingOverhead() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let env = try fixture.runtime.launchEnvironment()
        #expect(env["X87_PROFILE"] == nil)
        #expect(env["X87_SAMPLE"] == nil)
        #expect(env["X87_GUEST_RANGE"] == nil)
    }
}
