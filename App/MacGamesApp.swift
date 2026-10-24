#if !LOCAL_BUILD
import Sparkle
#endif
import SwiftUI

struct MacGamesApp: App {
    /// Checks the appcast of this repository's releases for a newer, signed MacGames.
    #if !LOCAL_BUILD
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    #endif

    var body: some Scene {
        Window("MacGames", id: "main") {
            LibraryView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                #if !LOCAL_BUILD
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                #else
                Text("Local build · automatic updates disabled")
                #endif
            }
        }
    }
}
