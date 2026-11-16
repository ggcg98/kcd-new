#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
TC="$ROOT/.tc"
mkdir -p "$TC"

echo "===== INSTALL ====="
if [ ! -x "$TC/ldid" ]; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld llvm make g++ pkg-config git perl dpkg curl xz-utils unzip libssl-dev binutils libplist-dev libplist-2.0-3
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ldid || true
  sudo ldconfig
  LDP=""
  for v in 14 15 16 13 12 11; do
    if [ -x "/usr/lib/llvm-$v/bin/ld64.lld" ]; then LDP="/usr/lib/llvm-$v/bin/ld64.lld"; break; fi
  done
  if [ -z "$LDP" ] && [ -x /usr/bin/ld64.lld ]; then LDP=/usr/bin/ld64.lld; fi
  if [ -z "$LDP" ]; then echo "NO LD64"; exit 1; fi
  echo "$LDP" > "$TC/ld64_path.txt"
  sudo ln -sf "$LDP" /usr/local/bin/ld64.lld
  mkdir -p "$TC/theos/sdks"
  rm -rf /tmp/sdks
  git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
  cd /tmp/sdks && git sparse-checkout set iPhoneOS16.5.sdk
  mv iPhoneOS16.5.sdk "$TC/theos/sdks/"
  rm -rf /tmp/ldid
  git clone --depth 1 https://github.com/ProcursusTeam/ldid.git /tmp/ldid
  cd /tmp/ldid && git submodule update --init && make -j4 || true
  if [ -f ldid ]; then cp ldid "$TC/ldid"; fi
  cd "$ROOT"
fi

sudo ldconfig
if [ -x /usr/bin/ldid ]; then sudo ln -sf /usr/bin/ldid /usr/local/bin/ldid
elif [ -f "$TC/ldid" ]; then sudo ln -sf "$TC/ldid" /usr/local/bin/ldid
else echo "NO LDID"; exit 1; fi
if [ -f "$TC/ld64_path.txt" ]; then sudo ln -sf "$(cat "$TC/ld64_path.txt")" /usr/local/bin/ld64.lld; fi

export THEOS="$TC/theos"
export PATH="/usr/local/bin:$TC:$PATH"
export AR=ar

echo "===== KFD ====="
rm -rf /tmp/kfdrepo
git clone --depth 1 https://github.com/Odyssey-Team/Taurine.git /tmp/kfdrepo

echo "===== TREES ====="
rm -rf src dist
mkdir -p src/kcore src/game src/tweak src/package/DEBIAN dist
cp -r /tmp/kfdrepo/Taurine/exploit/kfd/. src/kcore/kfd/
rm -f src/kcore/kfd/kfd_krw.m src/kcore/kfd/kfd_krw.h

cat > src/kcore/krw.h <<'KRWH_EOF'
#pragma once
#include <stdint.h>
#include <stddef.h>
extern uint64_t g_kbase, g_kslide, g_kernel_pmap, g_physmap_base, g_gnames;
extern int g_kfd_ready;
extern int g_off_teamid;
typedef struct { float x, y, z; } RVec3;
int row_up(void);
uint64_t r64(uint64_t a);
uint32_t r32(uint64_t a);
float rf32(uint64_t a);
int kread_buf(uint64_t a, void *b, size_t n);
uint64_t kread_ptr(uint64_t a);
uint64_t row_task_of_pid(int pid);
int row_pid_by_name(const char *key);
uint64_t row_base_of_task(uint64_t task);
uint64_t row_vtop(uint64_t task, uint64_t va);
int row_read_task(uint64_t task, uint64_t va, void *buf, size_t n);
int kcd_gnames_scan(void);
int kcd_fname(uint64_t pool, int32_t idx, char *out, int max);
int kcd_fname_str(uint64_t objaddr, char *out, int max);
int kcd_class_name(uint64_t obj, char *out, int max);
int kcd_is_bot(uint64_t pawn);
int kcd_team_of(uint64_t pawn);
int kcd_yaw_of(uint64_t pawn);
float kcd_health_of(uint64_t pawn);
int kcd_calib_teamid(void);
int kcd_reflect_teamid(void);
KRWH_EOF

echo "part1 done"
cat > src/kcore/krw.c <<'KRW_EOF'
#include "krw.h"
#include <stdlib.h>
#include <string.h>

#define OFF_PMAP_TTEP   0x08
#define OFF_TASK_MAP    0x28
#define OFF_VMMAP_PMAP  0x40
#define OFF_PROC_PID    0x60
#define OFF_PROC_TASK   0x10
#define OFF_PROC_NEXT   0x08
#define OFF_PAWN_PS     0x2B0
#define OFF_PAWN_CTRL   0x2A8
#define OFF_CTRL_ROT    0x2E4
#define OFF_OBJ_CLASS   0x10
#define OFF_OBJ_NAME    0x18
#define OFF_USTRUCT_CHL 0x48
#define OFF_UPROP_OFF   0x4C
#define OFF_UFIELD_NEXT 0x28

#if __has_include(<libkfd.h>)
#include <libkfd.h>
#define HAVE_KFD 1
#else
#define HAVE_KFD 0
#endif

uint64_t g_kbase=0,g_kslide=0,g_kernel_pmap=0,g_physmap_base=0,g_gnames=0;
int g_kfd_ready=0;
int g_off_teamid=0x2C0;
uint64_t g_ps_sample[32];
int g_ps_n=0;
static uint64_t g_h=0;
extern int proc_listpids(unsigned int,unsigned int,void*,int);
extern int proc_pidpath(int,void*,unsigned int);

#if HAVE_KFD
static int try_open(uint64_t p){uint64_t k=kopen(0x4000,p,2,2);if(k){g_h=k;return 1;}return 0;}
int row_up(void){
  if(!try_open(0)&&!try_open(1)&&!try_open(2))return -1;
  struct kfd*kd=(struct kfd*)g_h;
  g_kslide=kd->info.kernel.kernel_slide;
  g_kbase=0xFFFFFFF007004000ULL+g_kslide;
  g_kernel_pmap=kd->info.kernel.kernel_pmap;
  g_kfd_ready=1;return 0;
}
uint64_t r64(uint64_t a){uint64_t v=0;kread_(g_h,a,&v,8);return v;}
uint32_t r32(uint64_t a){uint32_t v=0;kread_(g_h,a,&v,4);return v;}
float rf32(uint64_t a){float v=0;kread_(g_h,a,&v,4);return v;}
int kread_buf(uint64_t a,void*b,size_t n){kread_(g_h,a,b,n);return 0;}
#else
int row_up(void){return -1;}
uint64_t r64(uint64_t a){(void)a;return 0;}
uint32_t r32(uint64_t a){(void)a;return 0;}
float rf32(uint64_t a){(void)a;return 0;}
int kread_buf(uint64_t a,void*b,size_t n){(void)a;(void)b;(void)n;return -1;}
#endif

uint64_t kread_ptr(uint64_t a){uint64_t v=0;kread_buf(a,&v,8);return v&0x0000FFFFFFFFFFFFULL;}
static int kptr(uint64_t p){return p>0x100000000ULL&&p<0x3000000000ULL;}
static uint64_t g_allproc=0;

static uint64_t find_allproc(void){
  for(uint64_t a=g_kbase+0x2000000ULL;a<g_kbase+0x6000000ULL;a+=8){
    uint64_t n=r64(a);if(!kptr(n))continue;
    uint64_t n2=r64(n);if(!kptr(n2))continue;
    uint64_t t=kread_ptr(n+OFF_PROC_TASK);if(!kptr(t))continue;
    uint64_t m=kread_ptr(t+OFF_TASK_MAP);if(!kptr(m))continue;
    int pid=(int)r32(n+OFF_PROC_PID);
    if(pid>0&&pid<100000)return a;
  }
  return 0;
}

