// r1_hex_support.cpp (NPU dev plan R1, review of 5d1ff55): evaluate master af0579c78's own Hexagon support decision
// (ggml_backend_hexagon_device_supports_op, ggml-hexagon.cpp :9381) offline, on the CPU, for every node the dry run
// placed on an NPU session. ggml-hexagon.cpp is compiled into this file unchanged; the Hexagon SDK headers are stubs
// that only declare types and functions (tools/r1-hex-stub/), and every SDK function defined here aborts if called,
// so nothing can pretend to be the NPU. The session is a stand-in carrying only what the support functions read:
// n_threads, n_hvx, n_hmx and vtcm_size (the board's own hwinfo: "threads 4, hvx 4, hmx 1, vtcm 8 MB"), mdev
// (one session, no group) and needs_repack.
//
//   r1_hex_support <node dump> <manifest> [vtcm_bytes] [n_hmx]
// <node dump>: R1_NODE_DUMP records written by the instrumented scheduler (r1-budget/instrumentation.diff), framed per
// graph: "GRAPH_BEGIN n_nodes=N", per non-view node "NODE i backend=..", one "T -1 op= type= ne= nb= flags= view= buf=
// name= params=" and one "S j ..." per source, then "GRAPH_END logged=K".
// Fails closed (review of cbe3b51): exit 3 if the file cannot be opened or read, a line is unknown or malformed (every
// field present once and numeric, 4 dimensions, 16 params, source slots 0..9 increasing), a NODE lacks its T line or its
// index is not increasing and below N, a graph is not closed or its NODE count differs from K, the number of graphs
// or their (n_nodes, logged) pairs differ from <manifest>, or no node is on an NPU session.
// <manifest>: written when the dump is captured (r1_node_manifest.sh): "r1-node-dump-manifest v1", "graphs G", then
// "graph i n_nodes N logged K" for i = 1..G in order; it is committed beside the dump. Otherwise one line per distinct (op, types, shapes,
// strides, params) signature on an NPU session with its verdict and count, a summary, and exit 0 only if every node
// is supported (1 if any is refused).
#include "ggml-hexagon.cpp"   // master af0579c78, unchanged (compiled against the stub SDK headers)

#include <fstream>
#include <map>
#include <set>
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

struct rec { int slot = 0, op = -1, type = -1; int64_t ne[4] = {}; size_t nb[4] = {}; int flags = 0, view = 0, buf = 0;
             std::string name; int32_t params[16] = {}; };

[[noreturn]] static void reject(size_t lineno, const std::string & why) {
    fprintf(stderr, "r1 harness: REJECT input (line %zu): %s\n", lineno, why.c_str());
    printf("RESULT INVALID INPUT: %s (line %zu)\n", why.c_str(), lineno);
    exit(3);
}

