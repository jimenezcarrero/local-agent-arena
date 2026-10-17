// r1_t7_compare.cpp (NPU dev plan T7): compare two llama-perplexity logit files written with --kl-divergence-base on
// the same text and settings (the reference REF and the candidate), position by position.
//
//   r1_t7_compare <ref.kld> <cand.kld> <expected token sha256>
//
// File format (tools/perplexity/perplexity.cpp at af0579c78): "_logits_", n_ctx (u32), n_vocab (i32), n_chunk (i32),
// the evaluation tokens (n_chunk x n_ctx i32, before the per-chunk BOS substitution), then per chunk n_ctx - 1 -
// n_ctx/2 rows of nv = 2*((n_vocab+1)/2)+4 uint16: two floats (scale, min_log_prob) and the quantized log-probs,
// log p_i = scale*q_i + min_log_prob (q_i = 0: at or below the floor, 16 nats under the top).
// Checks, failing closed (exit 3): both files open, carry the magic, equal headers and tokens, and have exactly the
// expected size; the tokens' sha256 (as stored, little-endian i32) equals the pinned value. Then per scored position:
//   top-1 agreement   REF's argmax == the candidate's argmax (ties: the lowest index, as perplexity's own rule);
//   rank              1 + the number of tokens the candidate rates strictly above REF's top token;
//   kld (cross-check) sum over REF entries above the floor of p_ref * (log p_ref - log p_cand), both dequantized.
// Output: summary lines; exit 0 when the inputs are valid (the T7 rule is applied by the caller).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// minimal SHA-256 (FIPS 180-4) for the token check
struct sha256 {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint8_t buf[64]; uint64_t len = 0; size_t n = 0;
    static uint32_t rr(uint32_t x, int k) { return (x >> k) | (x << (32 - k)); }
    void block(const uint8_t * p) {
        static const uint32_t K[64] = {
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,
            0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,
            0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,
            0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,
            0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
            0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++) w[i] = (p[4*i] << 24) | (p[4*i+1] << 16) | (p[4*i+2] << 8) | p[4*i+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rr(w[i-15], 7) ^ rr(w[i-15], 18) ^ (w[i-15] >> 3), s1 = rr(w[i-2], 17) ^ rr(w[i-2], 19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t t1 = hh + (rr(e, 6) ^ rr(e, 11) ^ rr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
            uint32_t t2 = (rr(a, 2) ^ rr(a, 13) ^ rr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    void add(const void * data, size_t sz) {
        const uint8_t * p = (const uint8_t *) data; len += sz;
        while (sz--) { buf[n++] = *p++; if (n == 64) { block(buf); n = 0; } }
    }
    std::string hex() {
        uint64_t bits = len * 8; uint8_t pad = 0x80; add(&pad, 1); pad = 0;
        while (n != 56) add(&pad, 1);
        for (int i = 7; i >= 0; i--) { uint8_t b = (uint8_t)(bits >> (8*i)); add(&b, 1); }
        char out[65]; for (int i = 0; i < 8; i++) snprintf(out + 8*i, 9, "%08x", h[i]); return out;
    }
};

[[noreturn]] static void reject(const std::string & why) {
    printf("RESULT INVALID INPUT: %s\n", why.c_str()); fprintf(stderr, "r1_t7_compare: %s\n", why.c_str()); exit(3);
}

struct kfile {
    FILE * f = nullptr; uint32_t n_ctx = 0; int32_t n_vocab = 0, n_chunk = 0; std::vector<int32_t> tokens; long data_off = 0;
    void open(const char * path) {
        f = fopen(path, "rb"); if (!f) reject(std::string("cannot open ") + path);
        char magic[8];
        if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "_logits_", 8)) reject(std::string(path) + ": not a logits file");
        if (fread(&n_ctx, 4, 1, f) != 1 || fread(&n_vocab, 4, 1, f) != 1 || fread(&n_chunk, 4, 1, f) != 1) reject(std::string(path) + ": short header");
        if (n_ctx < 4 || n_vocab < 2 || n_chunk < 1) reject(std::string(path) + ": implausible header");
        tokens.resize((size_t) n_ctx * n_chunk);
        if (fread(tokens.data(), 4, tokens.size(), f) != tokens.size()) reject(std::string(path) + ": short token block");
        data_off = ftell(f);
        const size_t nv = 2*((n_vocab + 1)/2) + 4, rows = (size_t)(n_ctx - 1 - n_ctx/2) * n_chunk;
        fseek(f, 0, SEEK_END);
        if ((size_t) ftell(f) != (size_t) data_off + rows * nv * 2) reject(std::string(path) + ": size differs from the header (truncated or extra data)");
        fseek(f, data_off, SEEK_SET);
    }
};

int main(int argc, char ** argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s <ref.kld> <cand.kld> <expected token sha256>\n", argv[0]); return 2; }
    kfile r, c; r.open(argv[1]); c.open(argv[2]);
    if (r.n_ctx != c.n_ctx || r.n_vocab != c.n_vocab || r.n_chunk != c.n_chunk) reject("headers differ");
    if (r.tokens != c.tokens) reject("evaluation tokens differ between the files");
    sha256 s; s.add(r.tokens.data(), r.tokens.size() * 4);
    const std::string tsha = s.hex();
    if (tsha != argv[3]) reject("token sha256 " + tsha + " differs from the pinned " + argv[3]);

    const int nv = 2*((r.n_vocab + 1)/2) + 4, nvocab = r.n_vocab;
    const size_t rows = (size_t)(r.n_ctx - 1 - r.n_ctx/2) * r.n_chunk;
    std::vector<uint16_t> a(nv), b(nv);
    size_t same = 0, rank1 = 0, rank5 = 0, rank10 = 0; double sum_rank = 0, sum_kld = 0; long max_rank = 0;
    std::vector<long> ranks; ranks.reserve(rows); std::vector<float> klds; klds.reserve(rows);
    for (size_t i = 0; i < rows; i++) {
        if (fread(a.data(), 2, nv, r.f) != (size_t) nv || fread(b.data(), 2, nv, c.f) != (size_t) nv) reject("short read");
        float sa, ma, sb, mb; memcpy(&sa, &a[0], 4); memcpy(&ma, &a[2], 4); memcpy(&sb, &b[0], 4); memcpy(&mb, &b[2], 4);
        if (!std::isfinite(sa) || !std::isfinite(ma) || !std::isfinite(sb) || !std::isfinite(mb)) reject("non-finite row header at position " + std::to_string(i));
        const uint16_t * qa = a.data() + 4; const uint16_t * qb = b.data() + 4;
        int ta = 0, tb = 0;
        for (int k = 1; k < nvocab; k++) { if (qa[k] > qa[ta]) ta = k; if (qb[k] > qb[tb]) tb = k; }
        same += ta == tb;
        long greater = 0; for (int k = 0; k < nvocab; k++) greater += qb[k] > qb[ta];
        const long rank = 1 + greater; ranks.push_back(rank);
        sum_rank += rank; rank1 += rank == 1; rank5 += rank <= 5; rank10 += rank <= 10; max_rank = std::max(max_rank, rank);
        double kl = 0;
        for (int k = 0; k < nvocab; k++) {
            const float la = sa*qa[k] + ma; if (la <= -16.f || qa[k] == 0) continue;
            const float lb = sb*qb[k] + mb; kl += std::exp((double) la) * (la - lb);
        }
        sum_kld += kl; klds.push_back((float) kl);
    }
    std::sort(ranks.begin(), ranks.end()); std::sort(klds.begin(), klds.end());
    auto pct = [&](auto & v, double p) { return v[std::min(v.size() - 1, (size_t) std::floor(p * (v.size() - 1) + 0.5))]; };
    printf("positions %zu (chunks %d, n_ctx %u, scored %u per chunk), n_vocab %d, token sha256 %s\n", rows, r.n_chunk, r.n_ctx,
           r.n_ctx - 1 - r.n_ctx/2, nvocab, tsha.c_str());
    printf("top-1 agreement (quantized logits): %.4f %%\n", 100.0 * same / rows);
    printf("rank of REF's top token in the candidate: mean %.4f, rank 1 %.4f %%, <=5 %.4f %%, <=10 %.4f %%, p99 %ld, max %ld\n",
           sum_rank / rows, 100.0 * rank1 / rows, 100.0 * rank5 / rows, 100.0 * rank10 / rows, pct(ranks, 0.99), max_rank);
    printf("KLD cross-check (both dequantized): mean %.6f, p99 %.6f, max %.6f\n", sum_kld / rows, pct(klds, 0.99), klds.back());
    printf("RESULT VALID\n");
    return 0;
}
