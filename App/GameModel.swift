import AppKit
import CoreGraphics
import Foundation
import MacGamesCore
import Observation

/// Serializes setup and launch operations in shared Windows environments.
@MainActor @Observable
final class OperationGate {
    /// The game whose task is running, if any.
    var owner: String?
}

/// Shares a settings model only between cards using the same prefix.
@MainActor
final class EnvironmentSettingsStore {
    private var environments: [URL: EnvironmentSettingsModel] = [:]

    func settings(for paths: GamePaths) -> EnvironmentSettingsModel {
        if let model = environments[paths.root] { return model }
        let model = EnvironmentSettingsModel(paths: paths)
        environments[paths.root] = model
        return model
    }
}

/// One observable preference for every card sharing an environment.
@MainActor @Observable
final class EnvironmentSettingsModel {
    private let paths: GamePaths
    private(set) var value: EnvironmentSettings

    init(paths: GamePaths) {
        self.paths = paths
        self.value = EnvironmentSettings.load(from: paths)
    }

    func setHiDPI(_ enabled: Bool) throws {
        let updated = EnvironmentSettings(hiDPI: enabled)
        try updated.save(to: paths)
        value = updated
    }

    func reload() {
        let saved = EnvironmentSettings.load(from: paths)
        if saved != value { value = saved }
    }
}

/// UI state for one game. Every blocking runtime call runs off the main actor.
@MainActor @Observable
final class GameModel: Identifiable {
    let profile: GameProfile
    let runtime: GameRuntime
    let environmentSettings: EnvironmentSettingsModel
    private(set) var state: GameState = .notSetUp
    /// The shared Windows environment is alive.
    private(set) var sessionRunning = false
    private(set) var sidecarRunning = false
    /// The game's community online client is installed.
    private(set) var onlineReady = false
    @ObservationIgnored private let gate: OperationGate
    /// This game's task is running.
    var busy: Bool { gate.owner == id }
    /// Any game's task is running; every action waits for it.
    var locked: Bool { gate.owner != nil }
    private(set) var activity: String?
    private(set) var error: String?
    /// The setup stage in progress, and the stages finished in this run.
    private(set) var step: SetupStep?
    private(set) var finishedSteps: Set<SetupStep> = []
    /// Set when an action would end a running game; the view asks first.
    var confirmingStop = false
    /// What a confirmed removal deletes, with its size; the view asks first.
    enum Removal: Equatable { case uninstall(bytes: UInt64), removeSetup(bytes: UInt64) }
    var removal: Removal?
    /// Every game of this environment is uninstalled, so its setup can go.
    private(set) var canRemoveSetup = false
    /// Saved at once on the main actor, so the file always holds the last change.
    var settings: LaunchSettings { didSet { runtime.settings = settings; refreshOptimization() } }
    /// What the next launch does with the x87 optimization.
    private(set) var optimization: OptimizationStatus = .notApplicable

    var hiDPI: Bool {
        get { environmentSettings.value.hiDPI }
        set {
            do { try environmentSettings.setHiDPI(newValue) }
            catch { self.error = String(describing: error) }
        }
    }

    nonisolated var id: String { profile.id }

    var localLaunch: Bool { runtime.paths.localLaunch }
    var actionTitle: String {
        if localLaunch && (localExecutable == nil || state == .needsGame) { return "Choose EXE…" }
        if localLaunch && state == .notSetUp { return "Play" }
        return state.actionTitle(launcher: launcherName)
    }
    var summary: String {
        guard localLaunch else { return state.summary(launcher: launcherName) }
        switch state {
        case .notSetUp: return "Choose the installed game’s EXE. The first Play prepares its Windows environment."
        case .needsGame: return "The selected EXE is missing or unreadable. Choose it again."
        case .ready: return "Ready to launch the selected EXE without Steam."
        case .running: return "The game is running in the \(runtime.paths.environment.title) environment."
        default: return "Choose the installed game's EXE."
        }
    }
    private(set) var localExecutable: URL?
    private(set) var workingDirectory: URL
    var showsSetupSteps: Bool { step != nil || (!localLaunch && (state == .notSetUp || state == .needsSteam)) }

    init(profile: GameProfile, gate: OperationGate, environments: EnvironmentSettingsStore) {
        self.profile = profile
        self.gate = gate
        let (events, sink) = AsyncStream.makeStream(of: RuntimeEvent.self)
        let runtime = GameRuntime(profile: profile, runtime: .inBundle(), localLaunch: true) { sink.yield($0) }
        self.runtime = runtime
        self.environmentSettings = environments.settings(for: runtime.paths)
        self.settings = runtime.settings
        self.localExecutable = runtime.localExecutable
        self.workingDirectory = runtime.paths.workingDirectory
        Task { [weak self] in
            for await event in events {
                switch event {
                case .progress(let line): self?.activity = line
                case .step(let next): self?.advance(to: next)
                }
            }
        }
    }

    /// Blocking runtime work runs here, not on the threads Swift uses for async tasks.
    private static let work = DispatchQueue(label: "com.tarikbc.macgames.work", qos: .userInitiated)
    private static let reads = DispatchQueue(label: "com.tarikbc.macgames.reads", qos: .utility, attributes: .concurrent)

