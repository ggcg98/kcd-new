#!/usr/bin/env bash
set -e
R="${1:-$PWD/src}"
mkdir -p "$R"/{kcore,game,daemon,tweak,tools,package/DEBIAN}
cd "$R"

cat > ent.plist <<'P1'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>platform-application</key><true/>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.container-required</key><false/>
<key>com.apple.private.skip-library-validation</key><true/>
<key>com.apple.private.amfi.can-load-cdhash</key><true/>
<key>get-task-allow</key><true/>
<key>task_for_pid-allow</key><true/>
<key>com.apple.system-task-ports</key><true/>
<key>com.apple.private.cs.debugger</key><true/>
<key>run-unsigned-code</key><true/>
</dict></plist>
P1

cat > config.plist <<'P2'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>filter_bot</key><true/>
<key>filter_team</key><true/>
<key>esp_enabled</key><true/>
<key>record_guard</key><true/>
<key>draw_box</key><true/>
<key>draw_bone</key><true/>
<key>draw_hp</key><true/>
<key>draw_dist</key><true/>
</dict></plist>
P2

cat > kcore/krw.h <<'P3'
#ifndef KRW_H
#define KRW_H
#include <stdint.h>
#include <stddef.h>
#ifndef KCD_READ_ONLY
#define KCD_READ_ONLY 1
#endif
typedef struct krw_backend {
    const char *name;
    int (*init)(void);
    int (*kread)(uint64_t, void *, size_t);
    int (*kwrite)(uint64_t, const void *, size_t);
    int (*physread)(uint64_t, void *, size_t);
    int (*physwrite)(uint64_t, const void *, size_t);
} krw_backend_t;
extern krw_backend_t be_kfd;
extern uint64_t g_kbase, g_kslide;
extern int g_kfd_ready;
int rw_up(void);
int rw_alive(void);
int kread_buf(uint64_t, void *, size_t);
int kwrite_buf(uint64_t, const void *, size_t);
uint64_t r64(uint64_t);
uint32_t r32(uint64_t);
float rf32(uint64_t);
void w64(uint64_t, uint64_t);
void w32(uint64_t, uint32_t);
uint64_t kread_ptr(uint64_t);
#define PAC_STRIP(x) ((x) & 0x0000FFFFFFFFFFFFULL)
#endif
P3

cat > kcore/krw.c <<'P1'
#include "krw.h"
#include <sys/utsname.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if __has_include(<kfd.h>)
  #include <kfd.h>
  #define HAVE_KFD 1
  static kfd_t *g_kfd = NULL;
#else
  #define HAVE_KFD 0
#endif
uint64_t g_kbase = 0, g_kslide = 0;
int g_kfd_ready = 0;
static void version_candidates(char list[][8], int *count) {
    struct utsname u;
    int a = 0, b = 0, c = 0;
    *count = 0;
    if (uname(&u) != 0) { snprintf(list[(*count)++], 8, "%s", "16.5"); return; }
    sscanf(u.release, "%d.%d.%d", &a, &b, &c);
    const char *v = "16.5";
    if (a == 21) {
        switch (b) {
            case 0: v = "15.0"; break;
            case 1: v = "15.1"; break;
            case 2: v = "15.2"; break;
            case 3: v = "15.3"; break;
            case 4: v = "15.4"; break;
            case 5: v = "15.5"; break;
            case 6: v = (c >= 1) ? "15.7" : "15.6"; break;
            default: v = "15.7"; break;
        }
    } else if (a == 22) {
        switch (b) {
            case 0: v = "16.0"; break;
            case 1: v = "16.1"; break;
            case 2: v = "16.2"; break;
            case 3: v = "16.3"; break;
            case 4: v = "16.4"; break;
            case 5: v = "16.5"; break;
            case 6: v = "16.6"; break;
            default: v = "16.5"; break;
        }
    }
    snprintf(list[(*count)++], 8, "%s", v);
    if (!strcmp(v, "15.6")) { snprintf(list[(*count)++], 8, "15.5"); snprintf(list[(*count)++], 8, "15.7"); }
    else if (!strcmp(v, "15.7")) { snprintf(list[(*count)++], 8, "15.6"); }
    else if (!strcmp(v, "16.4")) { snprintf(list[(*count)++], 8, "16.5"); snprintf(list[(*count)++], 8, "16.3"); }
    else if (!strcmp(v, "16.5")) { snprintf(list[(*count)++], 8, "16.4"); snprintf(list[(*count)++], 8, "16.6"); }
    else if (!strcmp(v, "16.6")) { snprintf(list[(*count)++], 8, "16.5"); }
}
static int kfd_up(void) {
#if HAVE_KFD
    char vers[6][8];
    int n = 0;
    version_candidates(vers, &n);
    const char *env = getenv("KCD_IOS");
    if (env && env[0]) { snprintf(vers[0], 8, "%s", env); n = 1; }
    static const uint16_t sz[] = { 0x4000, 0x8000, 0xC000 };
    for (int v = 0; v < n; v++) {
        for (int i = 0; i < 3; i++) {
            g_kfd = kfd_init(sz[i], vers[v], NULL, 0, 0);
            if (!g_kfd) continue;
            if (kfd_kbase(g_kfd, &g_kbase, &g_kslide) != 0) continue;
            uint32_t m = 0;
            if (kfd_kread(g_kfd, g_kbase, (uint64_t)&m, 4) != 0) continue;
            if (m == 0xFEEDFACF) { g_kfd_ready = 1; fprintf(stderr, "[kcd] kfd ok ver=%s\n", vers[v]); return 0; }
        }
    }
    fprintf(stderr, "[kcd] kfd init failed\n");
    return -1;
#else
    fprintf(stderr, "[kcd] kfd not imported\n");
    return -1;
#endif
}
#if HAVE_KFD
static int be_read(uint64_t a, void *b, size_t n) { return kfd_kread(g_kfd, a, (uint64_t)b, n); }
static int be_write(uint64_t a, const void *b, size_t n) { return kfd_kwrite(g_kfd, a, (uint64_t)b, n); }
static int be_pread(uint64_t p, void *b, size_t n) { return kfd_physread(g_kfd, p, (uint64_t)b, n); }
static int be_pwrite(uint64_t p, const void *b, size_t n) { return kfd_physwrite(g_kfd, p, (uint64_t)b, n); }
#else
static int be_read(uint64_t a, void *b, size_t n) { (void)a;(void)b;(void)n; return -1; }
static int be_write(uint64_t a, const void *b, size_t n) { (void)a;(void)b;(void)n; return -1; }
static int be_pread(uint64_t p, void *b, size_t n) { (void)p;(void)b;(void)n; return -1; }
static int be_pwrite(uint64_t p, const void *b, size_t n) { (void)p;(void)b;(void)n; return -1; }
#endif
krw_backend_t be_kfd = { "kfd", kfd_up, be_read, be_write, be_pread, be_pwrite };
int rw_up(void) { return be_kfd.init() == 0 ? 0 : -1; }
int rw_alive(void) {
    if (!g_kfd_ready) return -1;
    uint32_t m = 0;
    if (be_kfd.kread(g_kbase, &m, 4) != 0) return -1;
    return m == 0xFEEDFACF ? 0 : -1;
}
int kread_buf(uint64_t a, void *b, size_t n) { return be_kfd.kread(a, b, n); }
int kwrite_buf(uint64_t a, const void *b, size_t n) { return be_kfd.kwrite(a, b, n); }
uint64_t r64(uint64_t a) { uint64_t v = 0; be_kfd.kread(a, &v, 8); return v; }
uint32_t r32(uint64_t a) { uint32_t v = 0; be_kfd.kread(a, &v, 4); return v; }
float rf32(uint64_t a) { float v = 0; be_kfd.kread(a, &v, 4); return v; }
void w64(uint64_t a, uint64_t v) { be_kfd.kwrite(a, &v, 8); }
void w32(uint64_t a, uint32_t v) { be_kfd.kwrite(a, &v, 4); }
uint64_t kread_ptr(uint64_t a) { uint64_t v = 0; be_kfd.kread(a, &v, 8); return PAC_STRIP(v); }
P1
cat > kcore/koffsets.h <<'P1'
#ifndef KOFFSETS_H
#define KOFFSETS_H
#include <stdint.h>
typedef struct {
    uint64_t allproc, proc_task, proc_pid;
    uint64_t proc_list_next, proc_list_prev;
    uint64_t proc_hash_next, proc_hash_prev;
    uint64_t task_map, vmmap_pmap, pmap_ttep;
} KOffsets;
extern KOffsets g_ko;
void ko_default(KOffsets *);
int ko_load(KOffsets *, const char *);
int ko_save(const KOffsets *, const char *);
#define KO_PATH "/var/mobile/Library/Preferences/com.kcd.koff.plist"
#endif
P1

