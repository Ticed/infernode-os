# Kokoro on Apple Silicon: CPU, CoreML, MLX, MetalRT

**Date:** 2026-09-02
**Machine:** Apple Silicon, M2-class, arm64 macOS
**Scope:** synthesis wall time only. Nothing was played.
**Default engine:** unchanged. This is a measurement, not a switch.

These numbers were taken on a contended machine, with builds and an
emulator running concurrently rather than on an idle system. Absolute
wall times and realtime factors will read slow against an idle machine. Relative comparisons between routes measured
in the same session are the ranking evidence; load hits both sides
roughly equally and cancels. Where a gap is smaller than that
session's run-to-run spread, the routes are not ranked.

Published figures for Kokoro-82M on Apple Silicon are 12x–79x realtime.
They are idle-machine numbers from other hardware and are not claimed
here.

## Fixture

```
text:  Hello, this is a test of the speech system.
voice: af_bella   (the helper default)
rate:  24000 Hz mono float, then discarded
```

That utterance is 2.411 s from the ONNX graph and ~3.3 s from MLX /
MetalRT / native CoreML. Grapheme-to-phoneme and trim differ. First-word
latency is time until the first PCM sample exists; on this short reply
no route streamed a usable prefix, so first-word equals full synthesis.

N = 7 warm calls after one cold call, unless noted. Load in the table
is the 1-minute average at the start of that measurement.

## Results

Wall times are contended. Use the paired-session ratios below to rank.
Realtime factor (audio / wall) is recorded only as a contended
observation, not as a lab figure.

| Route | Load (1 min) | Warm wall, best / median / range | Contended RTF (best) | Size | Conversion | Adopt cost |
| --- | ---: | --- | ---: | ---: | --- | --- |
| Current: `kokoro-onnx` 0.4.7, CPU EP | 9.72 | **2455 / 2609 / 2455–3299 ms** | 0.98x | 326 MB ONNX + 27 MB voices | none | already the helper |
| Same ONNX, CoreML EP | 6.81 | 2569 / 2702 / 2569–2829 ms | 1.20x on a 3.09 s utterance | same graph | `ONNX_PROVIDER=CoreMLExecutionProvider` | one env var; no gain |
| Native CoreML, 3 s bucket (mattmireles Swift pipeline) | 5.29 | **199 / 201 / 199–219 ms** | 15.1x | 164 MB for 3 s only | preconverted `.mlpackage` + Swift `KokoroPipeline` | new helper, bucket models, MisakiSwift or a Python G2P sidecar |
| Native CoreML, 7 s bucket (duration model pick) | 5.29 | 264 / 269 / 264–281 ms | 12.5x | 286 MB for 3 s + 7 s | same, plus the 7 s decoder | same, and ANE compile failed on the 7 s generator (ran anyway) |
| `mlx-audio` 0.5.0 + `mlx` 0.32.2, GPU | 15.92 | **119 / 126 / 119–132 ms** | 27.7x | 312 MB bf16 weights | `pip install mlx-audio misaki[en]` | sibling helper next to `kokoro-cli`, fallback to ONNX |
| MetalRT v0.2.1 `metalrt_tts_*` C API | ~14 (same session as MLX; 5.51 on an earlier pass) | **333 / 345 / 333–360 ms** | 10.0x | 312 MB bf16 + 3 MB dylib | none; load `runanywhere/kokoro_bf16` | proprietary dylib, license is RCLI-scoped |

The CPU, MLX, and MetalRT rows in the table are the confirmation pass:
one script, sequential, load climbing from 9.72 through 15.92. Native
CoreML ran earlier in a quieter window (load 5.29). CoreML EP used a
longer 3.09 s utterance at load 6.81; its CPU counterpart at load 5.60
on that same text was 2594 ms best (range 2594–2952 ms).

## Paired comparisons (ranking evidence)

**CPU vs CoreML EP**, same 3.09 s ONNX graph, minutes apart, load 5.60
vs 6.81. Best 2594 ms vs 2569 ms. Gap 25 ms; CPU range in that session
was 359 ms. The gap is smaller than the spread. **Not ranked.**
Forcing the CoreML EP does not help. Partition log, reproduced: *109
partitions, 2256 nodes, 1038 supported by CoreML*.

**CPU vs MLX vs MetalRT**, confirmation pass, sequential, load 9.72 →
15.92. Wall-time ratios (not RTF):

| Pair | Ratio (best wall) | Spread in that session | Rank? |
| --- | ---: | --- | --- |
| CPU / MLX | 20.6x (2455 / 119) | CPU 2455–3299; MLX 119–132 | yes: MLX |
| CPU / MetalRT | 7.4x (2455 / 333) | MetalRT 333–360 | yes: MetalRT |
| MetalRT / MLX | 2.8x (333 / 119) | neither range overlaps | yes: MLX |

