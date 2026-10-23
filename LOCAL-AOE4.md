# Local game workflow

1. Select the game profile in **My Games**.
2. Choose the installed game EXE; the files stay in place.
3. Choose **Play**. The first launch prepares an isolated Windows environment.

This fork's local UI does not install or start Steam/Battle.net. The separate upstream proposal keeps their normal launcher flow.

**Settings -> Rosetta optimization** enables x87 translation. On the exact supported AoE IV build, it also enables the composed software-fault and fragment-cache path. One UI switch controls the combination; low-level mechanisms are explained in the description. The existing EXE hash and Rosetta-version guards remain in effect.

**Settings -> HiDPI (Retina)** enables native-resolution rendering on scaled displays. It can be explicitly turned off again. A changed setting applies on the next game launch, and the existing manual Wine preference is adopted when older settings are loaded. It does not modify Windows LogPixels/UI scaling.

Use **Working folder** only when the game needs a folder other than its EXE directory. Each local profile keeps its prefix, settings and logs under `~/Library/Application Support/macgames/<game-id>-local/`.

Build: `scripts/fetch-runtime.sh` then `scripts/build-local.sh`. Output: `build/MacGames Local.app`. The source-patched helper is prepared automatically; installed Wine is not modified.

CLI examples (replace `MacGames` with the bundle executable path when needed):

```sh
MacGames --command settings --game aoe4 --local --hidpi on
MacGames --command settings --game aoe4 --local --optimized on
MacGames --command play --game aoe4 --local
```

Advanced diagnostics (`--profile`, `record-performance`) deliberately add measurement overhead. Ordinary Play does not activate them. For FPS comparisons use the same loaded save, camera, pause state and actual HUD render dimensions; a selected 4K mode alone does not guarantee the same drawable size in a window.
