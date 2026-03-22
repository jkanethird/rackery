// llama_shim.cpp — thin wrapper so Dart FFI never has to mirror llama param structs.
// All functions use C linkage (extern "C") so Dart FFI can resolve them by plain name.
//
// Build:
//   g++ -shared -fPIC -O2 -o libllama_shim.so llama_shim.c \
//       -I$HOME/llama.cpp/include \
//       -I$HOME/llama.cpp/ggml/include \
//       -I$HOME/llama.cpp/tools/mtmd \
//       -L$HOME/llama.cpp/build/bin -lllama -lmtmd \
//       -Wl,-rpath,$HOME/llama.cpp/build/bin

#include <cstring>
#include <cstdint>
#include <cstdio>
#include "ggml.h"
#include "llama.h"
#include "mtmd.h"

extern "C" {

// ── Model params ─────────────────────────────────────────────────────────────
size_t shim_model_params_size() {
    return sizeof(struct llama_model_params);
}

void shim_model_params_default(void* out) {
    struct llama_model_params p = llama_model_default_params();
    memcpy(out, &p, sizeof(p));
}

void shim_model_params_set_gpu_layers(void* p, int32_t n) {
    static_cast<struct llama_model_params*>(p)->n_gpu_layers = n;
}

// ── Context params ────────────────────────────────────────────────────────────
size_t shim_ctx_params_size() {
    return sizeof(struct llama_context_params);
}

void shim_ctx_params_default(void* out) {
    struct llama_context_params p = llama_context_default_params();
    memcpy(out, &p, sizeof(p));
}

void shim_ctx_params_set_n_ctx(void* p, uint32_t n) {
    static_cast<struct llama_context_params*>(p)->n_ctx = n;
}

void shim_ctx_params_set_flash_attn(void* p, int enabled) {
    static_cast<struct llama_context_params*>(p)->flash_attn_type =
        static_cast<enum llama_flash_attn_type>(enabled);
}

// ── mtmd params ───────────────────────────────────────────────────────────────
size_t shim_mtmd_params_size() {
    return sizeof(struct mtmd_context_params);
}

void shim_mtmd_params_default(void* out) {
    struct mtmd_context_params p = mtmd_context_params_default();
    memcpy(out, &p, sizeof(p));
}

void shim_mtmd_params_set_gpu(void* p, int use_gpu) {
    static_cast<struct mtmd_context_params*>(p)->use_gpu = (use_gpu != 0);
}

// ── Convenience create/init functions ────────────────────────────────────────
void* shim_load_model(const char* path, void* model_params_blob) {
    return llama_model_load_from_file(
        path,
        *static_cast<struct llama_model_params*>(model_params_blob));
}

void* shim_new_ctx(void* model, void* ctx_params_blob) {
    return llama_init_from_model(
        static_cast<struct llama_model*>(model),
        *static_cast<struct llama_context_params*>(ctx_params_blob));
}

void* shim_mtmd_init(const char* mmproj_path, void* model, void* mtmd_params_blob) {
    return mtmd_init_from_file(
        mmproj_path,
        static_cast<struct llama_model*>(model),
        *static_cast<struct mtmd_context_params*>(mtmd_params_blob));
}

// ── Prompt evaluation: process all chunks into the KV cache ─────────────────
//
// For each chunk in `chunks`:
//   - TEXT chunk  → call llama_decode() with the text tokens
//   - IMAGE chunk → call mtmd_encode_chunk() to embed via CLIP, then write
//                   embeddings into the context via llama_decode_embd()
//
// Returns the KV position after encoding all chunks (n_past), or -1 on error.
// On return, `*n_past_out` is set to the consumed KV slots.
//
// NOTE: the caller is responsible for freeing `chunks` after this call.
int32_t shim_eval_chunks(
        void*                mtmd_ctx_v,   // mtmd_context*
        void*                llama_ctx_v,  // llama_context*
        const void*          chunks_v,     // const mtmd_input_chunks*
        int32_t              n_batch,
        int32_t*             n_past_out)   // out: kv position after eval
{
    mtmd_context*       mtmd_ctx  = static_cast<mtmd_context*>(mtmd_ctx_v);
    llama_context*      ctx       = static_cast<llama_context*>(llama_ctx_v);
    const mtmd_input_chunks* chunks = static_cast<const mtmd_input_chunks*>(chunks_v);

    int32_t n_past = (n_past_out != nullptr) ? *n_past_out : 0;
    const size_t count = mtmd_input_chunks_size(chunks);

    for (size_t i = 0; i < count; i++) {
        const mtmd_input_chunk* chunk = mtmd_input_chunks_get(chunks, i);
        enum mtmd_input_chunk_type type = mtmd_input_chunk_get_type(chunk);

        if (type == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
            // ------------------------------------------------------------------
            // Image chunk: run the CLIP encoder, then decode the embeddings
            // ------------------------------------------------------------------
            int rc = mtmd_encode_chunk(mtmd_ctx, chunk);
            if (rc != 0) {
                fprintf(stderr, "shim_eval_chunks: mtmd_encode_chunk failed (%d)\n", rc);
                return -1;
            }

            float* embd    = mtmd_get_output_embd(mtmd_ctx);
            size_t n_tokens = mtmd_input_chunk_get_n_tokens(chunk);

            // Feed embeddings into the context in batches
            size_t i_off = 0;
            const llama_model* model = llama_get_model(ctx);
            int n_embd = llama_model_n_embd(model);

            while (i_off < n_tokens) {
                size_t batch_sz = (size_t)n_batch;
                if (i_off + batch_sz > n_tokens) batch_sz = n_tokens - i_off;

                struct llama_batch batch = llama_batch_get_one(nullptr, (int32_t)batch_sz);
                // Override: provide embeddings instead of tokens
                batch.embd   = embd + i_off * n_embd;
                batch.token  = nullptr;
                batch.n_tokens = (int32_t)batch_sz;

                // Set positions and seq_ids
                // We need to allocate position/seq arrays on the stack or heap
                // Use llama_batch_init for proper memory management
                struct llama_batch full_batch = llama_batch_init((int32_t)batch_sz, n_embd, 1);
                full_batch.n_tokens = (int32_t)batch_sz;
                memcpy(full_batch.embd, embd + i_off * n_embd, batch_sz * n_embd * sizeof(float));
                for (int32_t j = 0; j < (int32_t)batch_sz; j++) {
                    full_batch.pos[j]      = n_past + (int32_t)(i_off + j);
                    full_batch.n_seq_id[j] = 1;
                    full_batch.seq_id[j][0] = 0;
                    full_batch.logits[j]   = (j == (int32_t)batch_sz - 1) ? 1 : 0;
                }

                // Force llama_decode to use embeddings instead of the allocated (but uninitialized) tokens
                llama_token* orig_token_ptr = full_batch.token;
                full_batch.token = nullptr;

                rc = llama_decode(ctx, full_batch);

                // Restore pointer so llama_batch_free can release it
                full_batch.token = orig_token_ptr;
                llama_batch_free(full_batch);

                if (rc != 0) {
                    fprintf(stderr, "shim_eval_chunks: llama_decode (embd) failed (%d) at i_off=%zu\n", rc, i_off);
                    return -1;
                }
                i_off += batch_sz;
            }
            n_past += (int32_t)n_tokens;

        } else if (type == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            // ------------------------------------------------------------------
            // Text chunk: decode the token IDs via llama_decode
            // ------------------------------------------------------------------
            size_t n_tokens = 0;
            const llama_token* tokens = mtmd_input_chunk_get_tokens_text(chunk, &n_tokens);
            if (n_tokens == 0 || tokens == nullptr) continue;

            size_t i_off = 0;
            while (i_off < n_tokens) {
                size_t batch_sz = (size_t)n_batch;
                if (i_off + batch_sz > n_tokens) batch_sz = n_tokens - i_off;

                struct llama_batch full_batch = llama_batch_init((int32_t)batch_sz, 0, 1);
                full_batch.n_tokens = (int32_t)batch_sz;
                for (int32_t j = 0; j < (int32_t)batch_sz; j++) {
                    full_batch.token[j]     = tokens[i_off + j];
                    full_batch.pos[j]       = n_past + (int32_t)(i_off + j);
                    full_batch.n_seq_id[j]  = 1;
                    full_batch.seq_id[j][0] = 0;
                    // Only compute logits for the very last token in the last batch
                    bool is_last = (i_off + j + 1 == n_tokens);
                    full_batch.logits[j] = is_last ? 1 : 0;
                }

                int rc = llama_decode(ctx, full_batch);
                llama_batch_free(full_batch);

                if (rc != 0) {
                    fprintf(stderr, "shim_eval_chunks: llama_decode (text) failed (%d)\n", rc);
                    return -1;
                }
                i_off += batch_sz;
            }
            n_past += (int32_t)n_tokens;
        }
        // else: skip audio or unknown chunk types
    }

    if (n_past_out != nullptr) *n_past_out = n_past;
    return 0; // success
}


// ── Single-token decode at explicit KV position ───────────────────────────
// Decodes `token` at position `pos` in the context, requesting logits output.
// Returns 0 on success, non-zero on failure.
int32_t shim_decode_token(
        void*        llama_ctx_v,
        int32_t      token,
        int32_t      pos)
{
    llama_context* ctx = static_cast<llama_context*>(llama_ctx_v);

    struct llama_batch batch = llama_batch_init(1, 0, 1);
    batch.n_tokens    = 1;
    batch.token[0]    = token;
    batch.pos[0]      = pos;
    batch.n_seq_id[0] = 1;
    batch.seq_id[0][0] = 0;
    batch.logits[0]   = 1; // request logits for this token

    int rc = llama_decode(ctx, batch);
    llama_batch_free(batch);
    return rc;
}

} // extern "C"
