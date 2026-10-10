// dspq_probe.c (D123) — diagnostic shim for the NPU hang. Built as a library named libcdsprpc.so and put first on
// LD_LIBRARY_PATH: ggml-hexagon dlopen()s "libcdsprpc.so" by name and resolves every FastRPC function with dlsym() on
// that handle, which searches this library and then its dependency, the real /lib/aarch64-linux-gnu/libcdsprpc.so.1.
// Only dspqueue_create/_write/_read are wrapped (counted, then forwarded unchanged); everything else resolves to the
// real library. A watcher thread checks once a second: when a queue has requests outstanding (writes > reads) and no
// read has succeeded on it for V0F_STALL_S seconds (default 60), it writes one snapshot of EVERY queue to
// $V0F_DUMP_DIR/qstat-<pid>-<n>.txt: host writes/reads, seconds since the last successful read, and dspqueue_get_stat
// WRITE_QUEUE_PACKETS (requests the DSP has not read yet) and READ_QUEUE_PACKETS (responses the host has not read).
// Reading: a stuck session with WRITE_QUEUE_PACKETS > 0 means the DSP side has not dequeued the request (the cause, a
// missed signal or a consumer thread that is blocked or gone, is not visible from the host); 0 means the DSP took it and
// has not answered. No behaviour change otherwise.
// Opt-in workaround (D124): with V0F_KICK_S=<s>, when a queue has an outstanding request that the DSP has not read
// (WRITE_QUEUE_PACKETS > 0) and no read has succeeded on it for <s> seconds, the watcher writes one early-wakeup packet
// (dspqueue_write_early_wakeup_noblock; writes are serialized by the queue mutex). The intent: a new packet changes the
// queue's write count, which should make a DSP-side consumer that missed a signal run again; the host reader consumes
// wakeup packets internally. In the D124 check it was ineffective (no packet was dequeued); this does not show why.
// Each kick is logged to $V0F_DUMP_DIR/kicks-<pid>.txt with the queue counters before it.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

typedef int AEEResult;
typedef void * dspqueue_t;
typedef void (*dspqueue_callback_t)(dspqueue_t, AEEResult, void *);
struct dspqueue_buffer;

#define MAXQ 16
static struct { dspqueue_t q; _Atomic uint64_t writes, reads; _Atomic int64_t last_read_ms; } Q[MAXQ];
static _Atomic int nq;  // published slots: Q[0..nq) are fully initialized
static pthread_mutex_t reg_lock = PTHREAD_MUTEX_INITIALIZER;
static void * real;
static AEEResult (*r_create)(int, uint32_t, uint32_t, uint32_t, dspqueue_callback_t, dspqueue_callback_t, void *, dspqueue_t *);
static AEEResult (*r_write)(dspqueue_t, uint32_t, uint32_t, struct dspqueue_buffer *, uint32_t, const uint8_t *, uint32_t);
static AEEResult (*r_read)(dspqueue_t, uint32_t *, uint32_t, uint32_t *, struct dspqueue_buffer *, uint32_t, uint32_t *, uint8_t *, uint32_t);
static AEEResult (*r_stat)(dspqueue_t, int, uint64_t *);
static AEEResult (*r_wake)(dspqueue_t, uint32_t, uint32_t);
static _Atomic int64_t last_kick_ms[MAXQ];

static int64_t now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000LL + t.tv_nsec / 1000000; }

