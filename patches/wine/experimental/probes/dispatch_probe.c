#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void (*softfault)(void);
static volatile LONG veh_count, seh_count, nested_count, unwind_count, caught;
static int nesting;

/* Call the exact exported entry without depending on JIT rewriting in a child
 * under a Windows debugger. Its synthetic fault PC is the final two bytes of
 * this call; advancing it by two resumes at the instruction after the call.
 */
__attribute__((noinline)) static void fault(void) { softfault(); }

static LONG CALLBACK nested_handler(EXCEPTION_POINTERS *e)
{
    if(e->ExceptionRecord->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&veh_count);
    if(!nesting) { nesting=1; fault(); nesting=0; }
    else InterlockedIncrement(&nested_count);
    e->ContextRecord->Rip+=2;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static LONG filter(EXCEPTION_POINTERS *e)
{
    if(e->ExceptionRecord->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&seh_count);
    e->ContextRecord->Rip+=2;
    return EXCEPTION_CONTINUE_EXECUTION;
}

static int child(void)
{
    softfault=(void(*)(void))GetProcAddress(GetModuleHandleA("ntdll.dll"),"__wine_aoe_softfault2");
    if(!softfault)return 2;
    PVOID token=AddVectoredExceptionHandler(1,nested_handler);
    if(!token)return 3;
    for(unsigned i=0;i<1000;i++)fault();
    RemoveVectoredExceptionHandler(token);
    if(veh_count!=2000||nested_count!=1000)return 4;
    puts("PASS nested VEH");
    for(unsigned i=0;i<1000;i++) {
        __try { fault(); }
        __except(filter(GetExceptionInformation())) { return 5; }
    }
    if(seh_count!=1000)return 6;
    puts("PASS resumable SEH");
    for(unsigned i=0;i<1000;i++) {
        __try {
            __try { fault(); }
            __finally { InterlockedIncrement(&unwind_count); }
        } __except(GetExceptionCode()==EXCEPTION_ILLEGAL_INSTRUCTION ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
            InterlockedIncrement(&caught);
        }
    }
    if(unwind_count!=1000||caught!=1000)return 13;
    puts("PASS nested VEH, resumable SEH, stack unwind and finally");
    return 0;
}

int main(int argc,char **argv)
{
    setvbuf(stdout,NULL,_IONBF,0);
    if(argc>1 && !strcmp(argv[1],"child"))return child();
    int result=child();
    if(result)return result;
    char path[MAX_PATH],command[MAX_PATH+16];
    if(!GetModuleFileNameA(NULL,path,sizeof(path)))return 7;
    snprintf(command,sizeof(command),"\"%s\" child",path);
    STARTUPINFOA si={0};PROCESS_INFORMATION pi;si.cb=sizeof(si);
    if(!CreateProcessA(NULL,command,NULL,NULL,FALSE,DEBUG_ONLY_THIS_PROCESS,NULL,NULL,&si,&pi))return 8;
    CloseHandle(pi.hThread);
    unsigned first_chance=0;DWORD exitcode=99;
    for(;;) {
        DEBUG_EVENT event;DWORD action=DBG_CONTINUE;
        if(!WaitForDebugEvent(&event,15000)) { TerminateProcess(pi.hProcess,9);return 9; }
        if(event.dwDebugEventCode==EXCEPTION_DEBUG_EVENT) {
            DWORD code=event.u.Exception.ExceptionRecord.ExceptionCode;
            if(code==EXCEPTION_ILLEGAL_INSTRUCTION) {
                if(!event.u.Exception.dwFirstChance)return 10;
                first_chance++;action=DBG_EXCEPTION_NOT_HANDLED;
            } else if(code!=EXCEPTION_BREAKPOINT)action=DBG_EXCEPTION_NOT_HANDLED;
        } else if(event.dwDebugEventCode==CREATE_PROCESS_DEBUG_EVENT && event.u.CreateProcessInfo.hFile)
            CloseHandle(event.u.CreateProcessInfo.hFile);
        else if(event.dwDebugEventCode==LOAD_DLL_DEBUG_EVENT && event.u.LoadDll.hFile)
            CloseHandle(event.u.LoadDll.hFile);
        if(event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT)exitcode=event.u.ExitProcess.dwExitCode;
        if(!ContinueDebugEvent(event.dwProcessId,event.dwThreadId,action))return 11;
        if(event.dwDebugEventCode==EXIT_PROCESS_DEBUG_EVENT)break;
    }
    CloseHandle(pi.hProcess);
    printf("debug child exit=%lu first_chance=%u\n",exitcode,first_chance);
    if(exitcode||first_chance!=4000)return 12;
    puts("PASS debugger receives every first-chance software exception");
    return 0;
}
