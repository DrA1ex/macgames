#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "aoe_hde_impl.h"
#define GAME_BASE 0x140000000ULL
#define BIG_PC 0x140f77b90ULL
#define BIG_SIZE 633
#define BIG_EXIT 579
static uint64_t relocated_pc(uint64_t address,uint64_t original,unsigned size,unsigned terminal,uint64_t clone){
 if(address<original||address>=original+size)return address;
 unsigned off=(unsigned)(address-original);return clone+off+(off>terminal?4:0);
}
static uint64_t logical_pc(uint64_t address,uint64_t original,unsigned size,unsigned terminal,uint64_t clone){
 if(address<clone||address>=clone+size+4)return address;
 unsigned off=(unsigned)(address-clone);if(off>=terminal&&off<terminal+5)return original+terminal;
 return original+off-(off>terminal?4:0);
}
// Preserve instruction boundaries except for the one-byte exit -> five-byte JMP.
// Reject short-branch overflow and every unrecognised relative encoding.
static int relocate_body_mode(const BYTE *plain,unsigned size,unsigned terminal,uint64_t original,BYTE *dest,int direct){
 BYTE boundary[1024]={0};unsigned off=0;uint64_t clone=(uintptr_t)dest;
 while(off<size){
  boundary[off]=1;if(off==terminal){if(plain[off]!=0x16)return 1;off++;continue;}
  hde64s h;BYTE scratch[32]={0};unsigned available=size-off;memcpy(scratch,plain+off,available<16?available:16);hde64_disasm(scratch,&h);
  if(!h.len||h.len>available||(h.flags&F_ERROR)||h.p_67||h.p_lock)return 2;off+=h.len;
 }
 if(off!=size)return 3;
 for(off=0;off<size;){
  unsigned out=off+(off>terminal&&!direct?4:0);
  if(off==terminal){if(direct)dest[out]=0xc3;else{dest[out]=0xe9;int64_t d=original+off-(clone+out+5);if(d<INT32_MIN||d>INT32_MAX)return 4;int32_t fixed=(int32_t)d;memcpy(dest+out+1,&fixed,4);}off++;continue;}
  hde64s h;BYTE scratch[32]={0};memcpy(scratch,plain+off,size-off<16?size-off:16);hde64_disasm(scratch,&h);memcpy(dest+out,plain+off,h.len);
  if(h.flags&F_RELATIVE){
   unsigned width=(h.flags&F_IMM8)?1:(h.flags&F_IMM32)?4:0;
   if(!width||!((h.opcode>=0x70&&h.opcode<=0x7f)||h.opcode==0xe8||h.opcode==0xe9||h.opcode==0xeb||(h.opcode==0x0f&&h.opcode2>=0x80&&h.opcode2<=0x8f)))return 5;
   int64_t displacement=width==1?(int8_t)h.imm.imm8:(int32_t)h.imm.imm32;
   uint64_t target=original+off+h.len+displacement;
   if(target>=original&&target<original+size){if(!boundary[target-original])return 6;target=direct?clone+(target-original):relocated_pc(target,original,size,terminal,clone);}
   int64_t d=target-(clone+out+h.len);
   if(width==1){if(d<INT8_MIN||d>INT8_MAX)return 7;dest[out+h.len-1]=(BYTE)(int8_t)d;}
   else{if(d<INT32_MIN||d>INT32_MAX)return 8;int32_t fixed=(int32_t)d;memcpy(dest+out+h.len-4,&fixed,4);}
  }
  if((h.flags&F_MODRM)&&h.modrm_mod==0&&h.modrm_rm==5){
   unsigned imm=0;if(h.flags&F_IMM8)imm++;if(h.flags&F_IMM16)imm+=2;if(h.flags&F_IMM32)imm+=4;if(h.flags&F_IMM64)imm+=8;
   if(!(h.flags&F_DISP32)||h.len<imm+4)return 9;
   unsigned at=h.len-imm-4;uint64_t target=original+off+h.len+(int64_t)(int32_t)h.disp.disp32;
   // Data references keep their original address, even inside the code image.
   int64_t d=target-(clone+out+h.len);if(d<INT32_MIN||d>INT32_MAX)return 10;int32_t fixed=(int32_t)d;memcpy(dest+out+at,&fixed,4);
  }
  off+=h.len;
 }
 return 0;
}
static int relocate_body(const BYTE *plain,unsigned size,unsigned terminal,uint64_t original,BYTE *dest){return relocate_body_mode(plain,size,terminal,original,dest,0);}
