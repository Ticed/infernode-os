#!/usr/bin/env python3
"""A voice turn through the desktop, checked by reading the screen.

The machine's default input and output are pointed at a loopback audio
device before the desktop starts, so InferNode picks them up the way it
picks up a headset: it is given no special configuration and cannot tell
the difference. Everything after that is what a person does — press
Esc-V, say "hey jarvis", speak a request, watch it send, hear the answer.

Every assertion is made against the pixels, through OCR, because every
one of these things is a promise made to the user's eyes:

  - the Voice tile changing from waiting to listening is how they know
    the wake word was heard;
  - partials appearing in the unsent turn are how they know it is
    following along;
  - the "Sending in Ns" countdown is the window in which they can say
    "cancel", so it has to be on screen and it has to count;
  - the answer has to appear as text, be something a person can be read
    aloud, and be spoken word for word as it was written.

The last of those is checked by recording the audio device while the
desktop speaks and transcribing what comes back, then comparing it with
the answer drawn on the screen. Nothing here trusts a log line saying a
sound was made.

Waiting is done by polling for the state that must arrive, never by
sleeping for a guessed interval: timeouts here are failure bounds, not
pacing. The one thing measured in time is the reply's trailing silence,
because "the speaking has stopped" has no other definition.

The driving lives in tools/mac/voice_session.py, which is also runnable
on its own to watch a turn happen. Requires a loopback audio device
(docs/SPEECH-VIRTUAL-AUDIO.md), the speech helpers, an LLM endpoint,
ffmpeg, the Xcode command line tools, and a logged-in desktop session
whose terminal holds Screen Recording and Accessibility permission.
Anything missing is a skip. See docs/VOICE-TESTING.md.
"""

import json
import os
import re
import pwd
import subprocess
import sys
import time
import urllib.request

ROOT = os.environ.get("ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools/mac"))

import voice_session as vs

TMP = vs.TMP
SHOTS = os.path.join(TMP, "gui-voice")
# A question rather than an instruction, on purpose. "Reply with exactly
# ..." is a request to use the say tool, so a turn built on it measures
# how well the model follows the tool protocol as much as it measures the
# voice path — and a model that answers it with an unparsed tool call
# fails here for a reason that has nothing to do with audio.
# Ordinary conversation is also what voice mode is mostly used for.
REQUEST = os.environ.get("GUI_VOICE_REQUEST", vs.REQUEST)

T_PARTIAL = 40       # partials appear while the request is being spoken
T_COUNTDOWN = 40     # the send countdown appears
T_SENT = 30          # ...and completes
T_ANSWER = 180       # the LLM answers
T_SPOKEN = 180       # the answer finishes being spoken

REPLY_SILENCE_S = 1.5    # trailing silence that means the speaking stopped


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def skip(msg):
    print("SKIP: " + msg)
    sys.exit(77)


# Glyphs the OCR cannot tell apart in this font — lowercase L, capital i
# and the digit one all draw as a bare stroke, and O and zero as a ring.
# Folding them is a statement about the reader, not leniency about the
# content: it is applied to both sides, so it can only ever let two
# readings agree, never make them disagree.
CONFUSABLE = str.maketrans({"i": "l", "1": "l", "0": "o"})


def normalize(text):
    return [w.translate(CONFUSABLE) for w in re.findall(r"[a-z0-9]+", text.lower())]


# A turn whose visible answer is a tool call the agent failed to parse:
# `{"name": "say", "parameters": {...}}` drawn as prose and read out loud
# as "name say parameters text ...".
TOOL_CALL_JSON = re.compile(r'\{\s*"?(name|tool|function)"?\s*[:=]', re.I)

# Chrome the pane draws about itself rather than about the conversation:
# the countdown, the queued state, the live listen state. A reply is one
# tile's body, bounded by the tiles' heads (below); these catch status
# text that sits between a tile and the reply.
STATUS_LINE = re.compile(
    r"^(queued follow-up|listening|speaking|voice ready|sending in|voice|thinking)", re.I)


