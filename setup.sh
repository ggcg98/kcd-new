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
  cd /tmp/sdks
  git sparse-checkout set iPhoneOS16.5.sdk
  mv iPhoneOS16.5.sdk "$TC/theos/sdks/"
  rm -rf /tmp/ldid
  git clone --depth 1 https://github.com/ProcursusTeam/ldid.git /tmp/ldid
  cd /tmp/ldid
  git submodule update --init
  make -j4 || true
  if [ -f ldid ]; then cp ldid "$TC/ldid"; fi
  cd "$ROOT"
fi

sudo ldconfig
if [ -x /usr/bin/ldid ]; then
  sudo ln -sf /usr/bin/ldid /usr/local/bin/ldid
elif [ -f "$TC/ldid" ]; then
  sudo ln -sf "$TC/ldid" /usr/local/bin/ldid
else
  echo "NO LDID"; exit 1
fi
if [ -f "$TC/ld64_path.txt" ]; then
  sudo ln -sf "$(cat "$TC/ld64_path.txt")" /usr/local/bin/ld64.lld
fi

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
rm -f src/kcore/kfd/kfd_krw.m
rm -f src/kcore/kfd/kfd_krw.h

cat > src/kcore/krw.h <<'EOF'
#pragma once
#include <stdint.h>
#include <stddef.h>

extern uint64_t g_kbase, g_kslide, g_kernel_pmap, g_physmap_base, g_gnames;
extern int g_kfd_ready;
extern int g_off_teamid;

typedef struct { float x, y, z; } RVec3;

int row_up(void);
int row_alive(void);
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
EOF

cat > src/kcore/krw.c <<'KRWEOF'
#include "krw.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define OFF_PMAP_TTEP    0x08
#define OFF_TASK_MAP     0x28
#define OFF_VMMAP_PMAP   0x40
#define OFF_PROC_PID     0x60
#define OFF_PROC_TASK    0x10
#define OFF_PROC_NEXT    0x08
#define OFF_PAWN_PS      0x2B0
#define OFF_PAWN_CTRL    0x2A8
#define OFF_CTRL_ROT     0x2E4
#define OFF_OBJ_CLASS    0x10
#define OFF_OBJ_NAME     0x18
#define OFF_USTRUCT_CHL  0x48
#define OFF_UPROP_OFF    0x4C
#define OFF_UFIELD_NEXT  0x28

#if __has_include(<libkfd.h>)
#include <libkfd.h>
#define HAVE_KFD 1
#else
#define HAVE_KFD 0
#endif

uint64_t g_kbase = 0, g_kslide = 0, g_kernel_pmap = 0, g_physmap_base = 0, g_gnames = 0;
int g_kfd_ready = 0;
int g_off_teamid = 0x2C0;
uint64_t g_ps_sample[32];
int g_ps_n = 0;
static uint64_t g_h = 0;

extern int proc_listpids(unsigned int, unsigned int, void *, int);
extern int proc_pidpath(int, void *, unsigned int);

#if HAVE_KFD
static int try_open(uint64_t puaf) {
    uint64_t k = kopen(0x4000, puaf, 2, 2);
    if (k) { g_h = k; return 1; }
    return 0;
}
int row_up(void) {
    if (!try_open(0) && !try_open(1) && !try_open(2)) return -1;
    struct kfd *kd = (struct kfd *)g_h;
    g_kslide = kd->info.kernel.kernel_slide;
    g_kbase = 0xFFFFFFF007004000ULL + g_kslide;
    g_kernel_pmap = kd->info.kernel.kernel_pmap;
    g_kfd_ready = 1;
    return 0;
}
uint64_t r64(uint64_t a) { uint64_t v = 0; kread_(g_h, a, &v, 8); return v; }
uint32_t r32(uint64_t a) { uint32_t v = 0; kread_(g_h, a, &v, 4); return v; }
float rf32(uint64_t a) { float v = 0; kread_(g_h, a, &v, 4); return v; }
int kread_buf(uint64_t a, void *b, size_t n) { kread_(g_h, a, b, n); return 0; }
#else
int row_up(void) { return -1; }
uint64_t r64(uint64_t a) { (void)a; return 0; }
uint32_t r32(uint64_t a) { (void)a; return 0; }
float rf32(uint64_t a) { (void)a; return 0; }
int kread_buf(uint64_t a, void *b, size_t n) { (void)a; (void)b; (void)n; return -1; }
#endif

