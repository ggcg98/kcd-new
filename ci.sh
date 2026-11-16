#!/bin/bash
set -o pipefail
cd "$GITHUB_WORKSPACE"
TC="$GITHUB_WORKSPACE/.tc"
mkdir -p "$TC"

echo "===== INSTALL ====="
if [ ! -x "$TC/ldid" ]; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld llvm make g++ pkg-config git perl dpkg curl xz-utils unzip libssl-dev binutils libplist-dev
  LDP=""
  for v in 14 15 16 13 12 11; do
    if [ -x "/usr/lib/llvm-$v/bin/ld64.lld" ]; then LDP="/usr/lib/llvm-$v/bin/ld64.lld"; break; fi
  done
  [ -z "$LDP" ] && [ -x /usr/bin/ld64.lld ] && LDP=/usr/bin/ld64.lld
  sudo ln -sf "$LDP" /usr/local/bin/ld64.lld
  mkdir -p "$TC/theos/bin/lib/Logos" "$TC/theos/sdks"
  echo "$LDP" > "$TC/ld64_path.txt"
  printf '#!/bin/sh\ncat "$1"\n' > "$TC/theos/bin/logos.pl"
  chmod +x "$TC/theos/bin/logos.pl"
  printf 'package Logos::Util;\n1;\n' > "$TC/theos/bin/lib/Logos/Util.pm"
  rm -rf /tmp/sdks
  git clone --filter=blob:none --sparse https://github.com/theos/sdks.git /tmp/sdks
  cd /tmp/sdks
  git sparse-checkout set iPhoneOS16.5.sdk
  mv iPhoneOS16.5.sdk "$TC/theos/sdks/"
  rm -rf /tmp/ldid
  git clone --depth 1 https://github.com/ProcursusTeam/ldid.git /tmp/ldid
  cd /tmp/ldid
  git submodule update --init
  make -j4
  cp ldid "$TC/ldid"
  cd "$GITHUB_WORKSPACE"
fi

sudo mkdir -p /usr/local/bin
if [ -f "$TC/ld64_path.txt" ]; then sudo ln -sf "$(cat "$TC/ld64_path.txt")" /usr/local/bin/ld64.lld; fi
sudo ln -sf "$TC/ldid" /usr/local/bin/ldid

echo "===== CLONE KFD ====="
rm -rf /tmp/t
git clone --depth 1 https://github.com/Odyssey-Team/Taurine.git /tmp/t

echo "===== GENERATE ====="
bash setup.sh
find src -type f | wc -l

echo "===== ATTACH ====="
KFD=/tmp/t/Taurine/exploit/kfd
rm -rf src/kcore/kfd
mkdir -p src/kcore/kfd
cp -r "$KFD"/. src/kcore/kfd/
rm -f src/kcore/kfd/kfd_krw.m src/kcore/kfd/kfd_krw.h

cd src

echo "===== KRW.H ====="
python3 - <<'PY'
p = 'kcore/krw.h'
s = open(p).read()
add = '''extern int g_kfd_ready;
extern uint64_t g_physmap_base;
extern uint64_t g_kernel_pmap;
extern uint64_t g_gnames;
extern int g_off_teamid;
extern int g_ps_n;
int kcd_gnames_scan(void);
int kcd_fname(uint64_t pool, int32_t idx, char *out, int max);
int kcd_is_bot(uint64_t pawn);
int kcd_team_of(uint64_t pawn);
int kcd_yaw_of(uint64_t pawn);
int kcd_calib_teamid(void);
int kcd_reflect_teamid(void);
uint64_t kdetect_physmap(void);
'''
if 'g_physmap_base' not in s:
    s = s.replace('extern int g_kfd_ready;', add.rstrip())
open(p, 'w').write(s)
print('krw.h ok')
PY

echo "===== KRW.C ====="
cat > kcore/krw.c <<'KRWEOF'
#include "krw.h"
#include "koffsets.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifndef OFF_PMAP_TTEP
#define OFF_PMAP_TTEP 0x08
#endif
#ifndef OFF_PAWN_CONTROLLER
#define OFF_PAWN_CONTROLLER 0x2A8
#define OFF_PAWN_PLAYERSTATE 0x2B0
#define OFF_CTRL_ROTATION 0x2E4
#define OFF_USTRUCT_CHILDREN 0x48
#define OFF_UPROP_OFFSET 0x4C
#define OFF_UFIELD_NEXT 0x28
#endif
#ifndef KFD_PUAF_LANDA
#define KFD_PUAF_LANDA 0
#define KFD_PUAF_PHYSPUPPET 1
#define KFD_PUAF_SMITH 2
#define KFD_KREAD_SEM 2
#define KFD_KWRITE_SEM 2
#endif

