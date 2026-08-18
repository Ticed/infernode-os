#!/usr/bin/env python3
"""Read the InferNode window the way a person reads it.

    ui-probe.py <window-id> [--keep <path.png>]

Captures the window and runs the text on it through Vision OCR, then
prints what a test needs to assert on:

    voice=<status>      the Voice resource tile's status word
    left=<text>         everything in the conversation pane, one line

The Voice row is found by its label rather than by coordinates, because
the resource list grows and shrinks as tools load.
"""
import subprocess
import sys
import tempfile
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OCR = os.path.join(ROOT, ".omx/tmp/bin/ocr")


def probe(window_id, keep=None):
    path = keep or tempfile.mktemp(suffix=".png")
    shot = subprocess.run(["screencapture", "-x", "-o", "-l" + str(window_id), path],
                          capture_output=True)
    if shot.returncode != 0 or not os.path.exists(path):
        return []          # the window server is between frames, or the window is gone
    out = subprocess.run([OCR, path, "--boxes"], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        box, _, text = line.partition("\t")
        x, y, w, h = (int(v) for v in box.split())
        rows.append((x, y, w, h, text.strip()))
    if keep is None:
        os.unlink(path)
    return rows


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: ui-probe.py <window-id> [--keep <path.png>]")
    keep = None
    if "--keep" in sys.argv:
        keep = sys.argv[sys.argv.index("--keep") + 1]
    rows = probe(sys.argv[1], keep)
    if not rows:
        print("voice=")
        print("left=")
        return

    width = max(x + w for x, y, w, h, _ in rows)
    # The Voice tile: its status sits at the far right of the same row.
    voice = ""
    for x, y, w, h, text in rows:
        if text.lstrip("• ").strip().lower() == "voice" and x > width * 0.5:
            same_row = [t for x2, y2, w2, h2, t in rows
                        if abs(y2 - y) < h and x2 > x + w]
            if same_row:
                voice = same_row[-1]
            break
    left = " | ".join(t for x, y, w, h, t in sorted(rows, key=lambda r: (r[1], r[0]))
                      if x < width * 0.5)
    print("voice=" + voice)
    print("left=" + left)


if __name__ == "__main__":
    main()
