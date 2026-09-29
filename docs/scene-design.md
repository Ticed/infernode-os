# Scene: a general 2-D situation display for InferNode

**Status:** implemented — `lib/scene` (model, camera, renderer),
`scenefs` (the served scene: camera, clock, record/replay),
`scene-view` (Matrix display module, replacing `geo-map`),
`scenerender` (headless → PNG), `scenedemo` (a synthetic producer),
`writepng`.  Man pages: scene(2), scenefs(4), scenerender(1),
imagefile(2); the Matrix library pages for `scene-view` and
`scene-fixture`.

Scene generalises the earlier geo-map contract
from "georeferenced units on a Mercator map" to "things in a 2-D space,
over time": a simulation on a local metre grid, a board game, a network
laid out in the plane, a test rig replaying a log, and — unchanged — a
map. The same data drives a live Matrix pane, a PNG written by a batch
job, and an agent that reads and steers the view through files.

Nothing here is domain-specific. The renderer knows shapes, colours,
labels, headings and time; it does not know what the things are.

---

## 1. Pieces

| Piece | Kind | Role |
|---|---|---|
| `module/scene.m`, `appl/lib/scene.b` | library | The model (entities, features, layers, meta, clock), the record grammar, frames and camera, the renderer, hit-testing. Every other piece is a thin client of it. |
| `scenefs` (`appl/cmd/scenefs.b`) | 9P server | Serves one live scene at `/mnt/scene`: producers write it, viewers read it, anyone steers it through `ctl`. Owns the camera and the playhead, records every change, replays a recording. |
| `scene-view` (`appl/matrix/scene-view.b`) | Matrix display | Draws a scene directory — a `scenefs` mount or a plain directory — into a Matrix region. |
| `scenerender` (`appl/cmd/scenerender.b`) | command | Renders a scene directory, or a recording at time *t*, to PNG (or an Inferno image). No window system needed. |
| `writepng` (`appl/lib/writepng.b`) | library | PNG encoder (`WImagefile`), so any Draw client can write a standard image. |
| `scenedemo` (`appl/cmd/scenedemo.b`) | command | A synthetic producer (a field survey) writing records to a scene's `log`: a demo and a test load. |
| `scene-fixture` (`appl/matrix/scene-fixture.b`) | Matrix service | Mounts a `scenefs` and runs `scenedemo`, so `lib/matrix/compositions/scene-demo` works from the picker. |

The load-bearing decision is the same one geo-map made: **get the data
contract right** and the producers, the renderers and the agents are
built independently.

---

## 2. The scene directory (the data contract)

A scene is a directory. The minimum is the geo-map contract, so every
existing geo tree is already a valid scene:

```
<scene>/
    meta              ndb stanza: frame, projection, units, title, ...   (optional)
    time              the scene clock: one number                         (optional)
    entities/<id>     one ndb stanza per thing that moves
    features/<id>     one ndb stanza per drawn graphic
    layers/<id>       one ndb stanza per background layer                 (optional)
```

Stanza files are one `attr=value` per line; the value is the rest of the
line (so `label=Relay 2` needs no quoting). Unknown attributes are kept
and ignored — the format is forward compatible.

### 2.1 Frames

`meta` names the coordinate frame. Everything else is in that frame;
pixels never appear in the model.

| `frame=` | Positions | Notes |
|---|---|---|
| `geo` (default) | `lat=` `lon=`; points `lat,lon` | WGS84. `projection=mercator` (default) or `equirect`, via `lib/geoproj`. Metres for radii and scale bar come from the projection. |
| `xy` | `x=` `y=`; points `x,y` | Planar, **y up**, `units=` names the unit (default `m`) for the scale bar and HUD only. A simulation grid, a board, a floor plan. |

Other `meta` attributes: `title=`, `bounds=x0,y0 x1,y1` (the extent a
fit should show when there is no data yet), `trail=<n>` (default trail
length for every entity).

### 2.2 Entity (a thing that moves)

```
x=1250  y=830           # or lat= lon= in the geo frame (required)
label=Relay 2
shape=triangle          # dot|square|triangle|diamond|circle|cross|ring   (default dot)
color=35C7FFFF          # RRGGBBAA; else from group; else from affil; else amber
group=blue              # categorical colour by name (stable across runs)
course=90               # degrees, 0 = +y / north, clockwise; draws a heading leader
size=6                  # glyph radius, px
stale=312.5             # scene time after which the entity is drawn dimmed
trail=40                # remember and draw the last 40 positions
dim=1                   # draw dimmed regardless of time
```

For compatibility with the geo contract, `kind=` (air/sea/subsurface/
ground/installation) maps onto shapes and `affil=` (friend/hostile/
neutral/unknown) onto the fixed four-colour palette when `shape=`/
`color=`/`group=` are absent.

