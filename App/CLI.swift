import CoreGraphics
import Foundation
import MacGamesCore

/// Headless access to every step, for scripting and testing without the UI.
@MainActor
enum CLI {
    static let usage = """
    usage: MacGames --command <check|setup|launcher|install|play|record-performance|stop|uninstall|remove-setup|status|reset-display|settings>
                    --game <id> [--root <data root>] [--optimized on|off] [--hud on|off] [--hidpi on|off] [--aoe-performance on|off] [--local-exe /path/to/game.exe | --local] [--profile /diagnostic/folder]
    games: \(GameProfile.all.map(\.id).joined(separator: ", "))
    """

    static func value(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ args: [String]) -> Int32 {
        guard let command = value("--command", in: args),
              let profile = value("--game", in: args).flatMap(GameProfile.named) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        // MacGames Local always uses an external executable; legacy launcher code remains in the library.
        let local = true
        let root = value("--root", in: args).map { URL(fileURLWithPath: $0) }
        let game = GameRuntime(profile: profile, root: root, runtime: .inBundle(), localLaunch: local) { event in
            if case .progress(let line) = event { print(line); fflush(stdout) }
        }
        if let folder = value("--profile", in: args) { game.diagnosticDirectory = URL(fileURLWithPath: folder) }
        do {
            if let exe = value("--local-exe", in: args) { try game.selectLocalExecutable(URL(fileURLWithPath: exe)) }
            switch command {
            case "check":
                let report = try game.check()
                print("Host check passed. Optimization available: \(report.optimizationAvailable)")
                report.notes.forEach { print($0) }
            case "setup":
                try game.prepare()
                try game.installLauncher()
            case "steam", "launcher":
                try game.openLauncher()
            case "install":
                try game.openForInstall()
            case "play":
                try game.play(LaunchContext.mainDisplay())
                try game.waitForGameStart()
            case "record-performance":
                guard let folder = value("--output", in: args) else { throw SetupError("Specify a new --output folder for the recording.") }
                try game.playWithPerformanceRecording(LaunchContext.mainDisplay(), output: URL(fileURLWithPath: folder))
            case "stop":
                try game.stop()
            case "uninstall":
                try game.uninstall()
            case "remove-setup":
                try game.removeEnvironment()
            case "status":
                print("\(profile.id): \(game.state().rawValue)")
                print("root: \(game.paths.root.path)")
            case "reset-display":
                game.resetDisplay()
                print("The next launch applies the window size again.")
            case "settings":
                var s = game.settings
                if let v = value("--optimized", in: args) {
                    s.optimized = v == "on"
                    if profile.id == "aoe4" { s.aoePerformance = s.optimized }
                }
                if let v = value("--hud", in: args) { s.hud = v == "on" }
                if let v = value("--hidpi", in: args) { try EnvironmentSettings(hiDPI: v == "on").save(to: game.paths) }
                if let v = value("--aoe-performance", in: args) { s.aoePerformance = v == "on" }
                game.settings = s
                print("optimized: \(s.optimized), hud: \(s.hud), hiDPI: \(game.environmentSettings.hiDPI), aoePerformance: \(s.aoePerformance == true)")
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return 64
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }
}
