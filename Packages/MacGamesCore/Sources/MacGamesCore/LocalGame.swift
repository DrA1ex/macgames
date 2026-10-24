import Foundation

/// Only the path is saved. MacGames never copies or patches the selected game files.
public struct LocalGameSelection: Codable, Sendable, Equatable {
    public let executable: URL
    public var workingDirectory: URL? = nil

    public init(executable: URL) throws {
        self.executable = executable.standardizedFileURL.resolvingSymlinksInPath()
        try validate()
    }

    public func validate() throws {
        guard executable.isFileURL, executable.pathExtension.lowercased() == "exe" else {
            throw SetupError("Choose a Windows .exe file inside the installed game folder.")
        }
        let values = try? executable.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isReadable == true else {
            throw SetupError("The selected EXE is missing or unreadable at \(executable.path). Reconnect the drive or choose the EXE again.")
        }
        if let workingDirectory {
            guard (try? workingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw SetupError("The working folder is missing. Choose an existing folder or use the EXE's folder.")
            }
        }
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 2) == Data([0x4d, 0x5a]) else {
            throw SetupError("The selected file is not a Windows executable (missing MZ header).")
        }
    }

    /// Infer the install root from the catalog's nested EXE path (Witcher, Hogwarts, etc.).
    /// A different EXE name is allowed; its parent is the fallback.
    public func installDirectory(for profile: GameProfile) -> URL {
        let components = profile.executableRelativePath.split(separator: "/").map(String.init)
        let actual = executable.pathComponents.suffix(components.count)
        guard actual.map({ $0.lowercased() }) == components.map({ $0.lowercased() }) else {
            return executable.deletingLastPathComponent()
        }
        return components.reduce(executable) { url, _ in url.deletingLastPathComponent() }
    }

    public static func load(from paths: GamePaths) -> LocalGameSelection? {
        let data = (try? Data(contentsOf: url(paths))) ?? (paths.localLaunch
            ? try? Data(contentsOf: paths.legacyLocalGameData.appendingPathComponent("local-game.json")) : nil)
        return data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func url(_ paths: GamePaths) -> URL { paths.gameData.appendingPathComponent("local-game.json") }

    func save(to paths: GamePaths) throws {
        try FileManager.default.createDirectory(at: paths.gameData, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(paths), options: .atomic)
    }
}

extension GameRuntime {
    public var localExecutable: URL? { LocalGameSelection.load(from: paths)?.executable }

    public func selectLocalExecutable(_ url: URL) throws {
        guard paths.localLaunch else { throw SetupError("Choose an EXE in a local game environment.") }
        guard !isSessionRunning() else { throw SetupError("Close the local game before changing its EXE.") }
        let selection = try LocalGameSelection(executable: url)
        // Keeping the source outside the disposable environment also makes Remove setup safe.
        let source = selection.executable.path
        let root = paths.root.resolvingSymlinksInPath().path
        guard !source.hasPrefix(root + "/") else {
            throw SetupError("Choose a game folder outside MacGames' local environment so removing setup cannot delete your game.")
        }
        try selection.save(to: paths)
    }

    public func setLocalWorkingDirectory(_ directory: URL?) throws {
        guard paths.localLaunch, var selection = LocalGameSelection.load(from: paths) else { throw SetupError("Choose the game EXE first.") }
        guard !isSessionRunning() else { throw SetupError("Close the game before changing its working folder.") }
        selection.workingDirectory = directory?.standardizedFileURL.resolvingSymlinksInPath()
        try selection.validate()
        try selection.save(to: paths)
    }

    func requireLauncherMode() throws {
        if paths.localLaunch {
            throw SetupError("This game uses the selected EXE. Steam is disabled for this environment.")
        }
    }

    func playLocal(_ context: LaunchContext) throws {
        guard let selection = LocalGameSelection.load(from: paths) else {
            throw SetupError("Choose the installed game’s EXE first.")
        }
        try selection.validate()
        guard state() != .running else { throw SetupError("\(profile.title) is already running.") }
        if let playing = runningGameTitle() {
            throw SetupError("Close \(playing) first. It shares the \(paths.environment.title) Windows environment.")
        }
        let legacyEngine = paths.legacyLocalRoot.appendingPathComponent("engine")
        if paths.legacyLocalRoot != paths.root, !processes(legacyEngine).paths(under: legacyEngine).isEmpty {
            throw SetupError("Close the previous \(profile.title) local session before importing its saved data.")
        }
        // Preserve the requested mode before a first registry import changes
        // the prefix's RetinaMode. Old per-game bottles remain untouched.
        try EnvironmentSettings.load(from: paths).save(to: paths)
        for warning in try LocalEnvironmentMigration.migrate(paths) { progress(warning) }
        if !fm.fileExists(atPath: paths.runtimeReady.path) { try prepare() }
        // A fresh Wine session must pick up this launch's sync and optimization settings.
        if isSessionRunning() { try stop() }
        try ensureEngine()
        for warning in try GameFiles.prepare(profile, paths: paths, runtime: runtime, context: context) { progress(warning) }
        switch profile.id {
        case "overwatch": try prepareOverwatch()
        case "coh3": try ensureCoH3Runtime()
        case "aom-retold":
            try importRegistry([RegistryValue(key: RegistryValue.appDefaults + #"AoMRT_s.exe\Mac Driver"#,
                                              name: "RetoldNotchSafeFullscreen", value: .string(context.hasNotch ? "y" : "n"))],
                               environment: environment(optimized: false, hud: false))
        default: break
        }
        try ensureRecipes(environment: environment(optimized: false, hud: false))
        let env = try launchEnvironment()
        try startWatchers(WindowsHelper.watchers(for: profile, paths: paths, context: context))
        progress("Starting \(selection.executable.lastPathComponent) directly…")
        // Wine accepts Unix absolute paths. No root drive remapping, copying or symlinks are needed.
        // Bridge.unixPath also understands this form, including spaces and Unicode.
        let fitCS2 = profile.id == "cs2" && fm.fileExists(atPath: cs2DisplayPending.path)
        let displayArgs = fitCS2 ? SteamLaunch.cs2DisplayArguments(width: context.width, height: context.height) : []
        var arguments = [selection.executable.path] + profile.gameArgs + displayArgs
        // Both modes start cooperatively without Wine's legacy re-exec, which
        // disables x87. The bridge separately guards the fixed-build extensions.
        let mode = env["MACGAMES_X87_MODE"] ?? ""
        let useSidecar = ["generic", "aoe-performance"].contains(mode)
        if useSidecar {
            let flag = mode == "aoe-performance" ? "--aoe-performance" : "--generic-x87"
            arguments = [flag, "--cooperative", paths.wine.path] + arguments
        }
        try startDetached(arguments, environment: env, workingDirectory: paths.workingDirectory,
                          log: paths.localLog.lastPathComponent, executable: useSidecar ? runtime.bridge : nil)
        if fitCS2 { try? fm.removeItem(at: cs2DisplayPending) }
    }

    func waitForLocalGameStart() throws {
        progress("Waiting for \(paths.gameExe.lastPathComponent)…")
        let deadline = Date().addingTimeInterval(gameStartTimeout)
        while Date() < deadline {
            if state(using: processes(paths.engine)) == .running { return }
            Thread.sleep(forTimeInterval: gameStartPoll)
        }
        throw SetupError("\(paths.gameExe.lastPathComponent) did not stay running. Log: \(paths.localLog.path). "
            + "Confirm that the full game is installed and that this edition can run directly. MacGames does not change license checks or install Steam in this mode.")
    }
}