uint64_t kread_ptr(uint64_t a) {
    uint64_t v = 0;
    kread_buf(a, &v, 8);
    return v & 0x0000FFFFFFFFFFFFULL;
}

int row_alive(void) {
    if (!g_kfd_ready) return -1;
    uint32_t m = 0;
    kread_buf(g_kbase, &m, 4);
    return m == 0xFEEDFACF ? 0 : -1;
}

static int kptr(uint64_t p) { return p > 0x100000000ULL && p < 0x3000000000ULL; }

static uint64_t g_allproc_head = 0;

static uint64_t find_allproc(void) {
    for (uint64_t a = g_kbase + 0x2000000ULL; a < g_kbase + 0x6000000ULL; a += 8) {
        uint64_t n = r64(a);
        if (!kptr(n)) continue;
        uint64_t n2 = r64(n);
        if (!kptr(n2)) continue;
        uint64_t t = kread_ptr(n + OFF_PROC_TASK);
        if (!kptr(t)) continue;
        uint64_t map = kread_ptr(t + OFF_TASK_MAP);
        if (!kptr(map)) continue;
        int pid = (int)r32(n + OFF_PROC_PID);
        if (pid > 0 && pid < 100000) return a;
    }
    return 0;
}

uint64_t row_task_of_pid(int want) {
    if (!g_allproc_head) g_allproc_head = find_allproc();
    if (!g_allproc_head) return 0;
    uint64_t p = r64(g_allproc_head);
    int guard = 0;
    while (kptr(p) && guard++ < 2000) {
        if ((int)r32(p + OFF_PROC_PID) == want) return kread_ptr(p + OFF_PROC_TASK);
        uint64_t nx = r64(p + OFF_PROC_NEXT);
        if (nx == g_allproc_head || nx == p) break;
        p = nx;
    }
    return 0;
}

int row_pid_by_name(const char *key) {
    int cap = 4096;
    pid_t *list = (pid_t *)malloc(sizeof(pid_t) * cap);
    if (!list) return -1;
    int n = proc_listpids(1, 0, list, sizeof(pid_t) * cap) / sizeof(pid_t);
    int found = -1;
    char path[1024];
    for (int i = 0; i < n; i++) {
        if (list[i] <= 0) continue;
        memset(path, 0, sizeof(path));
        proc_pidpath(list[i], path, sizeof(path) - 1);
        if (strstr(path, key)) { found = list[i]; break; }
    }
    free(list);
    return found;
}

uint64_t row_base_of_task(uint64_t task) {
    if (!task) return 0;
    for (uint64_t va = 0x100000000ULL; va < 0x200000000ULL; va += 0x1000000ULL) {
        uint32_t m = 0;
        if (row_read_task(task, va, &m, 4) != 0) continue;
        if (m == 0xFEEDFACF) return va;
    }
    return 0;
}

uint64_t row_vtop(uint64_t task, uint64_t va) {
    if (!task) return 0;
    uint64_t map = kread_ptr(task + OFF_TASK_MAP);
    if (!kptr(map)) return 0;
    uint64_t pmap = kread_ptr(map + OFF_VMMAP_PMAP);
    if (!kptr(pmap)) return 0;
    uint64_t ttep = r64(pmap + OFF_PMAP_TTEP);
    if (!ttep) return 0;
    uint64_t t1 = ttep & 0x0000FFFFFFFFC000ULL;
    uint64_t e1 = r64(t1 + (((va >> 36) & 0x7FF) * 8));
    if ((e1 & 3) != 3) return 0;
    uint64_t t2 = e1 & 0x0000FFFFFFFFC000ULL;
    uint64_t e2 = r64(t2 + (((va >> 25) & 0x7FF) * 8));
    if ((e2 & 3) != 3) return 0;
    uint64_t t3 = e2 & 0x0000FFFFFFFFC000ULL;
    uint64_t e3 = r64(t3 + (((va >> 14) & 0x7FF) * 8));
    if ((e3 & 3) != 3) return 0;
    return (e3 & 0x0000FFFFFFFFC000ULL) + (va & 0x3FFF);
}

