import Foundation

/// Opt-in frame timing, without changing the game's rendering or sync settings.
public enum PerformanceRecording {
    public static func environment(output: URL) -> [String: String] {
        ["MTL_HUD_ENABLED": "1", "MTL_HUD_LOG_ENABLED": "1", "MTL_HUD_LOG_SHADER_ENABLED": "1",
         "MTL_HUD_ELEMENTS": "fps,gputime,frameinterval,presentdelay,metalcpu,shaders,frameintervalgraph",
         "MTL_HUD_REPORT_URL": output.path]
    }
}

extension GameRuntime {
    /// Starts the usual game plus a bounded, read-only observer. The observer never stops the game.
    public func playWithPerformanceRecording(_ context: LaunchContext, output: URL) throws {
        guard paths.localLaunch else { throw SetupError("Choose an EXE to record performance.") }
        guard state() != .running else { throw SetupError("Save and close the game before recording a new launch.") }
        let helper = runtime.helpers.appendingPathComponent("PerformanceRecorder")
        guard fm.isExecutableFile(atPath: helper.path) else { throw SetupError("Rebuild MacGames Local to include PerformanceRecorder.") }
        guard !fm.fileExists(atPath: output.path) else { throw SetupError("Choose a new recording folder so existing measurements are preserved.") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let old = performanceDirectory
        performanceDirectory = output
        defer { performanceDirectory = old }
        try play(context)
        try waitForGameStart()
        let name = paths.gameExe.lastPathComponent.lowercased()
        guard let entry = processes(paths.engine).entries.first(where: {
            $0.argv0?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last?.lowercased() == name
        }) else { throw SetupError("The game started, but its process could not be found for recording.") }
        let metadata: [String: Any] = ["game": profile.id, "pid": entry.pid, "started": Date().timeIntervalSince1970,
                                       "optimized": settings.optimized, "exceptionHandling": settings.exceptionHandling,
                                       "executableSHA256": (try? sha256Hex(ofFileAt: paths.gameExe)) ?? "unreadable",
                                       "wineSync": "MSync", "graphics": String(describing: profile.graphics),
                                       "executable": paths.gameExe.path, "workingDirectory": paths.workingDirectory.path]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("launch.json"))
        let log = try ProcessRunner.appendHandle(for: output.appendingPathComponent("recorder.log"))
        defer { try? log.close() }
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(entry.pid), output.path]
        process.standardOutput = log; process.standardError = log; process.standardInput = FileHandle.nullDevice
        try process.run()
        progress("Recording frame timing and game threads. Close the game or finish recording within 10 minutes. Folder: \(output.path)")
    }
}
