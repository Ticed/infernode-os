#!/usr/bin/env python3
"""Bar-strip ink of the voice meters, excluding the two centre peak bars.

INF-44 verification: the defect was 16 RMS-driven bars stuck at 1px while
only the two peak bars (i == nbar/2, nbar/2-1) moved. Whole-pane pixel
counts cannot see that; this measures the meter bar strip itself and drops
the centre pair.

Reads a ui-timeline frame directory (.omx/tmp/ui-timeline/f*.png, cropped
to the conversation pane) and emits one TSV row per frame:

    t   accent_strip  accent_maxh  blue_strip  blue_maxh  nruns

    accent_strip  accent pixels in the listening meter's bar strip,
                  centre-two bars excluded
    accent_maxh   tallest kept bar in pixels
    blue_strip    same for the speaking meter (progfgcol)
    nruns         bar runs detected (18 = full bank)

The meter is found as the row where its 18 column runs appear (bar width
>= 8 at 1x), between the label and the pane's right edge. The centre pair
is the two runs nearest the strip's middle. An absent bank (meter hidden,
idle, or a still-collapsed 1px row) reports its raw run count and ink so
flattened bars stay visible in the trace.

    python3 tools/mac/meter-strip.py <frame-dir> > strip.tsv
"""

import glob
import os
import sys

import numpy as np
from PIL import Image

BAR_MINW = 8
MIN_RUNS = 15
CHIP_Y = 527          # the always-on voice chip starts below the meter


def profile(im, color):
    if color == "accent":
        r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
        return (r > 140) & (r > g + 60) & (r > b + 60)
    r, g, b = im[:, :, 0], im[:, :, 1], im[:, :, 2]
    return (b > 110) & (b > r + 35) & (b > g + 25)


def col_runs(xs):
    out = []
    on = False
    s = 0
    for x in range(len(xs)):
        if xs[x] > 0 and not on:
            on, s = True, x
        elif xs[x] == 0 and on:
            on = False
            out.append((s, x - 1))
    if on:
        out.append((s, len(xs) - 1))
    return out


def bar_bank_rows(mask, x0):
    """Rows whose right-of-label column runs look like the 18-bar bank."""
    rows = []
    for y in range(0, MAX_Y := mask.shape[0]):
        rr = col_runs(mask[y, x0:].astype(int))
        wide = [r for r in rr if r[1] - r[0] >= BAR_MINW]
        if len(wide) >= MIN_RUNS:
            rows.append(y)
    return rows


def strip_stats(mask, x0):
    """Signal mask -> (ink, max_h, nruns) with the centre pair dropped."""
    bank = bar_bank_rows(mask, x0)
    if not bank:
        return 0, 0, 0
    top = min(bank)
    # Bars grow down to the strip baseline; keep sampling to the chip's row.
    bottom = top
    for y in range(top, min(CHIP_Y, mask.shape[0]) - 1):
        if mask[y, x0:].any():
            bottom = y
        elif y - bottom > 2:
            break
    band = mask[top:bottom + 1, x0:]
    colsum = band.sum(axis=0)
    rr = col_runs(colsum)
    real = [r for r in rr if r[1] - r[0] >= BAR_MINW]
    if len(real) < MIN_RUNS:
        # Collapsed bank (all 1px bars): the columns still run.
        return int(band.sum()), 1, len(real)
    centre = len(real) // 2
    ink = 0
    for i, (a, b) in enumerate(real):
        if i in (centre, centre - 1):
            continue
        part = band[:, a:b + 1]
        ink += int(part.sum())
    # Bar height = vertical extent per bar column set, sharing the baseline.
    maxh = 0
    for a, b in real:
        part = band[:, a:b + 1]
        rows = np.nonzero(part.sum(axis=1))[0]
        if len(rows):
            maxh = max(maxh, int(rows[-1] - rows[0] + 1))
    return ink, maxh, len(real)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    frames = sorted(glob.glob(os.path.join(argv[0], "f*.png")))
    if not frames:
        sys.exit("meter-strip: no frames in " + argv[0])
    print("t\taccent_ink\taccent_maxh\tblue_ink\tblue_maxh\tnruns")
    for i, path in enumerate(frames):
        im = np.array(Image.open(path).convert("RGB")).astype(int)
        x0 = max(2, int(im.shape[1] * 0.15))
        ai, ah, an = strip_stats(profile(im, "accent"), x0)
        bi, bh, bn = strip_stats(profile(im, "blue"), x0)
        print("%0.2f\t%d\t%d\t%d\t%d\t%d" % (i / 20.0, ai, ah, bi, bh, max(an, bn)))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))