Contention was worse for MLX and MetalRT than for CPU in this pass
(load had climbed). That makes the MLX and MetalRT advantages against
CPU conservative, not optimistic.

**Native CoreML 3 s vs 7 s**, same process, load 5.29. 199 ms vs 264 ms.
Gap 65 ms; ranges 199–219 and 264–281 do not overlap. The 7 s bucket is
slower. The duration model picked 7 s for this text; the 3 s row forced
`canonical_duration_s = 2.8`. First 7 s compile printed
`ANECCompile() FAILED` and still produced audio, so the 7 s row is not
a clean ANE run.

**Native CoreML vs MLX:** not a paired session. CoreML 3 s was 199–219 ms
at load 5.29. Confirmation MLX was 119–132 ms at load 15.92. An earlier
MLX session at load 11.03 had warm range **118–235 ms**, which overlaps
CoreML's 199–219 ms. Point estimates still favour MLX under *worse*
load, but the advantage is not larger than every measured MLX spread.
**Not ranked.**

**Native CoreML vs MetalRT** at similar load (5.29 vs 5.51), minutes
apart. 199–219 ms vs 334–353 ms. Gap larger than either spread.
CoreML faster than MetalRT in that window. This is not the
confirmation pass; it is the closest like-for-like load we have for
those two.

Native CoreML numbers are from the Swift `kokoro-bench` binary in
`mattmireles/kokoro-coreml`, token-in / PCM-out. Misaki G2P on the same
text is 1.3 ms warm and is not in the 199 ms.

MetalRT was measured with the public `libmetalrt.dylib` (ABI 2) and
`metalrt_tts_synthesize`. It loads and runs on M2-class silicon.

MLX first synthesis after process start was 7.3 s on the confirmation
pass (74 s on a virgin venv while spaCy `en_core_web_sm` downloaded).
That is the same class of cost the resident helper already moves to
voice-mode entry. Warm numbers assume that helper.

## What was not measured

- Voice-mode end-to-end (9P, shim, playback setup). Synthesis only.
- Long utterances. MLX previously failed a long-utterance attempt
  elsewhere; this bakeoff did not retry it.
- `prince-canuma/Kokoro-82M` versus `mlx-community/Kokoro-82M-bf16`.
  This run used the latter.
- mlx-audio on the production speech venv (CPython 3.14.7). MLX was
  timed in an isolated 3.12.14 venv. The 3.14 venv was not modified.
- A from-scratch `coremltools` conversion of the ONNX graph. The
  native-CoreML candidate is the pre-split pipeline, not a second
  ONNX-to-mlpackage attempt.
- Quality / WER. Timing only.
- An idle-machine rerun. None of these wall times should be quoted as
  unloaded realtime.

Published numbers not reproduced here, labelled as such:

- Native CoreML: 30 s of audio in 379 ms on a Mac Studio (mattmireles
  Hugging Face card, June 2026). Different machine, 30 s bucket, idle.
- mlx-audio: "roughly half the above" on that card. Not ranked against
  native CoreML on this box; see paired comparisons.
- MetalRT: 178 ms / 2.8x over mlx-audio on short phrases, M4 Max
  (RunAnywhere blog). On the confirmation pass here, MetalRT was 2.8x
  *slower* than MLX. Different chip.

## Recommendation

**Adopt `mlx-audio` as an optional Apple Silicon helper. Keep
`kokoro-onnx` on CPU as the fallback. Do not switch the default in
this tree until the installer grows that extra and a 3.14 (or pinned
3.12) venv is confirmed.**

Defend it this way:

1. In the one session that timed CPU, MLX, and MetalRT back-to-back,
   MLX was 21x the CPU helper and 2.8x MetalRT. Those gaps are larger
   than the run-to-run spread. That is the ranking, not the contended
   27.7x realtime factor.
2. Native CoreML is **not** ranked against MLX. The quieter CoreML
   window and the first MLX session's 118–235 ms spread overlap. Pick
   MLX over CoreML on adoption cost (a pip extra versus a Swift
   pipeline plus bucket models), not on a speed ranking this bakeoff
   did not settle.
3. It is a different helper behind the existing shim path, not a
   speech9p change. Unavailable MLX degrades to the ONNX helper.
4. MetalRT works here and is proprietary. The M4 headline does not
   transfer. Do not take the closed-source dylib for a loss against
   MLX on M2-class silicon.
5. Staying on CPU is not defensible once MLX is a pip install. The
   paired CPU/MLX gap is an order of magnitude, not a spread artifact.

Knobs the maintainer still owns:

- Whether the default `kokorobin` becomes the MLX helper on Darwin, or
  stays ONNX until a later cutover.
- Whether the speech venv stays on 3.14 or a 3.12 venv is added for
  MLX.
- Whether native CoreML is a later iOS / ANE track, independent of the
  Mac helper.

No engine files, installer, or ctl defaults were changed.
