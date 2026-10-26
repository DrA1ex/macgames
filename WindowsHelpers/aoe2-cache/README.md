# AoE II selection-cache helper

Source for the exact-build cache DLL and its Steam-session loader. See ../../docs/aoe2-runtime.md for gates, behavior and validation limits. The loader and DLL each hash the actual EXE; only the supported game is accepted.

Build with `build.sh OUTPUT WINE_SOURCE/dlls/ntdll/unix`. HDE64 is reused from the pinned Wine source and retains the BSD terms in ../../LICENSES/HDE-LICENSE.txt; the independent cache/loader code follows the repository license.

selftest.c and pipeline.c are standalone Windows checks. selftest takes locally decoded large body, unwind and small body files; pipeline takes the small body. Link at image base 0x150000000, compile catch.c with clang Windows SEH support, and supply the same HDE include directory. Proprietary input snapshots are deliberately not distributed.
