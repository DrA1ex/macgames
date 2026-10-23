# Patch provenance and runtime build

## What is borrowed and what is implemented here

| Component | Origin | Changes in this fork |
|---|---|---|
| MacGames application and game profiles | [tarikbc/macgames](https://github.com/tarikbc/macgames), base `516faa41d0548eab831080054c22596a9aee48ef` | New integration and settings described below; original notices retained. |
| Wine softfault dispatcher and immutable fragment cache | Already shipped by MacGames [runtime 4](https://github.com/tarikbc/macgames/releases/tag/runtime-4), `Sources/wine-source.tar.gz` | Reused through the existing opt-in environment. These are not new Wine implementations by this fork. |
| x87 translator, cooperative protocol, and original softfault decoder | [athei/x87sidecar](https://github.com/athei/x87sidecar), as modified and distributed in MacGames runtime 4 | Three source patches below; original MIT notices retained in `LICENSES/Sidecar-MIT.txt`. |
| Performance investigation | [tarikbc/ageofempires-android](https://github.com/tarikbc/ageofempires-android/tree/d7749d907c394d200ec376f423cb41086712b59a/patches/fex) | FEX patches 0010/0012/0014/0017 supplied ideas and a comparison target. No FEX translator code was copied into Rosetta. Patch 0016 was investigated but not implemented. |
| HiDPI | Existing Wine `HKCU\Software\Wine\Mac Driver` / `RetinaMode` mechanism, already used by upstream's Overwatch recipe | New per-game preference, migration, UI/CLI, recipe override and launcher-session handling. No new pixel-scaling engine. |

### New x87sidecar work

Apply in numeric order to `Sources/sidecar-source.tar.gz` from runtime 4:

1. `x87sidecar/0001-compose-softfault-and-x87-decoders.patch`: original integration of two existing decoder paths, so the software-fault hook no longer disables x87 translation.
2. `x87sidecar/0002-fallback-gs-blocks-before-x87-emission.patch`: original whole-block GS/TLS fallback for the allocator failure observed during save loading. The stock Rosetta path handles these blocks.
3. `x87sidecar/0003-flush-fbld-deferred-pops-before-inputs.patch`: original register-pressure fix and regression case for FBLD after a deferred pop.

New changes to the MIT sidecar are provided under that component's MIT license. New Swift/app changes follow MacGames' existing contribution license. This document does not change third-party licenses.

The exact baseline sidecar archive SHA-256 is:
`50ad26b802a590b7c49a121da35ca632bc2676b2fcde40b663805e612d547ff0`.
The upstream runtime archive and its hashes remain pinned by `scripts/fetch-runtime.sh`.
The runtime source archive does not carry a trustworthy x87 Git commit identifier; we pin the actual distributed source bytes rather than invent one.

## Reproduce the working helper

```sh
scripts/fetch-runtime.sh
# Requires CMake and the Apple C++ toolchain; brew install cmake if needed.
scripts/prepare-aoe-runtime.sh
```

This verifies the source archive, applies the three patches, and builds a new arm64 helper in `build/aoe-runtime/`. It does not modify `Vendor/Engine`, the installed Wine engine, or its entitlements/signatures. The Xcode embed phase uses this helper, embeds a capability marker and corresponding patched sources, and keeps the original runtime licenses.

## Steam launch behavior

The existing `optimized` setting starts Steam with the existing Wine softfault/cache variables. A capability marker enables `MACGAMES_AOE_COMBINED=1` only when the app bundles the rebuilt sidecar. When Wine re-execs the Steam-launched `RelicCardinal.exe` through MacGamesBridge, the bridge checks its existing exact executable SHA-256 guard, then removes the legacy `X87_ALWAYS_NONE` switch for the composed decoder. Different or unreadable builds retain the plain-loader fallback, with all address-specific environment variables removed.

There is one UI switch, **Rosetta optimization**, rather than exposing implementation acronyms as separate controls. The description names x87, exception handling and translated-code reuse. The option still applies only to the supported game build and Rosetta versions.

## Validation and limits

The working combination was exercised in a locally installed AoE IV save on an M5 Pro / macOS 26.5.2. The initial user observation was 20-25 FPS and the corrected combination reached 55-58 FPS without the reported save-load crashes in that test. These are observations from one machine, not a reproducible cross-platform benchmark or a guarantee.

Later testing at a matching 3840x2160 window size found installed MacGames at 24.91 ms GPU / 39.70 FPS and the control with extra diagnostics disabled at 24.88 ms / 39.34 FPS. Extra instrumentation had confounded earlier comparisons. Performance runs should keep actual render dimensions and scene state equal and omit diagnostic counters, HUD logging, GPU capture and encoder profiling.

The Steam integration is covered by argument/environment/fallback and launcher-session tests; the full modified Steam end-to-end game path has not yet been manually tested. No game files, personal saves/logs, proprietary D3DMetal binaries, native resolve-skipping experiments or unsupported renderer replacements are included in this change.