uint64_t row_task_of_pid(int want){
  if(!g_allproc)g_allproc=find_allproc();
  if(!g_allproc)return 0;
  uint64_t p=r64(g_allproc);int g=0;
  while(kptr(p)&&g++<2000){
    if((int)r32(p+OFF_PROC_PID)==want)return kread_ptr(p+OFF_PROC_TASK);
    uint64_t nx=r64(p+OFF_PROC_NEXT);
    if(nx==g_allproc||nx==p)break;
    p=nx;
  }
  return 0;
}

int row_pid_by_name(const char*key){
  int cap=4096;
  pid_t*l=(pid_t*)malloc(sizeof(pid_t)*cap);
  if(!l)return -1;
  int n=proc_listpids(1,0,l,sizeof(pid_t)*cap)/sizeof(pid_t);
  int f=-1;char path[1024];
  for(int i=0;i<n;i++){
    if(l[i]<=0)continue;
    memset(path,0,sizeof(path));
    proc_pidpath(l[i],path,sizeof(path)-1);
    if(strstr(path,key)){f=l[i];break;}
  }
  free(l);return f;
}

uint64_t row_base_of_task(uint64_t task){
  if(!task)return 0;
  for(uint64_t va=0x100000000ULL;va<0x200000000ULL;va+=0x1000000ULL){
    uint32_t m=0;
    if(row_read_task(task,va,&m,4)!=0)continue;
    if(m==0xFEEDFACF)return va;
  }
  return 0;
}

uint64_t row_vtop(uint64_t task,uint64_t va){
  if(!task)return 0;
  uint64_t map=kread_ptr(task+OFF_TASK_MAP);if(!kptr(map))return 0;
  uint64_t pm=kread_ptr(map+OFF_VMMAP_PMAP);if(!kptr(pm))return 0;
  uint64_t tt=r64(pm+OFF_PMAP_TTEP);if(!tt)return 0;
  uint64_t t1=tt&0x0000FFFFFFFFC000ULL;
  uint64_t e1=r64(t1+(((va>>36)&0x7FF)*8));if((e1&3)!=3)return 0;
  uint64_t t2=e1&0x0000FFFFFFFFC000ULL;
  uint64_t e2=r64(t2+(((va>>25)&0x7FF)*8));if((e2&3)!=3)return 0;
  uint64_t t3=e2&0x0000FFFFFFFFC000ULL;
  uint64_t e3=r64(t3+(((va>>14)&0x7FF)*8));if((e3&3)!=3)return 0;
  return (e3&0x0000FFFFFFFFC000ULL)+(va&0x3FFF);
}

int row_read_task(uint64_t task,uint64_t va,void*buf,size_t n){
  if(!g_physmap_base)return -1;
  uint8_t*p=(uint8_t*)buf;
  while(n>0){
    uint64_t pa=row_vtop(task,va);if(!pa)return -1;
    size_t c=0x4000-(size_t)(va&0x3FFF);if(c>n)c=n;
    kread_buf(g_physmap_base+pa,p,c);
    va+=c;p+=c;n-=c;
  }
  return 0;
}

int kcd_fname(uint64_t pool,int32_t idx,char*out,int max){
  if(!pool||max<4)return 0;
  int blk=idx>>16,off=idx&0xFFFF;
  uint64_t bs=r64(pool+0x10);if(!kptr(bs))return 0;
  uint64_t b=r64(bs+(uint64_t)blk*8);if(!kptr(b))return 0;
  uint64_t e=b+(uint64_t)off*2;
  uint16_t h=(uint16_t)(r32(e)&0xFFFF);
  int len=(h>>6)&0x3FF;
  if(len<=0||len>=max)return 0;
  if(h&1){for(int i=0;i<len;i++)out[i]=(char)(r32(e+2+i*2)&0xFF);}
  else{for(int i=0;i<len;i++)out[i]=(char)(r32(e+2+i)&0xFF);}
  out[len]=0;return len;
}

int kcd_fname_str(uint64_t obj,char*out,int max){
  if(!obj||!g_gnames)return 0;
  return kcd_fname(g_gnames,(int32_t)r32(obj+OFF_OBJ_NAME),out,max);
}

int kcd_class_name(uint64_t obj,char*out,int max){
  if(!obj||!g_gnames)return 0;
  uint64_t cls=kread_ptr(obj+OFF_OBJ_CLASS);if(!kptr(cls))return 0;
  return kcd_fname(g_gnames,(int32_t)r32(cls+OFF_OBJ_NAME),out,max);
}

int kcd_gnames_scan(void){
  if(g_gnames)return 0;
  char tmp[64];
  for(uint64_t a=g_kbase+0x4000000ULL;a<g_kbase+0x10000000ULL;a+=8){
    uint64_t bs=r64(a+0x10);if(!kptr(bs))continue;
    uint64_t b0=r64(bs);if(!kptr(b0))continue;
    uint16_t h=(uint16_t)(r32(b0)&0xFFFF);
    int len=(h>>6)&0x3FF;
    if(len<2||len>16)continue;
    if(kcd_fname(a,0,tmp,60)>0&&strcmp(tmp,"None")==0){g_gnames=a;return 0;}
  }
  return -1;
}

int kcd_is_bot(uint64_t pawn){
  if(!pawn)return 1;
  uint64_t ps=kread_ptr(pawn+OFF_PAWN_PS);if(!ps)return 1;
  uint64_t c=kread_ptr(pawn+OFF_PAWN_CTRL);if(!c)return 1;
  char buf[64]={0};
  if(kcd_class_name(c,buf,60)>0){
    if(strstr(buf,"AIController"))return 1;
    if(strstr(buf,"AI_"))return 1;
  }
  if(kcd_class_name(pawn,buf,60)>0){
    if(strstr(buf,"_AI_"))return 1;
    if(strstr(buf,"Bot"))return 1;
  }
  return 0;
}

int kcd_team_of(uint64_t pawn){
  if(!pawn)return -1;
  uint64_t ps=kread_ptr(pawn+OFF_PAWN_PS);if(!ps)return -1;
  if(g_ps_n<32){
    int d=0;
    for(int i=0;i<g_ps_n;i++)if(g_ps_sample[i]==ps){d=1;break;}
    if(!d)g_ps_sample[g_ps_n++]=ps;
  }
  int t=(int)r32(ps+g_off_teamid);
  if(t<0||t>64)return -1;
  return t;
}

int kcd_yaw_of(uint64_t pawn){
  if(!pawn)return -1;
  uint64_t c=kread_ptr(pawn+OFF_PAWN_CTRL);if(!c)return -1;
  float y=rf32(c+OFF_CTRL_ROT);
  if(y>360.0f||y<-360.0f)return -1;
  int d=(int)y;if(d<0)d+=360;return d;
}

float kcd_health_of(uint64_t pawn){
  if(!pawn)return -1.0f;
  uint64_t ps=kread_ptr(pawn+OFF_PAWN_PS);
  uint64_t cd[6]={pawn+0x3A0,pawn+0x2F0,ps+0x2F0,ps+0x3A0,pawn+0x4A0,ps+0x4A0};
  for(int i=0;i<6;i++){
    if(!kptr(cd[i]))continue;
    float v=rf32(cd[i]);
    if(v>0.0f&&v<=1000.0f)return v;
  }
  return -1.0f;
}

int kcd_calib_teamid(void){
  if(g_ps_n<3)return -1;
  int best=-1,bs=-99999;
  for(int off=0x280;off<=0x340;off+=4){
    int vals[32],n=0,ok=1,mx=0,z=0;
    for(int i=0;i<g_ps_n;i++){
      int v=(int)r32(g_ps_sample[i]+off);
      if(v<0||v>64){ok=0;break;}
      vals[n++]=v;if(v>mx)mx=v;if(v==0)z++;
    }
    if(!ok)continue;
    int dis=0;
    for(int i=0;i<n;i++){
      int d=0;
      for(int j=0;j<i;j++)if(vals[j]==vals[i]){d=1;break;}
      if(!d)dis++;
    }
    int sc=0;
    if(dis>=2&&dis<=12)sc+=120;
    if(dis<=1)sc-=250;
    if(z==n)sc-=400;
    if(z>n/2)sc-=60;
    if(mx<=20)sc+=25;
    if(sc>bs){bs=sc;best=off;}
  }
  return best;
}

