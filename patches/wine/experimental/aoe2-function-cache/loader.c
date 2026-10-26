#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <wchar.h>
#include "pin.h"
/* This helper runs in the same isolated prefix, with no native debugger. */
int wmain(int argc,wchar_t **argv) {
 if(argc==3&&!wcscmp(argv[1],L"--check"))return pinned_executable(argv[2])?0:10;
 if(argc!=2)return 64;
 DWORD pid=0;HANDLE process=NULL;
 for(unsigned attempt=0;attempt<120&&!pid;attempt++){
  HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(snapshot==INVALID_HANDLE_VALUE)return 1;
  PROCESSENTRY32W e={.dwSize=sizeof(e)};
  for(BOOL ok=Process32FirstW(snapshot,&e);ok;ok=Process32NextW(snapshot,&e))if(!_wcsicmp(e.szExeFile,L"AoE2DE_s.exe")){
   if(pid){CloseHandle(snapshot);CloseHandle(process);return 2;}
   HANDLE candidate=OpenProcess(PROCESS_CREATE_THREAD|PROCESS_QUERY_INFORMATION|PROCESS_VM_OPERATION|PROCESS_VM_WRITE|PROCESS_VM_READ,FALSE,e.th32ProcessID);
   wchar_t image[32768];DWORD length=32768;
   if(candidate&&QueryFullProcessImageNameW(candidate,0,image,&length)&&pinned_executable(image)){pid=e.th32ProcessID;process=candidate;}
   else if(candidate)CloseHandle(candidate);
  }
  CloseHandle(snapshot);if(!pid)Sleep(1000);
 }
 if(!pid)return 3;
 SIZE_T size=(wcslen(argv[1])+1)*sizeof(wchar_t);void *remote=VirtualAllocEx(process,NULL,size,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
 if(!remote||!WriteProcessMemory(process,remote,argv[1],size,NULL)){CloseHandle(process);return 4;}
 HANDLE thread=CreateRemoteThread(process,NULL,0,(LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"LoadLibraryW"),remote,0,NULL);
 if(!thread){VirtualFreeEx(process,remote,0,MEM_RELEASE);CloseHandle(process);return 5;}
 DWORD wait=WaitForSingleObject(thread,10000),result=0;GetExitCodeThread(thread,&result);
 if(wait==WAIT_OBJECT_0)VirtualFreeEx(process,remote,0,MEM_RELEASE);
 printf("AoE II function cache: pid=%lu wait=%lu module=%08lx\n",pid,wait,result);fflush(stdout);
 CloseHandle(thread);CloseHandle(process);return wait==WAIT_OBJECT_0&&result?0:6;
}
