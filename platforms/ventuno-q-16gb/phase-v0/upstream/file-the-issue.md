# Filing the NPU hang issue from a phone

1. Close any half-filled llama.cpp issue tab. Signed in to GitHub, tap:

   ## [➜ Open the pre-filled llama.cpp issue form (v3, complete)](https://github.com/ggml-org/llama.cpp/issues/new?template=011-bug-results.yml&title=Eval%20bug%3A%20Hexagon%3A%20htp_main_thread%20exits%20on%20a%20dspqueue_peek%20error%20%28AEE_ENOMORE%20on%20v75%29%2C%20the%20host%20then%20hangs&version=version%3A%2011381%20%28836d57176%29%2C%20built%20with%20Clang%2021.1.8%20for%20Linux%20arm64.%20Release%20package%20built%20with%20the%20Snapdragon%20toolchain%20image%20arm64-linux%20v0.7%20%28Hexagon%20SDK%206.6.0.0%2C%20tools%2019.0.07%29%2C%20htp-v75.%20htp_main_thread%20is%20unchanged%20on%20master.&operating-system=Linux&backends=Hexagon&hardware=Arduino%20VENTUNO%20Q%3A%20QCS8275%20%28Hexagon%20v75%29%2C%2016%20GB%3B%20Ubuntu%2024.04%2C%20kernel%206.8.0-1084-qcom%2C%20qcom-fastrpc1%201.0.15%2Brepack2.&model=NeoHorse-1-4B%20%28qwen35%2C%204.21%20B%29%20from%20https%3A%2F%2Fhuggingface.co%2FTokenRhythm%2FNeoHorse-1-4B-GGUF%20%28NeoHorse-1-4B-BF16.gguf%2C%20rev%203c5d58ca%29%2C%20quantized%20with%20this%20build%3A%20llama-quantize%20--pure%20NeoHorse-1-4B-BF16.gguf%20NeoHorse-1-4B-q4_0-pure.gguf%20Q4_0.%20Needs%20two%20HTP%20sessions%20%28HTP0%3A0%2CHTP0%3A1%29%20on%20the%20one%20NPU.&info=%60%60%60%0AGGML_HEXAGON_DEVICES%3DHTP0%3A0%2CHTP0%3A1%20llama-server%20-m%20NeoHorse-1-4B-q4_0-pure.gguf%20-c%2032768%20--device%20HTP0%3A0%2CHTP0%3A1%20-ngl%2099%0A%60%60%60%0A%2A%2AProblem.%2A%2A%20At%20a%20random%20request%20generation%20stops%20for%20good%3A%20host%20threads%20wait%20in%20%60fastrpc_wait_for_completion%60%3B%20no%20kernel%20message%2C%20no%20abort.%2014%20hangs%20in%20898%20requests%20in%20our%20logs%20%28mixed%20configurations%29.%20%60GGML_HEXAGON_OPQUEUE%3D1%60%20did%20not%20help.%0A%0A%2A%2AHost%20side%2A%2A%20%28%60dspqueue_get_stat%60%20via%20a%20shim%29%3A%20one%20session%27s%20queue%20holds%201%20request%20never%20dequeued%20by%20the%20DSP%3B%20the%20other%20session%20is%20idle.%0A%0A%2A%2ADSP%20side%2A%2A%20%28FARF%20via%20%60llama-server.farf%60%29%3A%20see%20logs.%20The%20last%20line%20is%20%60htp_main_thread%60%27s%20%60FARF%28ERROR%29%60%3B%20the%20thread%20then%20%2A%2Aleaves%20its%20loop%2A%2A%20%28any%20peek%20error%20other%20than%20%60EWOULDBLOCK%60%2F%60EEXPIRED%60%29%2C%20so%20nothing%20reads%20that%20queue%20again.%20%600x2f%60%20%3D%20%60AEE_ENOMORE%60%2C%20from%20the%20dspqueue%27s%20internal%20signal%20wait%2C%20mid-decode.%0A%0A%2A%2AProposed%20change%2A%2A%3A%20keep%20the%20loop%20alive%20%28rate-limited%20log%2C%201%20ms%20sleep%2C%20retry%3B%20%60htp_iface_stop%60%20still%20ends%20it%20via%20%60ctx-%3Ekilled%60%29%3A%0A%60%60%60diff%0A---%20a%2Fggml%2Fsrc%2Fggml-hexagon%2Fhtp%2Fmain.c%0A%2B%2B%2B%20b%2Fggml%2Fsrc%2Fggml-hexagon%2Fhtp%2Fmain.c%0A%40%40%20-1349%2C6%20%2B1349%2C8%20%40%40%0A%20%0A%20%20%20%20%20FARF%28HIGH%2C%20%22htp-main-thread%3A%20started%22%29%3B%0A%20%0A%2B%20%20%20%20unsigned%20n_err%20%3D%200%3B%20%20%2F%2F%20consecutive%20dspqueue_peek%20errors%0A%2B%0A%20%20%20%20%20while%20%28%21atomic_load%28%26ctx-%3Ekilled%29%29%20%7B%0A%20%20%20%20%20%20%20%20%20uint32_t%20flags%20%3D%200%3B%0A%20%20%20%20%20%20%20%20%20uint32_t%20num_buffers%20%3D%200%3B%0A%40%40%20-1356%2C12%20%2B1358%2C18%20%40%40%0A%20%0A%20%20%20%20%20%20%20%20%20int%20err%20%3D%20dspqueue_peek%28ctx-%3Edsp_queue%2C%20%26flags%2C%20%26num_buffers%2C%20%26message_length%2C%2050000%29%3B%0A%20%20%20%20%20%20%20%20%20if%20%28err%20%3D%3D%200%29%20%7B%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20n_err%20%3D%200%3B%0A%20%20%20%20%20%20%20%20%20%20%20%20%20process_ops%28ctx%29%3B%0A%20%20%20%20%20%20%20%20%20%7D%20else%20if%20%28err%20%3D%3D%20AEE_EWOULDBLOCK%20%7C%7C%20err%20%3D%3D%20AEE_EEXPIRED%29%20%7B%0A%20%20%20%20%20%20%20%20%20%20%20%20%20continue%3B%0A%20%20%20%20%20%20%20%20%20%7D%20else%20%7B%0A-%20%20%20%20%20%20%20%20%20%20%20%20FARF%28ERROR%2C%20%22dspqueue_peek%20failed%3A%200x%2508x%22%2C%20%28unsigned%29%20err%29%3B%0A-%20%20%20%20%20%20%20%20%20%20%20%20break%3B%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20%2F%2F%20Do%20not%20leave%20the%20loop%3A%20nothing%20else%20reads%20this%20session%27s%20queue%2C%20so%20the%20host%20would%20wait%20forever.%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20%2F%2F%20Seen%20on%20v75%3A%20dspqueue_peek%20returns%20AEE_ENOMORE%20%280x2f%29%20from%20its%20internal%20signal%20wait%20in%20the%20middle%20of%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20%2F%2F%20a%20decode.%20Retry%20after%20a%20short%20sleep%3B%20htp_iface_stop%20ends%20the%20loop%20through%20ctx-%3Ekilled.%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20if%20%28n_err%2B%2B%20%3C%208%20%7C%7C%20%28n_err%20%25%201000%29%20%3D%3D%200%29%20%7B%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20%20%20%20%20FARF%28ERROR%2C%20%22dspqueue_peek%20failed%3A%200x%2508x%20%28%25u%20in%20a%20row%29%2C%20retrying%22%2C%20%28unsigned%29%20err%2C%20n_err%29%3B%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20%7D%0A%2B%20%20%20%20%20%20%20%20%20%20%20%20qurt_sleep%281000%29%3B%0A%20%20%20%20%20%20%20%20%20%7D%0A%20%20%20%20%20%7D%0A%60%60%60%0A%2A%2ATested%2A%2A%20on%20the%20same%20board%20%28same%20toolchain%3B%20unpatched%20rebuild%20byte-identical%20to%20the%20release%20library%29%3A%20240%2F240%20requests%20in%206%20servers%2C%20no%20hang%3B%208%20events%20of%20the%20same%20signature%2C%20each%20logged%20%60%281%20in%20a%20row%29%2C%20retrying%60%2C%20and%20the%20session%20kept%20serving.%20Clean%20SIGTERM%20shutdowns.%20Not%20exercised%3A%20repeated%20errors.%0A%0A%2A%2AQuestions%3A%2A%2A%20is%20retrying%20after%20%60AEE_ENOMORE%60%20safe%20and%20sufficient%2C%20or%20must%20the%20queue%20be%20re-imported%3F%20Why%20does%20the%20signal%20wait%20return%20%60AEE_ENOMORE%60%20with%20two%20sessions%3F%20Happy%20to%20open%20a%20PR.%0A%0A%2A%2AReproduction%20notes%3A%2A%2A%20-fit%20changes%20nothing%20here%20%28log%3A%20%22failed%20to%20fit%20params%20...%20n_gpu_layers%20already%20set%20by%20user%20to%2099%2C%20abort%22%29%2C%20i.e.%20as%20with%20-fit%20off.%20Not%20tried%20with%20llama-completion%3A%20the%20hang%20needs%20many%20requests%20on%20one%20running%20llama-server%20%28about%201%20in%2030%3B%20prompts%20255-1%2C462%20tokens%2C%2064-300%20generated%29.%20Not%20%2324963%3A%20its%20fix%20%2324954%20is%20in%20this%20build%2C%20and%20this%20hang%20also%20occurs%20in%20decode.&logs=%3Cdetails%3E%0A%3Csummary%3ELogs%3C%2Fsummary%3E%0A%0A%60%60%60console%0A%23%20unpatched%2C%20at%20the%20stall%0ACDSP0%3A%20Error%200x2f%3A%20wait_signal_locked%20failed%20for%20queue%2001E56910%20signal%200%0ACDSP0%3A%20wait_signal_locked%20failed%20with%200x2f%0ACDSP0%3A%20dspqueue_peek%20failed%3A%200x0000002f%0A%23%20patched%2C%20same%20event%3B%20the%20session%20continues%0ACDSP0%3A%20dspqueue_peek%20failed%3A%200x0000002f%20%281%20in%20a%20row%29%2C%20retrying%0A%60%60%60%0A%3C%2Fdetails%3E&first_bad_commit=Unknown%3A%20only%20836d57176%20tested%3B%20not%20bisected.)