int kcd_reflect_teamid(void){
  if(!g_gnames||g_ps_n<1)return -1;
  uint64_t cls=kread_ptr(g_ps_sample[0]+OFF_OBJ_CLASS);
  if(!kptr(cls))return -1;
  uint64_t p=kread_ptr(cls+OFF_USTRUCT_CHL);
  int g=0;
  while(kptr(p)&&g++<300){
    char nm[80]={0};
    kcd_fname_str(p,nm,72);
    if(strstr(nm,"Team")){
      int o=(int)r32(p+OFF_UPROP_OFF);
      if(o>0&&o<0x800)return o;
    }
    p=kread_ptr(p+OFF_UFIELD_NEXT);
  }
  return -1;
}
KRW_EOF

echo "part2 done"
cat > src/game/ue4.h <<'UE4H_EOF'
#pragma once
#include <stdint.h>
#include "krw.h"

typedef struct { float x, y; } Vec2;

#define BONE_N 15
#define MAX_ENT 64
#define MAX_LOOT 128

typedef struct {
    uint64_t pawn;
    RVec3    world;
    float    dist;
    int      team;
    int      is_bot;
    int      yaw;
    float    hp;
    char     op[32];
    RVec3    bones[BONE_N];
} EntOut;

#define LT_BOX   0
#define LT_GUN   1
#define LT_BAG   2
#define LT_AMMO  3
#define LT_MED   4
#define LT_ARMOR 5
#define LT_ITEM  6

typedef struct {
    uint64_t actor;
    RVec3    world;
    float    dist;
    int      rarity;
    int      type;
    char     name[40];
} LootOut;

typedef struct {
    uint64_t task, base, gworld, self_pawn;
    RVec3    pov_loc;
    float    pov_pitch, pov_yaw, fov;
    int      sw, sh, ready;
} Ue4Ctx;

int ue4_setup(Ue4Ctx *c);
int ue4_scan(Ue4Ctx *c, EntOut *out, int max);
int ue4_w2s(Ue4Ctx *c, RVec3 w, Vec2 *s);
int ue4_scan_loot(Ue4Ctx *c, LootOut *out, int max);
UE4H_EOF

cat > src/game/ue4.c <<'UE4_EOF'
#include "ue4.h"
#include <math.h>
#include <string.h>

#define OFF_UWORLD_LEVEL 0x30
#define OFF_LEVEL_ACTORS 0xA0
#define OFF_LEVEL_CNT    0xA8
#define OFF_ACTOR_ROOT   0x1B0
#define OFF_ROOT_LOC     0x1A0
#define OFF_PAWN_PS      0x2B0
#define OFF_GI_LOCAL     0x38
#define OFF_LP_PC        0x30
#define OFF_PC_CAM       0x2E0
#define OFF_CAM_CACHE    0x1A0
#define OFF_POV_LOC      0x10
#define OFF_POV_ROT      0x1C
#define OFF_POV_FOV      0x28
#define D2R 0.0174532925199433f

static int look_uworld(uint64_t u){
  if(u<0x100000000ULL||u>0x3000000000ULL)return 0;
  uint64_t l=kread_ptr(u+OFF_UWORLD_LEVEL);
  if(l<0x100000000ULL||l>0x3000000000ULL)return 0;
  uint64_t a=kread_ptr(l+OFF_LEVEL_ACTORS);
  if(a<0x100000000ULL||a>0x3000000000ULL)return 0;
  int c=(int)r32(l+OFF_LEVEL_CNT);
  if(c<1||c>200000)return 0;
  return 1;
}

static uint64_t scan_gworld(Ue4Ctx*c){
  for(uint64_t a=c->base+0x1000000ULL;a<c->base+0x6000000ULL;a+=8){
    uint64_t v=0;
    if(row_read_task(c->task,a,&v,8)!=0)continue;
    if(look_uworld(v))return v;
  }
  return 0;
}

int ue4_setup(Ue4Ctx*c){
  c->ready=0;
  uint64_t gw=scan_gworld(c);
  if(!gw)return -1;
  c->gworld=gw;
  uint64_t pc=0;
  uint64_t gi=kread_ptr(gw+0x1B8);
  if(gi>0x100000000ULL){
    uint64_t lp=kread_ptr(gi+OFF_GI_LOCAL);
    if(lp>0x100000000ULL)pc=kread_ptr(lp+OFF_LP_PC);
  }
  if(pc>0x100000000ULL){
    c->self_pawn=kread_ptr(pc+0x2A8);
    uint64_t cam=kread_ptr(pc+OFF_PC_CAM);
    if(cam>0x100000000ULL){
      RVec3 loc,rot;
      if(row_read_task(c->task,cam+OFF_CAM_CACHE+OFF_POV_LOC,&loc,12)==0)c->pov_loc=loc;
      if(row_read_task(c->task,cam+OFF_CAM_CACHE+OFF_POV_ROT,&rot,12)==0){
        c->pov_pitch=rot.x;c->pov_yaw=rot.y;
      }
      float f=0;
      if(row_read_task(c->task,cam+OFF_CAM_CACHE+OFF_POV_FOV,&f,4)==0){
        if(f>30.0f&&f<140.0f)c->fov=f;
      }
    }
  }
  if(c->fov<30.0f||c->fov>140.0f)c->fov=90.0f;
  if(c->self_pawn){
    uint64_t root=kread_ptr(c->self_pawn+OFF_ACTOR_ROOT);
    if(root>0x100000000ULL){
      RVec3 loc;
      if(row_read_task(c->task,root+OFF_ROOT_LOC,&loc,12)==0)c->pov_loc=loc;
    }
  }
  c->ready=1;
  return 0;
}

int ue4_w2s(Ue4Ctx*c,RVec3 w,Vec2*s){
  float dx=w.x-c->pov_loc.x,dy=w.y-c->pov_loc.y,dz=w.z-c->pov_loc.z;
  float cy=cosf(-c->pov_yaw*D2R),sy=sinf(-c->pov_yaw*D2R);
  float x1=dx*cy-dy*sy,y1=dx*sy+dy*cy,z1=dz;
  float cp=cosf(c->pov_pitch*D2R),sp=sinf(c->pov_pitch*D2R);
  float x2=x1*cp-z1*sp,z2=x1*sp+z1*cp,y2=y1;
  if(x2<1.0f)return 0;
  float sc=(c->sh*0.5f)/tanf(c->fov*D2R*0.5f);
  s->x=c->sw*0.5f+(y2*sc/x2);
  s->y=c->sh*0.5f-(z2*sc/x2);
  return 1;
}

static void build_bones(EntOut*e){
  float h=176.0f;
  RVec3 b=e->world;
  float yr=(float)e->yaw*D2R;
  float rx=cosf(yr)*20.0f,ry=sinf(yr)*20.0f;
  e->bones[0]=(RVec3){b.x,b.y,b.z+h};
  e->bones[1]=(RVec3){b.x,b.y,b.z+h*0.90f};
  e->bones[2]=(RVec3){b.x,b.y,b.z+h*0.80f};
  e->bones[3]=(RVec3){b.x-rx,b.y-ry,b.z+h*0.80f};
  e->bones[4]=(RVec3){b.x-rx*1.7f,b.y-ry*1.7f,b.z+h*0.60f};
  e->bones[5]=(RVec3){b.x-rx*2.2f,b.y-ry*2.2f,b.z+h*0.45f};
  e->bones[6]=(RVec3){b.x+rx,b.y+ry,b.z+h*0.80f};
  e->bones[7]=(RVec3){b.x+rx*1.7f,b.y+ry*1.7f,b.z+h*0.60f};
  e->bones[8]=(RVec3){b.x+rx*2.2f,b.y+ry*2.2f,b.z+h*0.45f};
  e->bones[9]=(RVec3){b.x,b.y,b.z+h*0.50f};
  e->bones[10]=(RVec3){b.x-rx*0.6f,b.y-ry*0.6f,b.z+h*0.50f};
  e->bones[11]=(RVec3){b.x+rx*0.6f,b.y+ry*0.6f,b.z+h*0.50f};
  e->bones[12]=(RVec3){b.x-rx*0.6f,b.y-ry*0.6f,b.z+h*0.26f};
  e->bones[13]=(RVec3){b.x+rx*0.6f,b.y+ry*0.6f,b.z+h*0.26f};
  e->bones[14]=(RVec3){b.x,b.y,b.z};
}

