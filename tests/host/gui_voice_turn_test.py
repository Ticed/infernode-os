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

Requires: a loopback audio device (docs/SPEECH-VIRTUAL-AUDIO.md), the
speech helpers, an LLM endpoint, ffmpeg, the Xcode command line tools,
and a logged-in desktop session whose terminal holds Screen Recording
and Accessibility permission. Anything missing is a skip.
"""

import json
import os
import re
import struct
import subprocess
import sys
import time
import urllib.request

ROOT = os.environ.get("ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
sys.path.insert(0, os.path.join(ROOT, "tools/mac"))

TMP = os.path.join(ROOT, ".omx/tmp")
SHOTS = os.path.join(TMP, "gui-voice")
BIN = os.path.join(TMP, "bin")
HELPERS = os.environ.get("INFERNODE_SPEECH_HOME", os.path.expanduser("~/.local/share/infernode-speech"))
WAKE = "tests/fixtures/speech/kokoro/hey_jarvis.pcm"
# A question rather than an instruction, on purpose. "Reply with exactly
# ..." is a request to use the say tool, so a turn built on it measures
# how well the model follows the tool protocol as much as it measures
# the voice path — and a model that answers it with an unparsed tool call
# (INF-27) fails here for a reason that has nothing to do with audio.
# Ordinary conversation is also what voice mode is mostly used for.
REQUEST = os.environ.get("GUI_VOICE_REQUEST",
                         "tests/fixtures/speech/kokoro/what_is_your_name.pcm")
RATE = 16000
GAP_MS = 150

# Failure bounds, not pacing. Each is generous enough that hitting one
# means the step is not happening at all.
T_WINDOW = 90        # the desktop's window appears
T_DESKTOP = 120      # ...and has drawn itself
T_VOICEMODE = 30     # Esc-V is picked up
T_WAKE = 30          # the wake word crosses the device and lights the tile
T_PARTIAL = 40       # partials appear while the request is being spoken
T_COUNTDOWN = 40     # the send countdown appears
T_SENT = 30          # ...and completes
T_ANSWER = 180       # the LLM answers
T_SPOKEN = 180       # the answer finishes being spoken

REPLY_SILENCE_S = 1.5    # trailing silence that means the speaking stopped
SPEECH_RMS = 0.01        # a spoken word against a silent virtual device


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def skip(msg):
    print("SKIP: " + msg)
    sys.exit(77)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def note(msg):
    print(msg, flush=True)


# ── host helpers ────────────────────────────────────────────────────

def build_tools():
    """Compile the window locator and the OCR reader if they are stale."""
    if not run(["xcrun", "--find", "swiftc"]).returncode == 0:
        skip("the Xcode command line tools are needed to build the screen readers")
    os.makedirs(BIN, exist_ok=True)
    for name in ("window-info", "ocr"):
        src = os.path.join(ROOT, "tools/mac", name + ".swift")
        out = os.path.join(BIN, name)
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            continue
        r = run(["xcrun", "swiftc", "-O", src, "-o", out])
        if r.returncode != 0:
            skip("cannot build %s: %s" % (name, r.stderr.strip().splitlines()[-1:]))


def audio_device(kind):
    return run(["SwitchAudioSource", "-c", "-t", kind]).stdout.strip()


def set_audio_device(kind, name):
    r = run(["SwitchAudioSource", "-t", kind, "-s", name])
    if r.returncode != 0:
        fail("cannot select '%s' as the default %s: %s" % (name, kind, r.stderr.strip()))


def loopback_device():
    r = run(["bash", "-c", '. "%s/tools/virtual-audio.sh"; va_find_device' % ROOT])
    return r.stdout.strip()


def avfoundation_index(name):
    r = run(["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""])
    audio = False
    for line in (r.stderr or "").splitlines():
        if "AVFoundation audio devices" in line:
            audio = True
            continue
        if not audio:
            continue
        m = re.search(r"\[(\d+)\] (.+)$", line)
        if m and m.group(2).strip() == name:
            return m.group(1)
    return None


def keystroke(script):
    r = run(["osascript"] + sum([["-e", line] for line in script], []))
    if r.returncode != 0:
        skip("cannot send keystrokes (grant the terminal Accessibility permission): " + r.stderr.strip())


def play(path):
    """Play a file out of the default output, which is the virtual device."""
    return subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wav_from_pcm(pcm, wav):
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "s16le", "-ar", str(RATE), "-ac", "1", "-i", pcm, wav], check=False)


def samples(path):
    raw = open(path, "rb").read()
    n = len(raw) // 2
    return list(struct.unpack("<%dh" % n, raw[:n * 2]))


def joined_stream(out):
    """The wake word and the request, trimmed and joined.

    Both fixtures carry padding, and if the join reaches the turn gate's
    silence window the desktop commits "hey jarvis" as a turn of its own.
    """
    block, floor = RATE // 100, 300

    def trim(s, front, back):
        blocks = [s[i:i + block] for i in range(0, len(s), block)]
        quiet = lambda b: max((abs(v) for v in b), default=0) < floor
        while front and blocks and quiet(blocks[0]):
            blocks.pop(0)
        while back and blocks and quiet(blocks[-1]):
            blocks.pop()
        return [v for b in blocks for v in b]

    for path, name, front, back in (
            (WAKE, "wake", False, True),
            (REQUEST, "request", True, False)):
        s = trim(samples(path), front, back)
        open(out % name, "wb").write(struct.pack("<%dh" % len(s), *s))


# ── reading the screen ──────────────────────────────────────────────

import importlib.util

_spec = importlib.util.spec_from_file_location("ui_probe", os.path.join(ROOT, "tools/mac/ui-probe.py"))
ui_probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ui_probe)


class Screen:
    """One reading of the window: the Voice tile, and the left pane."""

    def __init__(self, rows, width):
        self.rows = rows
        self.width = width

    @property
    def voice(self):
        for x, y, w, h, text in self.rows:
            if text.lstrip("• ").strip().lower() == "voice" and x > self.width * 0.5:
                right = [t for x2, y2, w2, h2, t in self.rows
                         if abs(y2 - y) < h and x2 > x + w]
                if right:
                    return right[-1].strip().lower()
        return ""

    @property
    def segments(self):
        return [t for x, y, w, h, t in sorted(self.rows, key=lambda r: (r[1], r[0]))
                if x < self.width * 0.5]

    @property
    def left(self):
        return " | ".join(self.segments)


def read_screen(window, keep=None):
    rows = ui_probe.probe(window, keep)
    width = max((x + w for x, y, w, h, _ in rows), default=1)
    return Screen(rows, width)


def press_until(window, predicate, script, timeout, what, shot=None):
    """Send a keystroke until the screen shows it landed."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        keystroke(script)
        attempt = time.monotonic() + 5
        while time.monotonic() < attempt:
            last = read_screen(window)
            if predicate(last):
                if shot:
                    read_screen(window, os.path.join(SHOTS, shot))
                return last
    fail("%s within %ds. The screen showed: voice=%s | %s"
         % (what, timeout, last.voice if last else "?", last.left if last else "?"))


