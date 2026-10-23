import Foundation
import Testing
@testable import MacGamesCore
@testable import BridgeKit

@Suite struct AoEPerformanceTests {
    let args = ["/helpers/MacGamesBridge", "--aoe-performance", "--cooperative", "/engine/wine", "/games/RelicCardinal.exe"]
    let pin = "5380c577805565817f528af6eac385263413fa6815553f9a31fa62561cb45e8c"

    func environment() -> [String: String] {
        ["WINEPREFIX": "/prefix", Bridge.pinKey: pin, "AOELAB_CODE_CACHE_GAME": "1",
         "AOELAB_SOFTFAULT_BRIDGE": "1", "AOE_SOFTFAULT_PC": "0x140001000",
         "AOELAB_SOFTFAULT_GAME": "1", "X87_ALWAYS_NONE": "1"]
    }

    @Test func matchingBuildKeepsExtensionsAndRemovesLegacyX87Disable() throws {
        let decision = Bridge.decide(arguments: args, environment: environment(), cwd: "/", isExecutable: { _ in true }) { path in
            #expect(path == "/games/RelicCardinal.exe"); return pin
        }
        guard case let .exec(path, argv, unset) = decision else { Issue.record("Expected sidecar"); return }
        #expect(path == "/helpers/x87sidecar")
        #expect(argv == [path, "--cooperative", "/engine/wine", "/games/RelicCardinal.exe"])
        #expect(unset.contains("X87_ALWAYS_NONE"))
        #expect(unset.contains("AOELAB_SOFTFAULT_GAME"))
        #expect(!unset.contains("AOE_SOFTFAULT_PC"))
        #expect(!unset.contains("AOELAB_CODE_CACHE_GAME"))
    }

    @Test func changedBuildFallsBackToGenericX87() {
        let decision = Bridge.decide(arguments: args, environment: environment(), cwd: "/", isExecutable: { _ in true }) { _ in "different" }
        guard case let .exec(path, _, unset) = decision else { Issue.record("Expected generic fallback"); return }
        #expect(path == "/helpers/x87sidecar")
        #expect(unset.contains("AOELAB_CODE_CACHE_GAME"))
        #expect(unset.contains("AOELAB_SOFTFAULT_BRIDGE"))
        #expect(unset.contains("AOE_SOFTFAULT_PC"))
        #expect(unset.contains("X87_ALWAYS_NONE"))
    }

    @Test func counterCollectionDoesNotNeedAddressPatches() {
        let args = ["/helpers/MacGamesBridge", "--generic-x87", "--cooperative", "/engine/wine", "/game.exe"]
        let env = ["AOELAB_COUNTERS_DIR": "/measurements", "MACGAMES_DIAGNOSTICS_DIR": "/measurements", "AOELAB_CODE_CACHE_GAME": "1"]
        let decision = Bridge.decide(arguments: args, environment: env, cwd: "/", isExecutable: { _ in true }) { _ in "" }
        guard case let .exec(_, _, unset) = decision else { Issue.record("Expected generic launch"); return }
        #expect(!unset.contains("AOELAB_COUNTERS_DIR"))
        #expect(unset.contains("AOELAB_CODE_CACHE_GAME"))
        var inherited = env; inherited["MACGAMES_DIAGNOSTICS_DIR"] = nil
        let refused = Bridge.decide(arguments: args, environment: inherited, cwd: "/", isExecutable: { _ in true }) { _ in "" }
        guard case let .exec(_, _, stripped) = refused else { Issue.record("Expected generic launch"); return }
        #expect(stripped.contains("AOELAB_COUNTERS_DIR"))
    }

    @Test func oldSettingsDoNotEnableAddressExtensions() throws {
        let settings = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"optimized":true,"hud":true}"#.utf8))
        #expect(settings.aoePerformance == nil)
        let updated = LaunchSettings(optimized: true, hud: true, aoePerformance: true)
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(updated)) == updated)
    }

    @Test func launchRequiresPatchedHelperAndDoesNotUseLegacyReexec() throws {
        let fixture = try FakeEnvironment(.aoe4, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        for name in ["RosettaProbe", "x87sidecar", "MacGamesBridge"] {
            let path = game.runtime.helpers.appendingPathComponent(name)
            try write("#!/bin/sh\nexit 0\n", to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        game.settings = LaunchSettings(optimized: true, aoePerformance: true)
        #expect(throws: SetupError.self) { try game.launchEnvironment() }
        try write("2\n", to: game.runtime.resources.appendingPathComponent("aoe-performance-v2"))
        let env = try game.launchEnvironment()
        #expect(env["MACGAMES_X87_MODE"] == "aoe-performance")
        #expect(env["AOELAB_CODE_CACHE_GAME"] == "1")
        #expect(env["AOELAB_SOFTFAULT_BRIDGE"] == "1")
        #expect(env["AOELAB_SOFTFAULT_GAME"] == nil)
        #expect(env["X87_ALWAYS_NONE"] == nil)
    }
}
