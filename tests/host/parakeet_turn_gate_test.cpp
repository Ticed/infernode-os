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

    if (failures != 0)
        return 1;
    std::puts("PASS: premature decoder EOU is gated by acoustic silence");
    std::puts("PASS");
    return 0;
}