#if __has_include(<libkfd.h>)
#include <libkfd.h>
#define HAVE_KFD 1
#else
#define HAVE_KFD 0
#endif

uint64_t g_kbase = 0;
uint64_t g_kslide = 0;
uint64_t g_kernel_pmap = 0;
uint64_t g_physmap_base = 0;
uint64_t g_gnames = 0;
int g_kfd_ready = 0;
int g_off_teamid = 0x2C0;
uint64_t g_ps_sample[32];
int g_ps_n = 0;
static uint64_t g_h = 0;

#if HAVE_KFD
static int try_open(uint64_t puaf, uint64_t kr, uint64_t kw) {
    uint64_t k = kopen(0x4000, puaf, kr, kw);
    if (k) { g_h = k; return 1; }
    return 0;
}
static int kfd_up(void) {
    if (!try_open(KFD_PUAF_LANDA, KFD_KREAD_SEM, KFD_KWRITE_SEM) &&
        !try_open(KFD_PUAF_PHYSPUPPET, KFD_KREAD_SEM, KFD_KWRITE_SEM) &&
        !try_open(KFD_PUAF_SMITH, KFD_KREAD_SEM, KFD_KWRITE_SEM)) return -1;
    struct kfd *kd = (struct kfd *)g_h;
    g_kslide = kd->info.kernel.kernel_slide;
    g_kbase = 0xFFFFFFF007004000ULL + g_kslide;
    g_kernel_pmap = kd->info.kernel.kernel_pmap;
    g_kfd_ready = 1;
    return 0;
}
static int be_read(uint64_t a, void *b, size_t n) { kread_(g_h, a, b, n); return 0; }
static int be_write(uint64_t a, const void *b, size_t n) { kwrite_(g_h, (void *)b, a, n); return 0; }
static int be_pread(uint64_t pa, void *b, size_t n) {
    if (!g_physmap_base) return -1;
    kread_(g_h, g_physmap_base + pa, b, n);
    return 0;
}
static int be_pwrite(uint64_t pa, const void *b, size_t n) { (void)pa; (void)b; (void)n; return -1; }
#else
static int kfd_up(void) { return -1; }
static int be_read(uint64_t a, void *b, size_t n) { (void)a; (void)b; (void)n; return -1; }
static int be_write(uint64_t a, const void *b, size_t n) { (void)a; (void)b; (void)n; return -1; }
static int be_pread(uint64_t a, void *b, size_t n) { (void)a; (void)b; (void)n; return -1; }
static int be_pwrite(uint64_t a, const void *b, size_t n) { (void)a; (void)b; (void)n; return -1; }
#endif

krw_backend_t be_kfd = { "kfd", kfd_up, be_read, be_write, be_pread, be_pwrite };

int rw_up(void) { return be_kfd.init() == 0 ? 0 : -1; }

int rw_alive(void) {
    if (!g_kfd_ready) return -1;
    uint32_t m = 0;
    if (be_read(g_kbase, &m, 4) != 0) return -1;
    return m == 0xFEEDFACF ? 0 : -1;
}

uint64_t kdetect_physmap(void) {
    if (!g_kernel_pmap) return 0;
    uint64_t t = 0;
    be_read(g_kernel_pmap + OFF_PMAP_TTEP, &t, 8);
    t &= 0x0000FFFFFFFFF000ULL;
    if (!t) return 0;
    for (int i = 0; i < 512; i++) {
        uint64_t e = 0;
        be_read(t + (uint64_t)i * 8, &e, 8);
        if ((e & 3) != 3) continue;
        if ((e & 0x0000FFFFFFE00000ULL) == 0)
            return 0xfffffff000000000ULL + ((uint64_t)i << 30);
    }
    return 0;
}

static int kptr(uint64_t p) { return p > 0x100000000ULL && p < 0x3000000000ULL; }

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
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PLAYERSTATE);
    if (!ps) return 1;
    uint64_t ctrl = kread_ptr(pawn + OFF_PAWN_CONTROLLER);
    if (!ctrl) return 1;
    if (g_gnames) {
        uint64_t cls = kread_ptr(ctrl + 0x10);
        if (cls) {
            char buf[64] = {0};
            kcd_fname(g_gnames, (int32_t)r32(cls + 0x18), buf, 60);
            if (strstr(buf, "AIController")) return 1;
            if (strstr(buf, "BP_AI") || strstr(buf, "AI_Guard")) return 1;
        }
    }
    return 0;
}