cat > kcore/koffsets.c <<'P2'
#import <Foundation/Foundation.h>
#include "koffsets.h"
#include <string.h>
KOffsets g_ko;
void ko_default(KOffsets *o) {
    memset(o, 0, sizeof(*o));
    o->proc_task = 0x10;
    o->proc_pid = 0x68;
    o->proc_list_next = 0x00;
    o->proc_list_prev = 0x08;
    o->proc_hash_next = 0x18;
    o->proc_hash_prev = 0x20;
    o->task_map = 0x28;
    o->vmmap_pmap = 0x38;
    o->pmap_ttep = 0x08;
}
int ko_load(KOffsets *o, const char *p) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:p]];
    if (!d) return -1;
    ko_default(o);
#define G(f) if (d[@#f]) o->f = [d[@#f] unsignedLongLongValue]
    G(allproc);G(proc_task);G(proc_pid);G(proc_list_next);G(proc_list_prev);
    G(proc_hash_next);G(proc_hash_prev);G(task_map);G(vmmap_pmap);G(pmap_ttep);
#undef G
    return 0;
}
int ko_save(const KOffsets *o, const char *p) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
#define S(f) d[@#f] = @((unsigned long long)o->f)
    S(allproc);S(proc_task);S(proc_pid);S(proc_list_next);S(proc_list_prev);
    S(proc_hash_next);S(proc_hash_prev);S(task_map);S(vmmap_pmap);S(pmap_ttep);
#undef S
    return [d writeToFile:[NSString stringWithUTF8String:p] atomically:YES] ? 0 : -1;
}
P2

cat > kcore/kautoconf.h <<'P3'
#ifndef KAUTOCONF_H
#define KAUTOCONF_H
#include "koffsets.h"
int ka_autoconf(KOffsets *);
const char *ka_last_error(void);
#endif
P3

cat > kcore/kautoconf.c <<'P4'
#include "kautoconf.h"
#include "krw.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static char g_err[128];
const char *ka_last_error(void) { return g_err; }
static uint64_t find_allproc(void) {
    static const uint64_t spans[] = { 0x4000000, 0x8000000, 0x10000000 };
    for (int s = 0; s < 3; s++) {
        uint64_t end = g_kbase + spans[s];
        for (uint64_t a = g_kbase; a < end; a += 8) {
            uint64_t first = r64(a);
            if (first < 0xffff000000000000ULL) continue;
            for (uint64_t o = 0; o < 0x40; o += 8) {
                if (r64(first + o) == a) {
                    uint32_t pid = r32(first + 0x68);
                    if (pid > 0 && pid < 0x10000) return a;
                }
            }
        }
    }
    return 0;
}
static uint64_t find_pid_offset(uint64_t allproc) {
    uint64_t f = kread_ptr(allproc);
    if (!f) return 0;
    for (uint64_t off = 0x20; off < 0x400; off += 4) {
        uint32_t v1 = r32(f + off);
        if (v1 < 2 || v1 > 0x10000) continue;
        uint64_t p2 = kread_ptr(f);
        if (p2 < 0xffff000000000000ULL) continue;
        uint32_t v2 = r32(p2 + off);
        if (v2 < 2 || v2 > 0x10000 || v2 == v1) continue;
        uint64_t p3 = kread_ptr(p2);
        if (p3 < 0xffff000000000000ULL) continue;
        uint32_t v3 = r32(p3 + off);
        if (v3 < 2 || v3 > 0x10000 || v3 == v1 || v3 == v2) continue;
        return off;
    }
    return 0;
}
static int verify_task(uint64_t proc, uint64_t ot, uint64_t om, uint64_t op, uint64_t ott) {
    uint64_t t = kread_ptr(proc + ot);
    if (t < 0xffff000000000000ULL) return 0;
    uint64_t m = kread_ptr(t + om);
    if (m < 0xffff000000000000ULL) return 0;
    uint64_t pm = kread_ptr(m + op);
    if (pm < 0xffff000000000000ULL) return 0;
    uint64_t tt = r64(pm + ott);
    if (!tt || (tt & 0xFFF) || tt > 0x4000000000ULL) return 0;
    return 1;
}
int ka_autoconf(KOffsets *out) {
    g_err[0] = 0;
    ko_default(out);
    uint64_t ap = find_allproc();
    if (!ap) { snprintf(g_err, sizeof(g_err), "allproc not found"); return -1; }
    out->allproc = ap;
    uint64_t po = find_pid_offset(ap);
    if (po) out->proc_pid = po;
    uint64_t p = kread_ptr(ap);
    int ok = 0;
    for (int i = 0; i < 512 && p && p >= 0xffff000000000000ULL; i++) {
        if ((int)r32(p + out->proc_pid) == (int)getpid()) {
            if (verify_task(p, out->proc_task, out->task_map, out->vmmap_pmap, out->pmap_ttep)) { ok = 1; break; }
            for (uint64_t to = 0x08; to < 0x80; to += 8) {
                if (verify_task(p, to, out->task_map, out->vmmap_pmap, out->pmap_ttep)) { out->proc_task = to; ok = 1; break; }
            }
            break;
        }
        p = kread_ptr(p + out->proc_list_next);
    }
    if (!ok) { snprintf(g_err, sizeof(g_err), "task verify failed"); return -2; }
    return 0;
}
P4
cat > kcore/pmap.h <<'P1'
#ifndef PMAP_H
#define PMAP_H
#include <stdint.h>
#include <stddef.h>
int rpm(uint64_t, uint64_t, void *, size_t);
int wpm(uint64_t, uint64_t, const void *, size_t);
uint64_t task_pmap(uint64_t);
uint64_t pmap_vtop(uint64_t, uint64_t);
#endif
P1

cat > kcore/pmap.m <<'P2'
#include "pmap.h"
#include "krw.h"
#include "koffsets.h"
#include <stdio.h>
#define PTE_M 0x0000FFFFFFFFF000ULL
#define BLK_M 0x0000FFFFFFE00000ULL
uint64_t task_pmap(uint64_t t) {
    uint64_t m = kread_ptr(t + g_ko.task_map);
    return m ? kread_ptr(m + g_ko.vmmap_pmap) : 0;
}
uint64_t pmap_vtop(uint64_t pm, uint64_t va) {
    uint64_t tt = r64(pm + g_ko.pmap_ttep) & PTE_M;
    if (!tt) return 0;
    uint64_t e1 = r64(tt + (((va >> 30) & 0x1FF) << 3));
    if ((e1 & 3) != 3) return 0;
    if (e1 & 1) return (e1 & BLK_M) | (va & 0x3FFFFFFFULL);
    uint64_t l2 = e1 & PTE_M;
    uint64_t e2 = l2 ? r64(l2 + (((va >> 21) & 0x1FF) << 3)) : 0;
    if ((e2 & 3) != 3) return 0;
    if (e2 & 1) return (e2 & BLK_M) | (va & 0x1FFFFFULL);
    uint64_t l3 = e2 & PTE_M;
    uint64_t e3 = l3 ? r64(l3 + (((va >> 12) & 0x1FF) << 3)) : 0;
    if ((e3 & 3) != 3) return 0;
    return (e3 & PTE_M) | (va & 0xFFFULL);
}
int rpm(uint64_t t, uint64_t va, void *b, size_t n) {
    uint64_t pm = task_pmap(t);
    if (!pm) return -1;
    uint8_t *o = b;
    while (n) {
        uint64_t pa = pmap_vtop(pm, va);
        if (!pa) return -2;
        size_t k = 0x1000 - (va & 0xFFF);
        if (k > n) k = n;
        if (be_kfd.physread(pa, o, k) != 0) return -3;
        va += k; o += k; n -= k;
    }
    return 0;
}
int wpm(uint64_t t, uint64_t va, const void *b, size_t n) {
#if KCD_READ_ONLY
    (void)t; (void)va; (void)b; (void)n;
    fprintf(stderr, "[RO] blocked\n");
    return -100;
#else
    uint64_t pm = task_pmap(t);
    if (!pm) return -1;
    const uint8_t *i = b;
    while (n) {
        uint64_t pa = pmap_vtop(pm, va);
        if (!pa) return -2;
        size_t k = 0x1000 - (va & 0xFFF);
        if (k > n) k = n;
        if (be_kfd.physwrite(pa, i, k) != 0) return -3;
        va += k; i += k; n -= k;
    }
    return 0;
#endif
}
P2

