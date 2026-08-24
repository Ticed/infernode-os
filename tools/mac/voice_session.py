#!/usr/bin/env python3
"""Drive the InferNode desktop's voice mode from the host, and read the screen.

Import it to write a test, or run it to watch a turn happen:

    python3 tools/mac/voice_session.py --watch 45
    python3 tools/mac/voice_session.py --say tests/fixtures/speech/kokoro/what_is_your_name.pcm

It handles the parts that are the same every time and are each worth
getting wrong exactly once:

  - pointing the machine's default input and output at a loopback audio
    device *before* the desktop starts, and putting them back afterwards.
    The desktop resolves the system default when it opens capture, so
    switching afterwards changes nothing;
  - finding the emulator's window by the pid of the process just started,
    because the window server keeps listing a window after its process is
    gone and capturing that one fails in a way that looks like a GUI bug;
  - pressing Esc-V until the screen shows it landed, because a window that
    is still taking focus drops the keys;
  - saying the wake word, then waiting to be told it is listening before
    speaking. Playing the wake word and the request as one stream loses the
    first words of the request: the listen session opens on the wake event,
    part-way through the sentence.

Everything waits by polling for the state that must arrive. Timeouts are
failure bounds, not pacing.

Requires a loopback audio device (docs/SPEECH-VIRTUAL-AUDIO.md), the speech
helpers, and a logged-in session whose terminal holds Screen Recording and
Accessibility permission. See docs/VOICE-TESTING.md.
"""

import importlib.util
import os
import re
import struct
import subprocess
import sys
import time

ROOT = os.environ.get("ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TMP = os.path.join(ROOT, ".omx/tmp")
BIN = os.path.join(TMP, "bin")
HELPERS = os.environ.get("INFERNODE_SPEECH_HOME",
                         os.path.expanduser("~/.local/share/infernode-speech"))
# Scripted user speech must not share Veltro's TTS voice. The same voice
# on both sides makes a recording ambiguous (who said what) and weakens
# any self-pickup or barge-in assertion. Distinct gender and accent.
VELTRO_VOICE = "af_bella"  # American female — the stack's default TTS
USER_VOICE = "bm_george"   # British male — committed user fixtures
WAKE = os.path.join(ROOT, "tests/fixtures/speech/kokoro/hey_jarvis.pcm")
REQUEST = os.path.join(ROOT, "tests/fixtures/speech/kokoro/what_is_your_name.pcm")
RATE = 16000

_spec = importlib.util.spec_from_file_location(
    "ui_probe", os.path.join(ROOT, "tools/mac/ui-probe.py"))
ui_probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ui_probe)


class Unavailable(Exception):
    """Something the host does not provide. Callers usually skip on this."""


def run(cmd, **kw):
    # ROOT is passed down explicitly: the shell helpers resolve the
    # emulator through it, and an importer need not have exported it.
    env = dict(os.environ, ROOT=ROOT)
    env.update(kw.pop("env", {}) or {})
    return subprocess.run(cmd, capture_output=True, text=True, env=env, **kw)


def note(msg):
    print(msg, flush=True)


# ── host tools ──────────────────────────────────────────────────────

def build_tools():
    """Compile the window locator and the OCR reader if they are stale."""
    if run(["xcrun", "--find", "swiftc"]).returncode != 0:
        raise Unavailable("the Xcode command line tools are needed to build the screen readers")
    os.makedirs(BIN, exist_ok=True)
    for name in ("window-info", "ocr"):
        src = os.path.join(ROOT, "tools/mac", name + ".swift")
        out = os.path.join(BIN, name)
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            continue
        r = run(["xcrun", "swiftc", "-O", src, "-o", out])
        if r.returncode != 0:
            raise Unavailable("cannot build %s: %s" % (name, r.stderr.strip()[-200:]))


def require_host_tools(extra=()):
    for tool in ("ffmpeg", "SwitchAudioSource", "afplay", "screencapture") + tuple(extra):
        if run(["which", tool]).returncode != 0:
            raise Unavailable("%s is needed (brew install ffmpeg switchaudio-osx)" % tool)
    if not os.path.isdir(os.path.join(HELPERS, "bin")):
        raise Unavailable("no speech helpers installed — run tools/install-speech-helpers.sh")
    build_tools()


# ── audio devices ───────────────────────────────────────────────────

def audio_device(kind):
    return run(["SwitchAudioSource", "-c", "-t", kind]).stdout.strip()


def set_audio_device(kind, name):
    r = run(["SwitchAudioSource", "-t", kind, "-s", name])
    if r.returncode != 0:
        raise Unavailable("cannot select '%s' as the default %s: %s"
                          % (name, kind, r.stderr.strip()))