static void op_from_class(uint64_t pawn,char*out){
  out[0]=0;
  char buf[80]={0};
  if(kcd_class_name(pawn,buf,72)<=0)return;
  char*p=buf;
  if(strncmp(p,"BP_",3)==0)p+=3;
  if(strncmp(p,"Operator_",9)==0)p+=9;
  if(strncmp(p,"Op_",3)==0)p+=3;
  int n=(int)strlen(p);
  if(n>2&&strcmp(p+n-2,"_C")==0)p[n-2]=0;
  strncpy(out,p,28);out[28]=0;
}

int ue4_scan(Ue4Ctx*c,EntOut*out,int max){
  if(!c->ready||!c->gworld)return 0;
  uint64_t l=kread_ptr(c->gworld+OFF_UWORLD_LEVEL);
  if(l<0x100000000ULL)return 0;
  uint64_t arr=kread_ptr(l+OFF_LEVEL_ACTORS);
  if(arr<0x100000000ULL)return 0;
  int cnt=(int)r32(l+OFF_LEVEL_CNT);
  if(cnt<1)return 0;
  if(cnt>4000)cnt=4000;
  uint64_t self=c->self_pawn;
  int n=0;
  for(int i=0;i<cnt&&n<max;i++){
    uint64_t a=0;
    if(row_read_task(c->task,arr+(uint64_t)i*8,&a,8)!=0)continue;
    if(a<0x100000000ULL||a>0x3000000000ULL)continue;
    if(a==self)continue;
    uint64_t ps=kread_ptr(a+OFF_PAWN_PS);
    if(ps<0x100000000ULL)continue;
    uint64_t root=kread_ptr(a+OFF_ACTOR_ROOT);
    if(root<0x100000000ULL)continue;
    RVec3 loc;
    if(row_read_task(c->task,root+OFF_ROOT_LOC,&loc,12)!=0)continue;
    if(loc.x<-1000000.0f||loc.x>1000000.0f)continue;
    if(loc.z<-100000.0f||loc.z>100000.0f)continue;
    float dx=loc.x-c->pov_loc.x,dy=loc.y-c->pov_loc.y,dz=loc.z-c->pov_loc.z;
    EntOut*e=&out[n];
    memset(e,0,sizeof(*e));
    e->pawn=a;
    e->world=loc;
    e->dist=sqrtf(dx*dx+dy*dy+dz*dz)/100.0f;
    e->is_bot=kcd_is_bot(a);
    e->team=kcd_team_of(a);
    e->yaw=kcd_yaw_of(a);
    if(e->yaw<0)e->yaw=0;
    e->hp=kcd_health_of(a);
    op_from_class(a,e->op);
    build_bones(e);
    n++;
  }
  return n;
}

static int kw_hit(const char *s, const char *k) {
    size_t n = strlen(k);
    for (const char *p = s; *p; p++) {
        size_t i = 0;
        while (i < n && p[i]) {
            char a = p[i], b = k[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
            i++;
        }
        if (i == n) return 1;
    }
    return 0;
}

static int loot_type(const char *c) {
    if (kw_hit(c,"Weapon")||kw_hit(c,"Rifle")||kw_hit(c,"Gun")||
        kw_hit(c,"Pistol")||kw_hit(c,"Sniper")||kw_hit(c,"Shotgun")||
        kw_hit(c,"SMG")||kw_hit(c,"LMG")||kw_hit(c,"Carbine")) return LT_GUN;
    if (kw_hit(c,"Backpack")||kw_hit(c,"Bag")||kw_hit(c,"Pack")||
        kw_hit(c,"Rucksack")) return LT_BAG;
    if (kw_hit(c,"Ammo")||kw_hit(c,"Bullet")||kw_hit(c,"Mag")||
        kw_hit(c,"Grenade")||kw_hit(c,"Bomb")) return LT_AMMO;
    if (kw_hit(c,"Med")||kw_hit(c,"Aid")||kw_hit(c,"Bandage")||
        kw_hit(c,"Injector")||kw_hit(c,"Stim")||kw_hit(c,"Syringe")) return LT_MED;
    if (kw_hit(c,"Armor")||kw_hit(c,"Vest")||kw_hit(c,"Helmet")||
        kw_hit(c,"Plate")||kw_hit(c,"Rig")) return LT_ARMOR;
    if (kw_hit(c,"Box")||kw_hit(c,"Case")||kw_hit(c,"Safe")||
        kw_hit(c,"Chest")||kw_hit(c,"Container")||kw_hit(c,"Loot")||
        kw_hit(c,"Supply")||kw_hit(c,"Stash")||kw_hit(c,"Crate")) return LT_BOX;
    if (kw_hit(c,"Item")||kw_hit(c,"Pickup")||kw_hit(c,"Pickable")||
        kw_hit(c,"Drop")) return LT_ITEM;
    return -1;
}

static int loot_rarity(uint64_t actor) {
    static const uint32_t offs[] = {
        0x2C0,0x2D0,0x2E0,0x2F0,0x300,0x310,0x3A0,0x3B0,0x4A0,0x5A0
    };
    for (int i = 0; i < 10; i++) {
        int v = (int)r32(actor + offs[i]);
        if (v >= 1 && v <= 6) return v;
    }
    return 0;
}

int ue4_scan_loot(Ue4Ctx *c, LootOut *out, int max) {
    if (!c->ready || !c->gworld) return 0;
    uint64_t l = kread_ptr(c->gworld + OFF_UWORLD_LEVEL);
    if (l < 0x100000000ULL) return 0;
    uint64_t arr = kread_ptr(l + OFF_LEVEL_ACTORS);
    if (arr < 0x100000000ULL) return 0;
    int cnt = (int)r32(l + OFF_LEVEL_CNT);
    if (cnt < 1) return 0;
    if (cnt > 6000) cnt = 6000;

    int n = 0;
    for (int i = 0; i < cnt && n < max; i++) {
        uint64_t a = 0;
        if (row_read_task(c->task, arr + (uint64_t)i * 8, &a, 8) != 0) continue;
        if (a < 0x100000000ULL || a > 0x3000000000ULL) continue;
        if (a == c->self_pawn) continue;

        char cls[96] = {0};
        if (kcd_class_name(a, cls, 88) <= 0) continue;

        int tp = loot_type(cls);
        if (tp < 0) continue;

        uint64_t ps = kread_ptr(a + OFF_PAWN_PS);
        if (ps > 0x100000000ULL) continue;

        int rar = loot_rarity(a);
        if (rar <= 0) rar = 3;

        uint64_t root = kread_ptr(a + OFF_ACTOR_ROOT);
        if (root < 0x100000000ULL) continue;

        RVec3 loc;
        if (row_read_task(c->task, root + OFF_ROOT_LOC, &loc, 12) != 0) continue;
        if (loc.x < -1000000.0f || loc.x > 1000000.0f) continue;
        if (loc.z < -100000.0f || loc.z > 100000.0f) continue;

        float dx = loc.x - c->pov_loc.x;
        float dy = loc.y - c->pov_loc.y;
        float dz = loc.z - c->pov_loc.z;

        LootOut *o = &out[n];
        memset(o, 0, sizeof(*o));
        o->actor = a;
        o->world = loc;
        o->dist = sqrtf(dx * dx + dy * dy + dz * dz) / 100.0f;
        o->rarity = rar;
        o->type = tp;

        char *p = cls;
        if (strncmp(p, "BP_", 3) == 0) p += 3;
        int L = (int)strlen(p);
        if (L > 2 && strcmp(p + L - 2, "_C") == 0) p[L - 2] = 0;
        strncpy(o->name, p, 36);
        o->name[36] = 0;
        n++;
    }
    return n;
}
UE4_EOF

echo "part3 done"
cat > src/tweak/Overlay.xm <<'OX1_EOF'
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdint.h>
#include <math.h>

#include "krw.h"
#include "ue4.h"

@interface UIWindow (KCDSec)
- (void)_setSecure:(BOOL)b;
@end

static Ue4Ctx  g_ctx;
static EntOut  g_ents[MAX_ENT];
static int     g_n = 0;
static int     g_run = 1;
static int     g_game_pid = 0;
static int     g_my_team = 1;
static float   g_near = 1e9f;
static int     g_near_team = -1;
static int     g_near_yaw = -1;
static char    g_near_op[32] = {0};
static int     g_back = 0;
static int     g_humans = 0;
static uint32_t g_tmask = 0;

static UIWindow *g_esp = nil;
static UIWindow *g_hud = nil;
static UIWindow *g_panel = nil;
static UILabel *g_l1 = nil;
static UILabel *g_l2 = nil;
static UILabel *g_l3 = nil;
static UIScrollView *g_psv = nil;
static BOOL g_panel_on = NO;

static id cfg_get(NSString *k) {
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
    return (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)k, CFSTR("com.kcd.config"));
}
static void cfg_set(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, CFSTR("com.kcd.config"));
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
}
static BOOL cfg_b(NSString *k, BOOL d) { id v = cfg_get(k); return v ? [v boolValue] : d; }
static int  cfg_i(NSString *k, int d)  { id v = cfg_get(k); return v ? [v intValue] : d; }