### 2.3 Feature (a drawn graphic)

As in the earlier geo contract: `type=point|polyline|polygon|circle`,
`points=`, `radius=` (in frame units: metres for geo, `units` for xy),
`color=`, `fill=`, `width=`, `label=`. Plus `dash=1` for a dashed
stroke. Features are drawn in file-name order, filled ones first.

### 2.4 Layer (background)

```
kind=grid   step=100  color=223044FF          # a regular grid in frame units (auto step if absent)
kind=image  file=/lib/scene/floor.png  bounds=x0,y0 x1,y1  opacity=160
```

Layers draw below features, in name order. `grid` replaces the default
graticule/grid; `image` is a raster pinned to frame coordinates and is
resampled to the current camera (cached until the camera moves).
A scene with no `layers/` gets the default grid.

### 2.5 Clock

`time` holds one number in the scene's own units (seconds by
convention). The renderer shows it in the HUD and compares `stale=`
against it. Nothing else interprets it: a scene without `time` is simply
timeless.

---

## 3. `scenefs` — the served scene

A plain directory is enough for a static picture. A *live* scene wants
more: a camera several viewers share, a way for an agent to see and move
what the human sees, a cheap change signal, and time travel. `scenefs`
serves the §2 directory plus a control surface:

```
/mnt/scene/
    ctl            (w)   one command per line (below)
    view           (r)   the shared camera: "frame F center A B zoom Z sel ID follow ID fit N"
    status         (r)   "mode M t T t0 T0 t1 T1 rate R gen G entities N features N"
    event          (r)   BLOCKING; one event per read (below)
    log            (w)   batched update records (§3.2) — the ingest wire
    history        (r)   the recording so far, as log records
    meta           (rw)
    time           (rw)
    entities/<id>  (rw)  create, write, remove — like a plain directory
    features/<id>  (rw)
    layers/<id>    (rw)
```

`scenefs` serves 9P on its standard input, the Inferno idiom:
`mount -c {scenefs} /mnt/scene`.

A producer may use either wire: write stanza files exactly as into a
plain directory (easy from `sh`: `echo ... > entities/r2`), or write a
batch of records to `log` (one write is seen whole — viewers never see
half a tick — which is what a simulation ticking hundreds of entities
wants; a bad record stops the write with an error, and the lines before
it stand). Stanza files behave as
files: a write lands at its offset and takes effect at once, so `echo >`
replaces, `echo >>` appends, and `rm` deletes.  (Taking effect on close
was tried and dropped: a shell's clunks arrive out of order.)

### 3.1 `ctl`

```
center A B        zoom Z        fit        follow ID        unfollow
select ID         deselect
play              pause         seek T     rate R           live        step [DT]
clear             (drop every entity, feature and layer; the recording keeps the clear)
```

Camera commands change `view` for every viewer: a human panning in one
`scene-view` moves the picture an agent reads, and an agent writing
`follow r2` moves the human's picture. `select` is how a click reaches
an agent (as an `event`).  `fit` cannot be answered by the server, which
does not know any viewer's size: it posts a request number in `view`
(`fit N`), the first viewer to see it fits for its own size and writes
the camera back, and the request reads 0 again.  A fresh scene starts
with a request; a viewer joining a scene whose camera is set adopts it.

### 3.2 Records (`log`, `history`, recordings)

One record per line, fields space-separated, rc-style quoting for values
with spaces:

```
time 12.5
ent r2 x=1250 y=830 'label=Relay 2' shape=triangle group=blue
feat ao type=polygon 'points=0,0 2000,0 2000,2000 0,2000' color=5A6B82FF
layer g kind=grid step=250
meta frame=xy units=m 'title=Search area'
del ent r2
clear
```

`ent`/`feat`/`layer` *replace* the object's stanza (a full state, not a
patch), so any suffix of a recording after a `clear` is
self-contained. `history` is exactly this stream with a `time` record
before each change, so `cat /mnt/scene/history > run.scene` saves a run
and `scenefs -r run.scene` (or `scenerender -r run.scene -t 300`)
replays it.

### 3.3 Time: live, paused, playing

`scenefs` keeps two states: **live** (what producers last wrote) and the
**playhead** state. In `live` mode they are the same object. `pause`,
`seek T` or `step` detach the playhead: `entities/` etc. then show the
scene as it was at the playhead, rebuilt from the recording, while
producers keep writing the live state underneath. `play` advances the
playhead at `rate` × wall-clock and rejoins live when it catches up;
`live` rejoins at once.  Replay covers the run since the last `clear`
(a restarted producer starts with one), so a clock that starts again
from 0 is not confused with the previous run's. As with vid9p, the
server owns the playhead, so every viewer of one scene is in step.

### 3.4 `event`

Each open of `event` is its own cursor; a read blocks until something
happens and returns one line:

