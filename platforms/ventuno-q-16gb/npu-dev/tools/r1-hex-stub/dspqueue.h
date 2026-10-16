#pragma once
// R1 support harness stub: declarations only; the harness defines them to abort.
#include <stdint.h>
#include "remote.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef void * dspqueue_t;
#define DSPQUEUE_TIMEOUT_NONE 0xffffffff
#define DSPQUEUE_BUFFER_FLAG_FLUSH_SENDER 1
#define DSPQUEUE_BUFFER_FLAG_INVALIDATE_RECIPIENT 2
struct dspqueue_buffer { uint32_t fd; uint32_t size; uint32_t offset; uint32_t flags; void * ptr; };
typedef void (*dspqueue_callback_t)(dspqueue_t, int, void *);
int dspqueue_create(int domain, uint32_t flags, uint32_t req_size, uint32_t resp_size, dspqueue_callback_t pkt, dspqueue_callback_t err, void * ctx, dspqueue_t * q);
int dspqueue_close(dspqueue_t q);
int dspqueue_export(dspqueue_t q, uint64_t * id);
int dspqueue_write(dspqueue_t q, uint32_t flags, uint32_t nb, struct dspqueue_buffer * b, uint32_t ms, const uint8_t * m, uint32_t t);
int dspqueue_read(dspqueue_t q, uint32_t * flags, uint32_t mb, uint32_t * nb, struct dspqueue_buffer * b, uint32_t mm, uint32_t * ml, uint8_t * m, uint32_t t);
#ifdef __cplusplus
}
#endif