int kcd_team_of(uint64_t pawn) {
    if (!pawn) return -1;
    uint64_t ps = kread_ptr(pawn + OFF_PAWN_PLAYERSTATE);
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
    uint64_t ctrl = kread_ptr(pawn + OFF_PAWN_CONTROLLER);
    if (!ctrl) return -1;
    float y = rf32(ctrl + OFF_CTRL_ROTATION);
    if (y > 360.0f || y < -360.0f) return -1;
    int d = (int)y;
    if (d < 0) d += 360;
    return d;
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
        if (maxv <= 8) sc += 10;
        if (sc > bs) { bs = sc; best = off; }
    }
    return best;
}

int kcd_reflect_teamid(void) {
    if (!g_gnames || g_ps_n < 1) return -1;
    uint64_t cls = kread_ptr(g_ps_sample[0] + 0x10);
    if (!cls) return -1;
    uint64_t p = kread_ptr(cls + OFF_USTRUCT_CHILDREN);
    int guard = 0;
    while (p && guard++ < 300) {
        char nm[80] = {0};
        kcd_fname(g_gnames, (int32_t)r32(p + 0x18), nm, 72);
        if (strstr(nm, "Team")) {
            int o = (int)r32(p + OFF_UPROP_OFFSET);
            if (o > 0 && o < 0x800) return o;
        }
        p = kread_ptr(p + OFF_UFIELD_NEXT);
    }
    return -1;
}

int kread_buf(uint64_t a, void *b, size_t n) { return be_kfd.kread(a, b, n); }
int kwrite_buf(uint64_t a, const void *b, size_t n) { return be_kfd.kwrite(a, b, n); }
uint64_t r64(uint64_t a) { uint64_t v = 0; be_kfd.kread(a, &v, 8); return v; }
uint32_t r32(uint64_t a) { uint32_t v = 0; be_kfd.kread(a, &v, 4); return v; }
float rf32(uint64_t a) { float v = 0; be_kfd.kread(a, &v, 4); return v; }
void w64(uint64_t a, uint64_t v) { be_kfd.kwrite(a, &v, 8); }
void w32(uint64_t a, uint32_t v) { be_kfd.kwrite(a, &v, 4); }
uint64_t kread_ptr(uint64_t a) { uint64_t v = 0; be_kfd.kread(a, &v, 8); return PAC_STRIP(v); }
KRWEOF
echo "krw.c written"
echo "===== PATCH OVERLAY ====="
python3 - <<'PY'
import re
p = 'tweak/Overlay.xm'
s = open(p).read()
s = s.replace('if (rw_up() != 0) return NULL;',
              'if (rw_up() != 0) return NULL;\n    g_physmap_base = kdetect_physmap();')
if 'g_kcd_tsize' not in s:
    s = ('extern CGFloat g_kcd_tsize;\n'
         'extern UIColor *g_kcd_tcolor;\n'
         'extern int g_kcd_botfilter;\n'
         'extern float g_kcd_near;\n'
         'extern uint64_t g_kcd_near_pawn;\n'
         'extern uint64_t g_kcd_last_pawn;\n'
         'extern int g_kcd_cur_team;\n'
         'extern int g_kcd_back;\n'
         'extern int g_kcd_count;\n'
         'extern int g_kcd_human;\n'
         'extern int g_kcd_teams;\n'
         'extern uint32_t g_kcd_tmask;\n'
         'extern UIColor *kcd_team_color(int t);\n') + s
s = re.sub(r'systemFontOfSize:[0-9][0-9.]*', 'systemFontOfSize:g_kcd_tsize', s)
s = re.sub(r'boldSystemFontOfSize:[0-9][0-9.]*', 'boldSystemFontOfSize:g_kcd_tsize', s)
s = re.sub(r'\[UIColor redColor\](?!\.CGColor)', 'g_kcd_tcolor', s)
open(p, 'w').write(s)
print('overlay ok')
PY

echo "===== FIX EXT ====="
[ -f kcore/koffsets.c ] && mv kcore/koffsets.c kcore/koffsets.m
[ -f game/ue4_offsets.c ] && mv game/ue4_offsets.c game/ue4_offsets.m
sed -i 's|kcore/koffsets\.c|kcore/koffsets.m|g' build.sh
sed -i 's|game/ue4_offsets\.c|game/ue4_offsets.m|g' build.sh
sed -i 's|kcore/kfd/libkfd/\*\.c|kcore/kfd/*.c|g' build.sh
sed -i 's|kcore/kfd/libkfd/\*\.m|kcore/kfd/*.m|g' build.sh

