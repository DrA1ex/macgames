#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#define CAPACITY 1024
#define SAMPLE_CAPACITY 512
typedef uint64_t (WINAPI *Observer)(ULONG,ULONG_PTR,EXCEPTION_RECORD*,CONTEXT*,void*,LONG,uint64_t);
typedef void *(WINAPI *SetObserver)(void*);
typedef LONG (WINAPI *QueryCounter)(LARGE_INTEGER*,LARGE_INTEGER*);
typedef struct {
 uint64_t magic;DWORD version,capacity;uint64_t frequency;
 volatile LONG64 events,dropped;volatile LONG stop,done;volatile LONG64 samples,errors;
 uint64_t pid,installed;BYTE reserved[176];
} Header;
typedef struct {
 volatile LONG64 key;uint64_t pc,handler;DWORD phase;volatile LONG ready;
 volatile LONG64 entered,returned,handled,searched,ticks,max_ticks,changed_code,different_rip;
 uint64_t last_rip,first_rip,min_ticks;DWORD last_code,last_result;
 BYTE before[16],after[16],reserved[32];
} Entry;
typedef struct {
 volatile LONG64 ready;uint64_t pc,handler,rip_before,rip_after,ticks;DWORD phase,result;
 uint64_t flags_before,flags_after;BYTE before[32],after[32],reserved[24],target[32];
} Sample;
_Static_assert(sizeof(Header)==256,"header layout");
_Static_assert(sizeof(Entry)==192,"entry layout");
_Static_assert(sizeof(Sample)==192,"sample layout");
typedef struct {Entry *entry;uint64_t start,rip,flags;BYTE before[32];LONG64 sample_index;BOOL captured;} Frame;
typedef struct {Frame frames[16];unsigned depth;} ThreadFrames;
static DWORD tls_index=TLS_OUT_OF_INDEXES;
static Header *header;static Entry *entries;static Sample *samples;
static QueryCounter query_counter;
static uint64_t clock_ticks(void){LARGE_INTEGER t;query_counter(&t,NULL);return t.QuadPart;}
static Entry *entry_for(uint64_t pc,uint64_t handler,unsigned phase){
 uint64_t key=pc^(handler*0x9e3779b97f4a7c15ULL)^phase;if(!key)key=1;
 unsigned index=(unsigned)(key^(key>>32))&(CAPACITY-1);
 for(unsigned n=0;n<32;n++,index=(index+1)&(CAPACITY-1)){
  Entry *e=entries+index;LONG64 old=InterlockedCompareExchange64(&e->key,key,0);
  if(!old){e->pc=pc;e->handler=handler;e->phase=phase;e->min_ticks=UINT64_MAX;InterlockedExchange(&e->ready,1);return e;}
  if((uint64_t)old==key&&e->ready&&e->pc==pc&&e->handler==handler&&e->phase==phase)return e;
 }
 InterlockedIncrement64(&header->dropped);return NULL;
}
static BOOL selection_pc(uint64_t pc){return pc==0x140f77b90ULL||pc==0x140f77dd3ULL||pc==0x140f77e10ULL||pc==0x140f77e3cULL;}
static uint64_t WINAPI observe(ULONG phase,ULONG_PTR pc,EXCEPTION_RECORD *rec,CONTEXT *context,void *handler,LONG result,uint64_t token){
 uint64_t end=clock_ticks();
 ThreadFrames *thread=TlsGetValue(tls_index);
 if(phase==1||phase==3){
  if(rec->ExceptionCode!=EXCEPTION_ILLEGAL_INSTRUCTION||pc<0x140001000ULL||pc>=0x143197790ULL)return 0;
#ifdef AUDIT_FOCUSED
  if(!selection_pc(pc))return 0;
#endif
  InterlockedIncrement64(&header->events);Entry *e=entry_for(pc,(uintptr_t)handler,phase);if(!e)return 0;
  LONG64 count=InterlockedIncrement64(&e->entered);
  if(!thread){thread=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,sizeof(*thread));if(!thread||!TlsSetValue(tls_index,thread)){InterlockedIncrement64(&header->errors);return 0;}}
  if(thread->depth==16){InterlockedIncrement64(&header->errors);return 0;}
  Frame *f=thread->frames+thread->depth++;ZeroMemory(f,sizeof(*f));f->entry=e;f->rip=context->Rip;f->flags=context->EFlags;f->sample_index=-1;
  if(phase==1&&(count==1||(selection_pc(pc)&&(count<=32||(count&1023)==0)))){
   SIZE_T got=0;f->captured=ReadProcessMemory(GetCurrentProcess(),(void*)pc,f->before,32,&got)&&got==32;
   if(f->captured&&selection_pc(pc)){LONG64 index=InterlockedIncrement64(&header->samples)-1;if(index<SAMPLE_CAPACITY)f->sample_index=index;}
  }
  f->start=clock_ticks();return (uintptr_t)f;
 }
 if(!token)return 0;
 Frame *f=(Frame*)(uintptr_t)token;
 if(!thread||!thread->depth||f!=thread->frames+thread->depth-1){InterlockedIncrement64(&header->errors);return 0;}
 Entry *e=f->entry;uint64_t elapsed=end-f->start;BYTE after[32]={0};SIZE_T got=0;BOOL captured=FALSE;
 if(f->captured)captured=ReadProcessMemory(GetCurrentProcess(),(void*)pc,after,32,&got)&&got==32;
 InterlockedIncrement64(&e->returned);InterlockedExchangeAdd64(&e->ticks,elapsed);
 LONG64 old=e->max_ticks;while(elapsed>(uint64_t)old){LONG64 current=InterlockedCompareExchange64(&e->max_ticks,elapsed,old);if(current==old)break;old=current;}
 old=e->min_ticks;while(elapsed<(uint64_t)old){LONG64 current=InterlockedCompareExchange64((volatile LONG64*)&e->min_ticks,elapsed,old);if(current==old)break;old=current;}
 if(result==EXCEPTION_CONTINUE_EXECUTION)InterlockedIncrement64(&e->handled);else if(result==EXCEPTION_CONTINUE_SEARCH)InterlockedIncrement64(&e->searched);
 if(context->Rip!=f->rip)InterlockedIncrement64(&e->different_rip);
 if(captured&&memcmp(f->before,after,32))InterlockedIncrement64(&e->changed_code);
 e->last_rip=context->Rip;e->last_code=rec->ExceptionCode;e->last_result=result;
 if(e->returned==1){e->first_rip=context->Rip;if(captured){memcpy(e->before,f->before,16);memcpy(e->after,after,16);}}
 if(f->sample_index>=0){
  Sample *s=samples+f->sample_index;s->pc=pc;s->handler=(uintptr_t)handler;s->phase=phase;s->result=result;s->rip_before=f->rip;s->rip_after=context->Rip;s->ticks=elapsed;s->flags_before=f->flags;s->flags_after=context->EFlags;
  memcpy(s->before,f->before,32);memcpy(s->after,after,32);
  ReadProcessMemory(GetCurrentProcess(),(void*)(uintptr_t)context->Rip,s->target,32,&got);
  InterlockedExchange64(&s->ready,1);
 }
 thread->depth--;return 0;
}
static DWORD WINAPI worker(void *unused){
 wchar_t output[32768];if(!GetEnvironmentVariableW(L"AOELAB_HANDLER_AUDIT_FILE",output,32768)&&!GetEnvironmentVariableW(L"LOCAL_HANDLER_AUDIT_FILE",output,32768))return 1;
#ifdef AUDIT_FOCUSED
 if(lstrlenW(output)>32750)return 8;
 lstrcatW(output,L".selected");
#endif
 HMODULE ntdll=GetModuleHandleW(L"ntdll.dll");SetObserver set=(SetObserver)GetProcAddress(ntdll,"__wine_aoe_set_exception_observer");query_counter=(QueryCounter)GetProcAddress(ntdll,"NtQueryPerformanceCounter");if(!set||!query_counter)return 2;
 HANDLE file=CreateFileW(output,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(file==INVALID_HANDLE_VALUE)return 3;
 SIZE_T size=sizeof(Header)+CAPACITY*sizeof(Entry)+SAMPLE_CAPACITY*sizeof(Sample);HANDLE map=CreateFileMappingW(file,NULL,PAGE_READWRITE,0,(DWORD)size,NULL);if(!map)return 4;
 header=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,size);if(!header)return 5;entries=(Entry*)(header+1);samples=(Sample*)(entries+CAPACITY);
 LARGE_INTEGER now,frequency;query_counter(&now,&frequency);header->version=2;header->capacity=CAPACITY;header->frequency=frequency.QuadPart;header->pid=GetCurrentProcessId();header->installed=clock_ticks();
 tls_index=TlsAlloc();if(tls_index==TLS_OUT_OF_INDEXES)return 7;
 void *old=set(observe);if(old){set(old);header->errors=1;header->done=1;return 6;}
 InterlockedExchange64((volatile LONG64*)&header->magic,0x31445541454f414cULL);
 while(!header->stop&&clock_ticks()-header->installed<header->frequency*300)Sleep(100);
 set(NULL);Sleep(200);InterlockedExchange(&header->done,1);FlushViewOfFile(header,size);
 // In-flight callbacks may finish after unregistering. Keep code and mappings alive.
 CloseHandle(map);CloseHandle(file);return 0;
}
BOOL WINAPI DllMain(HINSTANCE self,DWORD reason,void *reserved){if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(self);HANDLE t=CreateThread(NULL,0,worker,NULL,0,NULL);if(t)CloseHandle(t);}return TRUE;}
