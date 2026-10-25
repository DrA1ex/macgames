# Non-returning selected softfault experiment

This directory is excluded from the default patch glob in prepare-aoe-runtime.sh.
Apply 0006 after the normal sidecar patches only with experimental Wine patch
0009 and the already pinned AoE II executable. Enable LOCAL_AOE_SELECTION_JUMP=1
only in the isolated matching runtime. A mismatched native Wine has no veneers
and must never receive this switch. The diagnostic launcher checks both binary
hashes; this switch is not enabled by the regular game card.

The existing decoder represents an invalid opcode as a CALL into Wine. A
synthetic test demonstrated that Rosetta translates unreachable x87 bytes at
the advertised return address even when VEH resumes somewhere else. This patch
uses a JMP at four measured AoE II selection sites. Four immutable veneers in
Wine's existing bridge page push the original fault PC plus one, then jump to
the existing one-byte dispatcher. Thus the stack, registers, guest exception PC
and normal game handler behavior remain unchanged, including at the two-byte
site. Other sites retain the existing CALL path. No game bytes are patched.

On the development build, aoe2_nonreturn_probe.c reported four unreachable
FYL2XP1 translations with CALL and zero with JMP; all four handlers returned
correctly. aoe2_nonreturn_context_probe.c passed 46,000 deliveries, checking
all GPRs, RSP, carry, XMM/YMM, segment selectors and live per-thread debug
registers. Existing nested VEH, resumable SEH, unwind/finally and debugger
first-chance probes also passed. These are correctness and translation-behavior
checks; the first gameplay window reduced sidecar traffic from about 21,123 to 142 requests/s, but median raw HUD interval stayed at 33.34 ms. The user reported only a small improvement and substantial remaining lag. This does not establish a complete stutter fix.