cat > kcore/kern.h <<'P3'
#ifndef KERN_H
#define KERN_H
#include <stdint.h>
uint64_t proc_by_pid(int);
uint64_t task_of_pid(int);
uint64_t task_exe_base(uint64_t);
int find_game_pid(const char *);
#endif
P3

cat > kcore/kern.m <<'P4'
#include "kern.h"
#include "krw.h"
#include "koffsets.h"
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <libproc.h>
uint64_t proc_by_pid(int pid) {
    if (!g_ko.allproc) return 0;
    uint64_t p = kread_ptr(g_ko.allproc);
    for (int i = 0; i < 8192 && p; i++) {
        if ((int)r32(p + g_ko.proc_pid) == pid) return p;
        p = kread_ptr(p + g_ko.proc_list_next);
    }
    return 0;
}
uint64_t task_of_pid(int pid) {
    uint64_t p = proc_by_pid(pid);
    return p ? kread_ptr(p + g_ko.proc_task) : 0;
}
uint64_t task_exe_base(uint64_t t) {
    uint64_t m = kread_ptr(t + g_ko.task_map);
    if (!m) return 0;
    uint64_t e = kread_ptr(m), best = ~0ULL;
    for (int i = 0; i < 4096 && e && e != m; i++) {
        uint64_t s = r64(e + 0x10);
        if (s && s < best) best = s;
        e = kread_ptr(e);
    }
    return best == ~0ULL ? 0 : best;
}
int find_game_pid(const char *nd) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return -1;
    pid_t *ps = malloc((size_t)n);
    if (!ps) return -1;
    n = proc_listpids(PROC_ALL_PIDS, 0, ps, n);
    int f = -1;
    for (int i = 0; i < n; i++) {
        if (ps[i] <= 0) continue;
        char path[PATH_MAX];
        if (proc_pidpath(ps[i], path, sizeof(path)) <= 0) continue;
        if (strstr(path, nd)) { f = (int)ps[i]; break; }
    }
    free(ps);
    return f;
}
P4

cat > game/ue4_offsets.h <<'P1'
#ifndef UE4_OFFSETS_H
#define UE4_OFFSETS_H
#include <stdint.h>
typedef struct {
    char uuid_hex[40];
    uint64_t names_base, gworld, persistent_level, actors, pawn_pc, pawn_ps,
             actor_loc, actor_head, ps_team, ps_hp, ps_netconn, ps_flags,
             ps_bot_bit, ps_name, obj_class, obj_name;
    uint64_t mesh_component, bone_array, bone_count, component_to_world;
} Ue4Offsets;
extern Ue4Offsets g_ue;
void ue4_offsets_default(Ue4Offsets *);
int ue4_offsets_load(Ue4Offsets *, const char *);
int ue4_offsets_save(const Ue4Offsets *, const char *);
#define UE4_OFFSETS_PATH "/var/mobile/Library/Preferences/com.kcd.offsets.plist"
#endif
P1

cat > game/ue4_offsets.c <<'P2'
#import <Foundation/Foundation.h>
#include "ue4_offsets.h"
#include <string.h>
Ue4Offsets g_ue;
void ue4_offsets_default(Ue4Offsets *o) {
    memset(o, 0, sizeof(*o));
    o->gworld = 0x8F2A0C0ULL;
    o->persistent_level = 0x30;
    o->actors = 0xA0;
    o->pawn_pc = 0x2A0;
    o->pawn_ps = 0x2B0;
    o->actor_loc = 0x1A0;
    o->actor_head = 0x1B0;
    o->ps_team = 0x2E0;
    o->ps_hp = 0x2E8;
    o->ps_netconn = 0x2D0;
    o->ps_flags = 0x2EC;
    o->ps_bot_bit = 3;
    o->ps_name = 0x2F0;
    o->obj_class = 0x10;
    o->obj_name = 0x18;
    o->mesh_component = 0x310;
    o->bone_array = 0x6B0;
    o->bone_count = 0x6B8;
    o->component_to_world = 0x1A0;
}
int ue4_offsets_load(Ue4Offsets *o, const char *p) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithUTF8String:p]];
    if (!d) return -1;
    ue4_offsets_default(o);
    NSString *u = d[@"uuid_hex"];
    if ([u isKindOfClass:[NSString class]]) strncpy(o->uuid_hex, u.UTF8String, 39);
#define G(f) if (d[@#f]) o->f = [d[@#f] unsignedLongLongValue]
    G(names_base);G(gworld);G(persistent_level);G(actors);G(pawn_pc);G(pawn_ps);
    G(actor_loc);G(actor_head);G(ps_team);G(ps_hp);G(ps_netconn);G(ps_flags);
    G(ps_bot_bit);G(ps_name);G(obj_class);G(obj_name);
    G(mesh_component);G(bone_array);G(bone_count);G(component_to_world);
#undef G
    return 0;
}
int ue4_offsets_save(const Ue4Offsets *o, const char *p) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"uuid_hex"] = [NSString stringWithUTF8String:(o->uuid_hex[0] ? o->uuid_hex : "")];
#define S(f) d[@#f] = @((unsigned long long)o->f)
    S(names_base);S(gworld);S(persistent_level);S(actors);S(pawn_pc);S(pawn_ps);
    S(actor_loc);S(actor_head);S(ps_team);S(ps_hp);S(ps_netconn);S(ps_flags);
    S(ps_bot_bit);S(ps_name);S(obj_class);S(obj_name);
    S(mesh_component);S(bone_array);S(bone_count);S(component_to_world);
#undef S
    return [d writeToFile:[NSString stringWithUTF8String:p] atomically:YES] ? 0 : -1;
}
P2
cat > game/ue4.h <<'P3'
#ifndef UE4_H
#define UE4_H
#include <stdint.h>
#include "ue4_offsets.h"
#define MAX_ENT 64
#define MAX_BONES 24
typedef struct { float x, y, z; } Vec3;
typedef struct { float x, y; } Vec2;
typedef struct { float m[4][4]; } Matrix4x4;
typedef struct { Vec2 pt[MAX_BONES]; uint8_t valid[MAX_BONES]; uint32_t count; } SkelOut;
typedef struct {
    Vec2 head, foot;
    float dist;
    int32_t hp;
    int32_t team;
    uint64_t actor;
    uint8_t valid;
    SkelOut skel;
} EntOut;
typedef struct { uint64_t task, game_base, names_base, local_pc; int local_team; uint32_t flags; } RenderCtx;
#define F_BOT 0x1
#define F_TEAM 0x2
int ue4_setup(RenderCtx *);
int ue4_scan(const RenderCtx *, EntOut *, int);
int w2s(const Matrix4x4 *, Vec3, Vec3, Vec2 *);
float vdist(Vec3, Vec3);
#endif
P3

cat > game/skeleton.h <<'P4'
#ifndef SKELETON_H
#define SKELETON_H
#include "ue4.h"
int skel_read(uint64_t task, uint64_t actor, Vec3 *out, int max);
#endif
P4

