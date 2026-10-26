import Foundation
import Testing
@testable import MacGamesCore
@testable import BridgeKit

@Suite struct AoE2Tests {
    func helpers(_ f: FakeEnvironment) throws {
        for name in ["RosettaProbe", "x87sidecar", "MacGamesBridge"] {
            let url = f.runtime.runtime.helpers.appendingPathComponent(name)
            try write("#!/bin/sh\nexit 0\n", to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try write("2\n", to: f.runtime.runtime.resources.appendingPathComponent("aoe-performance-v2"))
        try write("1\n\(try sha256Hex(ofFileAt: f.runtime.runtime.sidecar))\n",
                  to: f.runtime.runtime.resources.appendingPathComponent("aoe2-selection-jump"))
    }

    func capability(at engine: URL) throws {
        let native = engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let pe = engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll")
        let folder = engine.appendingPathComponent("aoe2-function-cache")
        try write("aoe2-native", to: native); try write("aoe2-pe", to: pe)
        try write("cache", to: folder.appendingPathComponent("cache.dll"))
        try write("loader", to: folder.appendingPathComponent("loader.exe"))
        let pin = AoE2FunctionCache.Capability(version: 1, nativeSHA256: try sha256Hex(ofFileAt: native),
            peSHA256: try sha256Hex(ofFileAt: pe), dllSHA256: try sha256Hex(ofFileAt: folder.appendingPathComponent("cache.dll")),
            loaderSHA256: try sha256Hex(ofFileAt: folder.appendingPathComponent("loader.exe")))
        try JSONEncoder().encode(pin).write(to: folder.appendingPathComponent("capability.json"))
        try write("1\n\(pin.nativeSHA256)\n", to: engine.appendingPathComponent(".macgames-aoe2-fragment-cache"))
    }

    func prepared(_ f: FakeEnvironment) throws {
        try helpers(f)
        try capability(at: f.runtime.paths.engine)
        try write("aoe2-pe", to: f.runtime.paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll"))
        f.runtime.settings = LaunchSettings(optimized: true)
    }

    @Test func steamProfileUses813780AndTheSharedLibrary() {
        let home = URL(fileURLWithPath: "/Users/test")
        let p = GamePaths(profile: .aoe2, root: GamePaths.defaultRoot(for: GameProfile.aoe2.gameEnvironment, home: home))
        #expect(GameProfile.aoe2.launch == .steam)
        #expect(GameProfile.aoe2.environment == GameProfile.aoe4.environment)
        #expect(p.gameExe.path.hasSuffix("steamapps/common/AoE2DE/AoE2DE_s.exe"))
        #expect(SteamLaunch.arguments(p, .play([])).suffix(2) == ["-applaunch", "813780"])
        #expect(p.appManifest.lastPathComponent == "appmanifest_813780.acf")
    }

    @Test func cacheEnvironmentIsVerifiedStableAndTurnsOff() throws {
        let f = try FakeEnvironment(.aoe2); defer { f.cleanUp() }
        try prepared(f)
        let first = try f.runtime.launchEnvironment(), second = try f.runtime.launchEnvironment()
        #expect(first["AOELAB_CODE_CACHE_AOE2"] == "1")
        #expect(first["AOELAB_AOE2_SELECTION_JUMP"] == "1")
        #expect(first["MallocProbGuard"] == "1")
        #expect(SteamLaunch.fingerprint(first) == SteamLaunch.fingerprint(second))
        try write("changed", to: f.runtime.runtime.sidecar)
        #expect(try f.runtime.launchEnvironment()["AOELAB_AOE2_SELECTION_JUMP"] == nil)
        f.runtime.settings = LaunchSettings(optimized: false)
        let off = try f.runtime.launchEnvironment()
        #expect(off["AOELAB_AOE2_FUNCTION_CACHE_PERSIST"] == nil)
        #expect(off["AOELAB_CODE_CACHE_GAME"] == nil)
        #expect(off["MallocProbGuard"] == "1")
        try write("changed", to: f.runtime.paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll"))
        #expect(AoE2FunctionCache.verified(in: f.runtime.paths) == nil)
    }

    @Test func changedGameDoesNotReceiveTheCacheOrFixedAddresses() throws {
        let f = try FakeEnvironment(.aoe2); defer { f.cleanUp() }
        try prepared(f); try write("MZ another build", to: f.runtime.paths.gameExe)
        let env = try f.runtime.launchEnvironment()
        f.runtime.startAoE2FunctionCache(environment: env)
        #expect(!f.calls.contains { $0.contains("loader.exe") })
        let args = ["/helpers/MacGamesBridge", "--cooperative", "/wine", #"C:\Games\AoE2DE_s.exe"#]
        let decision = Bridge.decide(arguments: args, environment: env, cwd: "/", isExecutable: { _ in true }) { _ in "different" }
        guard case let .exec(path, _, unset) = decision else { Issue.record("Expected plain Wine"); return }
        #expect(path == "/wine")
        #expect(env.keys.filter { $0.hasPrefix("AOELAB_") }.allSatisfy { unset.contains($0) })
    }

    @Test func steamLaunchConnectsTheCacheAfterApplaunch() throws {
        let bytes = Data("MZ test fixture".utf8), original = GameProfile.aoe2
        let profile = GameProfile(id: original.id, title: original.title, steamAppID: original.steamAppID,
            installFolder: original.installFolder, executableRelativePath: original.executableRelativePath,
            optimizedExecutableSHA256: sha256Hex(bytes))
        let f = try FakeEnvironment(profile); defer { f.cleanUp() }
        try prepared(f); try f.installSteam()
        try FileManager.default.createDirectory(at: f.runtime.paths.gameExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: f.runtime.paths.gameExe)
        try write(#"""
        "AppState"
        {
            "appid" "813780"
            "StateFlags" "4"
            "installdir" "AoE2DE"
        }
        """#, to: f.runtime.paths.appManifest)
        try f.runtime.play(LaunchContext(width: 1920, height: 1080))
        #expect(f.waitForCall(containing: #"C:\macgames\loader.exe C:\macgames\cache.dll"#))
        let steam = try #require(f.calls.firstIndex { $0.contains("-applaunch 813780") })
        let cache = try #require(f.calls.firstIndex { $0.contains("loader.exe") })
        #expect(steam < cache)
    }

    @Test func profileEngineCanReturnToOrdinarySteamWithoutChangingThePrefix() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = try EngineInstallerTests().fakeRuntime(in: dir), installer = EngineInstaller(runtime: runtime)
        try capability(at: runtime.overlay("aoe2-selection"))
        try write("stock-pe", to: runtime.engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"))
        let aoe2 = GamePaths(profile: .aoe2, root: dir.appendingPathComponent("shared"))
        let aoe4 = GamePaths(profile: .aoe4, root: aoe2.root)
        #expect(aoe2.prefix == aoe4.prefix)
        try installer.install(for: aoe2); try PrefixSetup.apply(PrefixSetup.coreCopies(for: aoe2))
        #expect(AoE2FunctionCache.verified(in: aoe2) != nil)
        #expect(!installer.isCurrent(for: aoe4))
        try installer.install(for: aoe4); try PrefixSetup.apply(PrefixSetup.coreCopies(for: aoe4))
        #expect(read(aoe4.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")) == "stock-pe")
        #expect(AoE2FunctionCache.verified(in: aoe4) == nil)
        #expect(installer.isCurrent(for: aoe4))
    }

    @Test func openingSteamDoesNotReplaceALiveEngineAndPlayCannotStopAnotherGame() throws {
        let f = try FakeEnvironment(.aoe2); defer { f.cleanUp() }
        try f.installSteam(); f.runtime.settings = LaunchSettings(optimized: false)
        try capability(at: f.runtime.runtime.overlay("aoe2-selection"))
        f.live()
        try f.runtime.startSteam(.open)
        #expect(!f.calls.contains("wineserver -k"))
        #expect(f.calls.contains { $0.hasPrefix("wine reg import") })
        #expect(AoE2FunctionCache.verifiedEngine(f.runtime.paths.engine) == nil)
        f.live(["RelicCardinal.exe"])
        #expect(throws: SetupError.self) { try f.runtime.startSteam(.play([])) }
        #expect(!f.calls.contains("wineserver -k"))
    }

    @Test func playingRestartsIdleSteamBeforeChangingTheSharedEngine() throws {
        let f = try FakeEnvironment(.aoe2); defer { f.cleanUp() }
        try f.installSteam(); f.runtime.settings = LaunchSettings(optimized: false)
        try capability(at: f.runtime.runtime.overlay("aoe2-selection"))
        try write("old-pe", to: f.runtime.paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll"))
        for architecture in ["x86_64-windows", "i386-windows"] {
            try write("winemetal", to: f.runtime.runtime.engine.appendingPathComponent("lib/wine/\(architecture)/winemetal.dll"))
        }
        for name in ["dxgi", "d3d11", "d3d12", "atidxx64"] {
            try write("renderer", to: f.runtime.paths.frameworks.appendingPathComponent("renderer/d3dmetal/wine/x86_64-windows/\(name).dll"))
        }
        let live = f.snapshot(), log = f.dir.appendingPathComponent("root/calls.log")
        f.runtime.processes = { _ in
            (try? String(contentsOf: log, encoding: .utf8).contains("wineserver -k")) == true
                ? ProcessSnapshot(entries: []) : live
        }
        try f.runtime.startSteam(.play([]))
        let stop = try #require(f.calls.firstIndex(of: "wineserver -k"))
        let launch = try #require(f.calls.firstIndex { $0.contains("-applaunch 813780") })
        #expect(stop < launch)
        #expect(AoE2FunctionCache.verified(in: f.runtime.paths) != nil)
        #expect(read(f.runtime.paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")) == "aoe2-pe")
    }

    @Test func audioAllocatorParticipatesInTheSteamFingerprint() {
        #expect(SteamLaunch.fingerprint([:]) != SteamLaunch.fingerprint(["MallocProbGuard": "1"]))
    }
}
