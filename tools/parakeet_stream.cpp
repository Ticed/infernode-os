// parakeet_stream — InferNode's realtime STT adapter over parakeet.cpp.
//
// Reads s16le PCM from stdin (the shim's `micmode device` capture pump, or
// any remote audio source teed through the namespace) and drives the
// cache-aware streaming Parakeet EOU model, emitting the speech provider
// contract's newline-delimited records on stdout:
//
//   partial <utterance text so far>
//   final confidence=0.9123 <utterance text>
//
// A model-emitted end-of-utterance (<EOU>/<EOB>) event closes one decoder
// segment. It becomes a provider `final` only after sustained acoustic
// silence: the model can emit a false EOU during continuous speech, and
// treating that token as an immediate turn boundary starts TTS over the user.
// Silence is judged against the tracked noise floor rather than a fixed
// level, so capture gain and room noise do not decide whether turns can
// close at all; `--speech-rms` sets the quiet-room floor for that decision.
// `confidence=` is the
// mean of the utterance's per-word confidences (NeMo max_prob, min-
// aggregated per word by parakeet.cpp); it is omitted when no words were
// finalized. Exits 0 on stdin EOF after flushing the tail.
//
// Built by tools/install-speech-helpers.sh against a clone of
// https://github.com/mudler/parakeet.cpp — only committed upstream API is
// used (ModelLoader, StreamingMel, StreamingSession). The chunk windowing
// below mirrors the schedule of parakeet.cpp's test_streaming_encoder:
// chunk 0 = chunk_size_first frames, no overlap; later chunks =
// pre_encode_cache_size overlap + chunk_size frames; keep_all_outputs on
// the final (flush) chunk only.
//
// Flags mirror the whisper-stream wrapper so the shim can exec either
// binary from the same ctl configuration. Unknown flags are ignored with
// a warning rather than rejected, so shim-side additions never hard-break
// an installed adapter.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>

#include "model.hpp"
#include "mel.hpp"
#include "streaming.hpp"
#include "ggml_graph.hpp"  // pk::set_num_threads

#include "ggml.h"          // ggml_log_set, to keep helper stderr readable
#include "parakeet_turn_gate.h"

namespace {

std::string trim_copy(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

// Column-append newly-ready mel frames onto the row-major [n_mels, T] buffer.
void append_mel_frames(std::vector<float>& mel_buf, int n_mels, int& mel_T,
                       const std::vector<float>& frames, int n_new) {
    if (n_new <= 0) return;
    const int old_T = mel_T;
    const int new_T = old_T + n_new;
    std::vector<float> out((size_t)n_mels * new_T);
    for (int m = 0; m < n_mels; ++m) {
        for (int t = 0; t < old_T; ++t)
            out[(size_t)m * new_T + t] = mel_buf[(size_t)m * old_T + t];
        for (int t = 0; t < n_new; ++t)
            out[(size_t)m * new_T + (old_T + t)] = frames[(size_t)m * n_new + t];
    }
    mel_buf.swap(out);
    mel_T = new_T;
}

std::vector<float> mel_window(const std::vector<float>& mel, int n_mels, int T,
                              int lo, int hi) {
    const int len = hi - lo;
    std::vector<float> w((size_t)n_mels * len);
    for (int m = 0; m < n_mels; ++m)
        for (int t = 0; t < len; ++t)
            w[(size_t)m * len + t] = mel[(size_t)m * T + (lo + t)];
    return w;
}

// Feed every complete chunk window available in mel_buf to the session.
// A window that reaches the buffer end is held back unless `flush` — its
// frames may still grow — except on flush, where it goes in with is_last.
void feed_ready_chunks(pk::StreamingSession& sess,
                       const std::vector<float>& mel_buf,
                       int n_mels, int mel_T, int& fed_idx,
                       bool& first_chunk, bool flush) {
    const int chunk0 = sess.chunk_size_first();
    const int chunk_main = sess.chunk_size();
    const int pre_cache = sess.pre_encode_cache_size();
    while (fed_idx < mel_T) {
        const int chunk_size = first_chunk ? chunk0 : chunk_main;
        const int hi = std::min(fed_idx + chunk_size, mel_T);
        if (hi - fed_idx <= 0) break;
        const bool reaches_end = (hi >= mel_T);
        if (!flush && reaches_end) break;
        const int lo = first_chunk ? fed_idx : std::max(0, fed_idx - pre_cache);
        std::vector<float> win = mel_window(mel_buf, n_mels, mel_T, lo, hi);
        const bool is_last = flush && reaches_end;
        sess.feed_mel_chunk(win, hi - lo, is_last);
        fed_idx += chunk_size;
        first_chunk = false;
        if (is_last) break;
    }
}

struct RecordEmitter {
    pk::StreamingSession& sess;
    std::string last_partial;
    std::string turn_text;
    std::vector<float> word_confs;
    bool session_captured = false;

    explicit RecordEmitter(pk::StreamingSession& s) : sess(s) {}

    void collect_words() {
        for (const pk::Word& w : sess.drain_words())
            word_confs.push_back(w.conf);
    }

    static std::string join(const std::string& a, const std::string& b) {
        if (a.empty()) return b;
        if (b.empty()) return a;
        return a + " " + b;
    }

    std::string current_text() const {
        return trim_copy(sess.text());
    }

    std::string partial_text() const {
        return join(turn_text, current_text());
    }

    void capture_segment() {
        if (session_captured)
            return;
        const std::string segment = current_text();
        if (!segment.empty())
            turn_text = join(turn_text, segment);
        session_captured = true;
        last_partial.clear();
    }

    void reset_session() {
        session_captured = false;
        last_partial.clear();
    }

    bool has_text() const {
        return !turn_text.empty() || !current_text().empty();
    }

    void emit_final() {
        capture_segment();
        if (!turn_text.empty()) {
            if (word_confs.empty()) {
                std::printf("final %s\n", turn_text.c_str());
            } else {
                double sum = 0.0;
                for (float c : word_confs) sum += c;
                std::printf("final confidence=%.4f %s\n",
                            sum / word_confs.size(), turn_text.c_str());
            }
            std::fflush(stdout);
        }
        turn_text.clear();
        word_confs.clear();
        last_partial.clear();
    }

    // Returns true when the decoder emitted EOU. Preserve its text as one
    // segment, then let the caller reset the decoder without committing the
    // user turn until the acoustic gate observes real silence.
    bool step() {
        collect_words();
        std::vector<pk::EouEvent> evs = sess.drain_events();
        if (!evs.empty()) {
            capture_segment();
            return true;
        }
        const std::string cur = partial_text();
        if (!cur.empty() && cur != last_partial) {
            std::printf("partial %s\n", cur.c_str());
            std::fflush(stdout);
            last_partial = cur;
        }
        return false;
    }
};

// Read exactly n bytes unless EOF interrupts; returns bytes read.
size_t read_full(void* buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        size_t r = std::fread((char*)buf + got, 1, n - got, stdin);
        if (r == 0) break;
        got += r;
    }
    return got;
}

} // namespace

