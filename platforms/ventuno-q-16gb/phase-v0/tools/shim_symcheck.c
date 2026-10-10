// shim_symcheck.c (D125) — prints, for each FastRPC function ggml-hexagon resolves with dlsym() on dlopen("libcdsprpc.so")
// (htp-drv.cpp, 836d5717), the object that provides it under the current LD_LIBRARY_PATH: the shim (wrapped functions)
// or the real /lib/aarch64-linux-gnu/libcdsprpc.so.1 (everything else). A function the real library lacks too is reported
// as such (ggml-hexagon treats remote_system_request as optional). Exit 1 if the library is missing or a function the
// real library provides does not resolve.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

int main(void) {
    static const char * names[] = { "rpcmem_alloc", "rpcmem_alloc2", "rpcmem_free", "rpcmem_to_fd", "fastrpc_mmap",
        "fastrpc_munmap", "dspqueue_create", "dspqueue_close", "dspqueue_export", "dspqueue_write", "dspqueue_read",
        "dspqueue_read_noblock", "remote_handle64_open", "remote_handle64_invoke", "remote_handle_control",
        "remote_handle64_control", "remote_session_control", "remote_handle64_close", "remote_system_request" };
    void * h = dlopen("libcdsprpc.so", RTLD_NOW | RTLD_LOCAL);
    void * r = dlopen("/lib/aarch64-linux-gnu/libcdsprpc.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!h || !r) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    int bad = 0;
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
        void * p = dlsym(h, names[i]); Dl_info di = { 0 };
        if (!p && !dlsym(r, names[i])) { printf("%-24s absent (the real library lacks it too)\n", names[i]); continue; }
        if (!p || !dladdr(p, &di)) { printf("%-24s MISSING\n", names[i]); bad = 1; continue; }
        printf("%-24s %s\n", names[i], di.dli_fname);
    }
    return bad;
}