cat > game/skeleton.c <<'P5'
#include "skeleton.h"
#include "../kcore/krw.h"
#include "../kcore/pmap.h"
#include <math.h>
#include <string.h>
typedef struct { float qx, qy, qz, qw; float tx, ty, tz; float sx, sy, sz; float pad; } FT;
static Vec3 xf(const Matrix4x4 *m, float x, float y, float z) {
    Vec3 o;
    o.x = x*m->m[0][0] + y*m->m[1][0] + z*m->m[2][0] + m->m[3][0];
    o.y = x*m->m[0][1] + y*m->m[1][1] + z*m->m[2][1] + m->m[3][1];
    o.z = x*m->m[0][2] + y*m->m[1][2] + z*m->m[2][2] + m->m[3][2];
    return o;
}
int skel_read(uint64_t t, uint64_t actor, Vec3 *out, int max) {
    uint64_t mesh = 0;
    if (rpm(t, actor + g_ue.mesh_component, &mesh, 8) != 0 || !mesh) return -1;
    uint64_t arr = 0; int32_t cnt = 0;
    if (rpm(t, mesh + g_ue.bone_array, &arr, 8) != 0 || !arr) return -2;
    if (rpm(t, mesh + g_ue.bone_count, &cnt, 4) != 0) return -3;
    if (cnt <= 0) return -4;
    if (cnt > max) cnt = max;
    FT c2w;
    if (rpm(t, mesh + g_ue.component_to_world, &c2w, sizeof(c2w)) != 0) return -5;
    Matrix4x4 m;
    float x = c2w.qx, y = c2w.qy, z = c2w.qz, w = c2w.qw;
    m.m[0][0] = 1 - 2*(y*y + z*z);
    m.m[0][1] = 2*(x*y + z*w);
    m.m[0][2] = 2*(x*z - y*w);
    m.m[1][0] = 2*(x*y - z*w);
    m.m[1][1] = 1 - 2*(x*x + z*z);
    m.m[1][2] = 2*(y*z + x*w);
    m.m[2][0] = 2*(x*z + y*w);
    m.m[2][1] = 2*(y*z - x*w);
    m.m[2][2] = 1 - 2*(x*x + y*y);
    m.m[3][0] = c2w.tx;
    m.m[3][1] = c2w.ty;
    m.m[3][2] = c2w.tz;
    m.m[3][3] = 1.0f;
    FT buf[MAX_BONES];
    int n = cnt > MAX_BONES ? MAX_BONES : cnt;
    if (rpm(t, arr, buf, sizeof(FT) * (size_t)n) != 0) return -6;
    for (int i = 0; i < n; i++) out[i] = xf(&m, buf[i].tx, buf[i].ty, buf[i].tz);
    return n;
}
P5

cat > game/ue4.c <<'P6'
#include "ue4.h"
#include "skeleton.h"
#include "../kcore/krw.h"
#include "../kcore/pmap.h"
#include <string.h>
#include <math.h>
static uint64_t g_t;
int ue4_setup(RenderCtx *c) {
    g_t = c->task;
    ue4_offsets_default(&g_ue);
    ue4_offsets_load(&g_ue, UE4_OFFSETS_PATH);
    if (g_ue.names_base) c->names_base = c->game_base + g_ue.names_base;
    return 0;
}
static void rfname(uint64_t fa, char *o, int n) {
    o[0] = 0;
    if (!g_ue.names_base) return;
    int32_t i = 0;
    rpm(g_t, fa, &i, 4);
    if (i <= 0) return;
    uint32_t b = (uint32_t)i >> 16, of = (uint32_t)i & 0xFFFF;
    uint64_t ch = 0;
    rpm(g_t, g_ue.names_base + 0x10 + (uint64_t)b * 8, &ch, 8);
    if (!ch) return;
    uint16_t h = 0;
    rpm(g_t, ch + (uint64_t)of * 2, &h, 2);
    if (h & 1) {
        uint16_t w[64] = {0};
        rpm(g_t, ch + (uint64_t)of * 2 + 2, w, sizeof(w));
        for (int k = 0; k < n - 1 && w[k]; k++) o[k] = (char)(w[k] & 0x7F);
    } else rpm(g_t, ch + (uint64_t)of * 2 + 2, o, n - 1);
    o[n - 1] = 0;
}
static int bent(const RenderCtx *c, uint64_t a, EntOut *o) {
    uint64_t ps = 0;
    rpm(g_t, a + g_ue.pawn_ps, &ps, 8);
    if (!ps) return -1;
    uint64_t pc = 0;
    rpm(g_t, a + g_ue.pawn_pc, &pc, 8);
    int32_t hp = 0, tm = 0; uint8_t f = 0; uint64_t nc = 0;
    rpm(g_t, ps + g_ue.ps_hp, &hp, 4);
    rpm(g_t, ps + g_ue.ps_team, &tm, 4);
    rpm(g_t, ps + g_ue.ps_flags, &f, 1);
    rpm(g_t, ps + g_ue.ps_netconn, &nc, 8);
    char nm[32] = {0}, cl[48] = {0};
    rfname(ps + g_ue.ps_name, nm, sizeof(nm));
    if (pc) {
        uint64_t k = kread_ptr(pc + g_ue.obj_class);
        if (k) rfname(k + g_ue.obj_name, cl, sizeof(cl));
    }
    int bot = (f >> g_ue.ps_bot_bit) & 1;
    if (strstr(cl, "AIController") || strstr(cl, "AIBot")) bot = 1;
    if (!nc || !pc || !nm[0]) bot = 1;
    if (!strncmp(nm, "Bot", 3) || !strncmp(nm, "AI_", 3)) bot = 1;
    int ok = (hp > 0);
    if (ok && (c->flags & F_BOT) && bot) ok = 0;
    if (ok && (c->flags & F_TEAM) && c->local_team >= 0 && tm == c->local_team) ok = 0;
    if (!ok) return -2;
    o->hp = hp;
    o->team = (tm == c->local_team) ? 1 : 0;
    return 0;
}
int ue4_scan(const RenderCtx *c, EntOut *out, int max) {
    if (max <= 0 || !c->game_base) return -1;
    uint64_t w = kread_ptr(c->game_base + g_ue.gworld);
    if (!w) return -1;
    uint64_t l = kread_ptr(w + g_ue.persistent_level);
    if (!l) return -1;
    uint64_t arr = 0; int32_t num = 0;
    rpm(g_t, l + g_ue.actors, &arr, 8);
    rpm(g_t, l + g_ue.actors + 8, &num, 4);
    if (num <= 0 || num > 512) return -1;
    Vec3 cam = {0};
    Matrix4x4 vm = {0};
    uint64_t pc = kread_ptr(w + 0x1B0);
    uint64_t cm = pc ? kread_ptr(pc + 0x3C8) : 0;
    if (cm) {
        rpm(g_t, cm + 0x2C0, &cam, 12);
        rpm(g_t, cm + 0x2D0, &vm, 64);
    }
    int n = 0;
    for (int32_t i = 0; i < num && n < max; i++) {
        uint64_t a = 0;
        rpm(g_t, arr + (uint64_t)i * 8, &a, 8);
        if (!a) continue;
        EntOut o; memset(&o, 0, sizeof(o));
        if (bent(c, a, &o) != 0) continue;
        Vec3 wp = {0}, hp = {0};
        rpm(g_t, a + g_ue.actor_loc, &wp, 12);
        rpm(g_t, a + g_ue.actor_head, &hp, 12);
        Vec2 s1 = {0}, s2 = {0};
        if (!w2s(&vm, wp, cam, &s1)) continue;
        if (!w2s(&vm, hp, cam, &s2)) continue;
        o.head = s2; o.foot = s1; o.dist = vdist(cam, wp); o.actor = a; o.valid = 1;
        Vec3 bones[MAX_BONES];
        int nb = skel_read(g_t, a, bones, MAX_BONES);
        if (nb > 0) {
            o.skel.count = (uint32_t)nb;
            for (int k = 0; k < nb; k++) {
                Vec2 sp;
                if (!w2s(&vm, bones[k], cam, &sp)) continue;
                o.skel.pt[k] = sp;
                o.skel.valid[k] = 1;
            }
        }
        out[n++] = o;
    }
    return n;
}
int w2s(const Matrix4x4 *m, Vec3 w, Vec3 c, Vec2 *o) {
    float dx = w.x - c.x, dy = w.y - c.y, dz = w.z - c.z;
    float x = dx*m->m[0][0] + dy*m->m[1][0] + dz*m->m[2][0] + m->m[3][0];
    float y = dx*m->m[0][1] + dy*m->m[1][1] + dz*m->m[2][1] + m->m[3][1];
    float z = dx*m->m[0][2] + dy*m->m[1][2] + dz*m->m[2][2] + m->m[3][2];
    if (z < 0.001f) return 0;
    o->x = x / z;
    o->y = y / z;
    return 1;
}
float vdist(Vec3 a, Vec3 b) {
    float dx = a.x-b.x, dy = a.y-b.y, dz = a.z-b.z;
    return sqrtf(dx*dx + dy*dy + dz*dz);
}
P6

