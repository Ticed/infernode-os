#ifndef INFERNODE_PARAKEET_TURN_GATE_H
#define INFERNODE_PARAKEET_TURN_GATE_H

// The Parakeet EOU token is a decoder boundary, not proof that the person has
// stopped speaking. Commit only after an EOU-backed transcript is followed by
// sustained acoustic silence. A false EOU during continuous speech therefore
// resets the decoder without starting TTS in the middle of the utterance.
class ParakeetTurnGate {
public:
    explicit ParakeetTurnGate(int final_silence_ms)
        : final_silence_ms_(final_silence_ms), silence_ms_(0), pending_(false) {}

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

private:
    int final_silence_ms_;
    int silence_ms_;
    bool pending_;
};

#endif
