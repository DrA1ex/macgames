import Foundation

public enum GameState: String, Sendable, Equatable {
    case notSetUp
    case needsSteam
    case needsGame
    case installing
    case ready
    case running

    /// Reads the setup stage from disk. `sessionRunning` says whether this
    /// game's Wine session is alive; Steam's log alone can be stale.
    public static func derive(_ paths: GamePaths, sessionRunning: Bool, gameProcessRunning: Bool = false) -> GameState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.runtimeReady.path) else { return .notSetUp }
        if paths.localLaunch {
            if gameProcessRunning { return .running }
            guard let selection = LocalGameSelection.load(from: paths), (try? selection.validate()) != nil else { return .needsGame }
            return .ready
        }
        if paths.profile.launch == .battleNet {
            // `.needsSteam` stands for the environment's launcher client.
            guard fm.fileExists(atPath: paths.battleNetExe.path) else { return .needsSteam }
            guard fm.fileExists(atPath: paths.gameExe.path) else { return .needsGame }
            guard fm.fileExists(atPath: paths.installDir.appendingPathComponent(".build.info").path) else { return .installing }
            return sessionRunning && gameProcessRunning ? .running : .ready
        }
        guard fm.fileExists(atPath: paths.steamExe.path) else { return .needsSteam }
        guard let manifest = AppManifest(contentsOf: paths.appManifest) else { return .needsGame }
        guard manifest.isFullyInstalled(paths.profile), fm.fileExists(atPath: paths.gameExe.path) else { return .installing }
        if sessionRunning && (gameProcessRunning || GameProcessLog.isRunning(paths.profile, paths: paths)) { return .running }
        return .ready
    }
}

public struct LaunchSettings: Codable, Sendable, Equatable {
    /// Use the x87sidecar optimization when the profile and this Mac support it.
    public var optimized: Bool
    /// Show the Metal performance HUD.
    public var hud: Bool
    /// Opt-in fixed-build AoE exception/cache extensions; nil preserves older settings.
    public var aoePerformance: Bool?
    /// Use Wine's Retina rendering mode; older settings adopt the existing prefix value.
    public var hiDPI: Bool?

    public init(optimized: Bool = true, hud: Bool = false, aoePerformance: Bool? = nil, hiDPI: Bool? = nil) {
        self.optimized = optimized
        self.hud = hud
        self.aoePerformance = aoePerformance
        self.hiDPI = hiDPI
    }

    static func url(_ paths: GamePaths) -> URL { paths.gameData.appendingPathComponent("settings.json") }

    public static func load(from paths: GamePaths) -> LaunchSettings {
        var settings = (try? JSONDecoder().decode(LaunchSettings.self, from: Data(contentsOf: url(paths)))) ?? LaunchSettings(optimized: !paths.localLaunch)
        if settings.hiDPI == nil {
            settings.hiDPI = WineHiDPI.currentValue(in: paths.prefix) ?? paths.environment.games.contains {
                GameRecipes.registry(for: $0).contains(WineHiDPI.registryValue(true))
            }
        }
        return settings
    }

    public func save(to paths: GamePaths) throws {
        try FileManager.default.createDirectory(at: paths.gameData, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(paths), options: .atomic)
    }
}
