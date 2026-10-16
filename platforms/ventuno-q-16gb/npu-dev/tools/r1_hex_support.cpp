// r1_hex_support.cpp (NPU dev plan R1, review of 5d1ff55): evaluate master af0579c78's own Hexagon support decision
// (ggml_backend_hexagon_device_supports_op, ggml-hexagon.cpp :9381) offline, on the CPU, for every node the dry run
// placed on an NPU session. ggml-hexagon.cpp is compiled into this file unchanged; the Hexagon SDK headers are stubs
// that only declare types and functions (tools/r1-hex-stub/), and every SDK function defined here aborts if called,
// so nothing can pretend to be the NPU. The session is a stand-in carrying only what the support functions read:
// n_threads, n_hvx, n_hmx and vtcm_size (the board's own hwinfo: "threads 4, hvx 4, hmx 1, vtcm 8 MB"), mdev
// (one session, no group) and needs_repack.
//
//   r1_hex_support <node dump> [vtcm_bytes] [n_hmx]
// <node dump>: R1_NODE_DUMP records written by the instrumented scheduler (r1-budget/instrumentation.diff): per node
// "NODE i backend=..", then "T -1 op= type= ne= nb= flags= view= buf= name= params=" and one "S j ..." per source.
// Output: one line per distinct (op, types, shapes, strides, params) signature on an NPU session with its verdict and
// count, then a summary; exit 0 only if every node is supported.
#include "ggml-hexagon.cpp"   // master af0579c78, unchanged (compiled against the stub SDK headers)

#include <fstream>
#include <map>
#include <sstream>

[[noreturn]] static void r1_stub(const char * f) { fprintf(stderr, "r1 harness: SDK function %s called\n", f); abort(); }
extern "C" {
const char * htp_iface_URI = "stub";
void * rpcmem_alloc2(int, unsigned int, size_t) { r1_stub(__func__); }
void   rpcmem_free(void *) { r1_stub(__func__); }
int    rpcmem_to_fd(void *) { r1_stub(__func__); }
int remote_session_control(uint32_t, void *, uint32_t) { r1_stub(__func__); }
int remote_handle64_control(remote_handle64, uint32_t, void *, uint32_t) { r1_stub(__func__); }
int fastrpc_mmap(int, int, void *, int, size_t, fastrpc_map_flags) { r1_stub(__func__); }
int fastrpc_munmap(int, int, void *, size_t) { r1_stub(__func__); }
int remote_system_request(system_req_payload *) { r1_stub(__func__); }
int dspqueue_create(int, uint32_t, uint32_t, uint32_t, dspqueue_callback_t, dspqueue_callback_t, void *, dspqueue_t *) { r1_stub(__func__); }
int dspqueue_close(dspqueue_t) { r1_stub(__func__); }
int dspqueue_export(dspqueue_t, uint64_t *) { r1_stub(__func__); }
int dspqueue_write(dspqueue_t, uint32_t, uint32_t, struct dspqueue_buffer *, uint32_t, const uint8_t *, uint32_t) { r1_stub(__func__); }
int dspqueue_read(dspqueue_t, uint32_t *, uint32_t, uint32_t *, struct dspqueue_buffer *, uint32_t, uint32_t *, uint8_t *, uint32_t) { r1_stub(__func__); }
int htp_iface_open(const char *, remote_handle64 *) { r1_stub(__func__); }
int htp_iface_close(remote_handle64) { r1_stub(__func__); }
int htp_iface_start(remote_handle64, uint32_t, uint64_t, uint32_t, uint32_t, uint64_t, uint32_t) { r1_stub(__func__); }
int htp_iface_stop(remote_handle64) { r1_stub(__func__); }
int htp_iface_mmap(remote_handle64, uint32_t, uint64_t) { r1_stub(__func__); }
int htp_iface_munmap(remote_handle64, uint32_t) { r1_stub(__func__); }
int htp_iface_profiler(remote_handle64, uint32_t, const htp_iface_pmu_conf *) { r1_stub(__func__); }
int htp_iface_etm(remote_handle64, uint32_t) { r1_stub(__func__); }
int htp_iface_hwinfo(remote_handle64, unsigned int *, unsigned int *, unsigned int *, unsigned long long *) { r1_stub(__func__); }
int htpdrv_init(void) { r1_stub(__func__); }
domain * htpdrv_get_domain(int) { r1_stub(__func__); }
int htpdrv_get_arch(int, int *) { r1_stub(__func__); }
}

struct rec { int slot, op, type; int64_t ne[4]; size_t nb[4]; int flags, view, buf; std::string name; int32_t params[16]; };

static rec parse(const std::string & line) {
    rec r{}; std::istringstream is(line); std::string tag, j, kv;
    is >> tag >> j; r.slot = std::stoi(j);
    while (is >> kv) {
        auto eq = kv.find('='); std::string k = kv.substr(0, eq), v = kv.substr(eq + 1);
        auto ints = [&](auto * out, int n) { std::stringstream ss(v); std::string x; for (int i = 0; i < n && std::getline(ss, x, ','); i++) out[i] = std::stoll(x); };
        if (k == "op") r.op = std::stoi(v); else if (k == "type") r.type = std::stoi(v);
        else if (k == "ne") ints(r.ne, 4); else if (k == "nb") ints(r.nb, 4);
        else if (k == "flags") r.flags = std::stoi(v); else if (k == "view") r.view = std::stoi(v);
        else if (k == "buf") r.buf = std::stoi(v); else if (k == "name") r.name = v; else if (k == "params") ints(r.params, 16);
    }
    return r;
}

