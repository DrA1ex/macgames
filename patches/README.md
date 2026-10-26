# Patch provenance and runtime build

## What is borrowed and what is implemented here

| Component | Origin | Changes in this fork |
|---|---|---|
| MacGames application and game profiles | [tarikbc/macgames](https://github.com/tarikbc/macgames), base `516faa41d0548eab831080054c22596a9aee48ef` | New integration and settings described below; original notices retained. |
| Wine softfault dispatcher and immutable fragment cache | Already shipped by MacGames [runtime 4](https://github.com/tarikbc/macgames/releases/tag/runtime-4), `Sources/wine-source.tar.gz` | Reused through the existing opt-in environment. These are not new Wine implementations by this fork. |
| x87 translator, cooperative protocol, and original softfault decoder | [athei/x87sidecar](https://github.com/athei/x87sidecar), as modified and distributed in MacGames runtime 4 | Source patches below; original MIT notices retained in `LICENSES/Sidecar-MIT.txt`. |
| Performance investigation | [tarikbc/ageofempires-android](https://github.com/tarikbc/ageofempires-android/tree/d7749d907c394d200ec376f423cb41086712b59a/patches/fex) | FEX patches 0010/0012/0014/0017 supplied ideas and a comparison target. No FEX translator code was copied into Rosetta. Patch 0016 was investigated but not implemented. |
| HiDPI | Existing Wine `HKCU\Software\Wine\Mac Driver` / `RetinaMode` mechanism, already used by upstream's Overwatch recipe | New per-game preference, migration, UI/CLI, recipe override and launcher-session handling. No new pixel-scaling engine. |

### New x87sidecar work

Apply in numeric order to `Sources/sidecar-source.tar.gz` from runtime 4:

1. `x87sidecar/0001-compose-softfault-and-x87-decoders.patch`: original integration of two existing decoder paths, so the software-fault hook no longer disables x87 translation.
2. `x87sidecar/0002-fallback-gs-blocks-before-x87-emission.patch`: original whole-block GS/TLS fallback for the allocator failure observed during save loading. The stock Rosetta path handles these blocks.
3. `x87sidecar/0003-flush-fbld-deferred-pops-before-inputs.patch`: original register-pressure fix and regression case for FBLD after a deferred pop.
4. `x87sidecar/0004-reduce-fsincos-register-pressure.patch`: fork-only fix for the AoE II sidecar abort in `alloc_free_fpr` while translating FSINCOS. Reorders independent Estrin branches without changing arithmetic operations, reducing the peak from eight FPRs to seven. Includes a native emitter regression for every missing-register position in the eight-register scratch pool (`test_fsincos_pressure`). This change is separate from the existing upstream proposal.

New changes to the MIT sidecar are provided under that component's MIT license. New Swift/app changes follow MacGames' existing contribution license. This document does not change third-party licenses.

The exact baseline sidecar archive SHA-256 is:
`50ad26b802a590b7c49a121da35ca632bc2676b2fcde40b663805e612d547ff0`.
The upstream runtime archive and its hashes remain pinned by `scripts/fetch-runtime.sh`.
The runtime source archive does not carry a trustworthy x87 Git commit identifier; we pin the actual distributed source bytes rather than invent one.

5. `x87sidecar/0005-reduce-logarithm-register-pressure.patch`: fork-only fix for the captured FYL2XP1 abort in `emit_inline_log2`. Reuses dead/output registers to reduce the log core to five internal FPRs (seven including operands), preserving the arithmetic graph. FYL2X/FYL2XP1 decline to stock before emission when fewer than seven are available; a mid-run decline flushes deferred state. Native pressure tests cover all single-missing-register positions, low-pool fallback and mid-run flushing.

## Reproduce the working helper

```sh
scripts/fetch-runtime.sh
# Requires CMake and the Apple C++ toolchain; brew install cmake if needed.
scripts/prepare-aoe-runtime.sh
```

This verifies the source archive, applies the patches, and builds a new arm64 helper in `build/aoe-runtime/`. It does not modify `Vendor/Engine`, the installed Wine engine, or its entitlements/signatures. The Xcode embed phase uses this helper, embeds a capability marker and corresponding patched sources, and keeps the original runtime licenses.

## Steam launch behavior

The existing `optimized` setting starts Steam with the existing Wine softfault/cache variables. A capability marker enables `MACGAMES_AOE_COMBINED=1` only when the app bundles the rebuilt sidecar. When Wine re-execs the Steam-launched `RelicCardinal.exe` through MacGamesBridge, the bridge checks its existing exact executable SHA-256 guard, then removes the legacy `X87_ALWAYS_NONE` switch for the composed decoder. Different or unreadable builds retain the plain-loader fallback, with all address-specific environment variables removed.

There is one UI switch, **Rosetta optimization**, rather than exposing implementation acronyms as separate controls. The description names x87, exception handling and translated-code reuse. The option still applies only to the supported game build and Rosetta versions.

## Validation and limits

The working combination was exercised in a locally installed AoE IV save on an M5 Pro / macOS 26.5.2. The initial user observation was 20-25 FPS and the corrected combination reached 55-58 FPS without the reported save-load crashes in that test. These are observations from one machine, not a reproducible cross-platform benchmark or a guarantee.

Later testing at a matching 3840x2160 window size found installed MacGames at 24.91 ms GPU / 39.70 FPS and the control with extra diagnostics disabled at 24.88 ms / 39.34 FPS. Extra instrumentation had confounded earlier comparisons. Performance runs should keep actual render dimensions and scene state equal and omit diagnostic counters, HUD logging, GPU capture and encoder profiling.

The Steam integration is covered by argument/environment/fallback and launcher-session tests; the full modified Steam end-to-end game path has not yet been manually tested. No game files, personal saves/logs, proprietary D3DMetal binaries, native resolve-skipping experiments or unsupported renderer replacements are included in this change.

## Fork-only additions

The main branch additionally contains an original selected-EXE workflow, per-profile local prefixes, an optional working folder, generic cooperative x87 entry, and opt-in profiling/recording tools. These adapt existing MacGames/Wine/x87sidecar interfaces; they are not borrowed FEX patches and are excluded from the upstream proposal.

The original Wine research patches live in `wine/experimental/`, along with test probes and their applicability/validation limits. They apply to the pinned runtime4 Wine source. The fork bundles their tested combination in an AoE II overlay selected only for that game. Their base source archive SHA-256 is `7be5819017b34f09670293f2be7ed9f4476734b8f42dab121a8b74e6619c92a8`.

## Integrated AoE II runner profile

`prepare-aoe2-runtime.py` builds native/PE ntdll from the pinned Wine archive plus experimental 0004–0009, builds the bounded EXE-specific cache DLL/loader, and records every binary hash. It preserves the matching modified Wine/cache sources. For local reuse, `--import-engine /path/to/the/validated/engine` accepts only the exact previously tested binary pair and patch hashes; other inputs require a source build.

Both Xcode and `build-local.sh` embed this overlay and source archive. EngineInstaller selects it only for local AoE II, includes its capability hash in the installed-engine marker, and returns to the ordinary engine when another profile is launched. Prefix ntdll is recopied to match the selected engine. An active Wine session cannot be replaced. Settings, saves and external EXE paths stay in the existing shared environment.

The single common sidecar now includes patch 0006. Its four AoE II JMP sites are gated by the game's exact hash, the native/PE capability and a sidecar SHA marker; generic x87 and AoE IV retain their own launch paths. The AoE II profile also sets the previously validated `MallocProbGuard=1` audio workaround only for its game launch. Existing Rosetta optimization and Exception handling controls remain available for comparisons.

The validated local integration reused the exact previously tested native/PE binaries through the hash-checked import path. The clean Wine source-build fallback is provided but was not exercised in that integration run.