static void * watcher(void * arg) {
    (void) arg;
    const char * dir = getenv("V0F_DUMP_DIR"); const char * s = getenv("V0F_STALL_S");  // dir is also used for kick logs
    int64_t stall_ms = (s ? atoll(s) : 60) * 1000; int dumps = 0; int64_t armed_ms = 0;
    const char * k = getenv("V0F_KICK_S"); int64_t kick_ms = k ? atoll(k) * 1000 : 0;
    for (;;) {
        usleep(kick_ms ? 250000 : 1000000);
        int n = atomic_load_explicit(&nq, memory_order_acquire), stuck = -1; int64_t t = now_ms();
        for (int i = 0; kick_ms && r_wake && r_stat && i < n; i++) {
            uint64_t w = atomic_load(&Q[i].writes), r = atomic_load(&Q[i].reads), wq = 0;
            if (w <= r || t - atomic_load(&Q[i].last_read_ms) < kick_ms || t - atomic_load(&last_kick_ms[i]) < kick_ms) continue;
            if (r_stat(Q[i].q, 3 /* WRITE_QUEUE_PACKETS */, &wq) != 0 || wq == 0) continue;
            int rc = r_wake(Q[i].q, 0, 0); atomic_store(&last_kick_ms[i], t);
            if (dir) { char kp[512]; snprintf(kp, sizeof kp, "%s/kicks-%d.txt", dir, (int) getpid()); FILE * kf = fopen(kp, "a");
                if (kf) { fprintf(kf, "%lld queue %d writes %llu reads %llu since_last_read_s %.1f write_queue_packets %llu wakeup_rc %d\n",
                                  (long long) time(NULL), i, (unsigned long long) w, (unsigned long long) r,
                                  (t - atomic_load(&Q[i].last_read_ms)) / 1000.0, (unsigned long long) wq, rc); fclose(kf); } }
        }
        for (int i = 0; i < n; i++)
            if (atomic_load(&Q[i].writes) > atomic_load(&Q[i].reads) && t - atomic_load(&Q[i].last_read_ms) > stall_ms) { stuck = i; break; }
        if (stuck < 0 || !dir || dumps >= 3 || t - armed_ms < stall_ms) continue;
        armed_ms = t;  // at most one snapshot per stall period, three in all
        char path[512]; snprintf(path, sizeof path, "%s/qstat-%d-%d.txt", dir, (int) getpid(), ++dumps);
        FILE * f = fopen(path, "w"); if (!f) continue;
        fprintf(f, "# dspq_probe snapshot %d, pid %d, first stuck queue %d (stall threshold %lld s)\n", dumps, (int) getpid(), stuck, (long long) (stall_ms / 1000));
        fprintf(f, "queue writes reads outstanding since_last_read_s write_queue_packets read_queue_packets stat_rc\n");
        for (int i = 0; i < n; i++) {
            uint64_t wq = 0, rq = 0; int rc1 = r_stat ? r_stat(Q[i].q, 3 /* WRITE_QUEUE_PACKETS */, &wq) : -1;
            int rc2 = r_stat ? r_stat(Q[i].q, 1 /* READ_QUEUE_PACKETS */, &rq) : -1;
            uint64_t w = atomic_load(&Q[i].writes), r = atomic_load(&Q[i].reads);
            fprintf(f, "%d %llu %llu %lld %.1f %llu %llu %d/%d\n", i, (unsigned long long) w, (unsigned long long) r, (long long) (w - r),
                    (t - atomic_load(&Q[i].last_read_ms)) / 1000.0, (unsigned long long) wq, (unsigned long long) rq, rc1, rc2);
        }
        fclose(f);
    }
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    real = dlopen("/lib/aarch64-linux-gnu/libcdsprpc.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!real) { fprintf(stderr, "dspq_probe: cannot open the real libcdsprpc: %s\n", dlerror()); abort(); }
    r_create = dlsym(real, "dspqueue_create"); r_write = dlsym(real, "dspqueue_write");
    r_read = dlsym(real, "dspqueue_read"); r_stat = dlsym(real, "dspqueue_get_stat");
    r_wake = dlsym(real, "dspqueue_write_early_wakeup_noblock");
    if (!r_create || !r_write || !r_read) { fprintf(stderr, "dspq_probe: missing dspqueue symbols\n"); abort(); }
    pthread_t th; pthread_create(&th, NULL, watcher, NULL); pthread_detach(th);
    fprintf(stderr, "dspq_probe: active (dump dir %s, stall %s s, get_stat %s, kick %s s, wakeup %s)\n", getenv("V0F_DUMP_DIR") ? getenv("V0F_DUMP_DIR") : "unset",
            getenv("V0F_STALL_S") ? getenv("V0F_STALL_S") : "60", r_stat ? "yes" : "no", getenv("V0F_KICK_S") ? getenv("V0F_KICK_S") : "off", r_wake ? "yes" : "no");
}

static int slot_of(dspqueue_t q) { int n = atomic_load_explicit(&nq, memory_order_acquire); for (int i = 0; i < n; i++) if (Q[i].q == q) return i; return -1; }

AEEResult dspqueue_create(int domain, uint32_t flags, uint32_t rqs, uint32_t sqs, dspqueue_callback_t pcb, dspqueue_callback_t ecb, void * ctx, dspqueue_t * queue) {
    AEEResult rc = r_create(domain, flags, rqs, sqs, pcb, ecb, ctx, queue);
    // D125 (Codex review of 892d7b9 finding 2): creation is serialized and a slot is published (nq, release) only after
    // its handle and clock are set, so the watcher and slot_of() (acquire loads of nq) never see a half-built slot.
    // Queues beyond MAXQ are not tracked.
    if (rc == 0) {
        pthread_mutex_lock(&reg_lock);
        int i = atomic_load_explicit(&nq, memory_order_relaxed);
        if (i < MAXQ) { Q[i].q = *queue; atomic_store(&Q[i].last_read_ms, now_ms()); atomic_store_explicit(&nq, i + 1, memory_order_release); }
        pthread_mutex_unlock(&reg_lock);
    }
    return rc;
}

AEEResult dspqueue_write(dspqueue_t q, uint32_t flags, uint32_t nb, struct dspqueue_buffer * b, uint32_t ml, const uint8_t * m, uint32_t to) {
    AEEResult rc = r_write(q, flags, nb, b, ml, m, to);
    int i = slot_of(q);
    if (rc == 0 && i >= 0) {  // a write onto an idle queue starts the stall clock
        if (atomic_load(&Q[i].writes) == atomic_load(&Q[i].reads)) atomic_store(&Q[i].last_read_ms, now_ms());
        atomic_fetch_add(&Q[i].writes, 1);
    }
    return rc;
}

AEEResult dspqueue_read(dspqueue_t q, uint32_t * flags, uint32_t mb, uint32_t * nb, struct dspqueue_buffer * b, uint32_t mml, uint32_t * ml, uint8_t * m, uint32_t to) {
    AEEResult rc = r_read(q, flags, mb, nb, b, mml, ml, m, to);
    int i = slot_of(q); if (rc == 0 && i >= 0) { atomic_fetch_add(&Q[i].reads, 1); atomic_store(&Q[i].last_read_ms, now_ms()); }
    return rc;
}