echo "===== KILL AVAILABLE ====="
python3 - <<'PY'
import re, os
for r, _, fs in os.walk('kcore/kfd'):
    for f in fs:
        if f.endswith(('.h', '.c', '.m')):
            p = os.path.join(r, f)
            s = open(p, errors='ignore').read()
            s = re.sub(r'@available\(iOS 16(\.0)?, \*\)', '1', s)
            s = re.sub(r'@available\([^)]*\)', '0', s)
            open(p, 'w').write(s)
print('available killed')
PY

echo "===== BOT FILTER ====="
python3 - <<'PY'
import re
p = 'tweak/Overlay.xm'
s = open(p).read()
pat = r'for\s*\(\s*int\s+i\s*=\s*0\s*;\s*i\s*<\s*\w+\s*;\s*i\+\+\s*\)\s*\{\s*\n\s*[^\n]{0,90}?\b(\w+)\s*=[^=]'
m = re.search(pat, s)
if m:
    var = m.group(1)
    ins = ('\n        g_kcd_last_pawn = (uint64_t)%s;\n'
           '        g_kcd_cur_team = kcd_team_of(g_kcd_last_pawn);\n'
           '        if (g_kcd_botfilter && kcd_is_bot(g_kcd_last_pawn)) continue;') % var
    s = s[:m.end()] + ins + s[m.end():]
    print('inject_ok var=' + var)
else:
    print('inject_FAIL')
open(p, 'w').write(s)
PY

echo "===== INJECT SCAN ====="
python3 - <<'PY'
import re
p = 'tweak/Overlay.xm'
s = open(p).read()
s = re.sub(r'(void\s*\*\s*scan_loop\s*\([^)]*\)\s*\{)',
           r'\1\n    g_kcd_near = 1e9f; g_kcd_back = 0; g_kcd_count = 0; g_kcd_human = 0; g_kcd_near_pawn = 0; g_kcd_last_pawn = 0; g_kcd_tmask = 0;',
           s, count=1)
s = re.sub(r'(\n\s*(?:float|double)\s+dist\s*=\s*[^;]+;)',
           r'\1\n        g_kcd_count++;\n        g_kcd_human++;\n        if (dist < 40.0f) g_kcd_back++;\n        if (g_kcd_cur_team >= 0 && g_kcd_cur_team < 32) g_kcd_tmask |= (1u << g_kcd_cur_team);\n        if (dist < g_kcd_near) { g_kcd_near = dist; g_kcd_near_pawn = g_kcd_last_pawn; }',
           s)
open(p, 'w').write(s)
print('scan ok')
PY

echo "===== TEAM COLOR ====="
python3 - <<'PY'
s = open('tweak/Overlay.xm').read()
n = s.replace('[UIColor redColor].CGColor', 'kcd_team_color(g_kcd_cur_team).CGColor')
print('color_path OK' if n != s else 'color_path MISS')
open('tweak/Overlay.xm', 'w').write(n)
PY

echo "===== TEAM NUM ====="
python3 - <<'PY'
import re
p = 'tweak/Overlay.xm'
s = open(p).read()
hit = 0
pairs = [
    (r'stringWithFormat:@"%\.0fm"', 'stringWithFormat:@"%.0fm T%d", g_kcd_cur_team'),
    (r'stringWithFormat:@"%\.0f m"', 'stringWithFormat:@"%.0f m T%d", dist, g_kcd_cur_team'),
    (r'stringWithFormat:@"%d m"', 'stringWithFormat:@"%d m T%d", (int)dist, g_kcd_cur_team'),
]
for a, b in pairs:
    n = re.subn(a, b, s)
    if n[1]:
        s = n[0]
        hit += n[1]
open(p, 'w').write(s)
print('teamnum', hit)
PY

echo "===== HUD ====="
cat >> tweak/Overlay.xm <<'HUDEOF'

#include <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

CGFloat g_kcd_tsize = 13.0;
UIColor *g_kcd_tcolor = nil;
int g_kcd_botfilter = 1;
float g_kcd_near = 1e9f;
uint64_t g_kcd_near_pawn = 0;
uint64_t g_kcd_last_pawn = 0;
int g_kcd_cur_team = -1;
int g_kcd_back = 0;
int g_kcd_count = 0;
int g_kcd_human = 0;
int g_kcd_teams = 0;
uint32_t g_kcd_tmask = 0;
static int g_cal_done = 0;

static void kcd_pan_handle(id g);

@interface KCDPanT : NSObject @end
@implementation KCDPanT
+ (instancetype)sh { static KCDPanT *s = nil; if (!s) s = [KCDPanT new]; return s; }
- (void)pan:(id)g { kcd_pan_handle(g); }
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

