import Foundation

/// Imports user data from an old per-game bottle without replacing the shared
/// engine, registry, or any existing files. Old bottles remain usable for rollback.
enum LocalEnvironmentMigration {
    static func migrate(_ paths: GamePaths) throws -> [String] {
        let fm = FileManager.default
        let legacy = paths.legacyLocalRoot
        let marker = paths.gameData.appendingPathComponent("legacy-local-imported")
        guard paths.localLaunch, legacy != paths.root,
              fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: marker.path) else { return [] }
        var conflicts = 0
        func merge(_ source: URL, _ target: URL) throws {
            guard let attributes = try? source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  attributes.isSymbolicLink != true else { return }
            // Never follow a source or destination user-folder link into the Mac.
            if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
            if attributes.isDirectory == true {
                if fm.fileExists(atPath: target.path) {
                    guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { conflicts += 1; return }
                } else { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    try merge(child, target.appendingPathComponent(child.lastPathComponent))
                }
            } else if fm.fileExists(atPath: target.path) {
                if !fm.contentsEqual(atPath: source.path, andPath: target.path) { conflicts += 1 }
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
        }
        try merge(paths.legacyLocalGameData, paths.gameData)
        try merge(legacy.appendingPathComponent("prefix/drive_c/users"), paths.prefix.appendingPathComponent("drive_c/users"))
        try fm.createDirectory(at: paths.gameData, withIntermediateDirectories: true)
        try Data(legacy.path.utf8).write(to: marker, options: .atomic)
        return conflicts == 0 ? [] : ["Kept \(conflicts) existing shared-environment files. The older copies remain in \(legacy.path)."]
    }
}