# The pane heads every tile with its speaker's name, so the reply is the
# body under the agent's head, up to the next tile's head - whatever state
# that turn is in. The two speakers:
#   * the agent: "veltro" - the role the conversation service stamps on
#     its turns, and the marker answer_text already searched for;
#   * the human: /dev/user - which the emulator fills with the host user
#     that owns it, getpwuid(getuid())->pw_name (emu/MacOSX/os.c), and a
#     skiplogn boot never replaces it. The same call here, so the test
#     knows the name the pane will draw;
#   * "human" - the name luciconv falls back to whenever it cannot read
#     /dev/user (readdevuser returns it for a failed open, a short read
#     and an empty result alike), so the head is drawn from it too.
AGENT = "veltro"
USER = pwd.getpwuid(os.getuid()).pw_name
FALLBACK_USER = "human"


def role_marker(speakers):
    """A regex for a tile's head: the speaker's name, bare once the turn
    is sent, or with the " - not sent" suffix a turn still carries while
    it is a live draft (luciconv.b: rolelabel = username + " - not sent").
    A segment that heads a new tile ends the reply before it."""
    return re.compile(
        r"^(%s)(\s*-\s*not sent)?$"
        % "|".join(re.escape(s) for s in speakers), re.I)


ROLE_MARKER = role_marker((AGENT, USER, FALLBACK_USER))


def answer_segments(segments, seen, heads=ROLE_MARKER):
    """The reply among ``segments``: the body under the agent's head, up
    to the next tile's head or a segment that was already on screen when
    the answer began. ``seen`` holds the turn being answered, so the
    request tile and any earlier turn are never mistaken for the reply."""
    for i, text in enumerate(segments):
        if text.strip().lower() != AGENT:
            continue
        out = []
        for t in segments[i + 1:]:
            if t in seen or STATUS_LINE.match(t.strip()) or heads.match(t.strip()):
                break
            out.append(t.strip())
        if out:
            return " ".join(out)
    return ""


def answer_text(screen, seen):
    """The reply, read out of the conversation under its role marker."""
    return answer_segments(screen.segments, seen)


def llm_config():
    """The endpoint and model the desktop will actually call."""
    url = os.environ.get("GUI_VOICE_LLM_URL", "http://127.0.0.1:11434/v1")
    try:
        with urllib.request.urlopen(url + "/models", timeout=5) as r:
            models = [m["id"] for m in json.load(r).get("data", [])]
    except Exception as e:
        skip("no LLM endpoint at %s (%s)" % (url, e))
    if not models:
        skip("the LLM endpoint at %s serves no models" % url)
    configured = ""
    userndb = os.path.expanduser("~/.infernode/lib/ndb/llm")
    if os.path.exists(userndb):
        for line in open(userndb):
            if line.startswith("model="):
                configured = line.strip()[6:]
    # The configured model is used when the endpoint has it: a test that
    # failed because a 12B download is missing would be reporting on the
    # machine, not on the voice path. An embedding model answers
    # /v1/models and nothing else, so it can never be the fallback.
    chat = [m for m in models if "embed" not in m.lower()]
    if configured in models:
        model = configured
    elif chat:
        model = chat[0]
    else:
        skip("the LLM endpoint at %s serves only embedding models" % url)

    ndbdir = os.path.join(TMP, "ndb")
    os.makedirs(ndbdir, exist_ok=True)
    open(os.path.join(ndbdir, "llm"), "w").write(
        "mode=local\nbackend=openai\nurl=%s\nmodel=%s\ndial=\n" % (url, model))
    return url, model