static UIWindow *g_w = nil;
static UILabel *g_l1 = nil;
static UILabel *g_l2 = nil;
static UILabel *g_l3 = nil;

static id kcd_get(NSString *k) {
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
    return (__bridge id)CFPreferencesCopyAppValue((__bridge CFStringRef)k, CFSTR("com.kcd.config"));
}
static void kcd_set(NSString *k, id v) {
    CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v, CFSTR("com.kcd.config"));
    CFPreferencesAppSynchronize(CFSTR("com.kcd.config"));
}
static BOOL kcd_b(NSString *k, BOOL d) { id v = kcd_get(k); return v ? [v boolValue] : d; }
static int kcd_i(NSString *k, int d) { id v = kcd_get(k); return v ? [v intValue] : d; }

UIColor *kcd_team_color(int t) {
    if (t < 0) return [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0];
    int m = kcd_i(@"my_team", 1);
    if (t == m) return [UIColor colorWithRed:0.0 green:1.0 blue:0.93 alpha:1.0];
    static const int rgb[12][3] = {
        {255, 38, 38}, {255, 140, 0}, {255, 224, 0}, {160, 255, 0},
        {0, 224, 80}, {0, 224, 160}, {0, 200, 255}, {42, 107, 255},
        {138, 43, 226}, {224, 32, 192}, {255, 80, 144}, {176, 112, 48}
    };
    int i = t % 12;
    if (i < 0) i += 12;
    return [UIColor colorWithRed:rgb[i][0]/255.0 green:rgb[i][1]/255.0 blue:rgb[i][2]/255.0 alpha:1.0];
}

static void kcd_pan_handle(id g) {
    UIPanGestureRecognizer *p = (UIPanGestureRecognizer *)g;
    UIView *v = p.view;
    CGPoint d = [p translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [p setTranslation:CGPointZero inView:v.superview];
    if (p.state == UIGestureRecognizerStateEnded) {
        CGRect sc = [UIScreen mainScreen].bounds;
        int px = (int)(v.center.x / sc.size.width * 100.0);
        int py = (int)(v.center.y / sc.size.height * 100.0);
        NSString *kx, *ky;
        if (v.tag == 1) { kx = @"nearest_x"; ky = @"nearest_y"; }
        else if (v.tag == 2) { kx = @"back_x"; ky = @"back_y"; }
        else { kx = @"count_x"; ky = @"count_y"; }
        kcd_set(kx, @(px));
        kcd_set(ky, @(py));
    }
}

static UILabel *kcd_lab(CGFloat x, CGFloat y, int tag) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 360, 26)];
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:g_kcd_tsize];
    l.userInteractionEnabled = YES;
    l.tag = tag;
    UIPanGestureRecognizer *p = [[UIPanGestureRecognizer alloc] initWithTarget:[KCDPanT sh] action:@selector(pan:)];
    [l addGestureRecognizer:p];
    return l;
}

static void kcd_make(void) {
    if (g_w) return;
    g_kcd_tsize = kcd_i(@"text_size", 13);
    g_kcd_tcolor = [UIColor whiteColor];
    g_kcd_botfilter = kcd_b(@"bot_filter", YES) ? 1 : 0;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat W = sc.size.width, H = sc.size.height;
    g_w = [[KCDHudWin alloc] initWithFrame:sc];
    g_w.windowLevel = UIWindowLevelAlert + 500;
    g_w.backgroundColor = [UIColor clearColor];
    g_w.rootViewController = [[UIViewController alloc] init];
    g_w.rootViewController.view.backgroundColor = [UIColor clearColor];
    g_w.hidden = NO;
    g_l1 = kcd_lab(W * kcd_i(@"nearest_x", 5) / 100.0, H * kcd_i(@"nearest_y", 25) / 100.0, 1);
    g_l1.text = @"最近: --";
    [g_w.rootViewController.view addSubview:g_l1];
    g_l2 = kcd_lab(W * kcd_i(@"back_x", 5) / 100.0, H * kcd_i(@"back_y", 32) / 100.0, 2);
    [g_w.rootViewController.view addSubview:g_l2];
    g_l3 = kcd_lab(W * kcd_i(@"count_x", 5) / 100.0, H * kcd_i(@"count_y", 39) / 100.0, 3);
    [g_w.rootViewController.view addSubview:g_l3];
}

