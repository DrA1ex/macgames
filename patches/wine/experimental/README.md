# Experimental Wine work (not applied by default)

These two patches were implemented in this fork during the AoE IV investigation. They are not FEX code ports and are not part of the upstream PR or the default application runtime. They modify Wine's existing macOS software-fault implementation and keep Wine's LGPL-2.1-or-later licensing; see `LICENSES/Wine-LGPL.txt` and `LICENSES/Wine-LICENSE.txt`.

- **0004: live exception context.** Cache process-wide segment selectors after the first Unix call and read thread-local FS/debug-register state live from the TEB, with shared offset assertions. This avoids repeating a Unix transition solely to supplement an already captured context.
- **0005: direct dispatch.** Enter Wine's normal exception dispatcher directly when no debugger is attached. Preserve native first-chance debugger delivery otherwise. Add the required unwind metadata to both dynamically aligned softfault thunks; without that metadata the first prototype failed nested unwind/finally tests.

The patches apply sequentially to Wine sources shipped with MacGames runtime4 (`Sources/wine-source.tar.gz`, SHA-256 `7be5819017b34f09670293f2be7ed9f4476734b8f42dab121a8b74e6619c92a8`). A fresh source-application check is recorded during publication; no rebuilt Wine binaries are stored in Git.

`probes/softfault_probe.c` and `probes/dispatch_probe.c` are original Windows test sources used for register/context, debugger and exception/unwind validation. The investigation validated GPR/flags/XMM/YMM, segment and live debug state, main/new threads, nested VEH, resumable SEH, stack unwind/finally and 4000 debugger first-chance events. Those tests passed in the development build, but gameplay measurements did not establish a reliable FPS improvement. Do not promote these patches to the default runtime on the strength of the microbenchmark alone.

This directory contains research source, not a complete general-purpose Wine build distribution. A PE ntdll build needs a matching Wine build tree and cross-toolchain; preserve original binaries and use an isolated Wine prefix. No address or executable-build guards are relaxed by these patches.

Rejected native D3DMetal resolve-skipping experiments are not enabled or shipped: the actual game did not meet the safe eligibility conditions, so no performance benefit was established. D3DMetal4 preview was also not selected for the default runtime.
