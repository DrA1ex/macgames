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
    static func verified(in paths: GamePaths) -> Artifacts? {
        let folder = paths.engine.appendingPathComponent("aoe2-function-cache")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("capability.json")),
              let pin = try? JSONDecoder().decode(Capability.self, from: data), pin.version == 1 else { return nil }
        let dll = folder.appendingPathComponent("cache.dll"), loader = folder.appendingPathComponent("loader.exe")
        let files = [(paths.engine.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"), pin.nativeSHA256),
                     (paths.engine.appendingPathComponent("lib/wine/x86_64-windows/ntdll.dll"), pin.peSHA256),
                     (paths.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll"), pin.peSHA256),
                     (dll, pin.dllSHA256), (loader, pin.loaderSHA256)]
        guard files.allSatisfy({ file, expected in
            expected.count == 64 && (try? sha256Hex(ofFileAt: file)) == expected
        }) else { return nil }
        return Artifacts(dll: dll, loader: loader, capability: pin)
    }
}

extension GameRuntime {
    func startAoE2FunctionCache(environment: [String: String]) {
        guard profile.id == "aoe2", paths.localLaunch,
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
