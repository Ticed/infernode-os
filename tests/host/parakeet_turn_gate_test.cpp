#include <cstdio>
#include "../../tools/parakeet_turn_gate.h"

static int failures;

static void check(bool condition, const char* message) {
    if (condition)
        return;
    std::fprintf(stderr, "FAIL: %s\n", message);
    ++failures;
}

int main() {
    ParakeetTurnGate gate(800);

    gate.observe_audio(true, 100);
    gate.note_eou();
    check(!gate.ready(), "EOU during speech must not commit");

    for (int i = 0; i < 4; ++i)
        gate.observe_audio(false, 100);
    check(!gate.ready(), "short pause must not commit");

    gate.observe_audio(true, 100);
    check(!gate.ready(), "continued speech cancels accumulated silence");
    check(gate.pending(), "continued speech retains the decoder segment");

    for (int i = 0; i < 7; ++i)
        gate.observe_audio(false, 100);
    check(!gate.ready(), "799ms-or-less silence must not commit");
    gate.observe_audio(false, 100);
    check(gate.ready(), "sustained silence commits the aggregated turn");

    gate.reset();
    check(!gate.pending() && gate.silence_ms() == 0,
          "reset prepares the next independent turn");

    // A room whose noise floor sits above the configured level must still be
    // able to close a turn. Before the floor was tracked, every block here
    // read as speech and the silence timer never advanced.
    {
        const double floor_rms = 0.0115;  // measured: built-in mic at full gain
        const double speech = 0.045;
        ParakeetTurnGate noisy(800, 0.008);
        for (int i = 0; i < 30; ++i)
            noisy.observe_level(floor_rms, 100);
        check(noisy.speech_threshold() > floor_rms,
              "threshold rises above a noisy room's floor");
        for (int i = 0; i < 20; ++i)
            noisy.observe_level(speech, 100);
        check(noisy.silence_ms() == 0, "speech still reads as speech");
        noisy.note_eou();
        for (int i = 0; i < 8; ++i)
            noisy.observe_level(floor_rms, 100);
        check(noisy.ready(), "room noise at the floor commits the turn");
    }

    // A quiet room must behave exactly as the fixed threshold always did:
    // adapting downward would let faint noise cancel the silence timer.
    {
        ParakeetTurnGate quiet(800, 0.008);
        for (int i = 0; i < 30; ++i)
            quiet.observe_level(0.0028, 100);
        check(quiet.speech_threshold() == 0.008,
              "quiet room keeps the configured threshold");
    }

    // A sustained loud utterance must not drag the floor up to its own level,
    // or the speaker's own voice would start reading as silence.
    {
        ParakeetTurnGate loud(800, 0.008);
        loud.observe_level(0.002, 100);
        for (int i = 0; i < 100; ++i)
            loud.observe_level(0.05, 100);
        check(loud.speech_threshold() < 0.05,
              "10s of speech does not raise the floor into the speech level");
        check(loud.silence_ms() == 0, "speech never reads as silence");
    }

    if (failures != 0)
        return 1;
    std::puts("PASS: premature decoder EOU is gated by acoustic silence");
    std::puts("PASS: silence is judged against the tracked noise floor");
    std::puts("PASS");
    return 0;
}