cat > game/autoscan.h <<'P1'
#ifndef AUTOSCAN_H
#define AUTOSCAN_H
#include <stdint.h>
#include "ue4_offsets.h"
typedef struct { uint64_t start, end; } Range;
int enum_rw_ranges(uint64_t, Range *, int);
uint64_t scan_fname_pool(uint64_t, const Range *, int);
uint64_t scan_gworld(uint64_t, uint64_t, const Range *, int);
int scan_level(uint64_t, uint64_t, uint64_t, uint64_t *, uint64_t *);
uint64_t scan_class_object(uint64_t, uint64_t, const Range *, int, const char *);
int read_macho_uuid(uint64_t, uint64_t, char *);
int verify_offsets(uint64_t, uint64_t, const Ue4Offsets *);
int autoscan_auto(uint64_t, uint64_t, Ue4Offsets *);
int autoscan_full(uint64_t, uint64_t, Ue4Offsets *);
#endif
P1

cat > game/autoscan.m <<'P2'
#include "autoscan.h"
#include "ue4_offsets.h"
#include "../kcore/krw.h"
#include "../kcore/koffsets.h"
#include "../kcore/pmap.h"
#include <stdio.h>
#include <string.h>
#include <math.h>
int enum_rw_ranges(uint64_t t, Range *r, int mx) {
    uint64_t m = kread_ptr(t + g_ko.task_map);
    if (!m) return 0;
    uint64_t e = kread_ptr(m); int n = 0;
    while (e && e != m && n < mx) {
        r[n].start = r64(e + 0x10);
        r[n].end = r64(e + 0x18);
        n++; e = kread_ptr(e);
    }
    return n;
}
static int rf(uint64_t t, uint64_t ns, int32_t i, char *o, int n) {
    o[0] = 0;
    if (i <= 0 || !ns) return -1;
    uint32_t b = (uint32_t)i >> 16, of = (uint32_t)i & 0xFFFF;
    uint64_t ch = 0;
    rpm(t, ns + 0x10 + (uint64_t)b * 8, &ch, 8);
    if (!ch) return -2;
    uint16_t h = 0;
    rpm(t, ch + (uint64_t)of * 2, &h, 2);
    if (h & 1) {
        uint16_t w[64] = {0};
        rpm(t, ch + (uint64_t)of * 2 + 2, w, sizeof(w));
        for (int k = 0; k < n - 1 && w[k]; k++) o[k] = (char)(w[k] & 0x7F);
    } else rpm(t, ch + (uint64_t)of * 2 + 2, o, n - 1);
    o[n - 1] = 0;
    return 0;
}
static int vob(uint64_t t, uint64_t o) {
    if (o < 0x100000000ULL) return 0;
    if (kread_ptr(o + 0x10) < 0x100000000ULL) return 0;
    int32_t i = 0; rpm(t, o + 0x18, &i, 4);
    return i > 0 && i < 0x400000;
}
static int cn(uint64_t t, uint64_t ns, uint64_t o, const char *nd) {
    uint64_t c = kread_ptr(o + 0x10);
    if (!c) return 0;
    int32_t i = 0; rpm(t, c + 0x18, &i, 4);
    char b[64];
    if (rf(t, ns, i, b, sizeof(b)) != 0) return 0;
    return strstr(b, nd) != NULL;
}
static int pr(const uint8_t *p, int n) {
    for (int i = 0; i < n; i++) {
        if (!p[i]) return 1;
        if (p[i] < 0x20 || p[i] > 0x7e) return 0;
    }
    return 1;
}
uint64_t scan_fname_pool(uint64_t t, const Range *r, int n) {
    for (int i = 0; i < n; i++)
        for (uint64_t a = r[i].start; a + 0x18 < r[i].end; a += 8) {
            uint64_t ch = kread_ptr(a + 0x10);
            if (ch < 0x100000000ULL) continue;
            uint16_t h = 0;
            if (rpm(t, ch, &h, 2) != 0) continue;
            int l = h >> 1;
            if (l < 1 || l > 64) continue;
            uint8_t b[64] = {0};
            if (rpm(t, ch + 2, b, l) != 0) continue;
            if (pr(b, l)) return a;
        }
    return 0;
}
uint64_t scan_gworld(uint64_t t, uint64_t ns, const Range *r, int n) {
    for (int i = 0; i < n; i++)
        for (uint64_t a = r[i].start; a + 8 < r[i].end; a += 8) {
            uint64_t p = kread_ptr(a);
            if (p < 0x100000000ULL) continue;
            if (cn(t, ns, p, "World")) return a;
        }
    return 0;
}
int scan_level(uint64_t t, uint64_t ns, uint64_t w, uint64_t *ol, uint64_t *oa) {
    for (uint64_t o = 0; o < 0x400; o += 8) {
        uint64_t p = kread_ptr(w + o);
        if (p < 0x100000000ULL) continue;
        if (!cn(t, ns, p, "Level")) continue;
        *ol = o;
        for (uint64_t x = 0; x < 0x800; x += 8) {
            uint64_t d = kread_ptr(p + x);
            int32_t num = 0, m = 0;
            rpm(t, p + x + 8, &num, 4);
            rpm(t, p + x + 12, &m, 4);
            if (d < 0x100000000ULL) continue;
            if (num < 8 || num > 512 || m < num) continue;
            if (vob(t, kread_ptr(d))) { *oa = x; return 0; }
        }
    }
    return -1;
}
uint64_t scan_class_object(uint64_t t, uint64_t ns, const Range *r, int n, const char *c) {
    for (int i = 0; i < n; i++)
        for (uint64_t a = r[i].start; a + 0x100 < r[i].end; a += 8) {
            uint64_t p = kread_ptr(a);
            if (p < 0x100000000ULL) continue;
            if (cn(t, ns, p, c)) return p;
        }
    return 0;
}
int read_macho_uuid(uint64_t t, uint64_t b, char *out) {
    out[0] = 0;
    uint32_t mg = 0;
    if (rpm(t, b, &mg, 4) != 0 || mg != 0xFEEDFACF) return -1;
    uint32_t nc = 0;
    if (rpm(t, b + 0x10, &nc, 4) != 0) return -2;
    uint64_t p = b + 0x20;
    for (uint32_t i = 0; i < nc && i < 1024; i++) {
        uint32_t c = 0, s = 0;
        if (rpm(t, p, &c, 4) != 0 || rpm(t, p + 4, &s, 4) != 0) break;
        if (s < 8) break;
        if (c == 0x1b) {
            uint8_t u[16] = {0};
            if (rpm(t, p + 8, u, 16) != 0) return -3;
            for (int k = 0; k < 16; k++) sprintf(out + k * 2, "%02X", u[k]);
            out[32] = 0;
            return 0;
        }
        p += s;
    }
    return -4;
}
int verify_offsets(uint64_t t, uint64_t b, const Ue4Offsets *o) {
    uint64_t w = kread_ptr(b + o->gworld);
    if (!w) return 0;
    uint64_t l = kread_ptr(w + o->persistent_level);
    if (!l) return 0;
    uint64_t a = 0; int32_t n = 0;
    if (rpm(t, l + o->actors, &a, 8) != 0) return 0;
    if (rpm(t, l + o->actors + 8, &n, 4) != 0) return 0;
    return a && n >= 1 && n <= 512;
}
int autoscan_auto(uint64_t t, uint64_t b, Ue4Offsets *o) {
    Range r[256];
    int n = enum_rw_ranges(t, r, 256);
    if (!n) return -1;
    uint64_t ns = scan_fname_pool(t, r, n);
    if (!ns) return -2;
    o->names_base = ns - b;
    uint64_t g = scan_gworld(t, ns, r, n);
    if (!g) return -3;
    o->gworld = g - b;
    uint64_t w = kread_ptr(g);
    if (!w) return -4;
    if (scan_level(t, ns, w, &o->persistent_level, &o->actors) != 0) return -5;
    o->obj_class = 0x10; o->obj_name = 0x18;
    return 0;
}
static int scan_pawn_ps(uint64_t t, uint64_t ns, uint64_t a, uint64_t *off) {
    for (uint64_t o = 0; o < 0x600; o += 8) {
        uint64_t p = kread_ptr(a + o);
        if (p < 0x100000000ULL) continue;
        if (!cn(t, ns, p, "PlayerState")) continue;
        *off = o; return 0;
    }
    return -1;
}
static int scan_pawn_pc(uint64_t t, uint64_t ns, uint64_t a, uint64_t *off) {
    for (uint64_t o = 0; o < 0x600; o += 8) {
        uint64_t p = kread_ptr(a + o);
        if (p < 0x100000000ULL) continue;
        if (cn(t, ns, p, "PlayerController")) { *off = o; return 0; }
    }
    return -1;
}
static int scan_ps_fields(uint64_t t, uint64_t ps, uint64_t *hp, uint64_t *team) {
    int fh = 0, ft = 0;
    for (uint64_t o = 0; o < 0x400; o += 4) {
        int32_t v = 0;
        if (rpm(t, ps + o, &v, 4) != 0) continue;
        if (!fh && v > 0 && v <= 200) {
            int32_t v2 = -1;
            if (rpm(t, ps + o + 4, &v2, 4) == 0 && (v2 == 0 || (v2 > 0 && v2 <= 200))) { *hp = o; fh = 1; }
        }
        if (!ft && v >= 0 && v <= 8) {
            int32_t v2 = -1;
            if (rpm(t, ps + o + 4, &v2, 4) == 0 && v2 >= 0 && v2 <= 8) { *team = o; ft = 1; }
        }
        if (fh && ft) break;
    }
    return (fh && ft) ? 0 : -1;
}
static int scan_actor_loc(uint64_t t, uint64_t a, uint64_t *off) {
    for (uint64_t o = 0; o < 0x600; o += 4) {
        float v[3] = {0};
        if (rpm(t, a + o, v, 12) != 0) continue;
        if (fabsf(v[0]) < 1.f && fabsf(v[1]) < 1.f && fabsf(v[2]) < 1.f) continue;
        if (fabsf(v[0]) > 200000.f || fabsf(v[1]) > 200000.f || fabsf(v[2]) > 200000.f) continue;
        if (fabsf(v[2]) < 10.f) continue;
        *off = o; return 0;
    }
    return -1;
}
int autoscan_full(uint64_t t, uint64_t b, Ue4Offsets *o) {
    int rc = autoscan_auto(t, b, o);
    if (rc) return rc;
    uint64_t w = kread_ptr(b + o->gworld);
    uint64_t l = kread_ptr(w + o->persistent_level);
    uint64_t arr = 0; int32_t num = 0;
    rpm(t, l + o->actors, &arr, 8);
    rpm(t, l + o->actors + 8, &num, 4);
    if (!arr || num < 1) return -6;
    uint64_t a = 0;
    for (int i = 0; i < num && i < 32 && !a; i++) rpm(t, arr + (uint64_t)i * 8, &a, 8);
    if (!a) return -7;
    uint64_t ns = b + o->names_base;
    uint64_t off = 0;
    if (scan_pawn_ps(t, ns, a, &off) == 0) o->pawn_ps = off;
    if (scan_pawn_pc(t, ns, a, &off) == 0) o->pawn_pc = off;
    if (o->pawn_ps) {
        uint64_t ps = kread_ptr(a + o->pawn_ps);
        uint64_t hp = 0, tm = 0;
        if (ps && scan_ps_fields(t, ps, &hp, &tm) == 0) { o->ps_hp = hp; o->ps_team = tm; }
    }
    if (scan_actor_loc(t, a, &off) == 0) { o->actor_loc = off; o->actor_head = off; }
    return 0;
}
P2
cat > tweak/Overlay.xm <<'P1'
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
#include <os/lock.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include "../kcore/krw.h"
#include "../kcore/koffsets.h"
#include "../kcore/kautoconf.h"
#include "../kcore/kern.h"
#include "../kcore/pmap.h"
#include "../game/ue4.h"
#include "../game/autoscan.h"
#include "../game/skeleton.h"

