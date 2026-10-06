// libggml-hexagon-shim.so: dynamic-backend shim around the prebuilt, directly-linked libggml-hexagon.so (D74).
// The plugin loader (GGML_BACKEND_DL) looks for ggml_backend_init() in libggml-*.so files next to the binary;
// libggml-hexagon.so only exports ggml_backend_hexagon_reg(), so this shim forwards to it.
#include "ggml-backend.h"
typedef struct ggml_backend_reg * ggml_backend_reg_t;
extern ggml_backend_reg_t ggml_backend_hexagon_reg(void);
__attribute__((visibility("default"))) ggml_backend_reg_t ggml_backend_init(void) { return ggml_backend_hexagon_reg(); }
__attribute__((visibility("default"))) int ggml_backend_score(void) { return 1; }