def wait_for(window, predicate, timeout, what, shot=None):
    """Poll the screen until it shows something, or say what it showed."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = read_screen(window)
        if predicate(last):
            if shot:
                read_screen(window, os.path.join(SHOTS, shot))
            return last
    fail("%s within %ds. The screen showed: voice=%s | %s"
         % (what, timeout, last.voice if last else "?", last.left if last else "?"))


# ── the reply's audio ───────────────────────────────────────────────

def speech_windows(path):
    """(first, last) seconds containing speech, or None."""
    if not os.path.exists(path):
        return None
    s = samples(path)
    win = RATE // 4
    first = last = None
    for i in range(0, max(1, len(s) - win), win):
        block = s[i:i + win]
        rms = (sum(float(v) * v for v in block) / max(1, len(block))) ** 0.5 / 32768.0
        if rms >= SPEECH_RMS:
            first = i / RATE if first is None else first
            last = (i + win) / RATE
    if first is None:
        return None
    return first, last, len(s) / RATE


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
# as "name say parameters text ...". See INF-27.
TOOL_CALL_JSON = re.compile(r'\{\s*"?(name|tool|function)"?\s*[:=]', re.I)


# Lines the pane draws about itself rather than about the conversation.
STATUS_LINE = re.compile(
    r"^(queued follow-up|listening|speaking|voice ready|sending in|voice|thinking)",
    re.I)


def answer_text(screen, seen):
    """The reply, read out of the conversation under its role marker."""
    segments = screen.segments
    for i, text in enumerate(segments):
        if text.strip().lower() != "veltro":
            continue
        out = []
        for t in segments[i + 1:]:
            if t in seen or STATUS_LINE.match(t.strip()):
                break
            out.append(t.strip())
        if out:
            return " ".join(out)
    return ""


def main():
    if sys.platform != "darwin":
        skip("the screen readers are macOS only")
    for tool in ("ffmpeg", "SwitchAudioSource", "afplay", "screencapture"):
        if run(["which", tool]).returncode != 0:
            skip("%s is needed (brew install ffmpeg switchaudio-osx)" % tool)
    if not os.path.isdir(os.path.join(HELPERS, "bin")):
        skip("no speech helpers installed — run tools/install-speech-helpers.sh")
    os.makedirs(SHOTS, exist_ok=True)
    build_tools()

    device = loopback_device()
    if not device:
        skip("no virtual loopback audio device — brew install --cask blackhole-2ch")
    note("virtual audio device: " + device)

    index = avfoundation_index(device)
    if index is None:
        skip("'%s' is not a capture device ffmpeg can address" % device)

    # The LLM the desktop will actually call. The configured model is
    # used when the endpoint has it; a test that fails because a 12B
    # download is missing would be reporting on the machine, not on the
    # voice path.
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
    # An embedding model answers /v1/models and nothing else, so it must
    # never be picked as the fallback.
    chat = [m for m in models if "embed" not in m.lower()]
    if configured in models:
        model = configured
    elif chat:
        model = chat[0]
    else:
        skip("the LLM endpoint at %s serves only embedding models" % url)
    note("LLM: %s at %s" % (model, url))

    ndbdir = os.path.join(TMP, "ndb")
    os.makedirs(ndbdir, exist_ok=True)
    open(os.path.join(ndbdir, "llm"), "w").write(
        "mode=local\nbackend=openai\nurl=%s\nmodel=%s\ndial=\n" % (url, model))

    joined_stream(os.path.join(TMP, "gui-voice-%s.pcm"))
    speech = {}
    for name in ("wake", "request"):
        speech[name] = os.path.join(TMP, "gui-voice-%s.wav" % name)
        wav_from_pcm(os.path.join(TMP, "gui-voice-%s.pcm" % name), speech[name])

    original = {"output": audio_device("output"), "input": audio_device("input")}
    emu = None
    recorder = None
    try:
        # Before the desktop starts, so it resolves the system default to
        # the loopback device the way any Mac application would.
        set_audio_device("output", device)
        set_audio_device("input", device)
        note("default input and output set to '%s'" % device)

        env = dict(os.environ, ROOT=ROOT)
        emu = subprocess.Popen(
            [os.path.join(ROOT, "emu/MacOSX/o.emu"), "-c1",
             "-pheap=1024m", "-pmain=1024m", "-pimage=1024m", "-r" + ROOT,
             "sh", "-l", "/lib/lucifer/boot-voicetest.sh",
             os.path.join(HELPERS, "bin"), "/.omx/tmp/ndb"],
            stdout=open(os.path.join(TMP, "gui-voice-emu.log"), "w"),
            stderr=subprocess.STDOUT, env=env)

        # Match the window to the process just started: the window server
        # keeps listing a window for a moment after its process is gone,
        # and capturing that one fails in a way that looks like a GUI bug.
        deadline = time.monotonic() + T_WINDOW
        window = None
        while time.monotonic() < deadline and window is None:
            for line in run([os.path.join(BIN, "window-info"), "o.emu"]).stdout.splitlines():
                fields = line.split()
                if len(fields) > 1 and fields[1] == str(emu.pid):
                    window = fields[0]
                    break
        if window is None:
            fail("the desktop's window never appeared within %ds" % T_WINDOW)
        note("window %s" % window)

        wait_for(window, lambda s: "Tasks" in s.left, T_DESKTOP,
                 "the desktop never drew itself", "01-desktop.png")
        note("desktop up")

        # Esc-V is the documented way in, and it is the one a user reaches
        # for when the pointer is elsewhere. A window that is still taking
        # focus drops the keys, so press again until the desktop shows it
        # arrived rather than pressing once and hoping.
        press_until(window, lambda s: s.voice == "waiting",
                    ['tell application "System Events" to set frontmost of process "o.emu" to true',
                     "delay 0.4",
                     'tell application "System Events" to key code 53',
                     'tell application "System Events" to keystroke "v"'],
                    T_VOICEMODE, "voice mode did not turn on", "02-voice-mode.png")
        note("voice mode on, waiting for the wake word")

        # Say the wake word, then wait to be told it is listening before
        # speaking — which is both what the indicator is for and what
        # keeps the first words of the request out of the wake event.
        play(speech["wake"]).wait()
        wait_for(window, lambda s: s.voice == "listening", T_WAKE,
                 "the wake word never reached the desktop", "03-wake.png")
        note("wake word heard: the Voice tile is listening")
        player = play(speech["request"])

        expected = open(os.path.splitext(REQUEST)[0] + ".txt").read().strip()
        keywords = [w for w in normalize(expected) if len(w) >= 3]

        def partial_showing(s):
            words = normalize(s.left)
            return sum(1 for k in keywords if k in words) >= 2

        got = wait_for(window, partial_showing, T_PARTIAL,
                       "no partial transcript appeared while the request was spoken",
                       "04-partials.png")
        note("partials on screen: " + got.left)

        counts = []

        def countdown_showing(s):
            m = re.search(r"Sending in (\d+)s", s.left)
            if m and (not counts or counts[-1] != m.group(1)):
                counts.append(m.group(1))
            return len(counts) >= 2

        wait_for(window, countdown_showing, T_COUNTDOWN,
                 "the send countdown never appeared, or never counted down"
                 + (" (saw %s)" % counts if counts else ""),
                 "05-countdown.png")
        note("countdown visible and counting: " + " to ".join(c + "s" for c in counts))

        before = wait_for(window, lambda s: "Sending in" not in s.left, T_SENT,
                          "the countdown never completed", "06-sent.png")
        player.wait()

        # From here nothing but the desktop is playing, so anything on the
        # device is its own voice.
        replypcm = os.path.join(TMP, "gui-voice-reply.pcm")
        if os.path.exists(replypcm):
            os.unlink(replypcm)
        recorder = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
             "-i", ":" + index, "-t", str(T_SPOKEN), "-f", "s16le",
             "-ar", str(RATE), "-ac", "1", replypcm],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        note("request sent; recording '%s' for the answer" % device)

        seen = set(before.segments)
        after = wait_for(window, lambda s: answer_text(s, seen), T_ANSWER,
                         "the LLM never answered", "07-answer.png")
        answer = answer_text(after, seen)
        note("answer on screen: " + answer)

        # An answer is something a person can be read. A raw tool call is
        # not, and the fact that it was faithfully spoken is not a
        # mitigation — it is the failure.
        if TOOL_CALL_JSON.search(answer) or answer.count('"') > 2:
            fail("the answer is an unparsed tool call, not something to say aloud "
                 "(INF-27): " + answer)

        # "The speaking has stopped" is the one thing with no state to
        # poll for: wait until the device has been quiet for long enough
        # after it was loud.
        deadline = time.monotonic() + T_SPOKEN
        while time.monotonic() < deadline:
            w = speech_windows(replypcm)
            if w and w[2] - w[1] >= REPLY_SILENCE_S:
                break
        else:
            fail("the answer was still being spoken after %ds" % T_SPOKEN)
        recorder.terminate()
        recorder.wait()
        first, last, length = speech_windows(replypcm)
        note("answer spoken over %.1fs of the recording" % (last - first))

        heard = run(["bash", os.path.join(ROOT, "tools/transcribe-pcm.sh"), replypcm]).stdout.strip()
        if not heard:
            fail("nothing was heard on '%s' after the answer appeared — it was never spoken" % device)
        note("answer heard: " + heard)

        want = normalize(answer)
        got_words = normalize(heard)
        # Every word, in order. The screen and the speaker are two
        # renderings of one answer, so anything less than exact agreement
        # means the user was told two different things.
        if want != got_words:
            missing = [w for w in want if w not in got_words]
            extra = [w for w in got_words if w not in want]
            fail("the spoken answer is not word for word what the screen says.\n"
                 "  screen: %s\n  heard:  %s\n  on screen but not heard: %s\n"
                 "  heard but not on screen: %s"
                 % (" ".join(want), " ".join(got_words),
                    " ".join(missing) or "(none)", " ".join(extra) or "(none)"))
        note("screen and audio agree word for word (%d words)" % len(want))

        print("PASS: a wake word, a request, a countdown, an LLM turn and a spoken "
              "answer, all through '%s', all verified on screen" % device)
        print("PASS")
    finally:
        if recorder and recorder.poll() is None:
            recorder.terminate()
        if emu and emu.poll() is None:
            emu.terminate()
            try:
                emu.wait(timeout=10)
            except subprocess.TimeoutExpired:
                emu.kill()
        subprocess.run(["pkill", "-f", "o.emu.*boot-voicetest"], capture_output=True)
        for kind, name in original.items():
            if name:
                run(["SwitchAudioSource", "-t", kind, "-s", name])
        note("default input and output restored")


main()
