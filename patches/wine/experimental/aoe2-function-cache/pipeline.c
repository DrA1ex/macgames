#define FULL_SELFTEST
#include "cache.c"
#include <stdio.h>
static BYTE small[64],prefix[16];static LONG entries,exits,active;
static LONG CALLBACK original(EXCEPTION_POINTERS *e){
 uint64_t pc=e->ContextRecord->Rip;uint64_t token=observe(1,pc,e->ExceptionRecord,e->ContextRecord,(void*)original,0,0);LONG result=EXCEPTION_CONTINUE_SEARCH;
 if(e->ExceptionRecord->ExceptionCode==EXCEPTION_ILLEGAL_INSTRUCTION){
  if(pc==SMALL_PC){entries++;active++;e->ContextRecord->Rip=(uintptr_t)prefix;result=EXCEPTION_CONTINUE_EXECUTION;}
  if(pc==SMALL_PC+44){exits++;active--;e->ContextRecord->Rip=*(uint64_t*)(uintptr_t)e->ContextRecord->Rsp;e->ContextRecord->Rsp+=8;result=EXCEPTION_CONTINUE_EXECUTION;}
 }
 observe(2,pc,e->ExceptionRecord,e->ContextRecord,(void*)original,result,token);return result;
}
static int load(const char *path){FILE*f=fopen(path,"rb");if(!f)return 0;unsigned n=fread(small,1,45,f);fclose(f);return n==45;}
int main(int argc,char**argv){
 if(argc!=2||!load(argv[1]))return 1;
 header=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
 clones=VirtualAlloc((void*)CLONE_BASE,16384,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
 BYTE *code=VirtualAlloc((void*)0x140f70000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
 BYTE *a=VirtualAlloc((void*)0x140d50000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE),*b=VirtualAlloc((void*)0x1402a0000ULL,65536,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
 if(!header||(uintptr_t)clones!=CLONE_BASE||!code||!a||!b)return 2;
 DWORD old;VirtualProtect(prefix,sizeof(prefix),PAGE_EXECUTE_READWRITE,&old);prefix[0]=0x40;prefix[1]=0x53;prefix[2]=0x48;prefix[3]=0xb8;uint64_t resume=SMALL_PC+2;memcpy(prefix+4,&resume,8);prefix[12]=0xff;prefix[13]=0xe0;
 small[0]=0xd5;small[1]=0xfb;small[44]=0x16;memcpy((void*)SMALL_PC,small,45);
 uint64_t values[]={13,17,23,31},*table=values;BYTE first[]={0x48,0xb8,0,0,0,0,0,0,0,0,0xc3};uint64_t address=(uintptr_t)&table;memcpy(first+2,&address,8);memcpy(a+0x62b0,first,sizeof(first));
 const BYTE second[]={0x48,0x89,0x11,0x48,0x89,0xc8,0xc3},third[]={0x48,0x8b,0x01,0x48,0x83,0xc0,7,0xc3};memcpy(b+0x9630,second,sizeof(second));memcpy((void*)BIG_PC,third,sizeof(third));FlushInstructionCache(GetCurrentProcess(),NULL,0);
 void *old_veh=AddVectoredExceptionHandler(0,original),*new_veh=AddVectoredExceptionHandler(1,direct_handler);if(!old_veh||!new_veh)return 3;
 header->enabled=1;typedef uint64_t(*Fn)(int);Fn function=(Fn)SMALL_PC;
 for(unsigned n=0;n<40000;n++)if(function(n%4)!=values[n%4]+7||active)return 4;
 if(entries!=40||exits!=40||header->hits[1]!=39960||header->redirects[1]!=40||header->errors||header->mismatch[1]){printf("bad balance %ld %ld hits=%lld redirects=%lld errors=%lld\n",entries,exits,header->hits[1],header->redirects[1],header->errors);return 5;}
 puts("PASS 40000 real exception-chain calls, 39960 cache hits, 40 balanced original-handler validations");
 CONTEXT context={0},saved;EXCEPTION_RECORD record={0};EXCEPTION_POINTERS ep={&record,&context};memset(&context,0xa5,sizeof(context));context.Rip=SMALL_PC;record.ExceptionCode=EXCEPTION_ILLEGAL_INSTRUCTION;saved=context;
 if(direct_handler(&ep)!=EXCEPTION_CONTINUE_EXECUTION)return 6;saved.Rip=DIRECT_BASE+4096;if(memcmp(&saved,&context,sizeof(context)))return 7;
 puts("PASS cache-hit CONTEXT unchanged except instruction pointer");
 header->enabled=0;LONG before=entries;for(unsigned n=0;n<100;n++)if(function(n%4)!=values[n%4]+7||active)return 8;
 if(entries!=before+100||entries!=exits)return 9;
 puts("PASS live disable returns all calls to original handler with balanced entries/exits");
 header->enabled=1;header->reference[1][3]^=1;header->validation[1]=1023;
 if(function(0)!=20||initialized[1]!=-1||header->mismatch[1]!=1||active||entries!=exits)return 10;
 before=entries;for(unsigned n=0;n<100;n++)if(function(n%4)!=values[n%4]+7||active)return 11;
 if(entries!=before+100||entries!=exits)return 12;
 puts("PASS changed-body validation permanently falls back without executing stale cache");
 RemoveVectoredExceptionHandler(new_veh);RemoveVectoredExceptionHandler(old_veh);return 0;
}
