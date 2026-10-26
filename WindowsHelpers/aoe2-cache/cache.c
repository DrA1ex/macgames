/* Experimental AoE II selection-function cache. Original MacGames research
 * source, distributed under this repository's LICENSE. HDE64 retains BSD terms.
 * Never unload: executable copies and unwind tables may have in-flight frames. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "relocate.h"
#define SMALL_PC 0x140f77e10ULL
#define CLONE_BASE 0x191400000ULL
#define DIRECT_BASE (CLONE_BASE + 8192)
typedef void *(WINAPI *SetObserver)(void *);
typedef struct {
    uint64_t magic;
    DWORD version;
    volatile LONG enabled, stop, done;
    volatile LONG64 redirects[2], mismatch[2], errors;
    volatile LONG64 hits[2], validation[2];
    BYTE reference[2][640];
} Header;
static Header *header;
static BYTE *clones;
static RUNTIME_FUNCTION functions[4];
static volatile LONG initialized[2];
static PRUNTIME_FUNCTION original_function;
static PEXCEPTION_ROUTINE original_handler;
static void *original_handler_data;
static uint64_t to_original(uint64_t pc) {
    uint64_t v = logical_pc(pc, BIG_PC, BIG_SIZE, BIG_EXIT, CLONE_BASE);
    if (v != pc)
        return v;
    v = logical_pc(pc, SMALL_PC, 45, 44, CLONE_BASE + 4096);
    if (v != pc)
        return v;
    if (pc >= DIRECT_BASE && pc < DIRECT_BASE + BIG_SIZE)
        return BIG_PC + pc - DIRECT_BASE;
    if (pc >= DIRECT_BASE + 4096 && pc < DIRECT_BASE + 4096 + 45)
        return SMALL_PC + pc - DIRECT_BASE - 4096;
    return pc;
}
static uint64_t to_direct(uint64_t pc) {
    if (pc >= BIG_PC && pc < BIG_PC + BIG_SIZE)
        return DIRECT_BASE + pc - BIG_PC;
    if (pc >= SMALL_PC && pc < SMALL_PC + 45)
        return DIRECT_BASE + 4096 + pc - SMALL_PC;
    return pc;
}
static uint64_t project(uint64_t pc, BOOL direct);

static uint64_t to_shadow(uint64_t pc) {
    uint64_t v = relocated_pc(pc, BIG_PC, BIG_SIZE, BIG_EXIT, CLONE_BASE);
    if (v != pc)
        return v;
    return relocated_pc(pc, SMALL_PC, 45, 44, CLONE_BASE + 4096);
}
static uint64_t project(uint64_t pc, BOOL direct) {
    return direct ? to_direct(pc) : to_shadow(pc);
}
static EXCEPTION_DISPOSITION WINAPI eh_proxy(EXCEPTION_RECORD *record, void *frame, CONTEXT *context,
                                             DISPATCHER_CONTEXT *dispatch) {
    DISPATCHER_CONTEXT saved = *dispatch;
    CONTEXT *inner = dispatch->ContextRecord;
    BOOL direct = saved.ControlPc >= DIRECT_BASE && saved.ControlPc < DIRECT_BASE + 8192;
    uint64_t old_rip = context->Rip, old_inner_rip = inner ? inner->Rip : 0;
    uint64_t logical = to_original(saved.ControlPc), target = to_original(saved.TargetIp);
    dispatch->ControlPc = logical;
    dispatch->TargetIp = target;
    dispatch->FunctionEntry = original_function;
    dispatch->LanguageHandler = original_handler;
    dispatch->HandlerData = original_handler_data;
    context->Rip = to_original(old_rip);
    if (inner && inner != context)
        inner->Rip = to_original(old_inner_rip);
    EXCEPTION_DISPOSITION result = original_handler(record, frame, context, dispatch);
    // Preserve handler outputs; undo only the address projection presented to it.
    dispatch->ControlPc =
        dispatch->ControlPc == logical ? saved.ControlPc : project(dispatch->ControlPc, direct);
    dispatch->TargetIp = dispatch->TargetIp == target ? saved.TargetIp : project(dispatch->TargetIp, direct);
    if (dispatch->FunctionEntry == original_function)
        dispatch->FunctionEntry = saved.FunctionEntry;
    if (dispatch->LanguageHandler == original_handler)
        dispatch->LanguageHandler = saved.LanguageHandler;
    if (dispatch->HandlerData == original_handler_data)
        dispatch->HandlerData = saved.HandlerData;
    context->Rip = context->Rip == to_original(old_rip) ? old_rip : project(context->Rip, direct);
    if (inner && inner != context)
        inner->Rip = inner->Rip == to_original(old_inner_rip) ? old_inner_rip : project(inner->Rip, direct);
    return result;
}
static int register_big(const BYTE *plain, const BYTE *unwind, PRUNTIME_FUNCTION original,
                        PEXCEPTION_ROUTINE handler, void *data) {
    if (unwind[0] != 0x19 || unwind[1] != 43 || unwind[2] != 12)
        return 20;
    int error = relocate_body(plain, BIG_SIZE, BIG_EXIT, BIG_PC, clones);
    if (error)
        return error;
    original_function = original;
    original_handler = handler;
    original_handler_data = data;
    memcpy(clones + 1024, unwind, 40);
    DWORD handler_rva = (DWORD)(CLONE_BASE + 1280 - GAME_BASE);
    memcpy(clones + 1024 + 28, &handler_rva, 4);
    BYTE stub[] = {0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xe0};
    uint64_t proxy = (uintptr_t)eh_proxy;
    memcpy(stub + 2, &proxy, 8);
    memcpy(clones + 1280, stub, 12);
    functions[0].BeginAddress = (DWORD)(CLONE_BASE - GAME_BASE);
    functions[0].EndAddress = functions[0].BeginAddress + BIG_SIZE + 4;
    functions[0].UnwindData = (DWORD)(CLONE_BASE + 1024 - GAME_BASE);
    if (!RtlAddFunctionTable(functions, 1, GAME_BASE))
        return 21;
    FlushInstructionCache(GetCurrentProcess(), clones, 1292);
    int direct_error = relocate_body_mode(plain, BIG_SIZE, BIG_EXIT, BIG_PC, clones + 8192, 1);
    if (direct_error)
        return 50 + direct_error;
    memcpy(clones + 8192 + 1024, clones + 1024, 40);
    functions[2].BeginAddress = (DWORD)(DIRECT_BASE - GAME_BASE);
    functions[2].EndAddress = functions[2].BeginAddress + BIG_SIZE;
    functions[2].UnwindData = (DWORD)(DIRECT_BASE + 1024 - GAME_BASE);
    if (!RtlAddFunctionTable(functions + 2, 1, GAME_BASE))
        return 71;
    FlushInstructionCache(GetCurrentProcess(), clones + 8192, 1064);
    return 0;
}
static int prepare(unsigned index, const BYTE *body, uint64_t resume) {
    BYTE plain[640];
    unsigned size = index ? 45 : BIG_SIZE;
    memcpy(plain, body, size);
    SIZE_T got = 0;
    const BYTE big_prefix[] = {0x48, 0x89, 0x5c, 0x24, 0x10}, small_prefix[] = {0x40, 0x53};
    unsigned prolog = index ? 2 : 5;
    if (!ReadProcessMemory(GetCurrentProcess(), (void *)(uintptr_t)resume, plain, prolog, &got) ||
        got != prolog || memcmp(plain, index ? small_prefix : big_prefix, prolog))
        return 30;
    if (index) {
        int error = relocate_body(plain, 45, 44, SMALL_PC, clones + 4096);
        if (error)
            return error;
        const BYTE unwind[] = {1, 6, 2, 0, 6, 0x72, 2, 0x30};
        memcpy(clones + 4096 + 256, unwind, 8);
        functions[1].BeginAddress = (DWORD)(CLONE_BASE + 4096 - GAME_BASE);
        functions[1].EndAddress = functions[1].BeginAddress + 49;
        functions[1].UnwindData = functions[1].BeginAddress + 256;
        if (!RtlAddFunctionTable(functions + 1, 1, GAME_BASE))
            return 31;
        FlushInstructionCache(GetCurrentProcess(), clones + 4096, 272);
        int direct_error = relocate_body_mode(plain, 45, 44, SMALL_PC, clones + 12288, 1);
        if (direct_error)
            return 50 + direct_error;
        memcpy(clones + 12288 + 256, unwind, 8);
        functions[3].BeginAddress = (DWORD)(DIRECT_BASE + 4096 - GAME_BASE);
        functions[3].EndAddress = functions[3].BeginAddress + 45;
        functions[3].UnwindData = functions[3].BeginAddress + 256;
        if (!RtlAddFunctionTable(functions + 3, 1, GAME_BASE))
            return 72;
        FlushInstructionCache(GetCurrentProcess(), clones + 12288, 272);
    } else {
        DWORD64 base = 0;
        PRUNTIME_FUNCTION f = RtlLookupFunctionEntry(BIG_PC, &base, NULL);
        if (base != GAME_BASE || !f || f->BeginAddress != BIG_PC - GAME_BASE ||
            f->EndAddress != BIG_PC + BIG_SIZE - GAME_BASE || f->UnwindData != 0x3a3a940)
            return 32;
        BYTE *u = (BYTE *)(uintptr_t)(base + f->UnwindData);
        DWORD func_info, handler_rva, gs;
        memcpy(&func_info, u + 32, 4);
        memcpy(&handler_rva, u + 28, 4);
        memcpy(&gs, u + 36, 4);
        // This exact FH4 descriptor has cleanup actions and no catch/try block map.
        if (func_info != 0x3a3a968 || handler_rva != 0x2d6c130 || gs != 0x5a ||
            *(BYTE *)(uintptr_t)(base + func_info) != 0x28)
            return 33;
        int error = register_big(plain, u, f, (PEXCEPTION_ROUTINE)(uintptr_t)(base + handler_rva), u + 32);
        if (error)
            return error;
    }
    memcpy(header->reference[index], body, size);
    return 0;
}
static LONG CALLBACK direct_handler(EXCEPTION_POINTERS *e) {
    if (!header->enabled || e->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    uint64_t pc = e->ContextRecord->Rip;
    unsigned index;
    if (pc == BIG_PC)
        index = 0;
    else if (pc == SMALL_PC)
        index = 1;
    else
        return EXCEPTION_CONTINUE_SEARCH;
    if (initialized[index] != 2)
        return EXCEPTION_CONTINUE_SEARCH;
    if ((InterlockedIncrement64(header->validation + index) & 1023) == 0)
        return EXCEPTION_CONTINUE_SEARCH;
    if (*(BYTE *)(uintptr_t)pc != (index ? 0xd5 : 0xea))
        return EXCEPTION_CONTINUE_SEARCH;
    e->ContextRecord->Rip = DIRECT_BASE + index * 4096;
    InterlockedIncrement64(header->hits + index);
    return EXCEPTION_CONTINUE_EXECUTION;
}
static uint64_t WINAPI observe(ULONG phase, ULONG_PTR pc, EXCEPTION_RECORD *rec, CONTEXT *context,
                               void *handler, LONG result, uint64_t token) {
    if (handler == (void *)direct_handler)
        return 0;
    unsigned index;
    if (pc == BIG_PC)
        index = 0;
    else if (pc == SMALL_PC)
        index = 1;
    else
        return 0;
    if (phase == 1 && rec->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && header->enabled)
        return index + 1;
    if (phase != 2 || !token || result != EXCEPTION_CONTINUE_EXECUTION || !header->enabled)
        return 0;
    BYTE body[640];
    SIZE_T got = 0;
    unsigned size = index ? 45 : BIG_SIZE;
    if (!ReadProcessMemory(GetCurrentProcess(), (void *)pc, body, size, &got) || got != size) {
        InterlockedIncrement64(&header->errors);
        return 0;
    }
    if (!initialized[index]) {
        if (InterlockedCompareExchange(initialized + index, 1, 0) == 0) {
            int error = prepare(index, body, context->Rip);
            if (error) {
                InterlockedExchange64(&header->errors, error);
                InterlockedExchange(initialized + index, -1);
                return 0;
            }
            InterlockedExchange(initialized + index, 2);
        } else
            return 0;
    }
    if (initialized[index] != 2)
        return 0;
    if (memcmp(body, header->reference[index], size)) {
        InterlockedIncrement64(header->mismatch + index);
        InterlockedExchange(initialized + index, -1);
        return 0;
    }
    context->Rip = CLONE_BASE + index * 4096;
    InterlockedIncrement64(header->redirects + index);
    return 0;
}
#ifndef FULL_SELFTEST
#include "pin.h"
static DWORD WINAPI worker(void *unused) {
    wchar_t path[32768];
    if (!GetEnvironmentVariableW(L"AOELAB_AOE2_FUNCTION_CACHE_STATUS", path, 32768)) {
        DWORD n = GetTempPathW(32700, path);
        if (!n || n >= 32700)
            return 1;
        wsprintfW(path + n, L"macgames-aoe2-cache-%lu.bin", GetCurrentProcessId());
    }
    SetObserver set =
        (SetObserver)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "__wine_aoe_set_exception_observer");
    if (!set)
        return 2;
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return 3;
    HANDLE map = CreateFileMappingW(file, NULL, PAGE_READWRITE, 0, 4096, NULL);
    if (!map)
        return 4;
    header = MapViewOfFile(map, FILE_MAP_ALL_ACCESS, 0, 0, 4096);
    if (!header)
        return 5;
    wchar_t image[32768];
    DWORD length = GetModuleFileNameW(NULL, image, 32768);
    if (!length || length >= 32768 || (uintptr_t)GetModuleHandleW(NULL) != GAME_BASE ||
        !pinned_executable(image)) {
        header->errors = 74;
        header->done = 1;
        FlushViewOfFile(header, 4096);
        return 9;
    }
    clones = VirtualAlloc((void *)CLONE_BASE, 16384, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE);
    if ((uintptr_t)clones != CLONE_BASE) {
        header->errors = 40;
        header->done = 1;
        return 6;
    }
    header->version = 1;
    void *old = set(observe);
    if (old) {
        set(old);
        header->errors = 41;
        header->done = 1;
        return 7;
    }
    void *veh = AddVectoredExceptionHandler(1, direct_handler);
    if (!veh) {
        set(NULL);
        header->errors = 73;
        header->done = 1;
        return 8;
    }
    InterlockedExchange(&header->enabled, 1);
    InterlockedExchange64((volatile LONG64 *)&header->magic, 0x31435452454f414cULL);
    while (!header->stop)
        Sleep(100);
    InterlockedExchange(&header->enabled, 0);
    RemoveVectoredExceptionHandler(veh);
    set(NULL);
    Sleep(300);
    InterlockedExchange(&header->done, 1);
    FlushViewOfFile(header, 4096);
    CloseHandle(map);
    CloseHandle(file);
    return 0;
}
BOOL WINAPI DllMain(HINSTANCE self, DWORD reason, void *reserved) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(self);
        HANDLE t = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (t)
            CloseHandle(t);
    }
    return TRUE;
}
#endif