// parse "T -1 ..." / "S j ...": every field required, numeric fields fully numeric
static rec parse(const std::string & line0, size_t lineno) {
    // the name may contain spaces (ggml's automatic names, e.g. "Vcur-10 (view)"): it is everything between " name=" and
    // " params=", both required exactly once; the rest is space-separated key=value fields
    const size_t pn = line0.find(" name="), pp = line0.find(" params=");
    if (pn == std::string::npos || pp == std::string::npos || pp < pn || line0.find(" name=", pn + 1) != std::string::npos ||
        line0.find(" params=", pp + 1) != std::string::npos) reject(lineno, "missing or repeated name/params field");
    const std::string name = line0.substr(pn + 6, pp - pn - 6);
    const std::string line = line0.substr(0, pn) + line0.substr(pp);
    rec r; std::istringstream is(line); std::string tag, j, kv;
    auto num = [&](const std::string & v, const char * what) -> long long {
        size_t pos = 0; long long x = 0;
        try { x = std::stoll(v, &pos); } catch (...) { reject(lineno, std::string("non-numeric ") + what); }
        if (pos != v.size()) reject(lineno, std::string("non-numeric ") + what);
        return x;
    };
    auto list = [&](const std::string & v, auto * out, int n, const char * what) {
        std::stringstream ss(v); std::string x; int k = 0;
        while (std::getline(ss, x, ',')) { if (k >= n) reject(lineno, std::string("too many values in ") + what); out[k++] = num(x, what); }
        if (k != n) reject(lineno, std::string("wrong count in ") + what);
    };
    if (!(is >> tag >> j)) reject(lineno, "short record");
    r.slot = (int) num(j, "slot");
    std::set<std::string> seen;
    while (is >> kv) {
        auto eq = kv.find('=');
        if (eq == std::string::npos) reject(lineno, "field without '='");
        std::string k = kv.substr(0, eq), v = kv.substr(eq + 1);
        seen.insert(k);
        if (k == "op") r.op = (int) num(v, "op"); else if (k == "type") r.type = (int) num(v, "type");
        else if (k == "ne") list(v, r.ne, 4, "ne"); else if (k == "nb") list(v, r.nb, 4, "nb");
        else if (k == "flags") r.flags = (int) num(v, "flags"); else if (k == "view") r.view = (int) num(v, "view");
        else if (k == "buf") r.buf = (int) num(v, "buf");
        else if (k == "params") list(v, r.params, 16, "params");
        else reject(lineno, "unknown field " + k);
    }
    r.name = name; seen.insert("name");
    for (const char * k : {"op", "type", "ne", "nb", "flags", "view", "buf", "name", "params"})
        if (!seen.count(k)) reject(lineno, std::string("missing field ") + k);
    if (r.op < 0 || r.op >= GGML_OP_COUNT) reject(lineno, "op out of range");
    if (r.type < 0 || r.type >= GGML_TYPE_COUNT) reject(lineno, "type out of range");
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
    if (argc < 3) { fprintf(stderr, "usage: %s <node dump> <manifest> [vtcm_bytes] [n_hmx]\n", argv[0]); return 2; }
    std::vector<std::pair<long, long>> expect;      // per graph (n_nodes, logged), from the manifest
    {
        std::ifstream mf(argv[2]); std::string l; long g = -1;
        if (!mf.is_open()) reject(0, std::string("cannot open manifest ") + argv[2]);
        if (!std::getline(mf, l) || l != "r1-node-dump-manifest v1") reject(0, "manifest: bad header");
        if (!std::getline(mf, l) || sscanf(l.c_str(), "graphs %ld", &g) != 1 || g < 1) reject(0, "manifest: bad graph count");
        for (long i = 1; i <= g; i++) {
            long gi = 0, nn = 0, kk = 0;
            if (!std::getline(mf, l) || sscanf(l.c_str(), "graph %ld n_nodes %ld logged %ld", &gi, &nn, &kk) != 3 || gi != i)
                reject(0, "manifest: bad graph line " + std::to_string(i));
            expect.push_back({nn, kk});
        }
        if (std::getline(mf, l)) reject(0, "manifest: trailing lines");
    }
    const long expect_graphs = (long) expect.size();
    const uint64_t vtcm = argc > 3 ? strtoull(argv[3], nullptr, 0) : 8ull * 1024 * 1024;
    const uint32_t nhmx = argc > 4 ? (uint32_t) atoi(argv[4]) : 1;

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

    std::ifstream in(argv[1]);
    if (!in.is_open()) reject(0, std::string("cannot open ") + argv[1]);

    std::map<std::string, std::pair<int, bool>> sigs;
    size_t n_npu = 0, n_no = 0, lineno = 0;
    long n_graphs = 0, g_nodes = -1, g_logged = 0, last_idx = -1;
    std::string backend;
    rec node; bool have_node = false, have_t = false; std::vector<rec> srcs;

    auto finish_node = [&]() {
        if (!have_node) return;
        if (!have_t) reject(lineno, "NODE without its T record");
        have_node = false;
        bool npu = backend.rfind("RPC", 0) == 0;
        if (!npu || node.op == GGML_OP_NONE || node.op == GGML_OP_VIEW || node.op == GGML_OP_RESHAPE ||
            node.op == GGML_OP_PERMUTE || node.op == GGML_OP_TRANSPOSE) return;
        ggml_init_params ip{ 64 * 1024 * 1024, nullptr, true };
        ggml_context * ctx = ggml_init(ip);
        ggml_tensor * t = build(ctx, node);
        for (const auto & r : srcs) t->src[r.slot] = build(ctx, r);   // sources in their slots (S j)
        bool ok = ggml_backend_hexagon_device_supports_op(&dev, t);
        sess->needs_repack.clear();
        n_npu++; if (!ok) n_no++;
        auto & e = sigs[sig(t, node, srcs)]; e.first++; e.second = ok;
        ggml_free(ctx);
    };

    std::string line;
    while (std::getline(in, line)) {
        lineno++;
        std::istringstream is(line); std::string tag; is >> tag;
        if (tag == "GRAPH_BEGIN") {
            if (g_nodes >= 0) reject(lineno, "GRAPH_BEGIN inside an open graph");
            if (line.rfind("GRAPH_BEGIN n_nodes=", 0) != 0) reject(lineno, "malformed GRAPH_BEGIN");
            try { g_nodes = std::stol(line.substr(20)); } catch (...) { reject(lineno, "malformed GRAPH_BEGIN"); }
            if (g_nodes <= 0) reject(lineno, "graph with no nodes");
            g_logged = 0; last_idx = -1;
        } else if (tag == "GRAPH_END") {
            if (g_nodes < 0) reject(lineno, "GRAPH_END outside a graph");
            finish_node();
            long k = -1;
            if (line.rfind("GRAPH_END logged=", 0) != 0) reject(lineno, "malformed GRAPH_END");
            try { k = std::stol(line.substr(17)); } catch (...) { reject(lineno, "malformed GRAPH_END"); }
            if (k != g_logged) reject(lineno, "graph incomplete: " + std::to_string(g_logged) + " NODE records, GRAPH_END says " + std::to_string(k));
            if (n_graphs >= expect_graphs) reject(lineno, "more graphs than the manifest's " + std::to_string(expect_graphs));
            if (expect[n_graphs].first != g_nodes || expect[n_graphs].second != k)
                reject(lineno, "graph " + std::to_string(n_graphs + 1) + " differs from the manifest");
            n_graphs++; g_nodes = -1;
        } else if (tag == "NODE") {
            if (g_nodes < 0) reject(lineno, "NODE outside a graph");
            finish_node();
            long idx = -1; std::string b;
            if (!(is >> idx >> b) || b.rfind("backend=", 0) != 0) reject(lineno, "malformed NODE");
            if (idx <= last_idx || idx >= g_nodes) reject(lineno, "NODE index out of order or range");
            last_idx = idx; backend = b.substr(8); g_logged++;
            have_node = true; have_t = false; srcs.clear();
        } else if (tag == "T") {
            if (!have_node || have_t) reject(lineno, "T record without its NODE, or twice");
            node = parse(line, lineno); have_t = true;
            if (node.slot != -1) reject(lineno, "T record slot must be -1");
        } else if (tag == "S") {
            if (!have_node || !have_t) reject(lineno, "S record before its T record");
            rec r = parse(line, lineno);
            if (r.slot < 0 || r.slot >= GGML_MAX_SRC || (!srcs.empty() && r.slot <= srcs.back().slot)) reject(lineno, "source slot out of order or range");
            srcs.push_back(r);
        } else {
            reject(lineno, "unknown record '" + tag + "'");
        }
    }
    if (in.bad()) reject(lineno, "read error");
    if (g_nodes >= 0) reject(lineno, "input ends inside a graph (truncated)");
    if (n_graphs != expect_graphs) reject(lineno, std::to_string(n_graphs) + " complete graphs, expected " + std::to_string(expect_graphs));
    if (n_npu == 0) reject(lineno, "no node on an NPU session");

    for (auto & [k, v] : sigs) printf("%s x%d %s\n", v.second ? "SUPPORTED  " : "UNSUPPORTED", v.first, k.c_str());
    printf("RESULT vtcm %llu n_threads 4 n_hmx %u: %ld graphs, %zu NPU nodes, %zu signatures, %zu unsupported\n",
           (unsigned long long) vtcm, nhmx, n_graphs, n_npu, sigs.size(), n_no);
    return n_no == 0 ? 0 : 1;
}
