# Age of Empires II: Definitive Edition

The `aoe2` card starts the selected `AoE2DE_s.exe` directly, using MacGames' shared Steam environment without starting or installing Steam. Select the existing EXE; the game files stay in their original folder. Artwork uses Steam app 813780.

## Comparison modes

- **Rosetta optimization off:** ordinary Wine/Rosetta launch.
- **Rosetta optimization on:** cooperative generic x87 translation.
- **Rosetta optimization on + Exception handling (experimental):** x87 plus software delivery of supported invalid-opcode exceptions in the pinned executable's code range.

The exception switch defaults to off, including when reading older settings. It requires Rosetta optimization and a runtime with the composed decoder marker. The bridge hashes the EXE immediately before launch. A different or unreadable build falls back to generic x87 and loses every fixed-address extension.

The tested EXE SHA-256 is `124744bf4ae0d3856238e00d61fe321d47fcd3c0d7dfcd175c6c76aa9fb458ff`. Its executable sections are `.text` at `0x140001000..0x1431962f2` and `.rodata` at `0x143197000..0x143197790`. The bounded software-fault decoder uses `0x140001000..0x143197790`, with the existing Wine bridge entries at `0x180000000` and `0x180000010`. AoE IV's internal ring pointer is never used for this game.

A separately rebuilt native Wine can opt into the AoE II ring cache (experimental Wine patch 0007). This requires `engine/.macgames-aoe2-fragment-cache` containing version `1` and the SHA-256 of `lib/wine/x86_64-unix/ntdll.so` on separate lines. A missing, malformed or stale marker leaves the cache disabled. With a matching marker and exception handling enabled, the app sets both `AOELAB_CODE_CACHE_GAME=1` and `AOELAB_CODE_CACHE_AOE2=1`. The ring pointer is `0x144c943f0`, verified from the game handler and live memory; its actual allocation address is read at runtime. The cache copies only conservatively supported fragments after the game handler runs, preserving unsupported-path fallback and original fault PCs. The default packaged Wine is unchanged.

## CLI

```sh
MacGames --command settings --game aoe2 --local-exe /path/to/AoE2DE_s.exe --optimized off --exceptions off
MacGames --command play --game aoe2
MacGames --command settings --game aoe2 --optimized on --exceptions off
MacGames --command settings --game aoe2 --optimized on --exceptions on
MacGames --command record-performance --game aoe2 --output /new/recording-folder
```

Close the game between modes. Use the same save/replay, camera, resolution, renderer, HUD and sync settings for comparisons. Compare frame-time spikes and slow frames, not only average FPS. Diagnostic `--profile /new/folder` additionally records x87 and guest samples and should be measured separately from ordinary gameplay.

## Validation limits

The initial ordinary launch reproduced an intermittent Wine audio assertion in `mmdevapi_private.h:120` during audio stream initialization. Successful launches alone do not establish a fix. Startup reliability and gameplay frame pacing need separate validation; no stutter improvement is claimed by adding the profile or the experimental switch.

Live selected/unselected/selected measurements found handled `0xc000001d` exceptions at four selection-sensitive PCs (`0x140f77b90`, `0x140f77dd3`, `0x140f77e10`, `0x140f77e3c`). Native counters recorded zero hardware illegal-instruction traps while `NtRaiseException` remained hot: the software bridge was already active, but its delivery still crossed the Wine Unix boundary. This identifies a candidate cost; exception counts alone do not establish the cause of long frames.

A separate local test environment uses experimental Wine patches 0004/0005 for direct exception dispatch, with the original runtime preserved. Context preservation, SEH/unwind and debugger-fallback probes passed. Its first game test exposed a sidecar FSINCOS register-allocation abort, now covered by sidecar patch 0004. The old emitter aborts with seven free FPRs; the patched emitter passes all eight single-missing-register masks, and FSIN/FCOS/FSINCOS numerical and condition-code tests pass with and without IR lowering. Reliable startup remains unverified. The default packaged Wine runtime does not include the experimental dispatcher.

