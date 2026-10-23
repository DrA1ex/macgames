import Darwin
import Foundation

/// Top-level keys of a Steam `appmanifest_<id>.acf` (Valve KeyValues text).
public struct AppManifest: Sendable {
    public let values: [String: String]

    public init(text: String) {
        var values: [String: String] = [:]
        var depth = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" { depth += 1; continue }
            if line == "}" { depth -= 1; continue }
            guard depth == 1 else { continue }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // "key"<ws>"value" splits into ["", key, ws, value, ""]
            if parts.count >= 5 { values[String(parts[1])] = String(parts[3]) }
        }
        self.values = values
    }

    public init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    public subscript(key: String) -> String? { values[key] }

    /// StateFlags is a bit field; bit 4 ("fully installed") stays set while an update waits.
    public func isFullyInstalled(_ profile: GameProfile) -> Bool {
        guard let flags = self["StateFlags"].flatMap({ Int($0) }) else { return false }
        return self["appid"] == profile.steamAppID && self["installdir"] == profile.installFolder && flags & 4 != 0
    }
}

/// Reads Steam's `logs/gameprocess_log.txt` to tell whether the game process is alive.
public enum GameProcessLog {
    public static func isRunning(_ profile: GameProfile, log: String) -> Bool {
        var tracked: String?
        let id = profile.steamAppID
        for line in log.split(whereSeparator: \.isNewline) {
            if line.contains("AppID \(id) adding PID "), line.contains(profile.executableName) {
                let tail = line.components(separatedBy: "adding PID ").last ?? ""
                tracked = tail.components(separatedBy: " ").first
            }
            if line.contains("Remove \(id) from running list") { tracked = nil }
            if let pid = tracked, line.contains("AppID \(id) no longer tracking PID \(pid),") { tracked = nil }
        }
        return tracked != nil
    }

    public static func url(_ paths: GamePaths) -> URL { paths.steamDir.appendingPathComponent("logs/gameprocess_log.txt") }

    /// Reads at most the last 128 KiB, and nothing from before the current Steam
    /// session: a session ended with `wineserver -k` never logs the game's exit.
    public static func isRunning(_ profile: GameProfile, paths: GamePaths) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url(paths)) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let sessionStart = SteamSession.load(paths)?.gameLogOffset ?? 0
        try? handle.seek(toOffset: max(sessionStart <= size ? sessionStart : 0, size > 131_072 ? size - 131_072 : 0))
        let data = (try? handle.readToEnd()) ?? Data()
        return isRunning(profile, log: String(decoding: data, as: UTF8.self))
    }
}

@_silgen_name("proc_listallpids") private func proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pidpath") private func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

