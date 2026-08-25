#!/usr/bin/env python3
"""Unit test for the GUI voice turn's answer extraction, without the rig.

The end-to-end turn test needs a loopback audio device, the speech
helpers, an LLM endpoint, and Screen Recording and Accessibility
permission. None of those matter to answer_text(): it decides what the
pane's segments say on the screen. This test feeds it the segments the
end-to-end run actually read and asserts the reply does not absorb the
next tile.

See INF-59: answer_text walked forward from the agent's role marker,
collecting every segment until one was already seen or matched a pane
status line. The next turn's tile is new and its head does not read as a
status line, so "teodorandius - not sent" joined the reply. The fix stops
the walk at the next tile's head — a segment that names a speaker — so a
tile in any state ends the reply that precedes it.
"""

import importlib.util
import os
import sys

ROOT = os.environ.get("ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

spec = importlib.util.spec_from_file_location(
    "gui_voice_turn_test", os.path.join(ROOT, "tests/host/gui_voice_turn_test.py"))
gvt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gvt)


class Screen:
    """The part of a real Screen reading that answer_text uses."""

    def __init__(self, segments):
        self.segments = segments


def fail(what, got, want):
    print("FAIL: %s\n  got:  %r\n  want: %r" % (what, got, want))
    sys.exit(1)


def main():
    # The turn captured in :07-answer.png: under the agent's head is the
    # answer "I am Veltro.", spoken back word for word; directly below it
    # is the separate, empty tile voice mode opens for the next turn — its
    # head "teodorandius - not sent" over "Listening...". The head was new
    # (not in seen) and did not read as a status line, which is exactly
    # how it used to leak into the reply. The head is what the walk stops
    # on, so exercise the factored walk with a head regex built for the
    # captured turn's actual speakers. Answer_text reads the username
    # from the host this runs on (the desktop draws /dev/user, which the
    # emulator takes from the host); pinning it here keeps the assertion
    # deterministic on any machine.
    captured = ["veltro", "I am Veltro.", "teodorandius - not sent", "Listening..."]
    heads = gvt.role_marker(("veltro", "teodorandius"))
    for head in ("teodorandius - not sent", "teodorandius", "veltro"):
        if not heads.match(head.strip()):
            fail("tile head recognized: " + head, heads.match(head.strip()),
                 "a match")
    for body in ("I am Veltro.", "that Veltro said", "is 42"):
        if heads.match(body.strip()):
            fail("body text passes over: " + body, heads.match(body.strip()),
                 "no match")
    reply = gvt.answer_segments(captured, set(), heads=heads)
    if reply != "I am Veltro.":
        fail("reply is only the agent's tile body", reply, "I am Veltro.")

    # luciconv draws "human" instead whenever it cannot read /dev/user,
    # so the same turn under that name must read the same way.
    fallback = ["veltro", "I am Veltro.", "human - not sent", "Listening..."]
    reply = gvt.answer_segments(fallback, set(), heads=gvt.ROLE_MARKER)
    if reply != "I am Veltro.":
        fail("the /dev/user fallback head ends the reply", reply, "I am Veltro.")

    # The module's own marker, over the name it will read on this host, is
    # what the end-to-end run uses; assert the reply exactly rather than
    # merely that something came back.
    live = ["veltro", "I am Veltro.", "%s - not sent" % gvt.USER, "Listening..."]
    wrapper = gvt.answer_text(Screen(live), set())
    if wrapper != "I am Veltro.":
        fail("answer_text stops at this host's own tile head",
             wrapper, "I am Veltro.")

    print("PASS")


if __name__ == "__main__":
    main()