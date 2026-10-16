#pragma once
// R1 support harness stub: declarations only; the harness defines them to abort.
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef uint64_t remote_handle64;
typedef enum { FASTRPC_MAP_FD = 2, FASTRPC_MAP_FD_DELAYED = 3, FASTRPC_MAP_FD_DELAYED_EXTENDED = 5 } fastrpc_map_flags;
#define CDSP_DOMAIN_ID 3
#define CDSP_DOMAIN_NAME "cdsp"
#define DSPRPC_CONTROL_LATENCY 1
#define DSPRPC_CONTROL_UNSIGNED_MODULE 2
#define FASTRPC_RESERVE_NEW_SESSION 3
#define FASTRPC_GET_URI 4
#define FASTRPC_GET_EFFECTIVE_DOMAIN_ID 5
#define FASTRPC_GET_DOMAINS 6
#define FASTRPC_NSP 2
#define DOMAINS_LIST_FLAGS_SET_TYPE(f, t) ((f) | ((t) << 8))
typedef struct { int id; const char * uri; } domain;
struct remote_rpc_control_latency { uint32_t enable; uint32_t latency; };
struct remote_rpc_control_unsigned_module { int domain; int enable; };
struct remote_rpc_reserve_new_session { char * domain_name; uint32_t domain_name_len; char * session_name; uint32_t session_name_len; uint32_t effective_domain_id; uint32_t session_id; };
struct remote_rpc_get_uri { char * domain_name; uint32_t domain_name_len; uint32_t session_id; char * module_uri; uint32_t module_uri_len; char * uri; uint32_t uri_len; };
struct remote_rpc_effective_domain_id { char * domain_name; uint32_t domain_name_len; uint32_t session_id; uint32_t effective_domain_id; };
typedef struct { int id; int instance_id; int type; int flags; char name[64]; int status; } fastrpc_domain;
typedef struct { int domain_type; int max_domains; int num_domains; fastrpc_domain * domains; int flags; } fastrpc_domains_info;
typedef struct { int id; fastrpc_domains_info sys; } system_req_payload;
int remote_session_control(uint32_t req, void * data, uint32_t datalen);
int remote_handle64_control(remote_handle64 h, uint32_t req, void * data, uint32_t datalen);
int fastrpc_mmap(int domain, int fd, void * addr, int offset, size_t length, fastrpc_map_flags flags);
int fastrpc_munmap(int domain, int fd, void * addr, size_t length);
#ifdef __cplusplus
}
#endif