static void kcd_tick(void) {
    if (!g_l1) return;
    g_kcd_teams = __builtin_popcount(g_kcd_tmask);
    if (g_kcd_near > 1e8f) {
        g_l1.text = @"最近: --";
    } else {
        int y = kcd_b(@"facing_on", YES) ? kcd_yaw_of(g_kcd_near_pawn) : -1;
        if (y >= 0)
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  朝向 %d  队%d", g_kcd_near, y, g_kcd_cur_team];
        else
            g_l1.text = [NSString stringWithFormat:@"最近: %.0fm  队%d", g_kcd_near, g_kcd_cur_team];
    }
    if (kcd_b(@"blink_on", YES) && g_kcd_near < 15.0f) {
        float a = 0.35f + 0.65f * fabsf(sinf((float)CACurrentMediaTime() * 8.0f));
        g_l1.textColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:a];
    } else {
        g_l1.textColor = [UIColor whiteColor];
    }
    if (!kcd_b(@"back_on", YES)) {
        g_l2.hidden = YES;
    } else if (g_kcd_back > 0) {
        g_l2.hidden = NO;
        g_l2.text = [NSString stringWithFormat:@"背敌: %d (%dm内)", g_kcd_back, kcd_i(@"back_dist", 40)];
    } else {
        g_l2.hidden = YES;
    }
    if (!kcd_b(@"count_on", YES)) {
        g_l3.hidden = YES;
    } else {
        g_l3.hidden = NO;
        g_l3.text = [NSString stringWithFormat:@"真人: %d / 总: %d  队伍: %d", g_kcd_human, g_kcd_count, g_kcd_teams];
    }
}

__attribute__((constructor)) static void kcd_hud_install(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kcd_make();
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) { kcd_tick(); }];
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            if (kcd_gnames_scan() == 0) NSLog(@"[kcd] gnames=%llx", g_gnames);
        });
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            int tries = 0;
            while (tries++ < 40) {
                usleep(500000);
                if (g_ps_n >= 3) break;
            }
            if (g_ps_n < 3) { NSLog(@"[kcd] calib skip ps_n=%d", g_ps_n); return; }
            int sel = kcd_i(@"teamid_off", 0);
            if (sel > 0) {
                g_off_teamid = 0x2B8 + (sel - 1) * 8;
                NSLog(@"[kcd] calib manual 0x%X", g_off_teamid);
            } else {
                int o = kcd_calib_teamid();
                NSLog(@"[kcd] calib L1 0x%X n=%d", o, g_ps_n);
                if (o > 0) {
                    g_off_teamid = o;
                } else {
                    int r2 = kcd_reflect_teamid();
                    NSLog(@"[kcd] calib L2 0x%X", r2);
                    if (r2 > 0) g_off_teamid = r2;
                    else { g_off_teamid = 0x2C0; NSLog(@"[kcd] calib L3 0x2C0"); }
                }
            }
            g_cal_done = 1;
        });
    });
}
HUDEOF
echo "hud ok"

echo "===== PANEL ====="
cat >> tweak/Overlay.xm <<'PANELEOF'

#import <UIKit/UIKit.h>

extern int g_kfd_ready;
extern uint64_t g_gnames;

static UIWindow *g_pw = nil;
static UIScrollView *g_psv = nil;
static BOOL g_pon = NO;

static void kcd_panel_refresh(void);
static void kcd_panel_hide(void);

static NSArray *kcd_rows(void) {
    return @[
        @[@"h", @"绘制"],
        @[@"b", @"box_enemy", @"敌人方框"],
        @[@"b", @"skeleton", @"骨骼线"],
        @[@"b", @"health", @"血条"],
        @[@"b", @"distance", @"距离数字"],
        @[@"h", @"过滤"],
        @[@"b", @"bot_filter", @"只显示真人"],
        @[@"b", @"team_filter", @"过滤队友"],
        @[@"b", @"back_on", @"背敌预警"],
        @[@"h", @"外观"],
        @[@"i", @"text_size", @"字号", @[@11, @13, @15, @18, @22]],
        @[@"i", @"thick", @"框线粗细", @[@1, @2, @3]],
        @[@"i", @"max_dist", @"最远距离", @[@50, @100, @150, @200, @300, @400, @500]],
        @[@"h", @"其他"],
        @[@"i", @"my_team", @"我的队伍", @[@0, @1, @2, @3, @4, @5, @6, @7, @8]],
        @[@"i", @"teamid_off", @"偏移校准", @[@0, @1, @2, @3, @4, @5, @6]],
        @[@"b", @"nearest_on", @"最近敌人显示"],
        @[@"b", @"blink_on", @"近敌闪烁"],
        @[@"b", @"facing_on", @"敌人朝向"],
        @[@"b", @"count_on", @"人数统计"]
    ];
}