2. Every field is filled (version string, model, reproduction notes, first bad commit). Check **Linux** and **Hexagon** are selected.
3. GitHub may show "similar issues": checked on 2026-10-10, none is this bug (closest: #24963, a prefill HMX hang fixed by #24954, which is already in our build). Ignore the hint.
4. Tap **Create**, then send the issue link to Claude.

---

# title
Eval bug: Hexagon: htp_main_thread exits on a dspqueue_peek error (AEE_ENOMORE on v75), the host then hangs

# version
version: 11381 (836d57176), built with Clang 21.1.8 for Linux arm64. Release package built with the Snapdragon toolchain image arm64-linux v0.7 (Hexagon SDK 6.6.0.0, tools 19.0.07), htp-v75. htp_main_thread is unchanged on master.

# operating-system
Linux

# backends
Hexagon

# hardware
Arduino VENTUNO Q: QCS8275 (Hexagon v75), 16 GB; Ubuntu 24.04, kernel 6.8.0-1084-qcom, qcom-fastrpc1 1.0.15+repack2.

# model
NeoHorse-1-4B (qwen35, 4.21 B) from https://huggingface.co/TokenRhythm/NeoHorse-1-4B-GGUF (NeoHorse-1-4B-BF16.gguf, rev 3c5d58ca), quantized with this build: llama-quantize --pure NeoHorse-1-4B-BF16.gguf NeoHorse-1-4B-q4_0-pure.gguf Q4_0. Needs two HTP sessions (HTP0:0,HTP0:1) on the one NPU.

# info
```
GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 llama-server -m NeoHorse-1-4B-q4_0-pure.gguf -c 32768 --device HTP0:0,HTP0:1 -ngl 99
```
**Problem.** At a random request generation stops for good: host threads wait in `fastrpc_wait_for_completion`; no kernel message, no abort. 14 hangs in 898 requests in our logs (mixed configurations). `GGML_HEXAGON_OPQUEUE=1` did not help.

**Host side** (`dspqueue_get_stat` via a shim): one session's queue holds 1 request never dequeued by the DSP; the other session is idle.

**DSP side** (FARF via `llama-server.farf`): see logs. The last line is `htp_main_thread`'s `FARF(ERROR)`; the thread then **leaves its loop** (any peek error other than `EWOULDBLOCK`/`EEXPIRED`), so nothing reads that queue again. `0x2f` = `AEE_ENOMORE`, from the dspqueue's internal signal wait, mid-decode.

**Proposed change**: keep the loop alive (rate-limited log, 1 ms sleep, retry; `htp_iface_stop` still ends it via `ctx->killed`):
```diff
--- a/ggml/src/ggml-hexagon/htp/main.c
+++ b/ggml/src/ggml-hexagon/htp/main.c
@@ -1349,6 +1349,8 @@
 
     FARF(HIGH, "htp-main-thread: started");
 
+    unsigned n_err = 0;  // consecutive dspqueue_peek errors
+
     while (!atomic_load(&ctx->killed)) {
         uint32_t flags = 0;
         uint32_t num_buffers = 0;
@@ -1356,12 +1358,18 @@
 
         int err = dspqueue_peek(ctx->dsp_queue, &flags, &num_buffers, &message_length, 50000);
         if (err == 0) {
+            n_err = 0;
             process_ops(ctx);
         } else if (err == AEE_EWOULDBLOCK || err == AEE_EEXPIRED) {
             continue;
         } else {
-            FARF(ERROR, "dspqueue_peek failed: 0x%08x", (unsigned) err);
-            break;
+            // Do not leave the loop: nothing else reads this session's queue, so the host would wait forever.
+            // Seen on v75: dspqueue_peek returns AEE_ENOMORE (0x2f) from its internal signal wait in the middle of
+            // a decode. Retry after a short sleep; htp_iface_stop ends the loop through ctx->killed.
+            if (n_err++ < 8 || (n_err % 1000) == 0) {
+                FARF(ERROR, "dspqueue_peek failed: 0x%08x (%u in a row), retrying", (unsigned) err, n_err);
+            }
+            qurt_sleep(1000);
         }
     }
```
**Tested** on the same board (same toolchain; unpatched rebuild byte-identical to the release library): 240/240 requests in 6 servers, no hang; 8 events of the same signature, each logged `(1 in a row), retrying`, and the session kept serving. Clean SIGTERM shutdowns. Not exercised: repeated errors.

**Questions:** is retrying after `AEE_ENOMORE` safe and sufficient, or must the queue be re-imported? Why does the signal wait return `AEE_ENOMORE` with two sessions? Happy to open a PR.

**Reproduction notes:** -fit changes nothing here (log: "failed to fit params ... n_gpu_layers already set by user to 99, abort"), i.e. as with -fit off. Not tried with llama-completion: the hang needs many requests on one running llama-server (about 1 in 30; prompts 255-1,462 tokens, 64-300 generated). Not #24963: its fix #24954 is in this build, and this hang also occurs in decode.

# logs
<details>
<summary>Logs</summary>

```console
# unpatched, at the stall
CDSP0: Error 0x2f: wait_signal_locked failed for queue 01E56910 signal 0
CDSP0: wait_signal_locked failed with 0x2f
CDSP0: dspqueue_peek failed: 0x0000002f
# patched, same event; the session continues
CDSP0: dspqueue_peek failed: 0x0000002f (1 in a row), retrying
```
</details>

# first_bad_commit
Unknown: only 836d57176 tested; not bisected.