static UIColor *team_color(int t, BOOL me) {
    if (me) return [UIColor colorWithRed:0.0 green:1.0 blue:0.93 alpha:1.0];
    if (t < 0) return [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0];
    static const int rgb[12][3] = {
        {255,38,38},{255,140,0},{255,224,0},{160,255,0},
        {0,224,80},{0,224,160},{0,200,255},{42,107,255},
        {138,43,226},{224,32,192},{255,80,144},{176,112,48}
    };
    int i = t % 12;
    if (i < 0) i += 12;
    return [UIColor colorWithRed:rgb[i][0]/255.0 green:rgb[i][1]/255.0 blue:rgb[i][2]/255.0 alpha:1.0];
}

static void *scan_loop(void *arg) {
    (void)arg;
    if (row_up() != 0) return NULL;

    g_physmap_base = 0;
    uint64_t ttep = 0;
    kread_buf(g_kernel_pmap + 0x08, &ttep, 8);
    ttep &= 0x0000FFFFFFFFC000ULL;
    for (int i = 0; i < 512 && ttep; i++) {
        uint64_t e = 0;
        kread_buf(ttep + (uint64_t)i * 8, &e, 8);
        if ((e & 3) == 3 && (e & 0x0000FFFFFFE00000ULL) == 0) {
            g_physmap_base = 0xfffffff000000000ULL + ((uint64_t)i << 30);
            break;
        }
    }
    kcd_gnames_scan();

    while (g_run) {
        int pid = row_pid_by_name("DeltaForce");
        if (pid <= 0) { usleep(300000); continue; }
        if (pid != g_game_pid) {
            g_game_pid = pid;
            memset(&g_ctx, 0, sizeof(g_ctx));
            g_ctx.task = row_task_of_pid(pid);
            if (!g_ctx.task) { usleep(300000); continue; }
            g_ctx.base = row_base_of_task(g_ctx.task);
            if (!g_ctx.base) { usleep(300000); continue; }
            g_ctx.sw = (int)[UIScreen mainScreen].bounds.size.width;
            g_ctx.sh = (int)[UIScreen mainScreen].bounds.size.height;
            if (ue4_setup(&g_ctx) != 0) { g_game_pid = 0; usleep(500000); continue; }
            if (g_ps_n >= 3) {
                int sel = cfg_i(@"teamid_off", 0);
                if (sel > 0) g_off_teamid = 0x2B8 + (sel - 1) * 8;
                else {
                    int o = kcd_calib_teamid();
                    if (o > 0) g_off_teamid = o;
                    else { int r2 = kcd_reflect_teamid(); if (r2 > 0) g_off_teamid = r2; }
                }
            }
        }
        if (!g_ctx.ready) { usleep(200000); continue; }

        g_my_team = cfg_i(@"my_team", 1);
        g_n = ue4_scan(&g_ctx, g_ents, MAX_ENT);

        float nr = 1e9f;
        int nt = -1, ny = -1, bk = 0, hm = 0;
        char nop[32] = {0};
        uint32_t tm = 0;
        int botf = cfg_b(@"bot_filter", YES) ? 1 : 0;
        int maxd = cfg_i(@"max_dist", 300);

        for (int i = 0; i < g_n; i++) {
            EntOut *e = &g_ents[i];
            if (botf && e->is_bot) continue;
            if (e->dist > maxd) continue;
            hm++;
            if (e->team >= 0 && e->team < 32) tm |= (1u << e->team);
            Vec2 sp;
            BOOL on = ue4_w2s(&g_ctx, e->world, &sp) &&
                      sp.x > 0 && sp.x < g_ctx.sw && sp.y > 0 && sp.y < g_ctx.sh;
            if (!on && e->dist < 40.0f) bk++;
            if (e->dist < nr) {
                nr = e->dist;
                nt = e->team;
                ny = e->yaw;
                strncpy(nop, e->op, 31);
            }
        }
        g_near = nr;
        g_near_team = nt;
        g_near_yaw = ny;
        strncpy(g_near_op, nop, 31);
        g_near_op[31] = 0;
        g_back = bk;
        g_humans = hm;
        g_tmask = tm;

        usleep(cfg_i(@"scan_ms", 16) * 1000);
    }
    return NULL;
}