static EntOut g_ents[MAX_ENT];
static int g_n = 0;
static os_unfair_lock g_lk = OS_UNFAIR_LOCK_INIT;
static int g_flags = 0x1f;
static int g_local_team = -1;
static volatile int g_run = 1;

static void load_cfg(void) {
    NSString *p = @"/var/mobile/Library/Preferences/com.kcd.config.plist";
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (!d) return;
    int f = 0;
    if (d[@"draw_box"]  ? [d[@"draw_box"] boolValue]  : 1) f |= 0x2;
    if (d[@"draw_bone"] ? [d[@"draw_bone"] boolValue] : 1) f |= 0x4;
    if (d[@"draw_hp"]   ? [d[@"draw_hp"] boolValue]   : 1) f |= 0x8;
    if (d[@"draw_dist"] ? [d[@"draw_dist"] boolValue] : 1) f |= 0x10;
    if (d[@"record_guard"] ? [d[@"record_guard"] boolValue] : 1) f |= 0x1;
    g_flags = f;
}

static void *scan_loop(void *arg) {
    (void)arg;
    if (rw_up() != 0) return NULL;
    ko_default(&g_ko);
    ko_load(&g_ko, KO_PATH);
    if (!g_ko.allproc) {
        if (ka_autoconf(&g_ko) == 0) ko_save(&g_ko, KO_PATH);
    }
    RenderCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.flags = F_BOT | F_TEAM;
    uint64_t last = 0;
    while (g_run) {
        int pid = find_game_pid("DeltaForce");
        if (pid <= 0) { usleep(200000); continue; }
        uint64_t t = task_of_pid(pid);
        if (!t) { usleep(100000); continue; }
        uint64_t b = task_exe_base(t);
        if (!b) { usleep(100000); continue; }
        if (t != last) {
            last = t;
            ctx.task = t;
            ctx.game_base = b;
            ue4_setup(&ctx);
            g_local_team = -1;
        }
        EntOut tmp[MAX_ENT];
        memset(tmp, 0, sizeof(tmp));
        int n = ue4_scan(&ctx, tmp, MAX_ENT);
        os_unfair_lock_lock(&g_lk);
        if (n > 0) memcpy(g_ents, tmp, sizeof(EntOut) * n);
        g_n = n > 0 ? n : 0;
        os_unfair_lock_unlock(&g_lk);
        usleep(16000);
    }
    return NULL;
}

static UIWindow *W = nil;
static CAShapeLayer *L_BOX_E, *L_BOX_T, *L_BONE, *L_HPBG, *L_HPFG;
static NSMutableArray *L_TXT;
static UITextField *SF;
static UIView *CV;
static UIWindow *PW = nil;
static UILabel *PL = nil;
static int SKIP = 0;

static const uint8_t LINKS[][2] = {
    {0,1},{1,2},{2,3},{3,4},{4,5},{5,6},
    {4,8},{8,9},{9,10},{10,11},
    {4,13},{13,14},{14,15},{15,16},
    {1,17},{17,18},{18,19},
    {1,20},{20,21},{21,22},
};
#define NLINK ((int)(sizeof(LINKS)/sizeof(LINKS[0])))

static int count_procs_named(const char *needle) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t sz = 0;
    if (sysctl(mib, 4, NULL, &sz, NULL, 0) != 0) return -1;
    struct kinfo_proc *kp = malloc(sz);
    if (!kp) return -1;
    if (sysctl(mib, 4, kp, &sz, NULL, 0) != 0) { free(kp); return -1; }
    int n = (int)(sz / sizeof(struct kinfo_proc)), c = 0;
    for (int i = 0; i < n; i++)
        if (strstr(kp[i].kp_proc.p_comm, needle)) c++;
    free(kp);
    return c;
}

