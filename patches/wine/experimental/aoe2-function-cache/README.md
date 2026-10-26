# AoE II selection-function cache (opt-in)

The original handler repeatedly decodes and rewrites two functions when units are selected. Stable copies alone improved the user's HUD Frame Interval from 25–30 ms to an unstable 18–20 ms. This variant also avoids repeated handler decode/encode work on cache hits. The user then reported the same smoothness with and without selection in the reproduction save.

This is specific to EXE SHA-256 `124744bf4ae0d3856238e00d61fe321d47fcd3c0d7dfcd175c6c76aa9fb458ff`. It is now bundled with the runner as a game-specific overlay, selected by the local AoE II card. Other game profiles retain their ordinary engine. Original game files are never changed.

## Behavior

The first normal handler delivery decodes each body. The cache validates its prologue, relocation boundaries and unwind descriptor and registers independent executable copies. Cached entry faults enter RET copies directly. Every 1024th entry re-enters the original handler and compares the decoded body; this path uses a separate JMP-to-original-exit copy to balance original entries/exits. A changed body disables that function's cache. Other faults keep their original handler chain.

The large function retains Microsoft FH4 cleanup semantics through an address-projecting exception-handler proxy. The code and function tables remain allocated after disable for any in-flight frames. The persistent worker runs until process exit or its control file's stop field is set; it has no 15-minute timer. The earlier private trial DLL had that timer and is not this build.

The loader and DLL each independently hash the actual EXE. MacGames checks the EXE before starting the loader and verifies native Wine, both engine/prefix PE ntdll copies, DLL and loader hashes against the prepared capability file. It starts this helper only for local AoE II with Rosetta optimization, Exception handling and the verified ring cache enabled. Missing/stale capability files leave the extra DLL disabled.

## Prepare an isolated runtime

Apply experimental Wine patches 0004–0009 in addition to the existing runtime patches. The installer deliberately accepts only the development Wine binaries validated during this investigation. With an x86_64 MinGW compiler on PATH:

```sh
python3 patches/wine/experimental/aoe2-function-cache/install.py /path/to/separate-runtime-root
```

The root must already contain `engine/` and `prefix/`. The installer builds only this optional DLL/loader and writes `engine/aoe2-function-cache/capability.json`. It does not rebuild or replace Wine. Rebuild MacGames from this branch and use that root with the existing local-EXE CLI. The prepared card uses its existing Exception handling switch; no extra UI switch is added.

The regular runner profile also enables the separate audio workaround (`MallocProbGuard=1`) for AoE II. It is independent of this cache. The standalone research installer above does not set the launch environment.

## Checks and first live result

- All relative branch/call and RIP-relative relocation targets in JMP and RET layouts.
- Large-frame unwind at six positions, both layouts, with preserved nonvolatile registers.
- 500 original/JMP/RET exception triples through Wine's actual Microsoft FH4 handler: 1500 cleanup calls, no errors.
- 40000 original/JMP/RET small-function result comparisons.
- 40000 real exception-chain calls: 39960 cache hits and 40 balanced original-handler validations.
- Cache-hit CONTEXT changes only Rip; live disable and changed-body fallback retain balanced returns.
- Exact-game hash accepted; a different EXE rejected by the loader.
- MacGames capability tamper and changed-game fallback checks; full Swift suite: 319 tests in 81 suites.

In one same-process 20-second selected-group comparison, raw HUD interval median/p95 changed from 24.69/50.00 to 16.67/18.93 ms, and main-thread CPU from 72.35% to 46.59% of one core. Both functions completed about 447000 cached calls each during the initial capture without mismatch or errors. The user independently reported that selected units now behave like the unselected baseline. Raw HUD histories contain duplicate points and cannot be treated as unique-frame FPS. Other applications caused memory compression/swap activity during both windows. This establishes a successful reproduction test, not long-term gameplay or every possible save.

`selftest.c` and `pipeline.c` use locally obtained decoded body/unwind inputs, which are deliberately excluded from Git. Build the test executable with image base `0x150000000` to leave its synthetic game addresses free, and compile `catch.c` with clang's Windows SEH support. See the test source arguments. HDE64 files retain their BSD license in `HDE-LICENSE.txt`; the remaining research source follows the repository license.

## Integrated build

The ordinary app build now calls `scripts/prepare-aoe2-runtime.py` and bundles its overlay and matching source archive. It does not depend on local diagnostic folders. With the existing Rosetta optimization and Exception handling options enabled, the AoE II card chooses this engine, synchronizes prefix ntdll and connects the cache automatically. Switching to another card restores its ordinary engine before launch. The common sidecar retains independent per-game gates. Tests cover round-trip engine switching, an active-session replacement guard and stale sidecar/capability rejection.