static ggml_tensor * build(ggml_context * ctx, const rec & r) {
    ggml_tensor * t = ggml_new_tensor(ctx, (ggml_type) r.type, 4, r.ne);
    for (int i = 0; i < 4; i++) t->nb[i] = r.nb[i];
    t->op = (ggml_op) r.op; t->flags = r.flags;
    memcpy(t->op_params, r.params, sizeof(r.params));
    if (r.view) t->view_src = ggml_new_tensor(ctx, (ggml_type) r.type, 4, r.ne);   // a view: only its presence is read
    ggml_set_name(t, r.name.c_str());
    return t;
}

static std::string sig(const ggml_tensor * t, const rec & n, const std::vector<rec> & s) {
    std::ostringstream o;
    auto one = [&](const rec & r) {
        o << ggml_type_name((ggml_type) r.type) << "[" << r.ne[0] << "," << r.ne[1] << "," << r.ne[2] << "," << r.ne[3] << "]{"
          << r.nb[0] << "," << r.nb[1] << "," << r.nb[2] << "," << r.nb[3] << "}" << (r.view ? "v" : "");
    };
    o << ggml_op_desc(t) << " "; one(n); o << " p=";
    for (int i = 0; i < 16; i++) o << (i ? "," : "") << n.params[i];
    for (const auto & r : s) { o << " s" << r.slot << "="; one(r); }
    return o.str();
}

int main(int argc, char ** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <node dump> [vtcm_bytes] [n_hmx]\n", argv[0]); return 2; }
    const uint64_t vtcm = argc > 2 ? strtoull(argv[2], nullptr, 0) : 8ull * 1024 * 1024;
    const uint32_t nhmx = argc > 3 ? (uint32_t) atoi(argv[3]) : 1;

    // stand-in session: only the fields the support functions read are constructed
    alignas(ggml_hexagon_session) static unsigned char raw[sizeof(ggml_hexagon_session)];
    memset(raw, 0, sizeof(raw));
    auto * sess = reinterpret_cast<ggml_hexagon_session *>(raw);
    new (&sess->name) std::string("HTP0:0");
    new (&sess->needs_repack) std::unordered_set<const ggml_tensor *>();
    new (&sess->mdev) ggml_hexagon_mdev_group();
    sess->n_threads = 4; sess->n_hvx = 4; sess->n_hmx = nhmx; sess->vtcm_size = vtcm;

    ggml_hexagon_device_config cfg{}; cfg.name = "HTP0:0";
    static ggml_backend_device dev{};
    auto * dev_ctx = new ggml_backend_hexagon_device_context(0, cfg, &dev);
    dev.iface = ggml_backend_hexagon_device_i; dev.context = dev_ctx;
    dev_ctx->sess.reset(sess);                      // never released: no destructor runs on the stand-in

    std::ifstream in(argv[1]); std::string line, backend;
    std::map<std::string, std::pair<int, bool>> sigs;
    size_t n_nodes = 0, n_no = 0;
    std::vector<std::string> block;
    auto flush = [&]() {
        if (block.empty()) return;
        bool npu = backend.rfind("RPC", 0) == 0;
        rec n = parse(block[0]); std::vector<rec> srcs;
        for (size_t i = 1; i < block.size(); i++) srcs.push_back(parse(block[i]));
        block.clear();
        if (!npu || n.op == GGML_OP_NONE || n.op == GGML_OP_VIEW || n.op == GGML_OP_RESHAPE || n.op == GGML_OP_PERMUTE ||
            n.op == GGML_OP_TRANSPOSE) return;
        ggml_init_params ip{ 64 * 1024 * 1024, nullptr, true };
        ggml_context * ctx = ggml_init(ip);
        ggml_tensor * t = build(ctx, n);
        for (const auto & r : srcs) t->src[r.slot] = build(ctx, r);   // sources in their slots (S j)
        bool ok = ggml_backend_hexagon_device_supports_op(&dev, t);
        sess->needs_repack.clear();
        n_nodes++; if (!ok) n_no++;
        auto & e = sigs[sig(t, n, srcs)]; e.first++; e.second = ok;
        ggml_free(ctx);
    };
    while (std::getline(in, line)) {
        if (line.rfind("NODE ", 0) == 0) { flush(); auto p = line.find("backend="); backend = line.substr(p + 8); }
        else if (line.rfind("T ", 0) == 0 || line.rfind("S ", 0) == 0) block.push_back(line);
    }
    flush();
    for (auto & [k, v] : sigs) printf("%s x%d %s\n", v.second ? "SUPPORTED  " : "UNSUPPORTED", v.first, k.c_str());
    printf("RESULT vtcm %llu n_threads 4 n_hmx %u: %zu NPU nodes, %zu signatures, %zu unsupported\n",
           (unsigned long long) vtcm, nhmx, n_nodes, sigs.size(), n_no);
    return n_no == 0 ? 0 : 1;
}
