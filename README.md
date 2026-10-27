# MacGames Local — a fork of MacGames

**This is [DrA1ex/macgames](https://github.com/DrA1ex/macgames), a fork of [tarikbc/macgames](https://github.com/tarikbc/macgames).** It focuses on launching already-installed Windows games on Apple Silicon, tested AoE II/AoE IV Rosetta improvements, and an explicit HiDPI switch. It is an independent development fork; upstream downloads do not include these changes.

**[Download the fork DMG — v0.1.3-fork.2](https://github.com/DrA1ex/macgames/releases/tag/v0.1.3-fork.2)**

The ready-to-use build includes the AoE II selection-stutter fix, shared game environments and bundled AoE II artwork. It is an experimental, locally signed build and is **not Apple-notarized**. It uses the local-EXE interface below; the separate Steam contribution branch is not this release.

`fork.2` fixes an x87sidecar register-allocation abort seen when selecting a unit after playing for a while. GS/RIP memory operands now use the same whole-block Rosetta fallback as ordinary GS/TLS operands. The selection-function cache remains enabled. A standalone reproducer failed on `fork.1` and passes on this build; extended gameplay after this fix still needs validation.

## What this fork adds

- **Choose an installed EXE and play.** The local app uses the selected game files in place, with the same shared environment groups as upstream. It does not install or start Steam/Battle.net in this UI. A custom working folder is optional.
- **Rosetta optimization.** One switch covers x87 translation and, for the exact supported AoE IV executable, software-fault handling and translated-code reuse. The common sidecar composes the decoders and includes GS/TLS, FBLD, FSINCOS and logarithm fixes. Different executable builds retain the existing guards and fallback behavior.
- **Age of Empires II: Definitive Edition.** The card launches the existing EXE directly and installs its bundled game-specific Wine profile. With Rosetta optimization and Exception handling enabled, it connects the selection-function cache automatically and applies the audio startup workaround. AoE IV uses the same sidecar with its own settings. See [LOCAL-AOE2.md](LOCAL-AOE2.md).
- **HiDPI (Retina).** One saved preference per environment exposes Wine's RetinaMode on scaled displays. All cards in a group show the same value. Both on and off work, existing preferences are adopted on upgrade, and Windows UI DPI is left alone. Changes apply at the next game launch.
- **Opt-in diagnostics.** CLI profiling and performance recordings are separate from ordinary Play. Performance comparisons should omit extra counters, HUD logging, encoder tracking and GPU capture.
- **Reproducible helper build.** The patched x87sidecar is built from hash-pinned sources. Vendored/installed Wine Mach-O binaries are not rewritten by this build.

The inherited catalog contains more game profiles, but the modified local-launch/gameplay path has been exercised with Age of Empires IV and AoE II Definitive Edition. The tested AoE builds are guarded by the SHA-256 values already specified in `GameCatalog.swift`; this repository contains no game executable, saves, personal logs or proprietary graphics binaries.

## Focused upstream contribution

The earlier Steam/Battle.net-compatible proposal was merged as [upstream PR #5](https://github.com/tarikbc/macgames/pull/5) and shipped in [0.1.3](https://github.com/tarikbc/macgames/releases/tag/v0.1.3). Upstream tested the final head through Steam and notarized the rebuilt sidecar. Its shared environment HiDPI setting, fixed-on Overwatch mode and ordinary registry recipe updates are retained here.

This fork keeps its local-EXE interface. The separate [AoE II Steam contribution branch](https://github.com/DrA1ex/macgames/tree/feat/aoe2-steam) starts from upstream 0.1.3, without the fork-specific UI and diagnostics. It uses App ID 813780 and the existing shared Steam environment. No pull request has been opened; actual Steam gameplay still needs validation.

## Install the fork build

Download `MacGames-Fork-v0.1.3-fork.2.dmg` from the fork release, open it, and drag **MacGames.app** into **Applications**. Select the game's card, choose your installed Windows EXE and press **Play**. AoE II and the other compatible Steam-library profiles share `~/Library/Application Support/macgames/steam`; settings and caches remain per game. Special environment groups follow upstream's layout. The app prepares missing runtime dependencies on first launch.

For AoE II, enable **Rosetta optimization** and **Exception handling** to use the tested cache path. The fixed-address optimizations apply only to the supported EXE hash; other builds retain the guarded fallback. Game files and saves are not distributed in the DMG.

## Build and use

Requirements: Apple Silicon, macOS 26+, Apple's Swift/C++ Command Line Tools and CMake. Building the AoE II overlay also requires an x86_64 MinGW compiler and, for a fresh Wine build, LLVM/lld, bison and flex. The local build script uses an installed MacGames runtime or the verified vendored runtime; it does not require XcodeGen or Sparkle downloads.

```sh
git clone https://github.com/DrA1ex/macgames.git
cd macgames
scripts/fetch-runtime.sh
scripts/build-local.sh
open "build/MacGames Local.app"
```

The first command that fetches the runtime downloads upstream runtime4 and checks its SHA-256. The sidecar build applies `patches/x87sidecar/0001` through `0007` to the source archive and retains corresponding patched sources. The AoE II builder also prepares a separate native/PE Wine overlay and cache helper from pinned sources; see [patch provenance and build details](patches/README.md). CMake can be installed with `brew install cmake` if absent. The local app has upstream automatic updates disabled so an upstream release cannot silently replace the fork.

In the app, choose the matching profile, choose its installed EXE, then Play. Settings include **Rosetta optimization**, **HiDPI (Retina)** and the optional performance HUD. Environment groups match upstream: most games share `~/Library/Application Support/macgames/steam/`, while Skyrim, Overwatch and other special groups keep their own environments. Per-game selections, settings and caches stay under `games/<game-id>/`; game files stay in their chosen folder. See [LOCAL-AOE4.md](LOCAL-AOE4.md) for the local workflow and CLI.

Previous `<game-id>-local` bottles are retained for rollback. On first direct launch, missing game settings and user files are copied into the shared environment. Existing files are kept, conflicts are reported, and registry/engine files are not merged. The source baseline is tagged `local-before-shared-environments-2026-10-24`.

The release workflow signs the rebuilt sidecar with the release Developer ID and hardened runtime. Local builds keep their ad-hoc signatures.

The full Xcode project is also present. Generate it with XcodeGen; its runtime embed phase uses the same source-patched helper. Fork builds use a distinct `com.dra1ex.macgames.local` identity and disable upstream automatic updates.

## Patch origins and history

[patches/README.md](patches/README.md) identifies each borrowed mechanism and original change, links exact upstream sources and hashes, and explains licensing:

- MacGames, its Wine software-fault dispatcher/cache, and the original decoder hooks came from **tarikbc/macgames runtime4**.
- The translator and cooperative protocol came from **athei/x87sidecar**, including runtime4's existing modifications.
- **tarikbc/ageofempires-android**, pinned at `d7749d907c394d200ec376f423cb41086712b59a`, supplied research context and FEX optimization ideas. FEX translation code was not copied into Rosetta.
- Decoder composition, GS whole-block fallback, the FBLD fix, launcher integration, local-EXE workflow, and UI/settings/tests were implemented in this fork.
- Extra Wine context/direct-dispatch work is retained in [patches/wine/experimental](patches/wine/experimental/README.md), under separate commits. Its tested combination is bundled for the AoE II profile. Other cards retain their ordinary Wine; switching profiles restores the matching engine and prefix ntdll before launch.

Each working sidecar patch has its own commit. Integration, HiDPI, local-launch support, the two experimental Wine patches, and documentation are separate commits too. Rejected native D3DMetal resolve-skipping experiments are not enabled or bundled.

## Validation

- Upstream-compatible branch: **285 tests / 73 suites**, plus full Xcode/Steam/Sparkle app build.
- Fork main: **323 tests / 81 suites**, plus the complete local app and source-patched helper build.
- Separate AoE II Steam branch: **297 tests / 74 suites**, a complete Release build, and synthetic Wine → bridge → sidecar child-process checks. This does not replace actual Steam gameplay testing.
- Game observations: an M5 Pro / macOS 26.5.2 local AoE IV save improved from an initial user-reported 20-25 FPS to 55-58 FPS after the working combination and crash fixes. These are single-machine observations, not a controlled cross-platform benchmark or a promise.
- AoE II: the user reproduced selection stutter in «ПЕРФ», confirmed that the cache restored unselected-level smoothness, then repeated the test successfully through the ordinary runner with automatic installation/connection. Both functions passed without reported cache errors or body mismatches.
- Matched 3840x2160 windowed comparison: installed app **24.91 ms GPU / 39.70 FPS**; control without extra diagnostics **24.88 ms / 39.34 FPS**. Extra instrumentation had confounded earlier comparisons. Actual render size and scene state must match.

Run core tests with:

```sh
cd Packages/MacGamesCore
swift test --no-parallel
```

Local ad-hoc signatures change after rebuilding. macOS may request folder access again; avoid running differently built copies with the same app identity at once. No TCC resets, relaxed signature requirements or broad filesystem grants are part of this fork.

## Upstream and licenses

Original project: [tarikbc/macgames](https://github.com/tarikbc/macgames), [website](https://macgames.app/), [upstream releases](https://github.com/tarikbc/macgames/releases). Those releases are upstream builds, not releases of this fork. This fork provides source, a local build workflow and an experimental DMG release.

MacGames retains its [PolyForm Noncommercial 1.0.0 license and required notice](LICENSE). MIT x87sidecar/HDE and LGPL Wine retain their own notices in [LICENSES](LICENSES/). New sidecar/Wine modifications retain their respective component licenses; this fork does not relicense third-party components.
