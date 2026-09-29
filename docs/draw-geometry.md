# Anti-aliased geometry in the draw device

**Status:** the rasteriser, the draw operations and the client APIs are
built; the GPU work is next (§6).  Man pages: draw(3) for the protocol,
draw-image(2) for `Path`, `fillpath` and `strokepath`.

Before this work InferNode had five anti-aliasing implementations, each
private to one program: Wu lines inside `libmemdraw`'s `memimageline`,
coverage helpers inside Tk, the Limbo module `aadraw`, and the
rasterisers inside `outlinefont` and `readsvg`.  No Plan 9 or Inferno
lineage has anti-aliased geometry in the draw device; Inferno's
draw-image(2) listed it under BUGS.  Each program built a GREY8
coverage mask itself, shipped it to the draw device as an image, and
drew through it.  Now there is one rasteriser, in `libmemdraw`, reached
through the draw device, so every program gets the same pixels on every
platform, and whatever accelerates the draw device accelerates them all.

---

## 1. The rasteriser (`libmemdraw/aa.c`)

A pixel's coverage is the exact area of it inside the shape.  Each edge
adds to every pixel cell it crosses a *cover* (the signed height it spans
there) and an *area* (that height times twice its mean distance from the
cell's left side); walking a row from the left, the running cover is the
winding to the right, and a pixel's covered area is

    (2·Aaone·cover so far − area of the cell) / (2·Aaone²)

turned into coverage by the fill rule.  This is the method of FreeType's
grey rasteriser and of font-rs.

- **Integer throughout.** Coordinates are 24.8 fixed point (`Aaone` =
  256 to a pixel; the pixel (x, y) covers [x, x+1) × [y, y+1)).  There is
  no floating point, so the bare-metal kernel, where devdraw runs, draws
  exactly what the hosted emulator draws.
- **Composited as a mask.** Rows are accumulated a band at a time and
  each band is drawn with one `memimagedraw` through a GREY8 mask of its
  coverage.  Every op and channel format therefore behaves exactly as
  drawing through any mask does.
- **Fill rules** are fillpoly's: `wind` 1 is even-odd, anything else
  non-zero.
- **Layers.** `memaadraw` draws on a window the way `memline` does, a
  visible piece at a time and into the backing store.  The geometry
  never depends on the clip, so a shape diced into pieces has the same
  pixels as one drawn whole (tested).

## 2. Paths and strokes (`libmemdraw/aapath.c`)

- **Paths**: move, line, quadratic, cubic, close, and ellipse.  Curves
  are flattened to within 1/64 pixel.  An ellipse is flattened with its
  polygon's radius scaled so the polygon has the ellipse's exact area.
- **Strokes** are built as the outline of the stroke: along one side of
  the path, round the far end, back along the other side, round the near
  end.  Ends are butt, round or square; joins are miter (with a limit),
  round or bevel; an inner corner is the exact intersection of the two
  sides.  A stroke built instead as a union of overlapping pieces would
  count coverage twice where the pieces' edges share a pixel, and bead.
- **Known limit**, shared by every exact-area rasteriser (FreeType,
  Skia, font-rs, Vello): where one stroke crosses or doubles back on
  itself, a pixel that two edges pass through gets both edges' coverage,
  so a few pixels at the crossing are slightly darker.  The same happens
  at a very sharp turn on segments too short to hold the exact inner
  corner, where the outline pivots on the vertex instead.

## 3. What the draw operations do now (option B)

Draw's existing operations keep their meaning and messages:

| Operation | Now |
|---|---|
| `line`, `poly`, `bezier`, `bezspline` | anti-aliased strokes; a horizontal or vertical line with square ends is still exactly its rectangle of pixels |
| `ellipse`, `arc` (outlines) | anti-aliased rings; an arc's cut ends stay hard |
| `fillpoly`, `fillellipse`, `fillarc`, `fillbezier` | hard-edged, as before |

Points are pixel centres.  `Endsquare` stops half a pixel past the point,
so a line touches both its points; `Enddisc` is a disc on the point;
`Endarrow` is the arrowhead Plan 9 describes, in exact geometry.  A
polyline's joins are round, as the discs Plan 9's `poly` put there, and
a one-pixel polyline joins mitred so a corner on pixel centres is sharp.

Filled shapes keep hard edges so that filled shapes sharing an edge
(pie wedges, map regions, tilings) meet without a seam; anti-aliased
edges on both sides of a shared edge let the background show through.
The other cost of anti-aliasing is that a line erased by drawing it
again in the background colour leaves a faint trace, because blending
is not reversible; Wu lines already had this for thin diagonals.

A program that wants smooth fills asks for them with `fillpath`.

## 4. The protocol (draw(3))

Three messages, letters no other Plan 9 lineage uses:

    'G' dstid[4] srcid[4] sp[2*4] wind[4] n[2] path[n]
            fill a path
    'g' dstid[4] srcid[4] sp[2*4] width[4] cap[4] join[4] miter[4] n[2] path[n]
            stroke a path; width and miter limit are fixed point
    'U' n[2] path[n]
            more of a path than one message holds, for the next 'G' or 'g'

A path is a sequence of verbs, each a byte and its points: `M` move, `L`
line, `Q` quadratic (control, end), `C` cubic (two controls, end), `E`
ellipse (centre, then semi-axes as plain values), `Z` close.  Each
coordinate is the difference from the previous one (x from x, y from y,
starting at 0), fixed point, as a zigzag varint: seven bits a byte, low
first, the top bit set on all but the last.  The source is aligned so
`sp` corresponds to the pixel holding the path's first point.

As with 9front's additions, a client sends the new messages only when
it draws a path, so an older draw server fails only for a program that
uses them.

## 5. Client interfaces

- **C** (`libdraw/path.c`, `draw.h`): `allocpath`, `pathmove`,
  `pathline`, `pathquad`, `pathcurve`, `pathellipse`, `pathclose`,
  `fillpath[op]`, `strokepath[op]`, in fixed-point coordinates
  (`Pathunit` to a pixel).
- **Limbo** (`draw.m`): `Path.new().moveto(x, y).curveto(...)` in real
  pixel coordinates, `Image.fillpath` and `Image.strokepath` (and their
  `op` forms), `Capbutt`, `Capround`, `Capsquare`, `Joinmiter`,
  `Joinround`, `Joinbevel`.  Existing `.dis` files run unchanged.

Users: Tk's canvas lines, ovals and radio indicators, `lib/scene`,
Matrix's `line-plot`, `sparkline` and `video-overlay`.

## 6. The GPU (next)

Agreed direction:

- **The GPU goes below the draw device**, behind the platform seams
  that already exist, so no program knows which hardware drew its
  pixels: `hwdraw(Memdrawparam*)`, which `memimagedraw` offers every
  operation first (0 means "do it in software"), and the screen
  contract of `attachscreen` and `flushmemscreen`.
- **Not tied to SDL3.** SDL3 is one backend; a native backend, and the
  bare-metal kernel (which has no SDL), implement the same interface.
  `hwdraw` may be re-engineered for modern hardware: batched submission,
  images that may live on the GPU, and synchronisation wherever the CPU
  touches pixels (a software fallback, `readpixels`, window pictures,
  presenting the screen).
- **Coverage on the CPU, composition on the GPU.**  The rasteriser above
  computes coverage exactly and cheaply; the GPU composites (ops, masks,
  fills, copies, windows, the screen) with integer arithmetic that
  matches the software path bit for bit.  Every platform then draws the
  same pixels, and a test compares GPU output with software output.
  (No renderer that rasterises on the GPU promises identical output to
  its CPU path; Vello's tests allow differences of up to 7/255.)
- **The software path stays the reference**, and a backend without a
  GPU changes nothing.

## 7. Tests

- `tests/host/aa_test.sh` builds `libmemdraw/aatest.c`: exact coverage
  of shapes on known fractions; circle and ring areas; fill rules;
  crossing strokes leave no hole in any end/join combination; strokes
  against a brute-force reference (within 8/255 on every pixel of 60
  random strokes); tiling and offset invariance; the wire format,
  including a round trip from libdraw's encoder.
- `tests/scene_test.b` checks paths from Limbo.
