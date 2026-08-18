#!/usr/bin/env python3
"""Time what the InferNode window draws, to a twentieth of a second.

    python3 tools/mac/ui-timeline.py --drive tests/fixtures/speech/kokoro/what_is_your_name.pcm
    python3 tools/mac/ui-timeline.py --window 1193 --seconds 30

Screenshot polling through OCR takes ~0.6s a frame, so it cannot see a
tile that appears and disappears inside half a second — and several of
the voice UI's defects are exactly that (INF-32). This records the screen
as video instead and measures each frame, which puts the resolution at
the sampling rate rather than at the speed of the reader.

What it measures per frame, in the conversation pane:

    accent   pixels of the orange accent — status text, tile titles
    blue     pixels of the blue speaking indicator
    tile     pixels lighter than the pane background — how much is drawn

It prints every change, then the runs each signal was visible for. A tile
that flashes shows up as a run of 0.05–0.20s; one a person can read does
not.

--drive boots the desktop, enters voice mode, says the wake word and
speaks the given request, so one command reproduces a whole turn. Without
it, pass --window and drive the desktop yourself while it records.

The recording covers the whole display, including whatever else is on it,
and is deleted when the analysis finishes unless --keep is given.
"""

import glob
import os
import shutil
import subprocess
import sys
import time

ROOT = os.environ.get("ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools/mac"))
import voice_session as vs           # noqa: E402

WORK = os.path.join(vs.TMP, "ui-timeline")
FPS = 20


def analyse(frames, fps):
    """Per-frame pixel counts for the signals worth timing."""
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        sys.exit("ui-timeline: needs numpy and pillow (pip3 install numpy pillow)")

    rows = []
    for i, path in enumerate(sorted(frames)):
        im = np.array(Image.open(path).convert("RGB")).astype(int)
        pane = im.copy()
        pane[-95:, 500:] = 0            # mask the always-on voice chip
        r, g, b = pane[:, :, 0], pane[:, :, 1], pane[:, :, 2]
        rows.append((
            i / fps,
            int(((r > 140) & (r > g + 60) & (r > b + 60)).sum()),      # accent
            int(((b > 110) & (b > r + 35) & (b > g + 25)).sum()),      # blue
            int(((r + g + b) > 60).sum()),                             # tile
        ))
    return rows


def runs(rows, column, threshold):
    out, start = [], None
    for row in rows:
        on = row[column] > threshold
        if on and start is None:
            start = row[0]
        elif not on and start is not None:
            out.append((start, row[0]))
            start = None
    if start is not None:
        out.append((start, rows[-1][0]))
    return out


def main(argv):
    window = seconds = drive = None
    keep = False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--window":
            window = args.pop(0)
        elif a == "--seconds":
            seconds = float(args.pop(0))
        elif a == "--drive":
            drive = args.pop(0)
        elif a == "--keep":
            keep = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("unknown option " + a, file=sys.stderr)
            return 2
    if not window and not drive:
        print(__doc__, file=sys.stderr)
        return 2
    seconds = seconds or (45 if drive else 30)

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    mov = os.path.join(WORK, "screen.mov")

    session = None
    try:
        if drive:
            vs.require_host_tools()
            session = vs.VoiceSession(shots=WORK)
            session.start()
            session.enter_voice_mode()
            window, bounds = session.window, session.bounds
        else:
            listing = vs.run([os.path.join(vs.BIN, "window-info"), "o.emu"]).stdout
            info = [l.split() for l in listing.splitlines()]
            if not info:
                sys.exit("ui-timeline: no InferNode window on screen")
            bounds = [int(v) for v in info[0][2:6]]

        recorder = subprocess.Popen(["screencapture", "-v", "-V", str(int(seconds)), "-x", mov])
        marks = []
        start = time.monotonic()
        if drive:
            time.sleep(3)               # let the recorder get going
            session.wake()
            marks.append(("wake heard", time.monotonic() - start))
            session.speak(drive)
            marks.append(("request spoken", time.monotonic() - start))
        recorder.wait()

        # The window bounds are in points; the recording is in pixels.
        probe = vs.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                        "-show_entries", "stream=width", "-of", "csv=p=0", mov]).stdout.strip()
        scale = 2 if int(probe.split(",")[0]) > 2600 else 1
        x, y, w, h = (v * scale for v in bounds)
        # The conversation pane: the bottom-left of the window.
        crop = "crop=%d:%d:%d:%d" % (min(1100, w), min(600, h), x, y + h - min(600, h))
        vs.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", mov,
                "-vf", "%s,fps=%d" % (crop, FPS), os.path.join(WORK, "f%04d.png")])

        rows = analyse(glob.glob(os.path.join(WORK, "f*.png")), FPS)
        if not rows:
            sys.exit("ui-timeline: the recording produced no frames")

        for label, t in marks:
            print("  %6.2fs  %s (driven)" % (t + 3, label))
        print("\nchanges (accent / blue / drawn area):")
        previous = None
        for t, accent, blue, tile in rows:
            now = (accent // 200, blue // 200, tile // 2000)
            if now != previous:
                print("  %6.2fs  accent=%-6d blue=%-6d tile=%d" % (t, accent, blue, tile))
                previous = now
        print("\nvisible for:")
        for name, column, threshold in (("accent text", 1, 600), ("blue speaking box", 2, 600)):
            for a, b in runs(rows, column, threshold):
                flag = "   <- flash" if b - a <= 0.3 else ""
                print("  %-18s %6.2fs .. %6.2fs  (%.2fs)%s" % (name, a, b, b - a, flag))
    finally:
        if session:
            session.stop()
        if not keep:
            for f in glob.glob(os.path.join(WORK, "*.png")) + [mov]:
                if os.path.exists(f):
                    os.unlink(f)
            print("\n(recording deleted; pass --keep to retain it)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