The subsequent direct-dispatch gameplay capture still showed selection-dependent stutter: median raw HUD interval about 100 ms selected versus 16.67 ms unselected. Native `NtRaiseException` and hardware illegal-instruction counters stayed zero in both states. The four selection PCs fell from about 1,879/s each to 151/s each when deselected, while total exception rate rose; total exception count alone does not explain frame pacing.

Targeted handler timing then measured roughly 36–39 microseconds per call at these PCs and observed redirects into a mutable ring. Two continuation patterns were entry saves plus a jump back to the game; both exit sites generated RET. All 512 captured fragments normalized to three immutable keys. The new cache variant passes changing-content, RIP-relative, return, unsupported-branch and original-access-violation-PC probes, plus the context/SEH/debugger checks. In the first cache gameplay capture with the same save and selected group, the median raw HUD interval fell from about 100 ms in the earlier direct-dispatch capture to 33.34 ms (p95 51.56 ms), with GPU time around 7.48 ms. Over 20 seconds the cache recorded 869,961 hits, no new entries and 11,364 unsupported fragments. The user also reported a visible improvement, but selection still caused a substantial slowdown. These were separate launches, and raw HUD history contains duplicate points; this is not a controlled display-FPS benchmark. Patch 0008 additionally admits four observed register-only SSE2 forms for AoE II; its 20,650-continuation probe passed, including 400 SIMD cases. In its subsequent selected-group capture, all 863,069 cache requests hit existing entries over 20 seconds, with zero unsupported fragments or new entries. Median raw HUD interval remained 33.34 ms (p95 59.48 ms), so accepting the remaining SIMD fragments did not resolve the residual slowdown. GPU median was 7.76 ms. A separate ten-second native-counter window recorded no hardware illegal-instruction traps, no NtRaiseException transitions, no protection calls or cache flushes, and about 80 handled page-write faults per second. These observations narrow the remaining investigation; they do not identify a new proven cause.

That gameplay session later aborted in x87sidecar while translating FYL2XP1: `emit_inline_fyl2xp1` called `emit_inline_log2`, which exhausted its temporary FPR pool. This is distinct from the earlier FSINCOS abort and the intermittent audio Status assertion. Sidecar patch 0005 reproduces the old seven-register abort, lowers logarithm register pressure, and returns unsupported low-pool cases to stock Rosetta. All 34 native logarithm pressure/fallback cases, nine FSINCOS pressure cases and 84 numerical checks across FYL2X/FYL2XP1/FSINCOS (default and IR-disabled) passed. Sustained gameplay after this fix still requires validation.

With sidecar patch 0005, the subsequent selected-group capture recorded 826,901 cache hits in 20 seconds, zero unsupported fragments and median/p95 raw HUD intervals of 33.34/58.04 ms. The process remained alive through the ten-minute recording limit. This single run does not establish long-term stability or fix the intermittent audio assertion.

A separate synthetic probe then demonstrated speculative translation after the software-fault CALL: an unreachable FYL2XP1 tail was translated even though VEH redirected execution. The earlier live handler snapshots show changing encrypted bytes on entry and stable decoded bytes after the handler at the selection sites. Experimental Wine 0009 plus the separately opt-in sidecar experiment replaces the transfer at four pinned PCs with a non-returning JMP through equivalent bridge veneers. The synthetic comparison eliminates all four unreachable-tail translations, and 46,000 selected-site context checks pass. In the first selected-group gameplay comparison, sidecar traffic fell from approximately 21,123 to 142 requests/s. Median raw HUD interval remained 33.34 ms, while p95 fell from 58.04 to 50.00 ms; GPU medians were 7.75 and 7.61 ms. The user reported a small improvement but still unacceptable lag. Separate launches, duplicated HUD history points and system-wide memory activity limit this comparison. The remaining selection slowdown is unresolved.

