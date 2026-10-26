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
        #expect(cached["AOELAB_AOE2_FUNCTION_CACHE_PERSIST"] == nil, "native ring capability alone cannot load an extra DLL")
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
                   "AOELAB_CODE_CACHE_GAME": "1", "AOELAB_CODE_CACHE_AOE2": "1",
                   "AOELAB_AOE2_FUNCTION_CACHE_PERSIST": "1", "AOELAB_AOE2_FUNCTION_CACHE_STATUS": "C:\\cache.bin"]
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
    @Test func selectionCacheRequiresMatchingEnginePrefixAndHelpers() throws {
        let fixture = try FakeEnvironment(.aoe2, localLaunch: true); defer { fixture.cleanUp() }
        let paths = fixture.runtime.paths
        let folder = paths.engine.appendingPathComponent("aoe2-function-cache")
        let native = paths.engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let pe = paths.engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll")
        let prefixPE = paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")
        let dll = folder.appendingPathComponent("cache.dll"), loader = folder.appendingPathComponent("loader.exe")
        try write("native", to: native); try write("observer-pe", to: pe); try write("observer-pe", to: prefixPE)
        try write("selection-dll", to: dll); try write("selection-loader", to: loader)
        #expect(AoE2FunctionCache.verified(in: paths) == nil)
        let capability = AoE2FunctionCache.Capability(version: 1, nativeSHA256: try sha256Hex(ofFileAt: native),
            peSHA256: try sha256Hex(ofFileAt: pe), dllSHA256: try sha256Hex(ofFileAt: dll),
            loaderSHA256: try sha256Hex(ofFileAt: loader))
        let marker = folder.appendingPathComponent("capability.json")
        try JSONEncoder().encode(capability).write(to: marker)
        #expect(AoE2FunctionCache.verified(in: paths) != nil)
        for file in [native, pe, prefixPE, dll, loader] {
            let original = try Data(contentsOf: file)
            try write("replacement", to: file)
            #expect(AoE2FunctionCache.verified(in: paths) == nil)
            try original.write(to: file)
        }
        // Even a matching helper set cannot make a changed game receive the DLL.
        try write("MZ different game", to: paths.gameExe)
        fixture.runtime.startAoE2FunctionCache(environment: ["AOELAB_AOE2_FUNCTION_CACHE_PERSIST": "1"])
        #expect(!fixture.calls.contains { $0.contains("loader.exe") })
    }

    @Test func bundledSelectionRuntimeSwitchesBackForAnotherGame() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = try EngineInstallerTests().fakeRuntime(in: dir)
        let overlay = runtime.overlay("aoe2-selection")
        let native = overlay.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let pe = overlay.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll")
        let folder = overlay.appendingPathComponent("aoe2-function-cache")
        let dll = folder.appendingPathComponent("cache.dll"), loader = folder.appendingPathComponent("loader.exe")
        try write("aoe2-native", to: native); try write("aoe2-pe", to: pe)
        try write("cache", to: dll); try write("loader", to: loader)
        try write("stock-pe", to: runtime.engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"))
        let pin = AoE2FunctionCache.Capability(version: 1, nativeSHA256: try sha256Hex(ofFileAt: native),
            peSHA256: try sha256Hex(ofFileAt: pe), dllSHA256: try sha256Hex(ofFileAt: dll),
            loaderSHA256: try sha256Hex(ofFileAt: loader))
        try JSONEncoder().encode(pin).write(to: folder.appendingPathComponent("capability.json"))
        try write("1\n\(pin.nativeSHA256)\n", to: overlay.appendingPathComponent(".macgames-aoe2-fragment-cache"))
        let aoe2 = GamePaths(profile: .aoe2, root: dir.appendingPathComponent("shared"), localLaunch: true)
        let aoe4 = GamePaths(profile: .aoe4, root: aoe2.root, localLaunch: true)
        let installer = EngineInstaller(runtime: runtime)
        #expect(try installer.install(for: aoe2))
        try PrefixSetup.apply(PrefixSetup.coreCopies(for: aoe2))
        #expect(AoE2FunctionCache.verified(in: aoe2) != nil)
        #expect(installer.isCurrent(for: aoe2))
        #expect(!installer.isCurrent(for: aoe4))
        #expect(try installer.install(for: aoe4))
        try PrefixSetup.apply(PrefixSetup.coreCopies(for: aoe4))
        #expect(read(aoe4.engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")) == "fixed ntdll")
        #expect(read(aoe4.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")) == "stock-pe")
        #expect(AoE2FunctionCache.verified(in: aoe4) == nil)
        #expect(installer.isCurrent(for: aoe4))
        #expect(try installer.install(for: aoe2))
        try PrefixSetup.apply(PrefixSetup.coreCopies(for: aoe2))
        #expect(AoE2FunctionCache.verified(in: aoe2) != nil)
        try write("changed", to: dll)
        #expect(throws: SetupError.self) { try installer.install(for: aoe2) }
        #expect(read(aoe2.engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")) == "aoe2-native")
    }

    @Test func engineChangeCannotReplaceALiveSession() throws {
        let fixture = try FakeEnvironment(.aoe2, localLaunch: true); defer { fixture.cleanUp() }
        try write("new-version", to: fixture.runtime.runtime.resources.appendingPathComponent("VERSION"))
        fixture.live(["AoE2DE_s.exe"])
        #expect(throws: SetupError.self) { try fixture.runtime.ensureEngine() }
        #expect(read(fixture.runtime.paths.wine) == FakeEnvironment.wine)
    }

    @Test func selectionJumpCannotUseAReplacedSidecar() throws {
        let fixture = try FakeEnvironment(.aoe2, localLaunch: true); defer { fixture.cleanUp() }
        let runtime = fixture.runtime.runtime
        let marker = runtime.resources.appendingPathComponent("aoe2-selection-jump")
        try write("common-sidecar", to: runtime.sidecar)
        #expect(!AoE2FunctionCache.selectionJumpAvailable(in: runtime))
        try write("1\n\(try sha256Hex(ofFileAt: runtime.sidecar))\n", to: marker)
        #expect(AoE2FunctionCache.selectionJumpAvailable(in: runtime))
        try write("different-sidecar", to: runtime.sidecar)
        #expect(!AoE2FunctionCache.selectionJumpAvailable(in: runtime))
    }

}
