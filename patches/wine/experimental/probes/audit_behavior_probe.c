#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static unsigned count,errors;
static BYTE *code;
static LONG CALLBACK handler(EXCEPTION_POINTERS *e){
 if(e->ExceptionRecord->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION)return EXCEPTION_CONTINUE_SEARCH;
 if(e->ContextRecord->Rip!=0x140f77b90ULL||GetLastError()!=0x1234)errors++;
 count++;code[0x7b98]^=1;e->ContextRecord->Rip=0x140f77ba0ULL;e->ContextRecord->Rax=42;
 SetLastError(0x5678);return EXCEPTION_CONTINUE_EXECUTION;
}
int main(void){
 wchar_t dll[32768],path[32768];GetEnvironmentVariableW(L"AOELAB_AUDIT_DLL",dll,32768);GetEnvironmentVariableW(L"AOELAB_HANDLER_AUDIT_FILE",path,32768);
 if(!LoadLibraryW(dll))return 1;
 unsigned ready=0;
 for(unsigned n=0;n<200;n++){
  HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,0,NULL);uint64_t magic=0;DWORD got;
  if(f!=INVALID_HANDLE_VALUE){ReadFile(f,&magic,8,&got,NULL);CloseHandle(f);}
  if(magic==0x31445541454f414cULL){ready=1;break;}Sleep(10);
 }
 if(!ready)return 2;
 code=VirtualAlloc((void*)0x140f70000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);if((uintptr_t)code!=0x140f70000ULL)return 3;
 memset(code,0x90,65536);code[0x7b90]=0xd5;code[0x7b91]=0x7f;code[0x7ba0]=0xc3;
 void *token=AddVectoredExceptionHandler(1,handler);
 for(unsigned n=0;n<16;n++){SetLastError(0x1234);unsigned value=((unsigned(*)(void))(code+0x7b90))();if(value!=42||GetLastError()!=0x5678)errors++;}
 RemoveVectoredExceptionHandler(token);
 printf("events=%u errors=%u\n",count,errors);
 return count!=16||errors?4:0;
}