def loopback_device():
    """The loopback device tools/virtual-audio.sh would pick, or None."""
    out = run(["bash", "-c", '. "%s/tools/virtual-audio.sh"; va_find_device' % ROOT]).stdout.strip()
    return out or None


def avfoundation_index(name):
    """ffmpeg addresses capture devices by index, and indices shift."""
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


def play(path):
    """Play a file out of the default output, which is the virtual device."""
    return subprocess.Popen(["afplay", path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wav_from_pcm(pcm, wav):
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "s16le", "-ar", str(RATE), "-ac", "1", "-i", pcm, wav])
    return wav


def samples(path):
    raw = open(path, "rb").read()
    n = len(raw) // 2
    return list(struct.unpack("<%dh" % n, raw[:n * 2]))


def trim(s, front, back, block=RATE // 100, floor=300):
    """Drop leading or trailing near-silence, in 10 ms blocks."""
    blocks = [s[i:i + block] for i in range(0, len(s), block)]
    quiet = lambda b: max((abs(v) for v in b), default=0) < floor
    while front and blocks and quiet(blocks[0]):
        blocks.pop(0)
    while back and blocks and quiet(blocks[-1]):
        blocks.pop()
    return [v for b in blocks for v in b]


def speech_bounds(path, rms_floor=0.01, window=RATE // 4):
    """(first, last, length) seconds of speech in a recording, or None."""
    if not os.path.exists(path):
        return None
    s = samples(path)
    first = last = None
    for i in range(0, max(1, len(s) - window), window):
        block = s[i:i + window]
        rms = (sum(float(v) * v for v in block) / max(1, len(block))) ** 0.5 / 32768.0
        if rms >= rms_floor:
            first = i / RATE if first is None else first
            last = (i + window) / RATE
    if first is None:
        return None
    return first, last, len(s) / RATE


def transcribe(path):
    """What the local STT helper hears in a recording."""
    return run(["bash", os.path.join(ROOT, "tools/transcribe-pcm.sh"), path]).stdout.strip()


# ── reading the screen ──────────────────────────────────────────────

class Screen:
    """One reading of the window: the Voice tile, and the left pane."""

    def __init__(self, rows):
        self.rows = rows
        self.width = max((x + w for x, y, w, h, _ in rows), default=1)

    @property
    def voice(self):
        """The Voice resource tile's status word: waiting, listening, sending…"""
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


class Timeout(Exception):
    def __init__(self, what, timeout, screen):
        self.screen = screen
        super().__init__("%s within %ds. The screen showed: voice=%s | %s"
                         % (what, timeout,
                            screen.voice if screen else "?",
                            screen.left if screen else "?"))


class VoiceSession:
    """A desktop booted with voice mode, driven the way a person drives it."""

    # Failure bounds, not pacing.
    T_WINDOW = 90
    T_DESKTOP = 120
    T_VOICEMODE = 30
    T_WAKE = 30

    def __init__(self, device=None, shots=None, llm_ndb="/.omx/tmp/ndb"):
        self.device = device or loopback_device()
        if not self.device:
            raise Unavailable("no virtual loopback audio device — "
                              "brew install --cask blackhole-2ch")
        self.shots = shots
        self.llm_ndb = llm_ndb
        self.emu = None
        self.window = None
        self.bounds = None
        self._restore = {}
        if shots:
            os.makedirs(shots, exist_ok=True)

    # -- lifecycle --

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.stop()
        return False

    def start(self):
        """Point the default devices at the loopback device, then boot."""
        self._restore = {"output": audio_device("output"), "input": audio_device("input")}
        set_audio_device("output", self.device)
        set_audio_device("input", self.device)

        self.emu = subprocess.Popen(
            [os.path.join(ROOT, "emu/MacOSX/o.emu"), "-c1",
             "-pheap=1024m", "-pmain=1024m", "-pimage=1024m", "-r" + ROOT,
             "sh", "-l", "/lib/lucifer/boot-voicetest.sh",
             os.path.join(HELPERS, "bin"), self.llm_ndb],
            stdout=open(os.path.join(TMP, "voice-session-emu.log"), "w"),
            stderr=subprocess.STDOUT, env=dict(os.environ, ROOT=ROOT))

        deadline = time.monotonic() + self.T_WINDOW
        while time.monotonic() < deadline and self.window is None:
            # CGWindowList's on-screen filter misses a window created
            # behind a fullscreen app. Raise the emulator each poll.
            run(["osascript", "-e",
                 'tell application "System Events" to set frontmost of process "o.emu" to true'])
            for line in run([os.path.join(BIN, "window-info"), "o.emu"]).stdout.splitlines():
                fields = line.split()
                if len(fields) > 1 and fields[1] == str(self.emu.pid):
                    self.window = fields[0]
                    self.bounds = [int(v) for v in fields[2:6]]
                    break
        if self.window is None:
            raise Timeout("the desktop's window never appeared", self.T_WINDOW, None)

        self.wait_for(lambda s: "Tasks" in s.left or "No messages yet" in s.left,
                      self.T_DESKTOP,
                      "the desktop never drew itself", "01-desktop.png")
        return self

    def stop(self):
        if self.emu and self.emu.poll() is None:
            self.emu.terminate()
            try:
                self.emu.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.emu.kill()
        subprocess.run(["pkill", "-f", "o.emu.*boot-voicetest"], capture_output=True)
        for kind, name in self._restore.items():
            if name:
                run(["SwitchAudioSource", "-t", kind, "-s", name])
        self._restore = {}

    # -- reading --

    def read(self, keep=None):
        return Screen(ui_probe.probe(self.window, keep))

    def shot(self, name):
        if self.shots and name:
            self.read(os.path.join(self.shots, name))

    def wait_for(self, predicate, timeout, what, shot=None):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = self.read()
            if predicate(last):
                self.shot(shot)
                return last
        raise Timeout(what, timeout, last)

    def press_until(self, predicate, script, timeout, what, shot=None):
        """Send a keystroke until the screen shows it landed."""
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            self.keystroke(script)
            attempt = time.monotonic() + 5
            while time.monotonic() < attempt:
                last = self.read()
                if predicate(last):
                    self.shot(shot)
                    return last
        raise Timeout(what, timeout, last)

    # -- driving --

    def keystroke(self, script):
        r = run(["osascript"] + sum([["-e", line] for line in script], []))
        if r.returncode != 0:
            raise Unavailable("cannot send keystrokes (grant the terminal "
                              "Accessibility permission): " + r.stderr.strip())

    def enter_voice_mode(self):
        """Esc-V, the way in when the pointer is elsewhere."""
        return self.press_until(
            lambda s: s.voice == "waiting",
            ['tell application "System Events" to set frontmost of process "o.emu" to true',
             "delay 0.4",
             'tell application "System Events" to key code 53',
             'tell application "System Events" to keystroke "v"'],
            self.T_VOICEMODE, "voice mode did not turn on", "02-voice-mode.png")


    def wake(self, pcm=WAKE):
        """Say the wake word and wait to be told it is listening."""
        wav = wav_from_pcm_trimmed(pcm, os.path.join(TMP, "voice-session-wake.wav"),
                                   front=False, back=True)
        play(wav).wait()
        return self.wait_for(lambda s: s.voice == "listening" or "Listening" in s.left,
                             self.T_WAKE,
                             "the wake word never reached the desktop", "03-wake.png")

    def speak(self, pcm):
        """Play a request into the device. Returns the running player."""
        wav = wav_from_pcm_trimmed(pcm, os.path.join(TMP, "voice-session-request.wav"),
                                   front=True, back=False)
        return play(wav)


def wav_from_pcm_trimmed(pcm, wav, front, back):
    trimmed = wav.replace(".wav", ".pcm")
    s = trim(samples(pcm), front, back)
    open(trimmed, "wb").write(struct.pack("<%dh" % len(s), *s))
    return wav_from_pcm(trimmed, wav)


# ── CLI: watch a turn ───────────────────────────────────────────────

def main(argv):
    request = None
    watch = 45.0
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--say":
            request = args.pop(0)
        elif a == "--watch":
            watch = float(args.pop(0))
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("unknown option " + a, file=sys.stderr)
            return 2

    try:
        require_host_tools()
        session = VoiceSession(shots=os.path.join(TMP, "voice-session"))
    except Unavailable as e:
        print("unavailable: %s" % e, file=sys.stderr)
        return 77

    with session:
        note("window %s at %s, device '%s'" % (session.window, session.bounds, session.device))
        session.enter_voice_mode()
        note("voice mode on")
        session.wake()
        note("wake word heard")
        if request:
            session.speak(request)
            note("speaking " + request)
        # Print every change the screen goes through, with timings, which is
        # what an investigation actually wants to see.
        start = time.monotonic()
        last = None
        while time.monotonic() - start < watch:
            s = session.read()
            now = (s.voice, s.left)
            if now != last:
                note("%6.2fs voice=%-10s %s" % (time.monotonic() - start, s.voice, s.left))
                last = now
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