int row_read_task(uint64_t task, uint64_t va, void *buf, size_t n) {
    if (!g_physmap_base) return -1;
    uint8_t *p = (uint8_t *)buf;
    while (n > 0) {
        uint64_t pa = row_vtop(task, va);
        if (!pa) return -1;
        size_t chunk = 0x4000 - (size_t)(va & 0x3FFF);
        if (chunk > n) chunk = n;
        kread_buf(g_physmap_base + pa, p, chunk);
        va += chunk; p += chunk; n -= chunk;
    }
    return 0;
}

int kcd_fname(uint64_t pool, int32_t idx, char *out, int max) {
    if (!pool || max < 4) return 0;
    int blk = idx >> 16, off = idx & 0xFFFF;
    uint64_t blocks = r64(pool + 0x10);
    if (!kptr(blocks)) return 0;
    uint64_t b = r64(blocks + (uint64_t)blk * 8);
    if (!kptr(b)) return 0;
    uint64_t e = b + (uint64_t)off * 2;
    uint16_t h = (uint16_t)(r32(e) & 0xFFFF);
    int len = (h >> 6) & 0x3FF;
    if (len <= 0 || len >= max) return 0;
    if (h & 1) {
        for (int i = 0; i < len; i++) out[i] = (char)(r32(e + 2 + i * 2) & 0xFF);
    } else {
        for (int i = 0; i < len; i++) out[i] = (char)(r32(e + 2 + i) & 0xFF);
    }
    out[len] = 0;
    return len;
}

int kcd_fname_str(uint64_t objaddr, char *out, int max) {
    if (!objaddr || !g_gnames) return 0;
    return kcd_fname(g_gnames, (int32_t)r32(objaddr + OFF_OBJ_NAME), out, max);
}

int kcd_class_name(uint64_t obj, char *out, int max) {
    if (!obj || !g_gnames) return 0;
    uint64_t cls = kread_ptr(obj + OFF_OBJ_CLASS);
    if (!kptr(cls)) return 0;
    return kcd_fname(g_gnames, (int32_t)r32(cls + OFF_OBJ_NAME), out, max);
}

int kcd_gnames_scan(void) {
    if (g_gnames) return 0;
    char tmp[64];
    for (uint64_t a = g_kbase + 0x4000000ULL; a < g_kbase + 0x10000000ULL; a += 8) {
        uint64_t blocks = r64(a + 0x10);
        if (!kptr(blocks)) continue;
        uint64_t b0 = r64(blocks);
        if (!kptr(b0)) continue;
        uint16_t h = (uint16_t)(r32(b0) & 0xFFFF);
        int len = (h >> 6) & 0x3FF;
        if (len < 2 || len > 16) continue;
        if (kcd_fname(a, 0, tmp, 60) > 0 && strcmp(tmp, "None") == 0) {
            g_gnames = a;
            return 0;
        }
    }
    return -1;
}

int kcd_is_bot(uint64_t pawn) {
    if (!pawn) return 1;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PS);
    if (!ps) return 1;
    uint64_t ctrl = kread_ptr(pawn + OFF_PAWN_CTRL);
    if (!ctrl) return 1;
    char buf[64] = {0};
    if (kcd_class_name(ctrl, buf, 60) > 0) {
        if (strstr(buf, "AIController")) return 1;
        if (strstr(buf, "AI_")) return 1;
    }
    if (kcd_class_name(pawn, buf, 60) > 0) {
        if (strstr(buf, "_AI_")) return 1;
        if (strstr(buf, "Bot")) return 1;
    }
    return 0;
}

int kcd_team_of(uint64_t pawn) {
    if (!pawn) return -1;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PS);
    if (!ps) return -1;
    if (g_ps_n < 32) {
        int d = 0;
        for (int i = 0; i < g_ps_n; i++) if (g_ps_sample[i] == ps) { d = 1; break; }
        if (!d) g_ps_sample[g_ps_n++] = ps;
    }
    int t = (int)r32(ps + g_off_teamid);
    if (t < 0 || t > 64) return -1;
    return t;
}