@interface KCDView : UIView @end
@implementation KCDView
- (void)drawRect:(CGRect)r {
    (void)r;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int botf   = cfg_b(@"bot_filter", YES) ? 1 : 0;
    int teamf  = cfg_b(@"team_filter", NO) ? 1 : 0;
    int maxd   = cfg_i(@"max_dist", 300);
    int showbox = cfg_b(@"box_enemy", YES) ? 1 : 0;
    int showbone = cfg_b(@"skeleton", YES) ? 1 : 0;
    int showhp = cfg_b(@"health", YES) ? 1 : 0;
    int showdist = cfg_b(@"distance", YES) ? 1 : 0;
    int showname = cfg_b(@"op_name", YES) ? 1 : 0;
    CGFloat fs = (CGFloat)cfg_i(@"text_size", 13);
    CGFloat th = (CGFloat)cfg_i(@"thick", 1);
    UIFont *f = [UIFont boldSystemFontOfSize:fs];
    NSDictionary *wa = @{ NSFontAttributeName: f,
                          NSForegroundColorAttributeName: [UIColor whiteColor] };

    for (int i = 0; i < g_n; i++) {
        EntOut *e = &g_ents[i];
        if (botf && e->is_bot) continue;
        if (teamf && e->team == g_my_team) continue;
        if (e->dist > maxd) continue;

        RVec3 head = e->world;
        head.z += 176.0f;
        Vec2 ph, pf;
        if (!ue4_w2s(&g_ctx, head, &ph)) continue;
        if (!ue4_w2s(&g_ctx, e->world, &pf)) continue;
        CGFloat h = fabsf(pf.y - ph.y);
        if (h < 6.0f) continue;
        CGFloat w = h * 0.42f;
        CGRect box = CGRectMake(ph.x - w * 0.5f, ph.y, w, h);
        BOOL me = (e->team == g_my_team);
        UIColor *c = team_color(e->team, me);

        if (showbox) {
            CGContextSetStrokeColorWithColor(ctx, c.CGColor);
            CGContextSetLineWidth(ctx, th);
            CGContextStrokeRect(ctx, box);
        }

        if (showbone) {
            Vec2 bp[BONE_N];
            int ok[BONE_N];
            for (int k = 0; k < BONE_N; k++) ok[k] = ue4_w2s(&g_ctx, e->bones[k], &bp[k]);
            CGContextSetStrokeColorWithColor(ctx, c.CGColor);
            CGContextSetLineWidth(ctx, th);
            static const int ln[14][2] = {
                {1,2},{2,9},{2,3},{3,4},{4,5},{2,6},{6,7},
                {7,8},{9,10},{9,11},{10,12},{11,13},{12,14},{13,14}
            };
            for (int k = 0; k < 14; k++) {
                int a = ln[k][0], b = ln[k][1];
                if (!ok[a] || !ok[b]) continue;
                CGContextMoveToPoint(ctx, bp[a].x, bp[a].y);
                CGContextAddLineToPoint(ctx, bp[b].x, bp[b].y);
            }
            CGContextStrokePath(ctx);
            if (ok[0]) {
                CGFloat rr = MAX(2.0f, h * 0.06f);
                CGContextSetFillColorWithColor(ctx, c.CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(bp[0].x - rr, bp[0].y - rr, rr * 2, rr * 2));
            }
        }

        if (showhp && e->hp > 0.0f) {
            CGFloat pct = e->hp / 100.0f;
            if (pct > 1.0f) pct = 1.0f;
            CGRect hb = CGRectMake(box.origin.x - 5, box.origin.y, 3, box.size.height);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
            CGContextFillRect(ctx, hb);
            CGRect hf = CGRectMake(hb.origin.x,
                                   hb.origin.y + hb.size.height * (1.0f - pct),
                                   hb.size.width,
                                   hb.size.height * pct);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:1.0].CGColor);
            CGContextFillRect(ctx, hf);
        }

        NSString *txt = @"";
        if (showname && e->op[0]) txt = [NSString stringWithFormat:@"%s", e->op];
        if (showdist) {
            NSString *d = [NSString stringWithFormat:@"%.0fm", e->dist];
            txt = txt.length ? [NSString stringWithFormat:@"%@ %@", txt, d] : d;
        }
        if (txt.length) {
            [txt drawAtPoint:CGPointMake(box.origin.x, box.origin.y + box.size.height + 2)
              withAttributes:wa];
        }
    }
}
@end
OX1_EOF

echo "part4 done"
cat >> src/tweak/Overlay.xm <<'OX2_EOF'

static void make_esp(void) {
    if (g_esp) return;
    CGRect sc = [UIScreen mainScreen].bounds;
    g_esp = [[UIWindow alloc] initWithFrame:sc];
    g_esp.windowLevel = UIWindowLevelAlert + 400;
    g_esp.backgroundColor = [UIColor clearColor];
    g_esp.userInteractionEnabled = NO;
    if ([g_esp respondsToSelector:@selector(_setSecure:)]) [g_esp _setSecure:YES];

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    KCDView *v = [[KCDView alloc] initWithFrame:sc];
    v.backgroundColor = [UIColor clearColor];
    v.userInteractionEnabled = NO;
    [vc.view addSubview:v];
    g_esp.rootViewController = vc;
    g_esp.hidden = NO;

    [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer *tt) {
        (void)tt;
        [v setNeedsDisplay];
    }];
}

@interface KCDPan : NSObject @end
@implementation KCDPan
+ (instancetype)sh { static KCDPan *s; if (!s) s = [KCDPan new]; return s; }
- (void)pan:(UIPanGestureRecognizer *)p {
    UIView *v = p.view;
    CGPoint d = [p translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [p setTranslation:CGPointZero inView:v.superview];
    if (p.state == UIGestureRecognizerStateEnded) {
        CGRect sc = [UIScreen mainScreen].bounds;
        int px = (int)(v.center.x / sc.size.width * 100.0);
        int py = (int)(v.center.y / sc.size.height * 100.0);
        NSString *kx = @"nearest_x", *ky = @"nearest_y";
        if (v.tag == 2) { kx = @"back_x"; ky = @"back_y"; }
        if (v.tag == 3) { kx = @"count_x"; ky = @"count_y"; }
        cfg_set(kx, @(px));
        cfg_set(ky, @(py));
    }
}
@end

@interface KCDHudWin : UIWindow @end
@implementation KCDHudWin
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self) return nil;
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

static UILabel *mklab(CGFloat x, CGFloat y, int tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 420, 26)];
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:(CGFloat)cfg_i(@"text_size", 13)];
    l.userInteractionEnabled = YES;
    l.tag = tag;
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:[KCDPan sh]
                                                                       action:@selector(pan:)];
    [l addGestureRecognizer:p];
    return l;
}

static void make_hud(void) {
    if (g_hud) return;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat W = sc.size.width, H = sc.size.height;

    g_hud = [[KCDHudWin alloc] initWithFrame:sc];
    g_hud.windowLevel = UIWindowLevelAlert + 500;
    g_hud.backgroundColor = [UIColor clearColor];
    g_hud.rootViewController = [[UIViewController alloc] init];
    g_hud.rootViewController.view.backgroundColor = [UIColor clearColor];
    g_hud.hidden = NO;

    g_l1 = mklab(W * cfg_i(@"nearest_x", 5) / 100.0, H * cfg_i(@"nearest_y", 25) / 100.0, 1);
    g_l1.text = @"最近: --";
    [g_hud.rootViewController.view addSubview:g_l1];

    g_l2 = mklab(W * cfg_i(@"back_x", 5) / 100.0, H * cfg_i(@"back_y", 32) / 100.0, 2);
    [g_hud.rootViewController.view addSubview:g_l2];

    g_l3 = mklab(W * cfg_i(@"count_x", 5) / 100.0, H * cfg_i(@"count_y", 39) / 100.0, 3);
    [g_hud.rootViewController.view addSubview:g_l3];

    [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *tt) {
        (void)tt;
        if (!g_l1) return;
        int teams = __builtin_popcount(g_tmask);
        if (g_near > 1e8f) {
            g_l1.text = @"最近: --";
        } else if (g_near_op[0]) {
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  队%d  朝向 %d  %s",
                         g_near, g_near_team, g_near_yaw, g_near_op];
        } else {
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  队%d  朝向 %d",
                         g_near, g_near_team, g_near_yaw];
        }
        if (cfg_b(@"blink_on", YES) && g_near < 15.0f) {
            float a = 0.35f + 0.65f * fabsf(sinf((float)CACurrentMediaTime() * 8.0f));
            g_l1.textColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:a];
        } else {
            g_l1.textColor = [UIColor whiteColor];
        }
        if (!cfg_b(@"back_on", YES)) {
            g_l2.hidden = YES;
        } else if (g_back > 0) {
            g_l2.hidden = NO;
            g_l2.text = [NSString stringWithFormat:@"背敌: %d (%dm内)",
                         g_back, cfg_i(@"back_dist", 40)];
        } else {
            g_l2.hidden = YES;
        }
        if (!cfg_b(@"count_on", YES)) {
            g_l3.hidden = YES;
        } else {
            g_l3.hidden = NO;
            g_l3.text = [NSString stringWithFormat:@"真人: %d / 总: %d  队伍: %d",
                         g_humans, g_n, teams];
        }
    }];
}

static void panel_refresh(void);
static void panel_hide(void);