int main(int argc, char** argv) {
    // The shim tails this helper's stderr into its log; ggml's Metal
    // pipeline-compile chatter and [parakeet] load logs would bury real
    // errors there. PARAKEET_STREAM_DEBUG=1 restores them.
    if (std::getenv("PARAKEET_STREAM_DEBUG") == nullptr) {
        setenv("PARAKEET_LOG", "0", 1);
        ggml_log_set([](enum ggml_log_level, const char*, void*) {}, nullptr);
    }

    std::string model_path;
    int rate = 16000;
    int chans = 1;
    int final_silence_ms = 800;
    double speech_rms = 0.008;
    bool use_stdin = false;
    bool announce_ready = false;

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
            model_path = argv[++i];
        } else if (std::strcmp(argv[i], "--rate") == 0 && i + 1 < argc) {
            rate = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--chans") == 0 && i + 1 < argc) {
            chans = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--stdin") == 0) {
            use_stdin = true;
        } else if (std::strcmp(argv[i], "--final-silence-ms") == 0 && i + 1 < argc) {
            final_silence_ms = std::atoi(argv[++i]);
        } else if (std::strcmp(argv[i], "--speech-rms") == 0 && i + 1 < argc) {
            speech_rms = std::atof(argv[++i]);
        } else if (std::strcmp(argv[i], "--ready") == 0) {
            announce_ready = true;
        } else if (std::strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            pk::set_num_threads(std::atoi(argv[++i]));
        } else if (i + 1 < argc && argv[i][0] == '-' && argv[i + 1][0] != '-') {
            std::fprintf(stderr, "parakeet-stream: ignoring %s %s\n",
                         argv[i], argv[i + 1]);
            ++i;
        } else {
            std::fprintf(stderr, "parakeet-stream: ignoring %s\n", argv[i]);
        }
    }
    if (model_path.empty()) {
        std::fprintf(stderr,
            "usage: parakeet-stream --stdin --model <eou.gguf> "
            "[--rate HZ] [--chans N] [--threads N] "
            "[--final-silence-ms MS] [--speech-rms LEVEL]\n");
        return 2;
    }
    if (!use_stdin) {
        // The adapter deliberately has no microphone code: audio capture
        // belongs to the shim's capture pump (`micmode device`), which is
        // what makes remote-mic topologies pure namespace composition.
        std::fprintf(stderr,
            "error: parakeet-stream only supports --stdin PCM input; "
            "set 'micmode device' on the speech shim\n");
        return 2;
    }
    if (rate <= 0 || chans <= 0 || final_silence_ms < 0 || speech_rms < 0.0) {
        std::fprintf(stderr, "error: bad rate/chans/final-silence-ms/speech-rms\n");
        return 2;
    }

    pk::ModelLoader ml;
    if (!ml.load(model_path)) {
        std::fprintf(stderr, "error: cannot load model %s\n", model_path.c_str());
        return 1;
    }
    if (!ml.config().streaming.present) {
        std::fprintf(stderr,
            "error: %s is not a cache-aware streaming model "
            "(need parakeet_realtime_eou_120m-v1)\n", model_path.c_str());
        return 1;
    }

    pk::StreamingMel mel(ml);
    pk::StreamingSession sess(ml);
    const int n_mels = mel.n_mels();
    std::vector<float> mel_buf;
    int mel_T = 0;
    int fed_idx = 0;
    bool first_chunk = true;
    RecordEmitter emitter(sess);
    ParakeetTurnGate turn_gate(final_silence_ms, speech_rms);

    if (announce_ready) {
        std::fprintf(stderr, "ready\n");
        std::fflush(stderr);
    }

    // 100ms of input per iteration keeps partial latency low without
    // burning a graph launch per tiny read.
    const int block_samples = rate / 10;
    std::vector<int16_t> raw((size_t)block_samples * chans);
    std::vector<float> mono;
    mono.reserve(block_samples);
    // Linear-resampler carry between blocks (position in input samples).
    double resample_pos = 0.0;
    float prev_sample = 0.0f;
    bool have_prev = false;
    std::vector<float> pcm16k;

    for (;;) {
        size_t want = raw.size() * sizeof(int16_t);
        size_t got = read_full(raw.data(), want);
        size_t n_in = got / sizeof(int16_t) / chans;
        if (n_in == 0) break;

        mono.clear();
        for (size_t i = 0; i < n_in; ++i) {
            int acc = 0;
            for (int c = 0; c < chans; ++c) acc += raw[i * chans + c];
            mono.push_back((float)(acc / chans) / 32768.0f);
        }

        const std::vector<float>* feed = &mono;
        if (rate != 16000) {
            // Streaming linear resample, carrying one sample across blocks.
            pcm16k.clear();
            const double step = (double)rate / 16000.0;
            while (true) {
                double pos = resample_pos;
                long idx = (long)pos;
                if (idx >= (long)mono.size() - (have_prev ? 0 : 1)) break;
                float s0, s1;
                if (idx < 0) { s0 = have_prev ? prev_sample : mono[0]; s1 = mono[0]; }
                else { s0 = mono[(size_t)idx]; s1 = (size_t)idx + 1 < mono.size() ? mono[(size_t)idx + 1] : mono[(size_t)idx]; }
                double frac = pos - idx;
                pcm16k.push_back((float)(s0 + (s1 - s0) * frac));
                resample_pos += step;
                if ((long)resample_pos >= (long)mono.size()) break;
            }
            resample_pos -= (double)mono.size();
            prev_sample = mono.back();
            have_prev = true;
            feed = &pcm16k;
        }
        if (feed->empty()) continue;

        double square_sum = 0.0;
        for (float sample : *feed)
            square_sum += (double)sample * sample;
        const double rms = std::sqrt(square_sum / feed->size());
        const int block_ms = (int)((1000LL * feed->size()) / 16000);
        turn_gate.observe_level(rms, block_ms);

        int n_new = 0;
        std::vector<float> frames = mel.feed(feed->data(), (int)feed->size(), n_new);
        append_mel_frames(mel_buf, n_mels, mel_T, frames, n_new);
        feed_ready_chunks(sess, mel_buf, n_mels, mel_T, fed_idx, first_chunk, false);

        // The decoder stops producing text after EOU, so reset it immediately,
        // but preserve the segment and wait for acoustic silence before a
        // provider final. False EOU inside continuous speech is then harmless.
        bool reset_stream = false;
        if (emitter.step()) {
            turn_gate.note_eou();
            reset_stream = true;
        }
        if (turn_gate.ready() && emitter.has_text()) {
            emitter.emit_final();
            turn_gate.reset();
            reset_stream = true;
        }
        if (reset_stream) {
            sess.reset();
            mel.reset();
            mel_buf.clear();
            mel_T = 0;
            fed_idx = 0;
            first_chunk = true;
            emitter.reset_session();
        }
    }

    // EOF: flush the mel tail and the decoder, then emit any trailing text
    // as a final so a capture teardown never swallows a spoken turn.
    int n_tail = 0;
    std::vector<float> tail = mel.finalize(n_tail);
    append_mel_frames(mel_buf, n_mels, mel_T, tail, n_tail);
    feed_ready_chunks(sess, mel_buf, n_mels, mel_T, fed_idx, first_chunk, true);
    sess.finalize();
    emitter.step();
    emitter.emit_final();

    // ggml-metal's static destructors abort in __cxa_finalize (observed on
    // macOS arm64 Metal builds); every record is already flushed, so skip
    // static teardown instead of crashing a clean shutdown into SIGABRT.
    std::fflush(stdout);
    std::_Exit(0);
}
