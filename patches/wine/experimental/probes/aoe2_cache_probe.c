#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static BYTE *ring,*last_slot;
static unsigned calls,mode,errors,av_count;
static uint64_t data_value=0x1122334455667788ULL;
static unsigned simd_variant;
uint64_t simd_input0[2]={0x1122334455667788ULL,0x8877665544332211ULL};
uint64_t simd_input1[2]={0x0102030405060708ULL,0x1112131415161718ULL};
uint64_t simd_output0[2],simd_output1[2],simd_output_r8;
static LONG CALLBACK handler(EXCEPTION_POINTERS *e){
 if(e->ExceptionRecord->ExceptionCode==EXCEPTION_ACCESS_VIOLATION&&mode==2){
  if(e->ContextRecord->Rip!=(uintptr_t)last_slot||(uintptr_t)e->ExceptionRecord->ExceptionAddress!=(uintptr_t)last_slot)errors++;
  av_count++;e->ContextRecord->Rip=(uintptr_t)last_slot+2;e->ContextRecord->Rax=77;return EXCEPTION_CONTINUE_EXECUTION;
 }
 if(e->ExceptionRecord->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION)return EXCEPTION_CONTINUE_SEARCH;
 last_slot=ring+((calls&3)*32);memset(last_slot,0x90,32);
 if(mode==0){DWORD value=(calls&1)?0x22222222:0x11111111;last_slot[0]=0xb8;memcpy(last_slot+1,&value,4);last_slot[5]=0xc3;}
 else if(mode==1){int64_t delta=(BYTE*)&data_value-(last_slot+7);if(delta!= (int32_t)delta)errors++;int32_t d=delta;BYTE op[]={0x48,0x8b,0x05};memcpy(last_slot,op,3);memcpy(last_slot+3,&d,4);last_slot[7]=0xc3;}
 else if(mode==2){last_slot[0]=0x8b;last_slot[1]=0x01;last_slot[2]=0xc3;e->ContextRecord->Rcx=0;}
 else if(mode==3){BYTE op[]={0xb8,99,0,0,0,0x85,0xc0,0x74,0,0xc3};memcpy(last_slot,op,sizeof(op));}
 else {
  const BYTE ops[4][6]={{0x66,0x49,0x0f,0x7e,0xc0,0xc3},{0x66,0x0f,0xd4,0xc1,0xc3,0x90},{0x66,0x0f,0x70,0xc1,0x87,0xc3},{0x66,0x0f,0x6f,0xc8,0xc3,0x90}};
  memcpy(last_slot,ops[simd_variant],6);
 }
 calls++;e->ContextRecord->Rip=(uintptr_t)last_slot;return EXCEPTION_CONTINUE_EXECUTION;
}
__attribute__((naked,noinline)) static uint64_t fault(void){__asm__ volatile(".byte 0xd5,0x7f; ret");}
__attribute__((naked,noinline)) static void simd_fault(void){
 __asm__ volatile("sub $0x28,%rsp; movdqu simd_input0(%rip),%xmm0; movdqu simd_input1(%rip),%xmm1; mov $0xdeadbeef,%r8; lea 1f(%rip),%rax; push %rax; .byte 0xd5,0x7f; 1: movdqu %xmm0,simd_output0(%rip); movdqu %xmm1,simd_output1(%rip); mov %r8,simd_output_r8(%rip); add $0x28,%rsp; ret");
}
int main(void){
 BYTE *globals=VirtualAlloc((void*)0x144c90000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);if((uintptr_t)globals!=0x144c90000ULL)return 1;
 ring=VirtualAlloc((void*)0x150000000ULL,0x1000000,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);if((uintptr_t)ring!=0x150000000ULL)return 2;
 *(BYTE**)(globals+0x43f0)=ring;void *token=AddVectoredExceptionHandler(1,handler);if(!token)return 3;
 LARGE_INTEGER a,b,f;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);
 for(unsigned n=0;n<20000;n++){uint64_t wanted=(calls&1)?0x22222222:0x11111111;if(fault()!=wanted)errors++;}
 QueryPerformanceCounter(&b);printf("mutable-ring us_per_exception=%.3f errors=%u\n",(b.QuadPart-a.QuadPart)*1000000.0/f.QuadPart/20000,errors);
 mode=1;for(unsigned n=0;n<100;n++)if(fault()!=data_value)errors++;
 mode=2;for(unsigned n=0;n<50;n++)if(fault()!=77)errors++;
 mode=3;for(unsigned n=0;n<100;n++)if(fault()!=99)errors++;
 mode=4;
 for(simd_variant=0;simd_variant<4;simd_variant++)for(unsigned n=0;n<100;n++){
  uint64_t wanted0[2],wanted1[2],r8=0xdeadbeef;memcpy(wanted0,simd_input0,16);memcpy(wanted1,simd_input1,16);
  if(simd_variant==0)r8=simd_input0[0];
  if(simd_variant==1)for(unsigned i=0;i<2;i++)wanted0[i]+=simd_input1[i];
  if(simd_variant==2){uint32_t a[4],v[4];memcpy(a,simd_input1,16);for(unsigned i=0;i<4;i++)v[i]=a[(0x87>>(2*i))&3];memcpy(wanted0,v,16);}
  if(simd_variant==3)memcpy(wanted1,simd_input0,16);
  simd_fault();if(memcmp(wanted0,simd_output0,16)||memcmp(wanted1,simd_output1,16)||simd_output_r8!=r8)errors++;
 }
 RemoveVectoredExceptionHandler(token);printf("PASS checks: calls=%u access_violations=%u errors=%u\n",calls,av_count,errors);
 return errors||calls!=20650||av_count!=50?4:0;
}