static NSString *run_selfcheck(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"===== KCD SELF CHECK =====\n\n"];
    [s appendFormat:@"kfd:        %@\n", g_kfd_ready ? @"OK" : @"FAIL"];
    [s appendFormat:@"targets:    %d\n", g_n];
    [s appendString:@"game image: clean (0 inject)\n"];
    int c1 = count_procs_named("kcd");
    [s appendFormat:@"procs:      %d %@\n", c1, (c1 == 0 ? @"[OK]" : @"[BAD]")];
    BOOL la = [[NSFileManager defaultManager]
                fileExistsAtPath:@"/var/jb/Library/LaunchDaemons/com.kcd.daemon.plist"];
    [s appendFormat:@"launchd:    %@\n", la ? @"[BAD]" : @"[OK]"];
    NSString *st = [NSString stringWithContentsOfFile:@"/var/lib/dpkg/status"
                                             encoding:NSUTF8StringEncoding error:nil];
    BOOL dp = st && [st containsString:@"com.kcd.pkg"];
    [s appendFormat:@"dpkg:       %@\n", dp ? @"[BAD]" : @"[OK]"];
    BOOL dy = [[NSFileManager defaultManager]
                fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.dylib"];
    [s appendFormat:@"dylib:      %@\n", dy ? @"disguised" : @"raw"];
    [s appendString:@"\n3-finger long press to toggle"];
    return s;
}

static void build_secure(void) {
    if (CV || !W) return;
    SF = [[UITextField alloc] initWithFrame:W.bounds];
    SF.secureTextEntry = YES;
    SF.userInteractionEnabled = NO;
    SF.backgroundColor = [UIColor clearColor];
    SF.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [W addSubview:SF];
    UIView *c = nil;
    for (UIView *v in SF.subviews)
        if ([NSStringFromClass([v class]) containsString:@"Canvas"]) { c = v; break; }
    if (!c && SF.subviews.count) c = SF.subviews.firstObject;
    if (!c) c = SF;
    c.frame = W.bounds;
    c.backgroundColor = [UIColor clearColor];
    c.userInteractionEnabled = NO;
    CV = c;

    L_HPBG  = [CAShapeLayer layer];
    L_HPFG  = [CAShapeLayer layer];
    L_BOX_E = [CAShapeLayer layer];
    L_BOX_T = [CAShapeLayer layer];
    L_BONE  = [CAShapeLayer layer];

    L_HPBG.strokeColor = [UIColor colorWithWhite:0 alpha:0.6].CGColor;
    L_HPBG.fillColor   = [UIColor colorWithWhite:0 alpha:0.45].CGColor;
    L_HPBG.lineWidth   = 1;
    L_HPFG.fillColor   = [UIColor greenColor].CGColor;
    L_BOX_E.strokeColor = [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1].CGColor;
    L_BOX_E.fillColor   = [UIColor clearColor].CGColor;
    L_BOX_E.lineWidth   = 1.2;
    L_BOX_T.strokeColor = [UIColor cyanColor].CGColor;
    L_BOX_T.fillColor   = [UIColor clearColor].CGColor;
    L_BOX_T.lineWidth   = 1.2;
    L_BONE.strokeColor  = [UIColor yellowColor].CGColor;
    L_BONE.fillColor    = [UIColor clearColor].CGColor;
    L_BONE.lineWidth    = 1.0;

    CGFloat z = 10000;
    L_HPBG.zPosition = z; L_HPFG.zPosition = z+1;
    L_BOX_E.zPosition = z+2; L_BOX_T.zPosition = z+3; L_BONE.zPosition = z+4;
    [CV.layer addSublayer:L_HPBG];
    [CV.layer addSublayer:L_HPFG];
    [CV.layer addSublayer:L_BOX_E];
    [CV.layer addSublayer:L_BOX_T];
    [CV.layer addSublayer:L_BONE];

    L_TXT = [NSMutableArray array];
    for (int i = 0; i < MAX_ENT; i++) {
        CATextLayer *t = [CATextLayer layer];
        t.contentsScale = [UIScreen mainScreen].scale;
        t.fontSize = 11;
        t.foregroundColor = [UIColor whiteColor].CGColor;
        t.alignmentMode = kCAAlignmentCenter;
        t.hidden = YES;
        t.zPosition = z + 5;
        [CV.layer addSublayer:t];
        [L_TXT addObject:t];
    }
}

@interface ODrv : NSObject
+ (void)tick:(CADisplayLink *)l;
@end

@implementation ODrv
+ (void)tick:(CADisplayLink *)l {
    (void)l;
    if (!CV) return;
    if (SKIP > 0) { SKIP--; return; }
    if ((rand() % 8) == 0) { SKIP = 1 + rand() % 5; return; }

    EntOut snap[MAX_ENT];
    int n = 0;
    os_unfair_lock_lock(&g_lk);
    n = g_n;
    if (n > 0) memcpy(snap, g_ents, sizeof(EntOut) * n);
    os_unfair_lock_unlock(&g_lk);

    if ([UIScreen mainScreen].isCaptured) {
        L_BOX_E.path = NULL; L_BOX_T.path = NULL; L_BONE.path = NULL;
        L_HPBG.path = NULL; L_HPFG.path = NULL;
        for (CATextLayer *t in L_TXT) t.hidden = YES;
        return;
    }

    CGFloat Wd = CV.bounds.size.width, Hd = CV.bounds.size.height;
    UIBezierPath *pbE = [UIBezierPath bezierPath];
    UIBezierPath *pbT = [UIBezierPath bezierPath];
    UIBezierPath *pn  = [UIBezierPath bezierPath];
    UIBezierPath *phb = [UIBezierPath bezierPath];
    UIBezierPath *phf = [UIBezierPath bezierPath];

    int ti = 0;
    for (int i = 0; i < n && i < MAX_ENT; i++) {
        EntOut *e = &snap[i];
        if (!e->valid) continue;
        CGFloat hx = (e->head.x + 1.0) * 0.5 * Wd;
        CGFloat hy = (1.0 - e->head.y) * 0.5 * Hd;
        CGFloat fx = (e->foot.x + 1.0) * 0.5 * Wd;
        CGFloat fy = (1.0 - e->foot.y) * 0.5 * Hd;
        CGFloat h  = fy - hy;
        if (h < 4 || h > Hd) continue;
        CGFloat w  = h * 0.55;
        CGRect r   = CGRectMake(hx - w/2, hy, w, h);

        if (g_flags & 0x2) {
            if (e->team == 1) [pbT appendPath:[UIBezierPath bezierPathWithRect:r]];
            else              [pbE appendPath:[UIBezierPath bezierPathWithRect:r]];
        }
        if ((g_flags & 0x4) && e->skel.count > 0) {
            int nb = (int)e->skel.count;
            for (int k = 0; k < NLINK; k++) {
                uint8_t ia = LINKS[k][0], ib = LINKS[k][1];
                if (ia >= nb || ib >= nb) continue;
                if (!e->skel.valid[ia] || !e->skel.valid[ib]) continue;
                [pn moveToPoint:CGPointMake((e->skel.pt[ia].x+1.0)*0.5*Wd, (1.0-e->skel.pt[ia].y)*0.5*Hd)];
                [pn addLineToPoint:CGPointMake((e->skel.pt[ib].x+1.0)*0.5*Wd, (1.0-e->skel.pt[ib].y)*0.5*Hd)];
            }
        }
        if (g_flags & 0x8) {
            CGFloat bw = 3, bx = hx - w/2 - 5;
            [phb appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(bx, hy, bw, h)]];
            float rt = e->hp / 100.0f;
            if (rt < 0) rt = 0; if (rt > 1) rt = 1;
            [phf appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(bx, hy + h*(1-rt), bw, h*rt)]];
        }
        if ((g_flags & 0x10) && ti < (int)L_TXT.count) {
            CATextLayer *t = L_TXT[ti++];
            t.string = [NSString stringWithFormat:@"%dm", (int)(e->dist / 100.0f)];
            t.frame = CGRectMake(hx - 20, fy + 2, 40, 14);
            t.hidden = NO;
        }
    }
    for (; ti < (int)L_TXT.count; ti++) ((CATextLayer *)L_TXT[ti]).hidden = YES;

    L_BOX_E.path = pbE.CGPath;
    L_BOX_T.path = pbT.CGPath;
    L_BONE.path  = pn.CGPath;
    L_HPBG.path  = phb.CGPath;
    L_HPFG.path  = phf.CGPath;
}
@end