```
gen 42            # the visible scene changed (coalesced: only the latest is queued)
select r2         # a viewer selected r2
time 12.5         # the playhead moved
view ...          # the camera moved (same text as `view`)
```

Renderers poll `status` for `gen` instead (one small read per tick);
agents block on `event`.

### 3.5 Trust

`scenefs` holds no authority beyond the files it serves: it opens only a
recording named on its command line. Access is by placement — bind
`/mnt/scene` into a namespace to grant it.  A grant that should watch
but not steer is a separate `scenefs -r` of the recording, not a mode
flag.

---

## 4. Renderers

`lib/scene` draws, back to front: background, layers (or the default
grid/graticule), filled features, stroked features, trails, entity
glyphs with heading leaders, labels (decluttered), selection, HUD (frame,
scale bar, zoom, clock and mode). Colours are allocated once per value
and cached; glyphs are anti-aliased through `lib/aadraw`.

- **`scene-view`** (Matrix display, 100 ms ticker). It polls `status`
  when the mount is a `scenefs` (reload only on a new `gen`), else falls
  back to a count+mtime scan of the directories.  It keeps looking for a
  `status` file, because Matrix starts display modules before the
  services that may mount the scene. It follows the shared camera in
  `view` and writes its own pan/zoom/select back to `ctl`, so viewers and
  agents stay in step. Keys: `+`/`-` zoom, `h/j/k/l` pan, `f` fit,
  space play/pause, `.`/`,` step, `L` live.
- **`scenerender`** renders headless:

  ```
  scenerender [-w 1024] [-h 768] [-t T] [-v 'center A B zoom Z'] [-F font] [-n] [-l] scene-dir|-r recording out
  ```

  With `-r`, the recording is replayed to time `T` (default: the end)
  and trails are built from the full history — whole trajectories for a
  report or a sweep's figure. The PNG is a plain file: `present` can show
  it to a human, a Veltro agent can inspect it with `vision`.

- **Agents** need nothing new. An agent granted `/mnt/scene` reads
  `status`, `view` and the stanza files, blocks on `event` for what a
  human selects, and steers with `ctl` (`follow`, `seek`, `select`) —
  the human's `scene-view` moves with it. To show a picture it runs
  `scenerender` and hands the PNG to `present`.

---

## 5. Anti-aliasing and cost

Everything the renderer draws is anti-aliased by default, through
`lib/aadraw`: coverage is the analytic distance from each pixel centre to
the ideal edge.  `aadraw` was rewritten for this work to cost the edge,
not the area — only pixels within 1.5 px of an edge get the distance
arithmetic, each row's band found analytically, and a filled shape's
interior is Draw's own C fill.  The output is pixel-identical to the old
bounding-box version; the demo scene (1000×720, a 1 km translucent disc,
polygons, dashed rings, trails, labels) went from 55 ms to 11 ms a frame
under the JIT.  Every `aadraw` user (line-plot, sparkline, video-overlay)
gets the same.

Labels are placed after the geometry, most important first (selection,
entities, features, grid), each at the first of several candidate
positions that collides with nothing already placed or reserved (the HUD,
the zoom buttons) and lies inside the pane; entity and feature labels get
a background halo.

## 6. Matrix runtime: per-region redraw

Before this work Matrix redrew every region whenever any region changed,
so a 25 fps video pane repainted a map (and every gauge) 25 times a
second. The runtime now keeps an off-screen image per display region and
calls a module's `draw` only when that region went stale — its `update`
reported a change, it consumed input, it was resized or rethemed; the
frame is composited from the cached images. The module interface is
unchanged.

---

## 7. The GPU

The GPU belongs under `/dev/draw`, not in applications. Every program
here draws through the draw device's small set of operations; that is
the seam where acceleration goes, and it is why a Limbo program (or a
remote one over 9P) never needs to know which hardware drew its pixels.
Today the SDL3 backend only uploads a software framebuffer as a texture.
In order of return:

1. **Anti-aliasing in `libmemdraw`** (C), exposed as draw-device
   operations — `aadraw`'s three primitives are a natural first set. This
   takes the remaining coverage arithmetic out of Dis for every platform,
   headless ones included, and fixes the protocol a GPU would implement.
2. **Compositing on the GPU**: windows (memlayer) and large image draws
   as textured quads in the SDL3 backend, keeping the software path as
   the reference.
3. **GPU rasterisation** of the operations from step 1, behind the same
   protocol.

Step 1 is a prerequisite for 2 and 3 and is worth doing on its own.

---

## 8. Not yet

- Tile pyramids (`layers/<id>` with `kind=tiles`); only single images
  today.
- Interpolation between producer updates (the producer's tick rate is the
  display's motion rate).
- Seek cost is O(recording) and the history is in memory — fine to ~10⁵
  records; keyframes and a spill file later.
