#pragma once
// R1 support harness stub of the qaic-generated interface (htp/htp_iface.idl at af0579c78): declarations only.
#include <stdint.h>
#include "remote.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct htp_iface_pmu_conf { uint32_t events[8]; } htp_iface_pmu_conf;
extern const char * htp_iface_URI;
int htp_iface_open(const char * uri, remote_handle64 * h);
int htp_iface_close(remote_handle64 h);
int htp_iface_start(remote_handle64 h, uint32_t sess_id, uint64_t dsp_queue_id, uint32_t n_hvx, uint32_t n_hmx, uint64_t max_vmem, uint32_t power_mode);
int htp_iface_stop(remote_handle64 h);
int htp_iface_mmap(remote_handle64 h, uint32_t fd, uint64_t size);
int htp_iface_munmap(remote_handle64 h, uint32_t fd);
int htp_iface_profiler(remote_handle64 h, uint32_t mode, const htp_iface_pmu_conf * pmu);
int htp_iface_etm(remote_handle64 h, uint32_t enable);
int htp_iface_hwinfo(remote_handle64 h, unsigned int * n_threads, unsigned int * n_hvx, unsigned int * n_hmx, unsigned long long * vtcm_size);
#ifdef __cplusplus
}
#endif