/// The Wine processes that run at one moment. One snapshot answers every
/// status question of a refresh, so the process table is read only once.
public struct ProcessSnapshot: Sendable {
    public struct Entry: Sendable {
        public let pid: Int32
        /// The resolved path of the binary.
        public let path: String
        /// Wine keeps the Windows program's path here.
        public let argv0: String?
        /// Wine can run a temporary copy of its loader outside the engine directory.
        public let winePrefix: String?
        public init(pid: Int32, path: String, argv0: String?, winePrefix: String? = nil) {
            self.pid = pid; self.path = path; self.argv0 = argv0; self.winePrefix = winePrefix
        }
    }

    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }

    /// The processes whose binary is inside `folder`, such as the MacGames data folder.
    public static func take(under folder: URL) -> ProcessSnapshot {
        let directory = folder.resolvingSymlinksInPath()
        let prefix = directory.path + "/"
        let enginePrefix = directory.lastPathComponent == "engine"
            ? directory.deletingLastPathComponent().appendingPathComponent("prefix").path : nil
        return ProcessSnapshot(entries: LiveProcesses.allPids().compactMap { pid in
            guard let binary = LiveProcesses.path(pid) else { return nil }
            if binary.path.hasPrefix(prefix) {
                return Entry(pid: pid, path: binary.path, argv0: LiveProcesses.firstArgument(pid))
            }
            // Inspect only Wine loaders/helpers, not the environment of unrelated programs.
            guard ["wine", "wine64", "wine-preloader", "wine64-preloader", "x87sidecar"].contains(binary.lastPathComponent),
                  let info = LiveProcesses.launchInfo(pid), let winePrefix = info.winePrefix else { return nil }
            let resolved = URL(fileURLWithPath: winePrefix).resolvingSymlinksInPath().path
            guard resolved.hasPrefix(prefix) || resolved == enginePrefix else { return nil }
            return Entry(pid: pid, path: binary.path, argv0: info.argv0, winePrefix: resolved)
        })
    }

    func inside(_ folder: URL) -> [Entry] {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let winePrefix = folder.lastPathComponent == "engine"
            ? folder.deletingLastPathComponent().appendingPathComponent("prefix").resolvingSymlinksInPath().path : nil
        return entries.filter { $0.path.hasPrefix(prefix) || (winePrefix != nil && $0.winePrefix == winePrefix) }
    }

    /// Executable paths of the processes whose binary is inside `folder`.
    public func paths(under folder: URL) -> [URL] { inside(folder).map { URL(fileURLWithPath: $0.path) } }

    /// `true` when a process started from `folder` (a Wine engine) runs a Windows program named `executable`.
    public func isRunning(executable: String, under folder: URL) -> Bool {
        let want = executable.lowercased()
        return inside(folder).contains { entry in
            guard let argv0 = entry.argv0?.lowercased() else { return false }
            let name = argv0.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? argv0
            return name == want
        }
    }
}

public enum LiveProcesses {
    /// `true` when a process started from `folder` (a Wine engine) runs a
    /// Windows program named `executable`. Wine keeps the Windows path in argv[0].
    public static func isRunning(executable: String, under folder: URL) -> Bool {
        ProcessSnapshot.take(under: folder).isRunning(executable: executable, under: folder)
    }

    static func firstArgument(_ pid: Int32) -> String? { launchInfo(pid)?.argv0 }

    static func launchInfo(_ pid: Int32) -> (argv0: String?, winePrefix: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseLaunchInfo(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2: argc, executable path, NUL padding, argv, environment.
    /// Retains only argv[0] and WINEPREFIX; no other environment values are stored.
    static func parseLaunchInfo(_ buffer: [UInt8]) -> (argv0: String?, winePrefix: String?)? {
        guard buffer.count > 4 else { return nil }
        let argc = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard argc > 0, argc < buffer.count else { return nil }
        var i = 4
        func string() -> String {
            let start = i
            while i < buffer.count, buffer[i] != 0 { i += 1 }
            let value = String(decoding: buffer[start..<i], as: UTF8.self)
            if i < buffer.count { i += 1 }
            return value
        }
        _ = string() // Executable path.
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var argv0: String?
        for index in 0..<argc {
            guard i < buffer.count else { return nil }
            let argument = string()
            if index == 0 { argv0 = argument }
        }
        while i < buffer.count {
            let variable = string()
            if variable.hasPrefix("WINEPREFIX=") {
                return (argv0, String(variable.dropFirst("WINEPREFIX=".count)))
            }
        }
        return (argv0, nil)
    }

    /// Executable paths of live processes whose binary is inside `folder`.
    public static func paths(under folder: URL) -> [URL] {
        ProcessSnapshot.take(under: folder).paths(under: folder)
    }

    static func path(_ pid: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, 4096) }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .resolvingSymlinksInPath()
    }

    static func allPids() -> [Int32] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(min(count, Int32(pids.count)))).filter { $0 > 0 })
    }

    static func pids(under folder: URL) -> [Int32] {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        return allPids().filter { path($0)?.path.hasPrefix(prefix) ?? false }
    }
}
