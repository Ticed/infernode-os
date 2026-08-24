#ifndef INFERNODE_PARAKEET_TURN_GATE_H
#define INFERNODE_PARAKEET_TURN_GATE_H

// The Parakeet EOU token is a decoder boundary, not proof that the person has
// stopped speaking. Commit only after an EOU-backed transcript is followed by
// sustained acoustic silence. A false EOU during continuous speech therefore
// resets the decoder without starting TTS in the middle of the utterance.
//
// "Silence" is relative, not absolute. A fixed RMS threshold works only while
// the room and the input gain happen to sit below it; raise the capture gain
// or move to a noisier room and every block reads as speech, so the silence
// timer never advances and the turn never commits. The gate therefore tracks
// the noise floor and requires speech to stand above it, clamped so a quiet
// room behaves exactly as the fixed threshold always did.
class ParakeetTurnGate {
public:
    ParakeetTurnGate(int final_silence_ms, double speech_rms)
        : final_silence_ms_(final_silence_ms), speech_rms_(speech_rms),
          silence_ms_(0), pending_(false), noise_floor_(0.0),
          have_floor_(false) {}

    explicit ParakeetTurnGate(int final_silence_ms)
        : ParakeetTurnGate(final_silence_ms, 0.008) {}

    // Feed a block's RMS. Updates the noise floor, then applies the same
    // speech/silence accounting as observe_audio.
    void observe_level(double rms, int block_ms) {
        if (!have_floor_) {
            noise_floor_ = rms;
            have_floor_ = true;
        } else {
            // Fall toward quiet faster than we rise toward loud, so an
            // utterance cannot drag the floor up into its own level.
            const double alpha = rms < noise_floor_ ? FLOOR_FALL : FLOOR_RISE;
            noise_floor_ += (rms - noise_floor_) * alpha;
        }
        observe_audio(rms >= speech_threshold(), block_ms);
    }

    // The level a block must reach to count as speech: above the noise floor
    // by a clear margin, never below the configured floor (so a quiet room is
    // unchanged) and never so high that ordinary speech reads as silence.
    double speech_threshold() const {
        double t = noise_floor_ * SPEECH_OVER_NOISE;
        if (t < speech_rms_)
            return speech_rms_;
        if (t > speech_rms_ * MAX_ADAPT)
            return speech_rms_ * MAX_ADAPT;
        return t;
    }

    void observe_audio(bool speech, int block_ms) {
        if (speech)
            silence_ms_ = 0;
        else
            silence_ms_ += block_ms;
    }

    void note_eou() { pending_ = true; }

    bool ready() const {
        return pending_ && silence_ms_ >= final_silence_ms_;
    }

    void reset() {
        silence_ms_ = 0;
        pending_ = false;
    }

    int silence_ms() const { return silence_ms_; }
    bool pending() const { return pending_; }
    double noise_floor() const { return noise_floor_; }

private:
    // Per 100ms block: fall settles in ~2s, rise in ~20s.
    static constexpr double FLOOR_FALL = 0.05;
    static constexpr double FLOOR_RISE = 0.005;
    static constexpr double SPEECH_OVER_NOISE = 2.0;
    static constexpr double MAX_ADAPT = 4.0;

    int final_silence_ms_;
    double speech_rms_;
    int silence_ms_;
    bool pending_;
    double noise_floor_;
    bool have_floor_;
};

#endif
