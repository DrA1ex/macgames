import Foundation
import Testing
@testable import MacGamesCore
@testable import BridgeKit

@Suite struct AoE2Tests {
    @Test func oldSettingsLeaveExceptionsOff() throws {
        let old = try JSONDecoder().decode(LaunchSettings.self, from: Data(#"{"optimized":true,"hud":false}"#.utf8))
        #expect(!old.exceptionHandling)
        let current = LaunchSettings(optimized: true, exceptionHandling: true)
        #expect(try JSONDecoder().decode(LaunchSettings.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func aoe2UsesOwnBoundsAndOnlyVerifiedNativeCache() throws {
        let fixture = try FakeEnvironment(.aoe2, localLaunch: true); defer { fixture.cleanUp() }
        let game = fixture.runtime
        for name in ["RosettaProbe", "x87sidecar", "MacGamesBridge"] {
            let path = game.runtime.helpers.appendingPathComponent(name)
            try write("#!/bin/sh\nexit 0\n", to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try write("2\n", to: game.runtime.resources.appendingPathComponent("aoe-performance-v2"))
        game.settings = LaunchSettings(optimized: true)
        let generic = try game.launchEnvironment()
        #expect(generic["MACGAMES_X87_MODE"] == "generic")
        #expect(generic["AOELAB_SOFTFAULT_BRIDGE"] == nil)
        game.settings = LaunchSettings(optimized: true, exceptionHandling: true)
        let combined = try game.launchEnvironment()
        #expect(combined["MACGAMES_X87_MODE"] == "aoe-performance")
        #expect(combined["MACGAMES_OPTIMIZED_SHA256"] == GameProfile.aoe2.optimizedExecutableSHA256)
        #expect(combined["AOE_SOFTFAULT_END"] == "0x143197790")
        #expect(combined["AOELAB_CODE_CACHE_GAME"] == nil)
        #expect(combined["AOELAB_CODE_CACHE_AOE2"] == nil)
        #expect(combined["AOELAB_SOFTFAULT_GAME"] == nil, "direct launch avoids the AoE IV re-exec")
        let native = game.paths.engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let marker = game.paths.engine.appendingPathComponent(".macgames-aoe2-fragment-cache")
        try write("aoe2-native-fixture", to: native)
        let digest = try sha256Hex(ofFileAt: native)
        try write("1\n\(digest)\n", to: marker)
        let cached = try game.launchEnvironment()
        #expect(cached["AOELAB_CODE_CACHE_GAME"] == "1")
        #expect(cached["AOELAB_CODE_CACHE_AOE2"] == "1")
        game.performanceDirectory = game.paths.root.appendingPathComponent("aoe2-recording")
        let recording = try game.launchEnvironment()
        #expect(recording["AOELAB_COUNTERS_DIR"] == game.performanceDirectory?.path)
        #expect(recording["X87_SAMPLE"] == nil)
        game.performanceDirectory = nil
        try write("replaced-native", to: native)
        #expect(try game.launchEnvironment()["AOELAB_CODE_CACHE_GAME"] == nil)
        try write("1\ninvalid-digest\n", to: marker)
        #expect(try game.launchEnvironment()["AOELAB_CODE_CACHE_AOE2"] == nil)
        game.settings = LaunchSettings(optimized: false, exceptionHandling: true)
        let off = try game.launchEnvironment()
        #expect(off["MACGAMES_X87_MODE"] == nil)
        #expect(off["AOELAB_SOFTFAULT_BRIDGE"] == nil)
    }

    @Test func changedAoE2BuildLosesAllFixedAddressesButKeepsX87() throws {
        let args = ["/helpers/MacGamesBridge", "--aoe-performance", "--cooperative", "/wine", "/games/AoE2DE_s.exe"]
        let env = ["WINEPREFIX": "/prefix", Bridge.pinKey: GameProfile.aoe2.optimizedExecutableSHA256!,
                   "AOELAB_SOFTFAULT_BRIDGE": "1", "AOE_SOFTFAULT_PC": "0x140001000",
                   "AOE_SOFTFAULT_END": "0x143197790", "AOE_SOFTFAULT_TARGET": "0x180000010",
                   "AOE_SOFTFAULT_TARGET1": "0x180000000", "X87_ALWAYS_NONE": "1",
                   "AOELAB_CODE_CACHE_GAME": "1", "AOELAB_CODE_CACHE_AOE2": "1"]
        for hash in [GameProfile.aoe2.optimizedExecutableSHA256!, "changed-build"] {
            let decision = Bridge.decide(arguments: args, environment: env, cwd: "/", isExecutable: { _ in true }) { _ in hash }
            guard case let .exec(path, _, unset) = decision else { Issue.record("Expected sidecar"); return }
            #expect(path == "/helpers/x87sidecar")
            #expect(unset.contains("X87_ALWAYS_NONE"))
            for key in env.keys where key.hasPrefix("AOE_SOFTFAULT_") || key.hasPrefix("AOELAB_") {
                #expect(unset.contains(key) == (hash == "changed-build"))
            }
        }
    }
}