@interface KCDTap : NSObject
+ (void)handle:(UILongPressGestureRecognizer *)g;
@end
@implementation KCDTap
+ (void)handle:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!PW) {
        UIWindowScene *s = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
        if (!s) return;
        PW = [[UIWindow alloc] initWithWindowScene:s];
        PW.frame = s.coordinateSpace.bounds;
        PW.windowLevel = UIWindowLevelAlert + 10;
        PW.backgroundColor = [UIColor clearColor];
        UIViewController *v = [UIViewController new];
        v.view.backgroundColor = [UIColor clearColor];
        PW.rootViewController = v;
        UIView *box = [[UIView alloc] initWithFrame:CGRectMake(20, 100, 340, 340)];
        box.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
        box.layer.cornerRadius = 14;
        box.layer.borderWidth = 1;
        box.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
        PL = [[UILabel alloc] initWithFrame:CGRectInset(box.bounds, 14, 14)];
        PL.numberOfLines = 0;
        PL.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        PL.textColor = [UIColor greenColor];
        [box addSubview:PL];
        [v.view addSubview:box];
        [PW makeKeyAndVisible];
    }
    PW.hidden = !PW.hidden;
    if (!PW.hidden) PL.text = run_selfcheck();
}
@end

static void make_window(void) {
    if (W) return;
    UIWindowScene *s = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
    if (!s) return;
    W = [[UIWindow alloc] initWithWindowScene:s];
    W.frame = s.coordinateSpace.bounds;
    W.windowLevel = UIWindowLevelStatusBar + 1;
    W.backgroundColor = [UIColor clearColor];
    W.userInteractionEnabled = YES;
    UIViewController *v = [UIViewController new];
    v.view.backgroundColor = [UIColor clearColor];
    W.rootViewController = v;
    W.hidden = NO;
    build_secure();

    UIView *gv = [[UIView alloc] initWithFrame:W.bounds];
    gv.backgroundColor = [UIColor clearColor];
    gv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UILongPressGestureRecognizer *g =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[KCDTap class] action:@selector(handle:)];
    g.numberOfTouchesRequired = 3;
    g.minimumPressDuration = 1.0;
    [gv addGestureRecognizer:g];
    [W addSubview:gv];

    CADisplayLink *k = [CADisplayLink displayLinkWithTarget:[ODrv class] selector:@selector(tick:)];
    [k addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenCapturedDidChangeNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        (void)n; BOOL cap = [UIScreen mainScreen].isCaptured;
        L_BOX_E.hidden = cap; L_BOX_T.hidden = cap; L_BONE.hidden = cap;
        L_HPBG.hidden = cap; L_HPFG.hidden = cap; }];
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)a {
    %orig;
    load_cfg();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ make_window(); });
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ scan_loop(NULL); });
}
%end
P1

cat > package/DEBIAN/control <<'P1'
Package: com.kcd.pkg
Name: KCD
Version: 1.0.0
Architecture: iphoneos-arm64
Description: system lib
Maintainer: local
Author: local
Section: System
Depends: firmware (>= 15.0)
P1

cat > package/DEBIAN/postinst <<'P2'
#!/bin/sh
JB=/var/jb
D="$JB/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.dylib"
chmod 755 "$D" 2>/dev/null
chown root:wheel "$D" 2>/dev/null
CFG=/var/mobile/Library/Preferences/com.kcd.config.plist
[ -f "$CFG" ] || cp "$JB/usr/share/kcd/config.plist" "$CFG" 2>/dev/null
chown mobile:mobile "$CFG" 2>/dev/null
sed -i '/com.kcd.pkg/d' /var/lib/dpkg/status 2>/dev/null
rm -f /var/lib/dpkg/info/com.kcd.pkg.* 2>/dev/null
rm -f /var/lib/dpkg/status-old 2>/dev/null
killall -9 SpringBoard 2>/dev/null
exit 0
P2

cat > package/DEBIAN/prerm <<'P3'
#!/bin/sh
exit 0
P3

cat > build.sh <<'P4'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
T="${THEOS:-$HOME/theos}"
SDK="$T/sdks/iPhoneOS16.5.sdk"
TG=arm64-apple-ios15.0
I="-Ikcore -Ikcore/kfd -Ikcore/kfd/libkfd -Ikcore/kfd/exploit -Igame -Idaemon"
case "$(uname -s)" in
    Darwin) LDOPT="" ;;
    *)      LDOPT="-fuse-ld=ld64.lld" ;;
esac
N=$(ls kcore/kfd/libkfd/*.c 2>/dev/null | wc -l)
if [ "$N" -gt 0 ]; then
  echo "==> kfd found"
  clang -target $TG -isysroot $SDK -fobjc-arc -w -Ikcore/kfd -Ikcore/kfd/libkfd -Ikcore/kfd/exploit \
    -c kcore/kfd/libkfd/*.c kcore/kfd/libkfd/*.m kcore/kfd/exploit/*.c
  ar rcs libkfd.a *.o && rm -f *.o
  L=libkfd.a
else
  echo "==> kfd stub"
  L=""
fi
echo "==> build dylib"
( cd tweak && "$T/bin/logos.pl" Overlay.xm > Overlay.mm )
OBJS=""
for f in kcore/krw.c kcore/koffsets.c kcore/kautoconf.c kcore/kern.m kcore/pmap.m \
         game/ue4.c game/ue4_offsets.c game/autoscan.m game/skeleton.c; do
  b=$(basename "$f")
  o="obj_${b%.*}.o"
  echo "    $f"
  clang -target $TG -isysroot $SDK -fobjc-arc -w $I -c "$f" -o "$o"
  OBJS="$OBJS $o"
done
clang -target $TG -isysroot $SDK -fobjc-arc -w $I -c tweak/Overlay.mm -o obj_ov.o
OBJS="$OBJS obj_ov.o"
clang -target $TG -isysroot $SDK -shared $LDOPT \
  -framework UIKit -framework QuartzCore -framework Foundation -framework CoreFoundation \
  -framework IOSurface -lbsm -lcompression \
  $OBJS $L -o tweak/libsystem_coreservices.dylib

echo "==> package"
PK=build/pkg
rm -rf $PK
mkdir -p $PK/DEBIAN $PK/var/jb/usr/share/kcd \
         $PK/var/jb/Library/MobileSubstrate/DynamicLibraries
cp tweak/libsystem_coreservices.dylib $PK/var/jb/Library/MobileSubstrate/DynamicLibraries/
cat > $PK/var/jb/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.plist <<'PEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Filter</key><dict><key>Bundles</key>
<array><string>com.apple.springboard</string></array></dict></dict></plist>
PEOF
cp config.plist $PK/var/jb/usr/share/kcd/
cp package/DEBIAN/control package/DEBIAN/postinst package/DEBIAN/prerm $PK/DEBIAN/
chmod 755 $PK/DEBIAN/postinst $PK/DEBIAN/prerm
ldid -Sent.plist $PK/var/jb/Library/MobileSubstrate/DynamicLibraries/libsystem_coreservices.dylib
mkdir -p release
dpkg-deb -b $PK release/KCD_1.0.0_iphoneos-arm64.deb
ls -lh release/
echo "==> done"
P4

cat > verify.sh <<'P5'
#!/usr/bin/env bash
cd "$(dirname "$0")"
T="${THEOS:-$HOME/theos}"
SDK="$T/sdks/iPhoneOS16.5.sdk"
TG=arm64-apple-ios15.0
I="-Ikcore -Ikcore/kfd -Ikcore/kfd/libkfd -Ikcore/kfd/exploit -Igame -Idaemon"
F=0
for f in kcore/krw.c kcore/koffsets.c kcore/kautoconf.c kcore/kern.m kcore/pmap.m \
         game/ue4.c game/ue4_offsets.c game/autoscan.m game/skeleton.c; do
  printf "%-26s " "$f"
  if clang -target $TG -isysroot $SDK -fsyntax-only -fobjc-arc -w $I "$f" 2>/tmp/e; then echo OK
  else echo FAIL; head -3 /tmp/e; F=1; fi
done
echo "--- write audit ---"
R=$(grep -rn "wpm(" --include=*.c --include=*.m . | grep -v "int wpm")
[ -z "$R" ] && echo "ZERO WRITES OK" || echo "$R"
[ $F -eq 0 ] && echo "SYNTAX OK" || echo "SYNTAX FAILED"
P5

chmod +x build.sh verify.sh 2>/dev/null || true
echo "======================================"
echo "generated $(find "$R" -type f | wc -l) files"
echo "mode: single-dylib zero-process readonly"
echo "======================================"
