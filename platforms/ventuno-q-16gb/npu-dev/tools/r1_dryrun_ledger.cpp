// r1_dryrun_ledger.cpp (NPU dev plan R1, review of 6403ce1): master's no-allocation load (no_alloc, load mode
// NONE: metadata only, every allocation simulated) with every log line kept, so that GGML_SCHED_DEBUG=2 prints the
// scheduler's graph splits and copies; then each buffer type's model/context/compute in exact bytes.
// Build against a master af0579c78 tree (CPU + RPC), e.g.
//   c++ -O1 -std=c++17 -I<tree>/include -I<tree>/common -I<tree>/ggml/include r1_dryrun_ledger.cpp \
//       -L<build>/bin -lllama-common -lllama -lggml -lggml-base -Wl,-rpath,<build>/bin -o r1_dryrun_ledger
// Run with the usual llama CLI arguments, e.g.
//   GGML_SCHED_DEBUG=2 r1_dryrun_ledger -m <model> --rpc <devs> -c 16384 -ub 512 -b 2048 -np 1 -fa on -ngl 999 -ts ...
// Output: stderr = llama/ggml log (splits); stdout = "BUFT <name> model <bytes> context <bytes> compute <bytes>".
#include "arg.h"
#include "common.h"
#include "llama.h"
#include "../src/llama-ext.h"

#include <cinttypes>
#include <cstdio>

int main(int argc, char ** argv) {
    common_params params;
    if (!common_params_parse(argc, argv, params, LLAMA_EXAMPLE_FIT_PARAMS)) {
        return 1;
    }
    if (getenv("R1_COMMON_LOG")) {
        common_init();   // the production logger, as llama-server sets it up (timestamp and level prefixes); -lv applies
    } else {
        llama_log_set([](ggml_log_level, const char * text, void *) { fputs(text, stderr); }, nullptr);
    }
    llama_backend_init();

    auto mparams = common_model_params_to_llama(params);
    auto cparams = common_context_params_to_llama(params);
    mparams.no_alloc  = true;
    mparams.load_mode = LLAMA_LOAD_MODE_NONE;

    llama_model * model = llama_model_load_from_file(params.model.path.c_str(), mparams);
    if (!model) { fprintf(stderr, "model load failed\n"); return 1; }
    llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) { fprintf(stderr, "context init failed\n"); return 1; }

    for (const auto & [buft, mb] : llama_get_memory_breakdown(ctx)) {
        printf("BUFT %s model %zu context %zu compute %zu\n", ggml_backend_buft_name(buft), mb.model, mb.context, mb.compute);
    }
    llama_free(ctx);
    llama_model_free(model);
    return 0;
}