static NSString *kcd_val(NSString *key, NSArray *opts) {
    id v = kcd_get(key);
    if (opts) return v ? [NSString stringWithFormat:@"%@", v] : [NSString stringWithFormat:@"%@", opts[0]];
    return (v && [v boolValue]) ? @"开" : @"关";
}

static void kcd_panel_build(void) {
    if (g_pw) return;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat W = 340;
    CGFloat H = MIN(sc.size.height - 140, 700);
    g_pw = [[UIWindow alloc] initWithFrame:CGRectMake((sc.size.width - W) / 2, (sc.size.height - H) / 2, W, H)];
    g_pw.windowLevel = UIWindowLevelAlert + 1000;
    g_pw.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
    g_pw.layer.cornerRadius = 14;
    g_pw.layer.masksToBounds = YES;
    g_pw.hidden = YES;
    g_pw.rootViewController = [[UIViewController alloc] init];
    g_pw.rootViewController.view.backgroundColor = [UIColor clearColor];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, W - 100, 28)];
    t.text = @"三角洲透视  16.5";
    t.textColor = [UIColor whiteColor];
    t.font = [UIFont fontWithName:@"PingFangSC-Semibold" size:16];
    [g_pw.rootViewController.view addSubview:t];

    UIButton *cl = [UIButton buttonWithType:UIButtonTypeSystem];
    cl.frame = CGRectMake(W - 76, 8, 64, 30);
    [cl setTitle:@"关闭" forState:UIControlStateNormal];
    [cl setTitleColor:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] forState:UIControlStateNormal];
    cl.titleLabel.font = [UIFont fontWithName:@"PingFangSC-Regular" size:15];
    [cl addAction:[UIAction actionWithHandler:^(UIAction *a) { kcd_panel_hide(); }] forControlEvents:UIControlEventTouchUpInside];
    [g_pw.rootViewController.view addSubview:cl];

    g_psv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, W, H - 44)];
    [g_pw.rootViewController.view addSubview:g_psv];
}

static void kcd_panel_refresh(void) {
    if (!g_pw) return;
    for (UIView *v in g_psv.subviews) [v removeFromSuperview];
    CGFloat y = 8;
    for (NSArray *r in kcd_rows()) {
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
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8, y, 324, 40);
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        NSMutableString *tt = [NSMutableString stringWithFormat:@"  %@", nm];
        while ([tt length] < 22) [tt appendString:@" "];
        [tt appendString:kcd_val(key, opts)];
        [b setTitle:tt forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont fontWithName:@"PingFangSC-Regular" size:15];
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
            if ([r[0] isEqualToString:@"b"]) {
                kcd_set(key, @(!kcd_b(key, NO)));
            } else if (opts) {
                int cur = kcd_i(key, [opts[0] intValue]);
                NSUInteger i = [opts indexOfObject:@(cur)];
                i = (i == NSNotFound || i + 1 >= opts.count) ? 0 : i + 1;
                kcd_set(key, opts[i]);
            }
            kcd_panel_refresh();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_psv addSubview:b];
        y += 44;
    }
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 8, 320, 22)];
    st.text = [NSString stringWithFormat:@"内核: %@   名字池: %@   队伍偏移: 0x%X",
               g_kfd_ready ? @"正常" : @"异常",
               g_gnames ? @"正常" : @"未找到",
               g_off_teamid];
    st.textColor = g_kfd_ready ? [UIColor greenColor] : [UIColor redColor];
    st.font = [UIFont fontWithName:@"PingFangSC-Regular" size:12];
    [g_psv addSubview:st];
    y += 34;
    g_psv.contentSize = CGSizeMake(340, y);
}

static void kcd_panel_show(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        kcd_panel_build();
        kcd_panel_refresh();
        g_pw.hidden = NO;
        g_pon = YES;
    });
}

static void kcd_panel_hide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_pw.hidden = YES;
        g_pon = NO;
    });
}

static void kcd_panel_toggle2(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_pon) kcd_panel_hide();
        else kcd_panel_show();
    });
}
PANELEOF
echo "panel ok"

echo "===== VOL GESTURE ====="
cat >> tweak/Overlay.xm <<'VOLEOF'

#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef a);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef c, CFDictionaryRef m);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef c, void (*cb)(void *, void *, IOHIDEventRef), void *t, void *r);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef c, CFRunLoopRef rl, CFStringRef mode);
extern int IOHIDEventGetType(IOHIDEventRef e);
extern int64_t IOHIDEventGetIntegerValue(IOHIDEventRef e, int32_t f);

static BOOL kcd_vu = NO;
static BOOL kcd_vd = NO;
static int kcd_vtok = 0;