int kcd_yaw_of(uint64_t pawn) {
    if (!pawn) return -1;
    uint64_t ctrl = kread_ptr(pawn + OFF_PAWN_CTRL);
    if (!ctrl) return -1;
    float y = rf32(ctrl + OFF_CTRL_ROT);
    if (y > 360.0f || y < -360.0f) return -1;
    int d = (int)y;
    if (d < 0) d += 360;
    return d;
}

float kcd_health_of(uint64_t pawn) {
    if (!pawn) return -1.0f;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PS);
    uint64_t cand[6];
    cand[0] = pawn + 0x3A0;
    cand[1] = pawn + 0x2F0;
    cand[2] = ps + 0x2F0;
    cand[3] = ps + 0x3A0;
    cand[4] = pawn + 0x4A0;
    cand[5] = ps + 0x4A0;
    for (int i = 0; i < 6; i++) {
        if (!kptr(cand[i])) continue;
        float v = rf32(cand[i]);
        if (v > 0.0f && v <= 1000.0f) return v;
    }
    return -1.0f;
}

int kcd_calib_teamid(void) {
    if (g_ps_n < 3) return -1;
    int best = -1, bs = -99999;
    for (int off = 0x280; off <= 0x340; off += 4) {
        int vals[32], n = 0, ok = 1, maxv = 0, zeros = 0;
        for (int i = 0; i < g_ps_n; i++) {
            int v = (int)r32(g_ps_sample[i] + off);
            if (v < 0 || v > 64) { ok = 0; break; }
            vals[n++] = v;
            if (v > maxv) maxv = v;
            if (v == 0) zeros++;
        }
        if (!ok) continue;
        int dis = 0;
        for (int i = 0; i < n; i++) {
            int d = 0;
            for (int j = 0; j < i; j++) if (vals[j] == vals[i]) { d = 1; break; }
            if (!d) dis++;
        }
        int sc = 0;
        if (dis >= 2 && dis <= 12) sc += 120;
        if (dis <= 1) sc -= 250;
        if (zeros == n) sc -= 400;
        if (zeros > n / 2) sc -= 60;
        if (maxv <= 20) sc += 25;
        if (sc > bs) { bs = sc; best = off; }
    }
    return best;
}

int kcd_reflect_teamid(void) {
    if (!g_gnames || g_ps_n < 1) return -1;
    uint64_t cls = kread_ptr(g_ps_sample[0] + OFF_OBJ_CLASS);
    if (!kptr(cls)) return -1;
    uint64_t p = kread_ptr(cls + OFF_USTRUCT_CHL);
    int guard = 0;
    while (kptr(p) && guard++ < 300) {
        char nm[80] = {0};
        kcd_fname_str(p, nm, 72);
        if (strstr(nm, "Team")) {
            int o = (int)r32(p + OFF_UPROP_OFF);
            if (o > 0 && o < 0x800) return o;
        }
        p = kread_ptr(p + OFF_UFIELD_NEXT);
    }
    return -1;
}
KRWEOF
echo "part1 done"
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

cat > src/kcore/krw.h <<'EOF'
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
EOF

cat > src/kcore/krw.c <<'KRWEOF'
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
KRWEOF
echo "part1 done"
cat > src/game/ue4.h <<'EOF'
#pragma once
#include <stdint.h>
#include "krw.h"
typedef struct { float x, y; } Vec2;
#define BONE_N 15
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
typedef struct {
    uint64_t task, base, gworld, self_pawn;
    RVec3    pov_loc;
    float    pov_pitch, pov_yaw, fov;
    int      sw, sh, ready;
} Ue4Ctx;
#define MAX_ENT 64
int ue4_setup(Ue4Ctx *c);
int ue4_scan(Ue4Ctx *c, EntOut *out, int max);
int ue4_w2s(Ue4Ctx *c, RVec3 w, Vec2 *s);
EOF

cat > src/game/ue4.c <<'UEOF'
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
UEOF
echo "part2 ue4 done"
