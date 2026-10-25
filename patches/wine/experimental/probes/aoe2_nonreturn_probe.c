#include <windows.h>
#include <stdio.h>
#include <stdint.h>
static const uintptr_t sites[]={0x140f77b90ULL,0x140f77dd3ULL,0x140f77e10ULL,0x140f77e3cULL};
static unsigned handled,errors;
__attribute__((naked,noinline)) static unsigned safe_return(void){__asm__ volatile("mov $42,%eax; ret");}
static LONG CALLBACK handler(EXCEPTION_POINTERS *e){
 for(unsigned i=0;i<4;i++)if(e->ContextRecord->Rip==sites[i]){
  if(e->ExceptionRecord->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION||(uintptr_t)e->ExceptionRecord->ExceptionAddress!=sites[i])errors++;
  ++handled;e->ContextRecord->Rip=(uintptr_t)safe_return;return EXCEPTION_CONTINUE_EXECUTION;
 }
 return EXCEPTION_CONTINUE_SEARCH;
}
int main(void){
 BYTE *page=VirtualAlloc((void*)0x140f70000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);if((uintptr_t)page!=0x140f70000ULL)return 1;
 for(unsigned i=0;i<4;i++){BYTE *p=(void*)sites[i];unsigned len=i==2?2:1;p[0]=i==2?0xd5:i==0?0xea:0x16;if(len==2)p[1]=0x7f;p[len]=0xd9;p[len+1]=0xf9;p[len+2]=0xc3;}
 void *token=AddVectoredExceptionHandler(1,handler);
 for(unsigned i=0;i<4;i++){unsigned r=((unsigned(*)(void))sites[i])();printf("site=%llx result=%u\n",(unsigned long long)sites[i],r);if(r!=42)errors++;}
 RemoveVectoredExceptionHandler(token);printf("PASS unreachable-tail checks: handled=%u errors=%u\n",handled,errors);return errors||handled!=4?2:0;
}
