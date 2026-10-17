// r1_t7_tokens.cpp (NPU dev plan K5/T7): the evaluation tokens llama-perplexity at af0579c78 will use for a text, from
// the model's vocabulary only (vocab_only: no weights are read, so a header-only copy of the model is enough).
//
//   r1_t7_tokens <model.gguf> <text file> <n_ctx> <n_chunk> <out tokens file>
//
// Tokenizes as tools/perplexity/perplexity.cpp does (common_tokenize(ctx, params.prompt, true): add_special on,
// parse_special off), requires at least n_chunk x n_ctx tokens (perplexity's own n_chunk_max rule), and writes the first
// n_chunk x n_ctx token ids as little-endian int32: the block perplexity writes into its logits file (before its
// per-chunk BOS substitution). Prints the total count, add_bos, the BOS id and the count written.
#include "common.h"
#include "llama.h"

#include <cstdio>
#include <fstream>
#include <sstream>

int main(int argc, char ** argv) {
    if (argc != 6) { fprintf(stderr, "usage: %s <model> <text> <n_ctx> <n_chunk> <out>\n", argv[0]); return 2; }
    const int n_ctx = atoi(argv[3]), n_chunk = atoi(argv[4]);
    llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    llama_backend_init();
    auto mp = llama_model_default_params(); mp.vocab_only = true;
    llama_model * model = llama_model_load_from_file(argv[1], mp);
    if (!model) { fprintf(stderr, "model load failed\n"); return 3; }
    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::ifstream in(argv[2], std::ios::binary); if (!in) { fprintf(stderr, "cannot open text\n"); return 3; }
    std::stringstream ss; ss << in.rdbuf(); const std::string text = ss.str();
    const std::vector<llama_token> toks = common_tokenize(vocab, text, /* add_special */ true, /* parse_special */ false);
    const size_t need = (size_t) n_ctx * n_chunk;
    printf("tokens %zu, add_bos %d, bos %d, n_vocab %d\n", toks.size(), (int) llama_vocab_get_add_bos(vocab),
           (int) llama_vocab_bos(vocab), llama_vocab_n_tokens(vocab));
    if (toks.size() < need) { fprintf(stderr, "only %zu tokens, need %zu\n", toks.size(), need); return 3; }
    FILE * f = fopen(argv[5], "wb"); if (!f) { fprintf(stderr, "cannot write\n"); return 3; }
    if (fwrite(toks.data(), sizeof(int32_t), need, f) != need || fclose(f) != 0) { fprintf(stderr, "write failed\n"); return 3; }
    printf("written %zu (n_chunk %d x n_ctx %d)\n", need, n_chunk, n_ctx);
    llama_model_free(model);
    return 0;
}
