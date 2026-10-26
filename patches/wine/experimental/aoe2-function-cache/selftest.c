#define FULL_SELFTEST
#include "cache.c"
#include <stdio.h>
int call_and_catch(void (*function)(void));
static volatile LONG destructors,destructor_errors;
static void WINAPI destructor(void *object,ULONG64 frame){if(*(DWORD*)object!=0x12345678||object!=(void*)(uintptr_t)frame)InterlockedIncrement(&destructor_errors);InterlockedIncrement(&destructors);}
static void raise_cpp(void){ULONG_PTR info[4]={0x19930520,1,0,GAME_BASE};RaiseException(0xe06d7363,0,4,info);}
static void absolute_jump(BYTE *where,void *target){BYTE code[]={0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};uint64_t p=(uintptr_t)target;memcpy(code+2,&p,8);memcpy(where,code,12);}
static unsigned put_uint(BYTE *p,unsigned v){if(v<128){p[0]=v<<1;return 1;}p[0]=((v&63)<<2)|1;p[1]=v>>6;return 2;}
static int load(const char *path,BYTE *out,unsigned n){FILE *f=fopen(path,"rb");if(!f)return 0;unsigned got=fread(out,1,n,f);fclose(f);return got==n;}
static int verify_targets(const BYTE *plain,BYTE *shadow,BOOL direct){
 for(unsigned off=0;off<BIG_SIZE;){
  unsigned dst=off+(off>BIG_EXIT&&!direct?4:0);if(off==BIG_EXIT){if(direct){if(shadow[dst]!=0xc3)return 5;off++;continue;}int32_t d;memcpy(&d,shadow+dst+1,4);if(shadow[dst]!=0xe9||(uintptr_t)shadow+dst+5+(int64_t)d!=BIG_PC+off)return 1;off++;continue;}
  hde64s a,b;hde64_disasm(plain+off,&a);hde64_disasm(shadow+dst,&b);if(a.len!=b.len||a.opcode!=b.opcode||a.opcode2!=b.opcode2)return 2;
  if(a.flags&F_RELATIVE){unsigned w=(a.flags&F_IMM8)?1:4;int64_t x=w==1?(int8_t)a.imm.imm8:(int32_t)a.imm.imm32,y=w==1?(int8_t)b.imm.imm8:(int32_t)b.imm.imm32;uint64_t target=BIG_PC+off+a.len+x,expected=direct&&target>=BIG_PC&&target<BIG_PC+BIG_SIZE?(uintptr_t)shadow+target-BIG_PC:relocated_pc(target,BIG_PC,BIG_SIZE,BIG_EXIT,(uintptr_t)shadow);if((uintptr_t)shadow+dst+b.len+y!=expected)return 3;}
  if((a.flags&F_MODRM)&&a.modrm_mod==0&&a.modrm_rm==5)if(BIG_PC+off+a.len+(int64_t)(int32_t)a.disp.disp32!=(uintptr_t)shadow+dst+b.len+(int64_t)(int32_t)b.disp.disp32)return 4;
  off+=a.len;
 }
 return 0;
}
static void fake_code(BYTE *where,const BYTE *plain,BOOL shadow){
 memset(where,0x90,BIG_SIZE+4);memcpy(where,plain,28);
 // Same real stack layout; make a frame-local object for an FH4 destructor.
 const BYTE marker[]={0xc7,0x04,0x24,0x78,0x56,0x34,0x12};memcpy(where+43,marker,7);
 unsigned call=590+(shadow?4:0);where[50]=0xe9;int32_t d=(int32_t)(call-55);memcpy(where+51,&d,4);
 BYTE invoke[]={0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xd0};uint64_t target=(uintptr_t)raise_cpp;memcpy(invoke+2,&target,8);memcpy(where+call,invoke,12);
 memcpy(where+call+12,plain+550,30);where[call+12+29]=0xc3;
}
int main(int argc,char **argv){
 if(argc!=4)return 64;BYTE plain[640]={0},u[128]={0};if(!load(argv[1],plain,BIG_SIZE)||!load(argv[2],u,128))return 1;
 const BYTE prologue[]={0x48,0x89,0x5c,0x24,0x10};memcpy(plain,prologue,5);
 clones=VirtualAlloc((void*)CLONE_BASE,16384,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);if((uintptr_t)clones!=CLONE_BASE)return 2;
 int e=relocate_body(plain,BIG_SIZE,BIG_EXIT,BIG_PC,clones);if(e||verify_targets(plain,clones,FALSE)){printf("relocation error %d\n",e);return 3;}
 puts("PASS all branch, call and RIP-relative targets, including the expanded exit");
 BYTE *image=VirtualAlloc((void*)GAME_BASE,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
 BYTE *old_code=VirtualAlloc((void*)0x140f70000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
 if((uintptr_t)image!=GAME_BASE||(uintptr_t)old_code!=0x140f70000ULL)return 4;
 HMODULE runtime=LoadLibraryA("vcruntime140_1.dll");PEXCEPTION_ROUTINE fh4=(PEXCEPTION_ROUTINE)GetProcAddress(runtime,"__CxxFrameHandler4");if(!fh4)return 5;
 // An independent, synthetic Microsoft FH4 cleanup descriptor: state 0 only
 // inside the late basic block, so incorrect shadow ControlPc mapping fails.
 BYTE *f=image+0x1000;f[0]=0x28;DWORD rva=0x1020;memcpy(f+1,&rva,4);rva=0x1040;memcpy(f+5,&rva,4);
 BYTE *map=image+0x1020;map[0]=2;map[1]=14;rva=0x1100;memcpy(map+2,&rva,4);
 BYTE *ip=image+0x1040;unsigned n=0;ip[n++]=6;ip[n++]=0;ip[n++]=0;n+=put_uint(ip+n,590);ip[n++]=2;n+=put_uint(ip+n,13);ip[n++]=0;
 absolute_jump(image+0x1100,destructor);absolute_jump(image+0x1200,fh4);
 memcpy(image+0x2000,u,40);rva=0x1200;memcpy(image+0x2000+28,&rva,4);rva=0x1000;memcpy(image+0x2000+32,&rva,4);
 RUNTIME_FUNCTION original={.BeginAddress=(DWORD)(BIG_PC-GAME_BASE),.EndAddress=(DWORD)(BIG_PC+BIG_SIZE-GAME_BASE),.UnwindData=0x2000};
 if(!RtlAddFunctionTable(&original,1,GAME_BASE))return 6;
 e=register_big(plain,image+0x2000,&original,fh4,image+0x2000+32);if(e){printf("register error %d\n",e);return 7;}
 if(verify_targets(plain,clones+8192,TRUE))return 17;
 const unsigned positions[]={56,128,318,535,580,590};
 for(unsigned family=0;family<2;family++)for(unsigned n=0;n<sizeof(positions)/sizeof(positions[0]);n++){
  uint64_t stack[64]={0};for(unsigned i=12;i<=21;i++)stack[i]=0x100000+i;CONTEXT c={0};c.ContextFlags=CONTEXT_FULL;c.Rip=project(BIG_PC+positions[n],family);c.Rsp=(uintptr_t)stack;
  DWORD64 base=0,frame=0;PRUNTIME_FUNCTION fn=RtlLookupFunctionEntry(c.Rip,&base,NULL);void *data=NULL;
  if(fn!=functions+2*family||base!=GAME_BASE)return 8;
  RtlVirtualUnwind(UNW_FLAG_NHANDLER,base,c.Rip,fn,&c,&data,&frame,NULL);
  if(c.Rsp!=(uintptr_t)(stack+18)||c.Rip!=stack[17]||c.Rbx!=stack[19]||c.Rbp!=stack[20]||c.Rsi!=stack[21]||c.Rdi!=stack[16]||c.R12!=stack[15]||c.R13!=stack[14]||c.R14!=stack[13]||c.R15!=stack[12]){printf("bad unwind offset=%u\n",positions[n]);return 9;}
 }
 puts("PASS large-function unwind before and after expanded exit");
 fake_code((BYTE*)(uintptr_t)BIG_PC,plain,FALSE);fake_code(clones,plain,TRUE);fake_code(clones+8192,plain,FALSE);FlushInstructionCache(GetCurrentProcess(),NULL,0);
 for(unsigned n=0;n<500;n++){
  LONG direct_before=destructors;if(!call_and_catch((void(*)(void))(clones+8192))||destructors!=direct_before+1||destructor_errors)return 18;
  LONG before=destructors;if(!call_and_catch((void(*)(void))(uintptr_t)BIG_PC)||destructors!=before+1||destructor_errors)return 10;
  before=destructors;if(!call_and_catch((void(*)(void))clones)||destructors!=before+1||destructor_errors){printf("FH4 destructor failure count=%ld errors=%ld\n",destructors,destructor_errors);return 11;}
 }
 printf("PASS 500 original/shadow/direct Microsoft FH4 exception/unwind pairs; destructors=%ld errors=%ld\n",destructors,destructor_errors);
 BYTE small[64]={0};if(!load(argv[3],small,45))return 12;small[0]=0x40;small[1]=0x53;
 if(relocate_body(small,45,44,SMALL_PC,clones+4096))return 13;
 const BYTE small_unwind[]={1,6,2,0,6,0x72,2,0x30};memcpy(clones+4096+256,small_unwind,8);
 functions[1].BeginAddress=(DWORD)(CLONE_BASE+4096-GAME_BASE);functions[1].EndAddress=functions[1].BeginAddress+49;functions[1].UnwindData=functions[1].BeginAddress+256;
 if(!RtlAddFunctionTable(functions+1,1,GAME_BASE))return 14;
 if(relocate_body_mode(small,45,44,SMALL_PC,clones+12288,1))return 19;
 memcpy(clones+12288+256,small_unwind,8);
 functions[3].BeginAddress=(DWORD)(DIRECT_BASE+4096-GAME_BASE);functions[3].EndAddress=functions[3].BeginAddress+45;functions[3].UnwindData=functions[3].BeginAddress+256;
 if(!RtlAddFunctionTable(functions+3,1,GAME_BASE))return 20;
 BYTE *a=VirtualAlloc((void*)0x140d50000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE),*b=VirtualAlloc((void*)0x1402a0000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);if(!a||!b)return 15;
 uint64_t values[]={13,17,23,31},*table=values;BYTE first[]={0x48,0xb8,0,0,0,0,0,0,0,0,0xc3};uint64_t address=(uintptr_t)&table;memcpy(first+2,&address,8);memcpy((void*)0x140d562b0ULL,first,sizeof(first));
 const BYTE second[]={0x48,0x89,0x11,0x48,0x89,0xc8,0xc3},third[]={0x48,0x8b,0x01,0x48,0x83,0xc0,7,0xc3};memcpy((void*)0x1402a9630ULL,second,sizeof(second));memcpy((void*)(uintptr_t)BIG_PC,third,sizeof(third));
 memcpy((void*)(uintptr_t)SMALL_PC,small,45);*((BYTE*)(uintptr_t)SMALL_PC+44)=0xc3;FlushInstructionCache(GetCurrentProcess(),NULL,0);
 typedef uint64_t (*Fn)(int);Fn control=(Fn)(uintptr_t)SMALL_PC,candidate=(Fn)(clones+4096),direct=(Fn)(clones+12288);
 for(unsigned n=0;n<10000;n++)for(unsigned i=0;i<4;i++)if(control(i)!=values[i]+7||candidate(i)!=values[i]+7||direct(i)!=values[i]+7)return 16;
 puts("PASS 40000 small-function original/shadow/direct call triples with the shared relocator");return 0;
}
