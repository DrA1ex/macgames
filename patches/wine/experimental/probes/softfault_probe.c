#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static volatile LONG cases, errors;
static volatile ULONG length;
static volatile ULONG_PTR expected;
static CONTEXT expected_context;
const uint64_t avx_expected[4]={0x1122334455667788ULL,0x99aabbccddeeff00ULL,0x123456789abcdef0ULL,0xfedcba9876543210ULL};
uint64_t avx_result[4];

static LONG CALLBACK handler(EXCEPTION_POINTERS *e)
{
    if (e->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (e->ContextRecord->Rax != 0x12345678 || !(e->ContextRecord->EFlags & 1) ||
        (ULONG_PTR)e->ExceptionRecord->ExceptionAddress != expected || e->ContextRecord->Rip != expected ||
        e->ContextRecord->Xmm0.Low != avx_expected[0] || (uint64_t)e->ContextRecord->Xmm0.High != avx_expected[1])
        InterlockedIncrement(&errors);
    if (e->ContextRecord->SegCs != expected_context.SegCs ||
        e->ContextRecord->SegSs != expected_context.SegSs ||
        e->ContextRecord->SegDs != expected_context.SegDs ||
        e->ContextRecord->SegEs != expected_context.SegEs ||
        e->ContextRecord->SegFs != expected_context.SegFs ||
        e->ContextRecord->SegGs != expected_context.SegGs ||
        e->ContextRecord->Dr0 != expected_context.Dr0 ||
        e->ContextRecord->Dr1 != expected_context.Dr1 ||
        e->ContextRecord->Dr2 != expected_context.Dr2 ||
        e->ContextRecord->Dr3 != expected_context.Dr3 ||
        e->ContextRecord->Dr6 != expected_context.Dr6 ||
        e->ContextRecord->Dr7 != expected_context.Dr7)
        InterlockedIncrement(&errors);
    InterlockedIncrement(&cases);
    e->ContextRecord->Rip += length;
    return EXCEPTION_CONTINUE_EXECUTION;
}

__attribute__((naked,noinline)) static void aad(void)
{
    __asm__ volatile("vmovdqu avx_expected(%rip),%ymm0; mov $0x12345678,%eax; stc; .globl aad_fault; aad_fault: .byte 0xd5,0x7f; vmovdqu %ymm0,avx_result(%rip); vzeroupper; ret");
}
__attribute__((naked,noinline)) static void pushds(void)
{
    __asm__ volatile("vmovdqu avx_expected(%rip),%ymm0; mov $0x12345678,%eax; stc; .globl pushds_fault; pushds_fault: .byte 0x1e; vmovdqu %ymm0,avx_result(%rip); vzeroupper; ret");
}
__attribute__((naked,noinline)) static void ud2(void)
{
    __asm__ volatile("vmovdqu avx_expected(%rip),%ymm0; mov $0x12345678,%eax; stc; .globl ud2_fault; ud2_fault: .byte 0x0f,0x0b; vmovdqu %ymm0,avx_result(%rip); vzeroupper; ret");
}
extern const char aad_fault[],pushds_fault[],ud2_fault[];

static int query_context(void)
{
    ZeroMemory(&expected_context,sizeof(expected_context));
    expected_context.ContextFlags=CONTEXT_CONTROL|CONTEXT_SEGMENTS|CONTEXT_DEBUG_REGISTERS;
    return GetThreadContext(GetCurrentThread(),&expected_context)!=0;
}

static DWORD WINAPI verify_live_thread_context(void *argument)
{
    CONTEXT original,updated;
    if (!query_context()) return 5;
    original=expected_context;
    for(unsigned t=0;t<3;t++) {
        updated=original;
        updated.ContextFlags=CONTEXT_DEBUG_REGISTERS;
        updated.Dr0=0x12345000+(ULONG_PTR)argument*0x10000+t*0x1000;
        updated.Dr7&=~0xffULL; /* No enabled breakpoint; vary only cached address. */
        if(!SetThreadContext(GetCurrentThread(),&updated)||!query_context())return 6;
        cases=errors=0;length=2;expected=(ULONG_PTR)aad_fault;
        for(unsigned n=0;n<1000;n++)aad();
        if(cases!=1000||errors)return 7;
    }
    original.ContextFlags=CONTEXT_DEBUG_REGISTERS;
    if(!SetThreadContext(GetCurrentThread(),&original))return 8;
    puts("PASS live per-thread debug cache and selectors");
    return 0;
}

int main(void)
{
    HMODULE ntdll=GetModuleHandleW(L"ntdll.dll");
    IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER*)ntdll;
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64*)((BYTE*)ntdll+dos->e_lfanew);
    printf("NTDLL timestamp=%08lx softfault_rva=%llx\n",(unsigned long)nt->FileHeader.TimeDateStamp,
        (unsigned long long)((BYTE*)GetProcAddress(ntdll,"__wine_aoe_softfault1")-(BYTE*)ntdll));
    PVOID token=AddVectoredExceptionHandler(1,handler);
    if (!token) return 2;
    if (!query_context()) return 5;
    struct {const char *name; void (*fn)(void); const char *pc; ULONG len;} tests[]={
        {"AAD software 2-byte",aad,aad_fault,2},{"PUSH DS software 1-byte",pushds,pushds_fault,1},
        {"UD2 native fallback",ud2,ud2_fault,2}};
    LARGE_INTEGER begin,end,freq;QueryPerformanceFrequency(&freq);
    for (unsigned t=0;t<sizeof(tests)/sizeof(tests[0]);t++) {
        cases=errors=0;length=tests[t].len;expected=(ULONG_PTR)tests[t].pc;
        QueryPerformanceCounter(&begin);
        for (unsigned i=0;i<10000;i++) {
            tests[t].fn();
            for(unsigned lane=0;lane<4;lane++)if(avx_result[lane]!=avx_expected[lane])InterlockedIncrement(&errors);
        }
        QueryPerformanceCounter(&end);
        printf("%s: cases=%ld errors=%ld us_per_exception=%.3f pc=%p\n",tests[t].name,cases,errors,
            (double)(end.QuadPart-begin.QuadPart)*1000000.0/freq.QuadPart/10000,tests[t].pc);
        if(cases!=10000||errors)return 1;
    }
    if(verify_live_thread_context((void*)1))return 7;
    HANDLE thread=CreateThread(NULL,0,verify_live_thread_context,(void*)2,0,NULL);
    DWORD result=9;
    if(!thread||WaitForSingleObject(thread,10000)!=WAIT_OBJECT_0||!GetExitCodeThread(thread,&result)||result)return 9;
    CloseHandle(thread);
    RemoveVectoredExceptionHandler(token);
    puts("PASS: exception kind, guest PC, RAX, carry flag, XMM0, YMM0, selectors, live debug registers and native fallback");
    return 0;
}
