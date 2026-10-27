/* Regression for GS/RIP FILD fusion allocating an already occupied X29.
 * Run each case through x87sidecar --cooperative wine x87-gs-rip.exe N.
 * The stock path must preserve the x87 comparison result for all widths. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    unsigned which = argc > 1 ? (unsigned)atoi(argv[1]) : 2;
    if (which > 3) return 64;
    uint64_t raw;
    __asm__ volatile("movq %%gs:0x40,%0" : "=r"(raw));
    double expected = which == 0 ? (double)(int16_t)raw :
                      which == 1 ? (double)(int32_t)raw : (double)(int64_t)raw;
    if (which == 3) memcpy(&expected, &raw, sizeof expected);
    /* GS:[RIP+disp32] resolves to TEB+0x40. Rosetta decodes this as AbsMem,
     * unlike the ordinary GS:[disp32] MemRef covered by the earlier test.
     * The first instruction is FILD m16/m32/m64 or FLD m64; then FLD1,
     * FUCOMPP, FNSTSW AX, RET. No game code or game addresses are used. */
    unsigned char bytes[] = {0x65,0xdf,0x2d,0,0,0,0,0xd9,0xe8,0xda,0xe9,0xdf,0xe0,0xc3};
    if (which == 0) bytes[2] = 0x05;
    if (which == 1) { bytes[1] = 0xdb; bytes[2] = 0x05; }
    if (which == 3) { bytes[1] = 0xdd; bytes[2] = 0x05; }
    unsigned char *code = VirtualAlloc((void *)0x10000000, 4096,
        MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    if (code != (void *)0x10000000) return 3;
    int32_t displacement = (int32_t)(0x40 - (uintptr_t)(code + 7));
    memcpy(bytes + 3, &displacement, sizeof displacement);
    memcpy(code, bytes, sizeof bytes);
    FlushInstructionCache(GetCurrentProcess(), code, sizeof bytes);
    unsigned status = ((unsigned (*)(void))code)() & 0x4500;
    unsigned wanted = 1.0 < expected ? 0x100 : 1.0 == expected ? 0x4000 : 0;
    VirtualFree(code, 0, MEM_RELEASE);
    if (status != wanted) {
        printf("FAIL case=%u status=%x expected=%x\n", which, status, wanted);
        return 2;
    }
    printf("PASS GS/RIP x87 case=%u comparison=%x\n", which, status);
    return 0;
}