static NSArray *rows(void) {
    return @[
        @[@"h", @"绘制"],
        @[@"b", @"box_enemy", @"敌人方框"],
        @[@"b", @"skeleton", @"骨骼线"],
        @[@"b", @"health", @"血条"],
        @[@"b", @"distance", @"距离数字"],
        @[@"b", @"op_name", @"干员名"],
        @[@"h", @"过滤"],
        @[@"b", @"bot_filter", @"只显示真人"],
        @[@"b", @"team_filter", @"过滤队友"],
        @[@"b", @"back_on", @"背敌预警"],
        @[@"h", @"物资"],
        @[@"b", @"loot_on", @"物资透视"],
        @[@"b", @"loot_box", @"  箱子"],
        @[@"b", @"loot_gun", @"  枪械"],
        @[@"b", @"loot_bag", @"  背包"],
        @[@"b", @"loot_ammo", @"  弹药"],
        @[@"b", @"loot_med", @"  药品"],
        @[@"b", @"loot_armor", @"  护甲"],
        @[@"i", @"loot_min", @"最低品质", @[@3, @4, @5]],
        @[@"i", @"loot_dist", @"物资距离", @[@50, @100, @150, @200, @300]],
        @[@"h", @"外观"],
        @[@"i", @"text_size", @"字号", @[@11, @13, @15, @18, @22]],
        @[@"i", @"thick", @"框线粗细", @[@1, @2, @3]],
        @[@"i", @"max_dist", @"最远距离", @[@50, @100, @150, @200, @300, @400, @500]],
        @[@"h", @"其他"],
        @[@"i", @"my_team", @"我的队伍", @[@0, @1, @2, @3, @4, @5, @6, @7, @8]],
        @[@"i", @"teamid_off", @"偏移校准", @[@0, @1, @2, @3, @4, @5, @6]],
        @[@"b", @"blink_on", @"近敌闪烁"],
        @[@"b", @"count_on", @"人数统计"]
    ];
}

static void panel_build(void) {
    if (g_panel) return;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat W = 340;
    CGFloat H = MIN(sc.size.height - 120, 740);
    g_panel = [[UIWindow alloc] initWithFrame:CGRectMake((sc.size.width - W) / 2,
                                                        (sc.size.height - H) / 2, W, H)];
    g_panel.windowLevel = UIWindowLevelAlert + 1000;
    g_panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.93];
    g_panel.layer.cornerRadius = 14;
    g_panel.layer.masksToBounds = YES;
    g_panel.hidden = YES;
    g_panel.rootViewController = [[UIViewController alloc] init];
    g_panel.rootViewController.view.backgroundColor = [UIColor clearColor];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, W - 100, 28)];
    t.text = @"三角洲透视";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont fontWithName:@"PingFangSC-Semibold" size:16];
    [g_panel.rootViewController.view addSubview:t];

    UIButton *cl = [UIButton buttonWithType:UIButtonTypeSystem];
    cl.frame = CGRectMake(W - 76, 8, 64, 30);
    [cl setTitle:@"关闭" forState:UIControlStateNormal];
    [cl setTitleColor:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1]
             forState:UIControlStateNormal];
    [cl addAction:[UIAction actionWithHandler:^(UIAction *a) {
        (void)a;
        panel_hide();
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_panel.rootViewController.view addSubview:cl];

    g_psv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, W, H - 44)];
    [g_panel.rootViewController.view addSubview:g_psv];
}

static void panel_refresh(void) {
    if (!g_panel) return;
    for (UIView *v in g_psv.subviews) [v removeFromSuperview];

    CGFloat y = 8;
    for (NSArray *r in rows()) {
        if ([r[0] isEqualToString:@"h"]) {
            UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 300, 22)];
            h.text = r[1];
            h.textColor = [UIColor colorWithWhite:0.6 alpha:1];
            h.font = [UIFont fontWithName:@"PingFangSC-Regular" size:13];
            [g_psv addSubview:h];
            y += 26;
            continue;
        }
        NSString *key = r[1];
        NSString *nm = r[2];
        NSArray *opts = (r.count > 3) ? r[3] : nil;
        id cur = cfg_get(key);
        NSString *val;
        if (opts) {
            val = cur ? [NSString stringWithFormat:@"%@", cur]
                      : [NSString stringWithFormat:@"%@", opts[0]];
        } else {
            val = (cur && [cur boolValue]) ? @"开" : @"关";
        }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8, y, 324, 38);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        NSMutableString *tt = [NSMutableString stringWithFormat:@"  %@", nm];
        while ([tt length] < 22) [tt appendString:@" "];
        [tt appendString:val];
        [b setTitle:tt forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont fontWithName:@"PingFangSC-Regular" size:15];
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
            (void)a;
            if ([r[0] isEqualToString:@"b"]) {
                cfg_set(key, @(!cfg_b(key, NO)));
            } else if (opts) {
                int cv = cfg_i(key, [opts[0] intValue]);
                NSUInteger i = [opts indexOfObject:@(cv)];
                i = (i == NSNotFound || i + 1 >= opts.count) ? 0 : i + 1;
                cfg_set(key, opts[i]);
            }
            panel_refresh();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_psv addSubview:b];
        y += 42;
    }

    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, 320, 22)];
    st.text = [NSString stringWithFormat:@"内核: %@  名字池: %@  队伍偏移: 0x%X",
               g_kfd_ready ? @"正常" : @"异常",
               g_gnames ? @"正常" : @"未找到",
               g_off_teamid];
    st.textColor = g_kfd_ready ? [UIColor greenColor] : [UIColor redColor];
    st.font = [UIFont fontWithName:@"PingFangSC-Regular" size:12];
    [g_psv addSubview:st];
    y += 34;
    g_psv.contentSize = CGSizeMake(340, y);
}

static void panel_show(void) {
    panel_build();
    panel_refresh();
    g_panel.hidden = NO;
    g_panel_on = YES;
}
static void panel_hide(void) {
    g_panel.hidden = YES;
    g_panel_on = NO;
}
static void panel_toggle(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_panel_on) panel_hide();
        else panel_show();
    });
}

static LootOut g_loot[MAX_LOOT];
static int     g_loot_n = 0;
static UIWindow *g_lwin = nil;

static UIColor *rar_color(int r) {
    if (r >= 6) return [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1];
    if (r >= 5) return [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1];
    if (r >= 4) return [UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1];
    return [UIColor colorWithRed:0.63 green:0.13 blue:0.94 alpha:1];
}

static const char *type_tag(int t) {
    switch (t) {
        case LT_BOX:   return "箱";
        case LT_GUN:   return "枪";
        case LT_BAG:   return "包";
        case LT_AMMO:  return "弹";
        case LT_MED:   return "药";
        case LT_ARMOR: return "甲";
        default:       return "物";
    }
}

static void *loot_loop(void *arg) {
    (void)arg;
    while (1) {
        if (g_ctx.ready && cfg_b(@"loot_on", YES)) {
            g_loot_n = ue4_scan_loot(&g_ctx, g_loot, MAX_LOOT);
        } else {
            g_loot_n = 0;
        }
        usleep(400000);
    }
    return NULL;
}

