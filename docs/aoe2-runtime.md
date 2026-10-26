# Age of Empires II: Definitive Edition

The profile uses Steam app **813780**, installed as `steamapps/common/AoE2DE/AoE2DE_s.exe`, and the existing shared Steam environment. Play uses Steam's normal `-applaunch 813780`; this branch does not add external-EXE selection or another bottle.

The existing Rosetta optimization switch controls the exact-build optimization. The game EXE is checked by MacGamesBridge, the cache loader and the cache DLL. A different EXE falls back to the ordinary Wine path. The observed supported EXE SHA-256 is `124744bf4ae0d3856238e00d61fe321d47fcd3c0d7dfcd175c6c76aa9fb458ff`; this has not yet been verified against a fresh Steam installation.

## Runtime

The common sidecar adds the FSINCOS/logarithm register-pressure fixes and four bounded non-returning AoE II transfers. Its normal AoE IV path remains separate. The AoE II Wine overlay adds direct software-fault delivery, a conservative continuation cache and the observer needed by the small selection-function cache. Cached functions retain their unwind metadata and Microsoft FH4 cleanup. Every 1024th cached entry is revalidated through the original handler; a changed body disables that cache. The EXE itself is never modified.

EngineInstaller selects the overlay for AoE II, and restores the ordinary engine and prefix ntdll for other profiles. The previous game must be closed before changing the shared engine. Opening an existing Steam preserves downloads and still applies ordinary registry recipes. The cache helper starts after the Steam play request; its control-file path is stable so it does not invalidate the Steam session fingerprint.

AoE II also uses `MallocProbGuard=1` to select caulk's alternative audio allocator, avoiding the reproduced startup assertion on the test machine. This is process-wide and is included in the managed Steam fingerprint. It is separate from the selection optimization and is not evidence of a general audio fix on every Mac.

## Source build and signing

`scripts/prepare-aoe2-runtime.py` checks the runtime4 Wine source archive, applies only `patches/wine/aoe2`, builds native/PE ntdll and the helper, and records actual binary hashes. The corresponding modified Wine and helper sources, plus the HDE license, are embedded with the app. HDE headers are reused from the same pinned Wine source; no second decoder copy is vendored here.

The runtime builder needs Apple's compiler plus LLVM/lld, bison/flex and an x86_64 MinGW compiler. CMake remains required for the sidecar. **The additional build toolchain needs maintainer agreement before an upstream PR**, under CONTRIBUTING.md; preparing this branch does not imply that agreement or create an issue. A prebuilt upstream runtime overlay could replace the local Wine build later without changing the game-launch path.

Release signing signs the new native module and then refreshes its capability hashes and the sidecar marker before signing the outer app. Vendored Wine executables and their entitlements are preserved. Final Developer ID signing and notarization require the maintainer's release credentials and have not been performed here.

## Validation

- Core tests cover the Steam App ID/path, shared prefix, automatic helper ordering, stable fingerprint, changed-EXE fallback, stale capabilities, engine switching, active-game protection and preservation of an open Steam session.
- The native/PE pair and complete Release app build from source. A synthetic Windows `steam.exe` fixture uses CreateProcess to launch the game-named child with the Steam App ID. It exercises the actual Wine → MacGamesBridge → sidecar chain, x87 math, changed-hash fallback and independent AoE IV bounds.
- Cache probes validate relative targets, CONTEXT preservation, balanced fallback/disable and Microsoft FH4 cleanup. Inputs containing locally decoded game bodies are not included in this repository.
- Local-EXE gameplay in the fork was tested with a save that reproduces the selected-unit slowdown, which was resolved. **Actual Steam gameplay, install/update cycles and other hardware still need testing.** No uncapped-FPS or notarization claim is made for this branch.