    private static func off<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: body()) } }
    }

    private func refreshOptimization() {
        let r = runtime
        Task { optimization = await Self.off(Self.reads) { r.optimizationStatus() } }
    }

    /// Reads the game's status; the library passes one process `snapshot` to all games of a poll.
    func refresh(_ snapshot: ProcessSnapshot? = nil) async {
        guard !locked else { return }
        let r = runtime
        let (state, live, sidecar, optimization, online, removable) = await Self.off(Self.reads) {
            let processes = snapshot ?? ProcessSnapshot.take(under: r.paths.engine)
            return (r.state(using: processes), r.isSessionRunning(using: processes),
                    processes.isRunning(executable: "x87sidecar", under: r.paths.engine),
                    r.optimizationStatus(), r.onlineReady, r.canRemoveEnvironment)
        }
        self.localExecutable = r.localExecutable
        self.workingDirectory = r.paths.workingDirectory
        environmentSettings.reload()
        self.onlineReady = online
        self.canRemoveSetup = removable
        // An old error no longer describes a game that moved to another stage.
        if state != self.state { error = nil }
        self.optimization = optimization
        self.state = state
        self.sessionRunning = live
        self.sidecarRunning = sidecar
    }

    /// The one action that moves this game to its next stage.
    func primaryAction() {
        if state == .running { confirmingStop = true; return }
        guard localExecutable != nil, state != .needsGame else { chooseExecutable(); return }
        let context = LaunchContext.mainDisplay()
        finishedSteps = []
        perform("Starting \(profile.title)") { r in try r.play(context); try r.waitForGameStart() }
    }

    var launcherName: String { "Windows environment" }

    func chooseExecutable() {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose \(profile.title)’s EXE"
        panel.message = "Select the game executable in its installed folder. Files stay in place."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = localExecutable?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Saving the selected EXE") { try $0.selectLocalExecutable(url) }
    }

    func chooseWorkingDirectory() {
        guard !locked, !sessionRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Working folder"
        panel.message = "Usually this is the folder containing the EXE. Choose another only if this game needs it."
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.directoryURL = workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Saving the working folder") { try $0.setLocalWorkingDirectory(url) }
    }
    func resetWorkingDirectory() {
        perform("Using the EXE’s folder") { try $0.setLocalWorkingDirectory(nil) }
    }

    func playOnline() {
        let context = LaunchContext.mainDisplay()
        perform(onlineReady ? "Starting the online client" : "Setting up online play") { r in try r.playOnline(context) }
    }

    func requestStop() {
        if state == .running || (localLaunch && sessionRunning) { confirmingStop = true } else { stop() }
    }

    func stop() { perform("Stopping") { r in try r.stop() } }

    /// The game has files on this Mac.
    var canUninstall: Bool { !localLaunch && (state == .ready || state == .installing) }

    /// Measures what goes, then asks for confirmation.
    func requestUninstall() {
        let r = runtime
        Task { removal = .uninstall(bytes: await Self.off(Self.reads) { (try? r.installedSize()) ?? 0 }) }
    }

    func requestRemoveSetup() {
        let r = runtime
        Task { removal = .removeSetup(bytes: await Self.off(Self.reads) { (try? r.environmentSize()) ?? 0 }) }
    }

    func confirmRemoval() {
        switch removal {
        case .uninstall: perform("Uninstalling \(profile.title)") { r in try r.uninstall() }
        case .removeSetup: perform("Removing the setup") { r in try r.removeEnvironment() }
        case nil: break
        }
        removal = nil
    }
    func resetDisplay() { runtime.resetDisplay(); activity = "The next launch sets the window size again." }
    func showLogs() { NSWorkspace.shared.open(runtime.paths.logs) }
    /// The external installation folder, or the environment before selection.
    var dataFolder: URL {
        let folder = runtime.paths.installDir
        return FileManager.default.fileExists(atPath: folder.path) ? folder : runtime.paths.root
    }
    func showData() { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }
    func dismissError() { error = nil }

    private func advance(to next: SetupStep) {
        if let current = step { finishedSteps.insert(current) }
        step = next
    }

    private func perform(_ label: String, _ work: @escaping @Sendable (GameRuntime) throws -> Void) {
        guard !locked else { return }
        gate.owner = id; error = nil; activity = "\(label)…"
        let r = runtime
        Task {
            let failure: String? = await Self.off(Self.work) {
                do { try work(r); return nil } catch { return String(describing: error) }
            }
            if failure == nil, let current = step { finishedSteps.insert(current) }
            step = nil
            gate.owner = nil
            error = failure
            if failure == nil { activity = nil }
            await refresh()
        }
    }
}

/// The game list and the selection. New profiles appear here with no other change.
@MainActor @Observable
final class LibraryModel {
    let gate = OperationGate()
    private let environments = EnvironmentSettingsStore()
    let games: [GameModel]
    /// Remembered between launches.
    var selectedID: String = UserDefaults.standard.string(forKey: "selectedGame")
        .flatMap { id in GameProfile.named(id)?.id } ?? GameProfile.all.first?.id ?? "" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedGame") }
    }

    init() {
        let gate = self.gate, environments = self.environments
        games = GameProfile.all.map { GameModel(profile: $0, gate: gate, environments: environments) }
    }

    var selected: GameModel? { games.first { $0.id == selectedID } }
    /// Match upstream's environment groups while keeping direct EXE launches.
    var sections: [(title: String, games: [GameModel])] {
        GameEnvironment.groups.map { group in
            (group.title, group.games.compactMap { profile in games.first { $0.id == profile.id } })
        }.filter { !$0.games.isEmpty }
    }

    /// Games in sidebar order, for ⌘1…⌘9.
    var ordered: [GameModel] { sections.flatMap(\.games) }

    func select(index: Int) {
        guard ordered.indices.contains(index) else { return }
        selectedID = ordered[index].id
    }

    func poll() async {
        while !Task.isCancelled {
            let snapshot = await Task.detached { ProcessSnapshot.take(under: GamePaths.dataFolder()) }.value
            for game in games { await game.refresh(snapshot) }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