static void kcd_hid_cb(void *t, void *r, IOHIDEventRef e) {
    if (IOHIDEventGetType(e) != 3) return;
    int64_t u = IOHIDEventGetIntegerValue(e, 0x00030000);
    int64_t pr = IOHIDEventGetIntegerValue(e, 0x00030002);
    if (u != 0xE9 && u != 0xEA) return;
    if (pr != 0) {
        if (u == 0xE9) kcd_vu = YES;
        else kcd_vd = YES;
        if (kcd_vu && kcd_vd) {
            kcd_vtok++;
            int my = kcd_vtok;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (my == kcd_vtok && kcd_vu && kcd_vd) {
                    kcd_vu = NO;
                    kcd_vd = NO;
                    kcd_panel_toggle2();
                }
            });
        }
    } else {
        if (u == 0xE9) kcd_vu = NO;
        else kcd_vd = NO;
        kcd_vtok++;
    }
}

__attribute__((constructor)) static void kcd_vol_install(void) {
    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!c) return;
    IOHIDEventSystemClientSetMatching(c, (__bridge CFDictionaryRef)@{} );
    IOHIDEventSystemClientRegisterEventCallback(c, kcd_hid_cb, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}
VOLEOF
echo "vol ok"

echo "===== KILL TOUCH ====="
python3 - <<'PY'
p = 'tweak/Overlay.xm'
s = open(p).read()
s = s.replace('numberOfTouchesRequired = 3;', 'numberOfTouchesRequired = 99;')
s = s.replace('numberOfTouchesRequired=3;', 'numberOfTouchesRequired=99;')
s = s.replace('minimumPressDuration = 1.0', 'minimumPressDuration = 99.0')
s = s.replace('minimumPressDuration=1.0', 'minimumPressDuration=99.0')
open(p, 'w').write(s)
print('touch off')
PY

echo "===== FIX HEADERS ====="
python3 - <<'PY'
p = 'kcore/kern.m'
s = open(p).read()
s = s.replace('#include <libproc.h>',
              '#include <sys/syslimits.h>\n#define PROC_ALL_PIDS 1\n'
              'extern int proc_listpids(unsigned int, unsigned int, void *, int);\n'
              'extern int proc_pidpath(int, void *, unsigned int);')
open(p, 'w').write(s)

p2 = 'tweak/Overlay.xm'
s2 = open(p2).read()
s2 = s2.replace('#include <sys/sysctl.h>', '#include <unistd.h>\n#include <sys/sysctl.h>')
s2 = s2.replace('struct kinfo_proc *kp = malloc(sz);', 'struct kinfo_proc *kp = (struct kinfo_proc *)malloc(sz);')
open(p2, 'w').write(s2)
print('headers ok')
PY

echo "===== FIX HOOK ====="
cat > /tmp/hook.txt <<'HOOKEOF'
#include <objc/runtime.h>
static void (*kcd_orig_adfl)(id, SEL, id) = 0;
static void kcd_hook_adfl(id self, SEL _cmd, id a) {
    if (kcd_orig_adfl) kcd_orig_adfl(self, _cmd, a);
    load_cfg();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ make_window(); });
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ scan_loop(NULL); });
}
__attribute__((constructor)) static void kcd_install_hook(void) {
    Class c = objc_getClass("SpringBoard");
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(applicationDidFinishLaunching:));
    if (!m) return;
    kcd_orig_adfl = (void (*)(id, SEL, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)kcd_hook_adfl);
}
HOOKEOF
python3 - <<'PY'
import re
p = 'tweak/Overlay.xm'
s = open(p).read()
h = open('/tmp/hook.txt').read()
n = re.sub(r'%hook\s+SpringBoard.*?%end', h, s, flags=re.S)
open(p, 'w').write(n)
print('hook ok')
PY

echo "===== PATCH LINK ====="
LDP=$(cat "$TC/ld64_path.txt")
sed -i "s|-fuse-ld=ld64.lld|-fuse-ld=$LDP -Wl,-platform_version,ios,15.0,15.0|g" build.sh
sed -i 's|-c tweak/Overlay.mm|-x objective-c -c tweak/Overlay.mm|g' build.sh
sed -i 's|-framework UIKit|-framework UIKit -framework IOKit -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework CoreImage|g' build.sh

echo "===== BUILD ====="
export THEOS="$TC/theos"
export PATH="/usr/local/bin:$TC:$PATH"
export AR=ar
bash build.sh

echo "===== COLLECT ====="
cd "$GITHUB_WORKSPACE"
mkdir -p dist
cp src/release/*.deb dist/ 2>/dev/null || cp src/*.deb dist/ 2>/dev/null || true
ls -lh dist/ || true
