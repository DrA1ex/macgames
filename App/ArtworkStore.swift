import AppKit
import MacGamesCore
import Observation

/// Loads bundled artwork first, then Steam artwork with memory/disk caching.
@MainActor @Observable
final class ArtworkStore {
    static let shared = ArtworkStore()

    private(set) var images: [URL: NSImage] = [:]
    /// Images the CDN does not have, so views can show their fallback.
    private(set) var failed: Set<URL> = []
    /// Art paths the store lists, for apps that keep their art in hashed folders.
    private(set) var resolved: [String: GameProfile.Artwork] = [:]
    @ObservationIgnored private var loading: Set<URL> = []
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let bundled: [String: GameProfile.Artwork]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20,
                                   directory: caches.appendingPathComponent("com.tarikbc.macgames/artwork"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        var local: [String: GameProfile.Artwork] = [:]
        if let resources = Bundle.main.resourceURL {
            for profile in GameProfile.all {
                let folder = resources.appendingPathComponent("Artwork/\(profile.id)")
                let hero = folder.appendingPathComponent("hero.jpg")
                let logo = folder.appendingPathComponent("logo.png")
                let portrait = folder.appendingPathComponent("portrait.jpg")
                if [hero, logo, portrait].allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
                    local[profile.id] = GameProfile.Artwork(hero: hero, logo: logo, portrait: portrait)
                }
            }
        }
        bundled = local
    }

    /// Prefer bundled art; other games resolve their artwork through Steam.
    func artwork(for profile: GameProfile) -> GameProfile.Artwork? {
        if let art = bundled[profile.id] { return art }
        resolveOnce()
        return profile.artwork(resolved: resolved)
    }

    /// The image if it is loaded; otherwise starts loading it and returns `nil`.
    func image(_ url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !loading.contains(url), !failed.contains(url) else { return nil }
        loading.insert(url)
        Task {
            defer { loading.remove(url) }
            if url.isFileURL {
                if let image = NSImage(contentsOf: url) { images[url] = image }
                else { failed.insert(url) }
                return
            }
            guard let (data, response) = try? await session.data(from: url) else { return }
            if (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                images[url] = image
            } else {
                failed.insert(url)
            }
        }
        return nil
    }

    /// Asks the network first, so changed art shows up; offline, the last reply is used.
    private func resolveOnce() {
        guard !resolving else { return }
        resolving = true
        let url = SteamStoreArt.request(appIDs: Array(Set(GameProfile.all.map(\.steamAppID))).sorted())
        Task {
            var reply = try? await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            if (reply?.1 as? HTTPURLResponse)?.statusCode != 200 {
                reply = try? await session.data(for: URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad))
            }
            if let data = reply?.0 { resolved = SteamStoreArt.parse(data) }
        }
    }
}

extension GameProfile {
    @MainActor var art: Artwork? { ArtworkStore.shared.artwork(for: self) }
}