## Intermittent audio startup assertion

A later native-fault capture identified `STATUS_ILLEGAL_INSTRUCTION` (`0xc000001d`) in Apple's `caulk::alloc::consolidating_free_map<...>::maybe_create_free_node + 119` while Wine was creating the audio stream. The instruction is an intentional `UD2` invariant trap. Saved registers show a zero-sized free node and a 4,160-byte request, leading to a negative remainder. The source of the allocator's inconsistent state is not established. Similar macOS 26 audio crashes and the same trap location are discussed in [Apple's developer forum](https://developer.apple.com/forums/thread/824550).

Local binary inspection found that caulk selects a zeroing malloc-zone resource when the process's first malloc zone is `ProbGuardMallocZone`. `MallocProbGuard=1` selects that zone for this process. An isolated x86 helper confirmed that the actual audio resource changes from `darwin_resource<audio_allocator>` to `resource<zeroing_allocator<malloc_zone_allocator>>`. This uses an existing branch in the system library; no system files, preferences or assertions are patched.

A controlled startup batch used one unchanged launch and five launches with this environment setting in a separate prefix. The control reproduced the exact caulk trap after 23 seconds. All five alternative-allocator launches remained alive and produced frames during the following 35-second observation windows (about 39 seconds including launch). No save was loaded. These results support a startup workaround, not a claim of long-term stability or reduced gameplay stutter. The minimal native audio probe also passed without the workaround, so that probe alone is not evidence that the intermittent bug is fixed.

For an explicit local trial, pass the environment to the CLI:

```sh
env MallocProbGuard=1 MacGames --command play --game aoe2
```

Keep this scoped to the AoE II process. It enables a process-wide diagnostic malloc wrapper as well as caulk's alternative audio resource, so gameplay performance still needs validation. It is not enabled by the ordinary game card in this source revision.

The bounded handler capture after loading the reproduction save measured roughly 6,713 calls/s at each of the four selection PCs and 14.8–15.9 microseconds per original handler call. Chain and handler times overlap and must not be added. Main-thread samples repeatedly found rewriting of the same two function bodies. A direct-store replacement for Wine MOVS did not improve a corrected executable-code benchmark and was rejected.

## Selection-function cache

The separate [function-cache source and preparation instructions](patches/wine/experimental/aoe2-function-cache/README.md) preserve immutable copies of both decoded functions. The first version retained every original entry/exit handler and improved the user's selected Frame Interval from 25–30 ms to an unstable 18–20 ms, compared with about 10 ms unselected.

The next version enters a cached RET copy directly, with original-handler revalidation every 1024 entries. Normal handler fallbacks still use their matching original exit, so entry/exit accounting stays balanced. Microsoft FH4 cleanup, relocation, context preservation, live disable and changed-body fallback checks passed. The user then reported the same smoothness with and without selection in «ПЕРФ».

In a same-process 20-second selected-group comparison, raw HUD interval median/p95 fell from 24.69/50.00 to 16.67/18.93 ms; main-thread CPU fell from 72.35% to 46.59% of one core. Raw histories contain duplicate points, so these are not unique-frame FPS counts. The initial window recorded about 447000 hits per function with no errors or body mismatches; the longer trial exceeded 13.9 million hits per function without errors. This is a successful reproduction test; longer sessions and other saves remain to be tested.

MacGames can connect this cache automatically on a separately prepared engine when both existing optimization switches are on. A capability file pins native Wine, engine/prefix PE ntdll, cache DLL and loader hashes. MacGames, the loader and the DLL independently retain the exact-game hash gate. A normal packaged engine has no capability file and does not load this DLL. The persistent helper has no 15-minute limit. The earlier private temporary probe is distinct.

One evening launch remained in the load menu and showed black after a second load click, before any new function-cache DLL was loaded. Restarting the unchanged runtime allowed the same save to load. That incident is unresolved and should not be attributed to the then-unloaded candidate.
