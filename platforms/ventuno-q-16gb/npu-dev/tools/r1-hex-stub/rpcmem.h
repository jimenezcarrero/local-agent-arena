#pragma once
// R1 support harness stub: declarations only; the harness defines them to abort.
#ifdef __cplusplus
extern "C" {
#endif
#define RPCMEM_HEAP_ID_SYSTEM 25
#define RPCMEM_DEFAULT_FLAGS 1
void * rpcmem_alloc2(int heapid, unsigned int flags, size_t size);
void   rpcmem_free(void * po);
int    rpcmem_to_fd(void * po);
#ifdef __cplusplus
}
#endif
