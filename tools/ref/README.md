# Rendering against references

Charon is judged by how pages look, against two kinds of reference.

**Acceptance: web-platform-tests reftests.** Each reftest names a
reference page that must render identically. `wptrun.py` renders both
in Charon at 800x600, compares pixels within the test's `<meta
name=fuzzy>`, and writes `summary.txt` (per directory), `results.txt`
(per test) and `index.html` (failures side by side, test vs reference;
`--chromium` adds Chromium's rendering of the test).

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/web-platform-tests/wpt.git
(cd wpt; git sparse-checkout set css/CSS2 css/css-flexbox css/css-grid css/reference css/support fonts resources)
tools/ref/wptrun.py -j 3 wpt css/css-flexbox css/CSS2
```

Tests that need script to reach their final state are counted as
`needs-js`, apart from the pass rate: Charon has no script engine.

**Real pages: Chromium.** `compare.py` renders a URL in headless Chromium
(scripts off, which is the fair comparison) and in Charon, and writes
`<n>.png`: Chromium | Charon | differences in red, with an exact and a
layout score (the share of 8px cells that differ, which forgives glyph
rasterisation but not misplaced boxes).

```sh
tools/ref/mirror.py &          # https://<host>/<path> as http://127.0.0.1:8780/<host>/<path>
tools/ref/compare.py -o /tmp/live http://127.0.0.1:8780/pypi.org/
```

`mirror.py` fetches live sites on the host and caches them, rewriting
their URLs to point back at itself, so both browsers render the same
bytes and Charon, which fetches through webfs, needs no route to the
site. `--offline` replays only the cache.

Pieces: `shot.js` (Chromium, via Playwright), `p9img.py` (reads Inferno
images), `tests/charonbatch.b` (renders a list of pages in one emu).
