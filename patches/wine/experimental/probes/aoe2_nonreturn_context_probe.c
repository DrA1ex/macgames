#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static volatile LONG cases, errors;
static volatile ULONG length;
static volatile ULONG_PTR expected;
static CONTEXT expected_context;
const uint64_t avx_expected[4]={0x1122334455667788ULL,0x99aabbccddeeff00ULL,0x123456789abcdef0ULL,0xfedcba9876543210ULL};
uint64_t avx_result[4];
void (*fault_target)(void);
ULONG_PTR expected_rsp;
uint64_t rax_result;
BYTE carry_result;

static LONG CALLBACK handler(EXCEPTION_POINTERS *e)
{
    if (e->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (e->ContextRecord->Rax != 0x12345678 || !(e->ContextRecord->EFlags & 1) ||
        e->ContextRecord->Rbx!=0x12345679 || e->ContextRecord->Rcx!=0x1234567a ||
        e->ContextRecord->Rdx!=0x1234567b || e->ContextRecord->Rsi!=0x1234567c ||
        e->ContextRecord->Rdi!=0x1234567d || e->ContextRecord->Rbp!=0x1234567e ||
        e->ContextRecord->R8!=0x1234567f || e->ContextRecord->R9!=0x12345680 ||
        e->ContextRecord->R10!=0x12345681 || e->ContextRecord->R11!=0x12345682 ||
        e->ContextRecord->R12!=0x12345683 || e->ContextRecord->R13!=0x12345684 ||
        e->ContextRecord->R14!=0x12345685 || e->ContextRecord->R15!=0x12345686 ||
        e->ContextRecord->Rsp!=expected_rsp ||
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

__attribute__((naked,noinline)) static void selected_call(void) {
 __asm__ volatile("push %rbx; push %rbp; push %rsi; push %rdi; push %r12; push %r13; push %r14; push %r15; sub $0x28,%rsp; lea -8(%rsp),%rax; mov %rax,expected_rsp(%rip); vmovdqu avx_expected(%rip),%ymm0; mov $0x12345678,%eax; mov $0x12345679,%ebx; mov $0x1234567a,%ecx; mov $0x1234567b,%edx; mov $0x1234567c,%esi; mov $0x1234567d,%edi; mov $0x1234567e,%ebp; mov $0x1234567f,%r8d; mov $0x12345680,%r9d; mov $0x12345681,%r10d; mov $0x12345682,%r11d; mov $0x12345683,%r12d; mov $0x12345684,%r13d; mov $0x12345685,%r14d; mov $0x12345686,%r15d; stc; call *fault_target(%rip); mov %rax,rax_result(%rip); setc carry_result(%rip); vmovdqu %ymm0,avx_result(%rip); vzeroupper; add $0x28,%rsp; pop %r15; pop %r14; pop %r13; pop %r12; pop %rdi; pop %rsi; pop %rbp; pop %rbx; ret");
}

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
        cases=errors=0;length=2;expected=0x140f77e10ULL;fault_target=(void(*)(void))expected;
        for(unsigned n=0;n<1000;n++)selected_call();
        if(cases!=1000||errors)return 7;
    }
    original.ContextFlags=CONTEXT_DEBUG_REGISTERS;
    if(!SetThreadContext(GetCurrentThread(),&original))return 8;
    puts("PASS live per-thread debug cache and selectors");
    return 0;
}

int main(void)
{
    wchar_t audit_dll[32768],audit_file[32768];
    if(GetEnvironmentVariableW(L"AOELAB_AUDIT_DLL",audit_dll,32768)) {
        if(!LoadLibraryW(audit_dll)) return 88;
        if(!GetEnvironmentVariableW(L"AOELAB_HANDLER_AUDIT_FILE",audit_file,32768)) return 89;
        int ready=0;
        for(unsigned n=0;n<200;n++) {
            uint64_t magic=0;DWORD got=0;
            HANDLE file=CreateFileW(audit_file,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);
            if(file!=INVALID_HANDLE_VALUE) {ReadFile(file,&magic,8,&got,NULL);CloseHandle(file);}
            if(magic==0x31445541454f414cULL) {ready=1;break;}
            Sleep(10);
        }
        if(!ready)return 90;
    }

    HMODULE ntdll=GetModuleHandleW(L"ntdll.dll");
    IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER*)ntdll;
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64*)((BYTE*)ntdll+dos->e_lfanew);
    printf("NTDLL timestamp=%08lx softfault_rva=%llx\n",(unsigned long)nt->FileHeader.TimeDateStamp,
        (unsigned long long)((BYTE*)GetProcAddress(ntdll,"__wine_aoe_softfault1")-(BYTE*)ntdll));
    PVOID token=AddVectoredExceptionHandler(1,handler);
    if (!token) return 2;
    if (!query_context()) return 5;
    struct {const char *name; void (*fn)(void); const char *pc; ULONG len;} tests[]={
        {"selected b90",selected_call,(void*)0x140f77b90ULL,1},
        {"selected dd3",selected_call,(void*)0x140f77dd3ULL,1},
        {"selected e10",selected_call,(void*)0x140f77e10ULL,2},
        {"selected e3c",selected_call,(void*)0x140f77e3cULL,1}};
    BYTE *page=VirtualAlloc((void*)0x140f70000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
    if((uintptr_t)page!=0x140f70000ULL)return 91;
    for(unsigned n=0;n<4;n++){BYTE *p=(void*)tests[n].pc;p[0]=n==2?0xd5:n==0?0xea:0x16;if(tests[n].len==2)p[1]=0x7f;p[tests[n].len]=0xc3;}
    LARGE_INTEGER begin,end,freq;QueryPerformanceFrequency(&freq);
    for (unsigned t=0;t<sizeof(tests)/sizeof(tests[0]);t++) {
        cases=errors=0;length=tests[t].len;expected=(ULONG_PTR)tests[t].pc;fault_target=(void(*)(void))expected;
        QueryPerformanceCounter(&begin);
        for (unsigned i=0;i<10000;i++) {
            tests[t].fn();
            if(rax_result!=0x12345678||carry_result!=1)InterlockedIncrement(&errors);
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