def main():
    if sys.platform != "darwin":
        skip("the screen readers are macOS only")
    try:
        vs.require_host_tools()
        url, model = llm_config()
        session = vs.VoiceSession(shots=SHOTS)
    except vs.Unavailable as e:
        skip(str(e))
    if not os.path.exists(REQUEST):
        fail("missing request fixture " + REQUEST)

    index = vs.avfoundation_index(session.device)
    if index is None:
        skip("'%s' is not a capture device ffmpeg can address" % session.device)
    vs.note("virtual audio device: %s" % session.device)
    vs.note("LLM: %s at %s" % (model, url))

    recorder = None
    try:
        with session:
            vs.note("window %s; desktop up" % session.window)
            session.enter_voice_mode()
            vs.note("voice mode on, waiting for the wake word")

            session.wake()
            vs.note("wake word heard: the Voice tile is listening")
            player = session.speak(REQUEST)

            expected = open(os.path.splitext(REQUEST)[0] + ".txt").read().strip()
            keywords = [w for w in normalize(expected) if len(w) >= 3]

            got = session.wait_for(
                lambda s: sum(1 for k in keywords if k in normalize(s.left)) >= 2,
                T_PARTIAL, "no partial transcript appeared while the request was spoken",
                "04-partials.png")
            vs.note("partials on screen: " + got.left)

            counts = []

            def countdown_showing(s):
                m = re.search(r"Sending in (\d+)s", s.left)
                if m and (not counts or counts[-1] != m.group(1)):
                    counts.append(m.group(1))
                return len(counts) >= 2

            session.wait_for(countdown_showing, T_COUNTDOWN,
                             "the send countdown never appeared, or never counted down"
                             + (" (saw %s)" % counts if counts else ""),
                             "05-countdown.png")
            vs.note("countdown visible and counting: " + " to ".join(c + "s" for c in counts))

            before = session.wait_for(lambda s: "Sending in" not in s.left, T_SENT,
                                      "the countdown never completed", "06-sent.png")
            player.wait()

            # From here nothing but the desktop is playing, so anything on
            # the device is its own voice.
            replypcm = os.path.join(TMP, "gui-voice-reply.pcm")
            if os.path.exists(replypcm):
                os.unlink(replypcm)
            recorder = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
                 "-i", ":" + index, "-t", str(T_SPOKEN), "-f", "s16le",
                 "-ar", str(vs.RATE), "-ac", "1", replypcm],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            vs.note("request sent; recording '%s' for the answer" % session.device)

            seen = set(before.segments)
            after = session.wait_for(lambda s: answer_text(s, seen), T_ANSWER,
                                     "the LLM never answered", "07-answer.png")
            answer = answer_text(after, seen)
            vs.note("answer on screen: " + answer)
            # One spoken turn is one conversation entry. A leftover
            # "Queued follow-up — not sent — delivered — 0/1" tile is a defect.
            if re.search(r"queued follow-up", after.left, re.I):
                fail("the answered turn is also drawn as a queued follow-up: "
                     + after.left)


            # An answer is something a person can be read. A raw tool call
            # is not, and the fact that it was faithfully spoken is not a
            # mitigation — it is the failure.
            if TOOL_CALL_JSON.search(answer) or answer.count('"') > 2:
                fail("the answer is an unparsed tool call, not something to say aloud: "
                     + answer)

            # "The speaking has stopped" is the one thing with no state to
            # poll for: wait until the device has been quiet for long
            # enough after it was loud.
            deadline = time.monotonic() + T_SPOKEN
            while time.monotonic() < deadline:
                w = vs.speech_bounds(replypcm)
                if w and w[2] - w[1] >= REPLY_SILENCE_S:
                    break
            else:
                fail("the answer was still being spoken after %ds" % T_SPOKEN)
            recorder.terminate()
            recorder.wait()

            first, last, length = vs.speech_bounds(replypcm)
            vs.note("answer spoken over %.1fs of the recording" % (last - first))

            heard = vs.transcribe(replypcm)
            if not heard:
                fail("nothing was heard on '%s' after the answer appeared — "
                     "it was never spoken" % session.device)
            vs.note("answer heard: " + heard)

            want, got_words = normalize(answer), normalize(heard)
            # Every word, in order. The screen and the speaker are two
            # renderings of one answer, so anything less than exact
            # agreement means the user was told two different things.
            if want != got_words:
                missing = [w for w in want if w not in got_words]
                extra = [w for w in got_words if w not in want]
                fail("the spoken answer is not word for word what the screen says.\n"
                     "  screen: %s\n  heard:  %s\n  on screen but not heard: %s\n"
                     "  heard but not on screen: %s"
                     % (" ".join(want), " ".join(got_words),
                        " ".join(missing) or "(none)", " ".join(extra) or "(none)"))
            vs.note("screen and audio agree word for word (%d words)" % len(want))

        print("PASS: a wake word, a request, a countdown, an LLM turn and a spoken "
              "answer, all through '%s', all verified on screen" % session.device)
        print("PASS")
    except vs.Timeout as e:
        fail(str(e))
    except vs.Unavailable as e:
        skip(str(e))
    finally:
        if recorder and recorder.poll() is None:
            recorder.terminate()
        vs.note("default input and output restored")


if __name__ == "__main__":
    main()