@interface KCDLootView : UIView @end
@implementation KCDLootView
- (void)drawRect:(CGRect)r {
    (void)r;
    if (!cfg_b(@"loot_on", YES)) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    int minr = cfg_i(@"loot_min", 3);
    int maxd = cfg_i(@"loot_dist", 200);
    int show_box = cfg_b(@"loot_box", YES) ? 1 : 0;
    int show_gun = cfg_b(@"loot_gun", YES) ? 1 : 0;
    int show_bag = cfg_b(@"loot_bag", YES) ? 1 : 0;
    int show_ammo = cfg_b(@"loot_ammo", NO) ? 1 : 0;
    int show_med = cfg_b(@"loot_med", YES) ? 1 : 0;
    int show_armor = cfg_b(@"loot_armor", YES) ? 1 : 0;

    CGFloat fs = (CGFloat)cfg_i(@"text_size", 13) - 3;
    if (fs < 8) fs = 8;
    UIFont *f = [UIFont boldSystemFontOfSize:fs];

    for (int i = 0; i < g_loot_n; i++) {
        LootOut *o = &g_loot[i];
        if (o->rarity < minr) continue;
        if (o->dist > maxd) continue;

        switch (o->type) {
            case LT_BOX:   if (!show_box) continue; break;
            case LT_GUN:   if (!show_gun) continue; break;
            case LT_BAG:   if (!show_bag) continue; break;
            case LT_AMMO:  if (!show_ammo) continue; break;
            case LT_MED:   if (!show_med) continue; break;
            case LT_ARMOR: if (!show_armor) continue; break;
            default: break;
        }

        RVec3 top = o->world;
        top.z += 35.0f;
        Vec2 sp, st;
        if (!ue4_w2s(&g_ctx, o->world, &sp)) continue;
        if (!ue4_w2s(&g_ctx, top, &st)) continue;
        CGFloat h = fabsf(st.y - sp.y);
        if (h < 3.5f) h = 10.0f;
        if (h > 90.0f) h = 90.0f;
        CGFloat w = h;
        CGRect box = CGRectMake(sp.x - w * 0.5f, sp.y - h, w, h);

        UIColor *c = rar_color(o->rarity);
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 1.4f);
        CGContextStrokeRect(ctx, box);
        CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.15f].CGColor);
        CGContextFillRect(ctx, box);

        if (o->type == LT_MED) {
            CGContextSetLineWidth(ctx, 1.6f);
            CGContextMoveToPoint(ctx, box.origin.x + w * 0.5f, box.origin.y + h * 0.2f);
            CGContextAddLineToPoint(ctx, box.origin.x + w * 0.5f, box.origin.y + h * 0.8f);
            CGContextMoveToPoint(ctx, box.origin.x + w * 0.2f, box.origin.y + h * 0.5f);
            CGContextAddLineToPoint(ctx, box.origin.x + w * 0.8f, box.origin.y + h * 0.5f);
            CGContextStrokePath(ctx);
        }

        NSString *t = [NSString stringWithFormat:@"%s %s %.0fm",
                       type_tag(o->type), o->name, o->dist];
        NSDictionary *wa = @{ NSFontAttributeName: f,
                              NSForegroundColorAttributeName: c };
        [t drawAtPoint:CGPointMake(box.origin.x, box.origin.y - fs - 1)
        withAttributes:wa];
    }
}
@end

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef a);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef c, CFDictionaryRef m);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef c,
                                                        void (*cb)(void *, void *, IOHIDEventRef),
                                                        void *t, void *r);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef c,
                                                      CFRunLoopRef rl, CFStringRef mode);
extern int IOHIDEventGetType(IOHIDEventRef e);
extern int64_t IOHIDEventGetIntegerValue(IOHIDEventRef e, int32_t f);

static BOOL g_vu = NO, g_vd = NO;
static int g_vtok = 0;

static void hid_cb(void *t, void *r, IOHIDEventRef e) {
    (void)t; (void)r;
    if (IOHIDEventGetType(e) != 3) return;
    int64_t u  = IOHIDEventGetIntegerValue(e, 0x00030000);
    int64_t pr = IOHIDEventGetIntegerValue(e, 0x00030002);
    if (u != 0xE9 && u != 0xEA) return;
    if (pr != 0) {
        if (u == 0xE9) g_vu = YES; else g_vd = YES;
        if (g_vu && g_vd) {
            g_vtok++;
            int my = g_vtok;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (my == g_vtok && g_vu && g_vd) {
                    g_vu = NO;
                    g_vd = NO;
                    panel_toggle();
                }
            });
        }
    } else {
        if (u == 0xE9) g_vu = NO; else g_vd = NO;
        g_vtok++;
    }
}

__attribute__((constructor)) static void kcd_boot(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        make_esp();
        make_hud();

        CGRect sc = [UIScreen mainScreen].bounds;
        g_lwin = [[UIWindow alloc] initWithFrame:sc];
        g_lwin.windowLevel = UIWindowLevelAlert + 450;
        g_lwin.backgroundColor = [UIColor clearColor];
        g_lwin.userInteractionEnabled = NO;
        if ([g_lwin respondsToSelector:@selector(_setSecure:)]) [g_lwin _setSecure:YES];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        vc.view.userInteractionEnabled = NO;
        KCDLootView *lv = [[KCDLootView alloc] initWithFrame:sc];
        lv.backgroundColor = [UIColor clearColor];
        lv.userInteractionEnabled = NO;
        [vc.view addSubview:lv];
        g_lwin.rootViewController = vc;
        g_lwin.hidden = NO;
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *tt) {
            (void)tt;
            [lv setNeedsDisplay];
        }];

        dispatch_async(dispatch_get_global_queue(0, 0), ^{ scan_loop(NULL); });
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ loot_loop(NULL); });

        IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (c) {
            IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{});
            IOHIDEventSystemClientRegisterEventCallback(c, hid_cb, NULL, NULL);
            IOHIDEventSystemClientScheduleWithRunLoop(c, CFRunLoopGetMain(),
                                                      kCFRunLoopDefaultMode);
        }
    });
}
OX2_EOF

cat > src/ent.plist <<'PL1_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.security.no-container</key><true/>
    <key>com.apple.private.skip-library-validation</key><true/>
    <key>com.apple.private.hid.client.event-monitor</key><true/>
    <key>get-task-allow</key><true/>
</dict>
</plist>
PL1_EOF

cat > src/package/DEBIAN/control <<'PL2_EOF'
Package: com.kcd.deltaforce
Name: KCD
Version: 1.0
Architecture: iphoneos-arm64
Description: readonly esp
Maintainer: kcd
Author: kcd
Section: Tweaks
Depends: mobilesubstrate
PL2_EOF

printf '#!/bin/bash\nkillall -9 SpringBoard 2>/dev/null || true\nexit 0\n' > src/package/DEBIAN/postinst
printf '#!/bin/bash\nkillall -9 SpringBoard 2>/dev/null || true\nexit 0\n' > src/package/DEBIAN/prerm
chmod 755 src/package/DEBIAN/postinst src/package/DEBIAN/prerm

cd src

echo "===== COMPILE ====="
SDK="$THEOS/sdks/iPhoneOS16.5.sdk"
TG=arm64e-apple-ios15.0
LDP=$(cat "$TC/ld64_path.txt" 2>/dev/null || echo "/usr/local/bin/ld64.lld")
CF="-target $TG -isysroot $SDK -fobjc-arc -w -O1 -Ikcore -Igame -Ikcore/kfd -Ikcore/kfd/libkfd -Ikcore/kfd/libkfd/libkfd"

rm -rf obj release
mkdir -p obj release

for f in kcore/krw.c game/ue4.c; do
  echo "  $f"
  clang $CF -c "$f" -o "obj/$(basename "$f" .c).o"
done

echo "  tweak/Overlay.xm"
clang $CF -x objective-c -c tweak/Overlay.xm -o obj/Overlay.o

echo "===== LINK ====="
clang -target $TG -isysroot $SDK -dynamiclib \
  -fuse-ld=$LDP -Wl,-platform_version,ios,15.0,15.0 \
  -o release/libsystem_coreservices.dylib obj/*.o \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework QuartzCore -framework IOKit

ldid -S ent.plist release/libsystem_coreservices.dylib

echo "===== PACKAGE ====="
rm -rf pkg
mkdir -p pkg/var/jb/Library/MobileSubstrate/DynamicLibraries
cp release/libsystem_coreservices.dylib pkg/var/jb/Library/MobileSubstrate/DynamicLibraries/
printf '{ Filter = { Executables = ( SpringBoard ); }; }\n' \
  > pkg/var/jb/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.plist
cp -r package/DEBIAN pkg/DEBIAN
dpkg-deb -b pkg "$ROOT/dist/com.kcd.deltaforce_1.0_iphoneos-arm64.deb"

ls -lh "$ROOT/dist/"
echo "===== DONE ====="
