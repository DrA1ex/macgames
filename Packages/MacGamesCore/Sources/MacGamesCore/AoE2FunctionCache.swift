import Foundation

/// Only a separately prepared engine can provide the tested selection-function cache.
/// The ordinary runtime has neither its capability file nor its extra DLL.
enum AoE2FunctionCache {
    struct Capability: Codable {
        let version: Int
        let nativeSHA256: String
        let peSHA256: String
        let dllSHA256: String
        let loaderSHA256: String
    }
    struct Artifacts {
        let dll: URL
        let loader: URL
        let capability: Capability
    }
    static func verifiedEngine(_ engine: URL) -> Artifacts? {
        let folder = engine.appendingPathComponent("aoe2-function-cache")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("capability.json")),
              let pin = try? JSONDecoder().decode(Capability.self, from: data), pin.version == 1 else { return nil }
        let dll = folder.appendingPathComponent("cache.dll"), loader = folder.appendingPathComponent("loader.exe")
        let files = [(engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"), pin.nativeSHA256),
                     (engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"), pin.peSHA256),
                     (dll, pin.dllSHA256), (loader, pin.loaderSHA256)]
        guard files.allSatisfy({ file, expected in
            expected.count == 64 && (try? sha256Hex(ofFileAt: file)) == expected
        }) else { return nil }
        return Artifacts(dll: dll, loader: loader, capability: pin)
    }

    static func verified(in paths: GamePaths) -> Artifacts? {
        guard let files = verifiedEngine(paths.engine),
              (try? sha256Hex(ofFileAt: paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")))
                == files.capability.peSHA256 else { return nil }
        return files
    }

    static func selectionJumpAvailable(in runtime: RuntimeLayout) -> Bool {
        guard let text = try? String(contentsOf: runtime.resources.appendingPathComponent("aoe2-selection-jump"), encoding: .utf8) else { return false }
        let fields = text.split(whereSeparator: \.isNewline)
        return fields.count == 2 && fields[0] == "1" && fields[1].count == 64
            && (try? sha256Hex(ofFileAt: runtime.sidecar)) == String(fields[1])
    }

    /// This overlay belongs to AoE II. EngineInstaller changes the shared
    /// engine only after the previous Steam session has ended.
    static func bundledOverlay(for paths: GamePaths, runtime: RuntimeLayout) throws -> URL? {
        guard paths.profile.id == "aoe2" else { return nil }
        let overlay = runtime.overlay("aoe2-selection")
        guard FileManager.default.fileExists(atPath: overlay.path) else { return nil }
        guard let files = verifiedEngine(overlay),
              let ring = try? String(contentsOf: overlay.appendingPathComponent(".macgames-aoe2-fragment-cache"), encoding: .utf8),
              ring.split(whereSeparator: \.isNewline).map(String.init) == ["1", files.capability.nativeSHA256] else {
            throw SetupError("The bundled AoE II runtime is incomplete or changed. Rebuild MacGames before launching it.")
        }
        return overlay
    }
}

extension GameRuntime {
    func startAoE2FunctionCache(environment: [String: String]) {
        guard profile.id == "aoe2",
              environment["AOELAB_AOE2_FUNCTION_CACHE_PERSIST"] == "1",
              let pin = profile.optimizedExecutableSHA256,
              (try? sha256Hex(ofFileAt: paths.gameExe)) == pin,
              let files = AoE2FunctionCache.verified(in: paths) else { return }
        do {
            let dll = try stage(files.dll), loader = try stage(files.loader)
            let staged = driveC.appendingPathComponent("macgames")
            guard try sha256Hex(ofFileAt: staged.appendingPathComponent(files.dll.lastPathComponent)) == files.capability.dllSHA256,
                  try sha256Hex(ofFileAt: staged.appendingPathComponent(files.loader.lastPathComponent)) == files.capability.loaderSHA256 else {
                throw SetupError("The AoE II cache helper changed while being prepared.")
            }
            try startDetached([loader, dll], environment: environment, workingDirectory: driveC,
                              log: "aoe2-cache.log")
        } catch { progress("The AoE II selection cache did not start: \(error)") }
    }
}
