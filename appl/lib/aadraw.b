implement AAdraw;

#
# aadraw — anti-aliased geometry for Limbo Draw clients (see aadraw.m).
#
# Coverage is analytic: the distance from a pixel's centre to the ideal
# edge, clamped over a one-pixel transition band.  Exact and smooth —
# supersampling a thin band beats (beads) against the sample lattice;
# distance never does.
#
# The work is proportional to the edge, not the area.  Only pixels
# within a band of the edge can be partly covered, so only they get the
# distance arithmetic; each row's band is found analytically.  A filled
# shape's interior is left to Draw's own (C) fill, drawn into the
# coverage mask first.  A disc a thousand pixels across costs its
# circumference, not a million square roots in Dis.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;
include "math.m";
	math: Math;
include "aadraw.m";

display: ref Display;

BAND: con 1.5;	# half-width of the band that can be partly covered, px

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	display = d;
}

cov01(d: real): byte
{
	v := 0.5 - d;		# d < -0.5 fully in, > 0.5 fully out
	if(v <= 0.0)
		return byte 0;
	if(v >= 1.0)
		return byte 255;
	return byte (int (v * 255.0));
}

# Blend src through a coverage mask over bb (cov is Dx*Dy bytes).
cover(dst: ref Image, bb: Rect, src: ref Image, cov: array of byte)
{
	if(src == nil || bb.dx() <= 0 || bb.dy() <= 0 || display == nil)
		return;
	m := display.newimage(Rect((0, 0), (bb.dx(), bb.dy())), Draw->GREY8, 0, Draw->Transparent);
	if(m == nil)
		return;
	m.writepixels(m.r, cov);
	dst.draw(bb, src, m, (0, 0));
}

# A W×H coverage mask holding Draw's plain (C) fill of a shape's
# interior: the starting point for filled shapes.
newmask(W, H: int): (ref Image, array of byte)
{
	cov := array[W*H] of { * => byte 0 };
	if(display == nil)
		return (nil, cov);
	return (display.newimage(Rect((0, 0), (W, H)), Draw->GREY8, 0, Draw->Black), cov);
}

clipbb(dst: ref Image, bb: Rect): Rect
{
	c := dst.clipr;
	if(bb.min.x < c.min.x) bb.min.x = c.min.x;
	if(bb.min.y < c.min.y) bb.min.y = c.min.y;
	if(bb.max.x > c.max.x) bb.max.x = c.max.x;
	if(bb.max.y > c.max.y) bb.max.y = c.max.y;
	return bb;
}

ptsbb(pts: array of Point): Rect
{
	bb := Rect(pts[0], pts[0]);
	for(i := 1; i < len pts; i++) {
		if(pts[i].x < bb.min.x) bb.min.x = pts[i].x;
		if(pts[i].y < bb.min.y) bb.min.y = pts[i].y;
		if(pts[i].x > bb.max.x) bb.max.x = pts[i].x;
		if(pts[i].y > bb.max.y) bb.max.y = pts[i].y;
	}
	return bb;
}

# The x interval of row py within distance D of the line through
# (x0,y0)-(x1,y1), clipped to [xlo, xhi].
rowspan(py, x0, y0, x1, y1, D, xlo, xhi: real): (real, real)
{
	vx := x1 - x0; vy := y1 - y0;
	if(vy != 0.0) {
		# |(px-x0)*vy - (py-y0)*vx| <= D*L
		L := math->sqrt(vx*vx + vy*vy);
		k := (py - y0) * vx;
		e := D * L;
		p := (k - e) / vy + x0;
		q := (k + e) / vy + x0;
		if(p > q) { t := p; p = q; q = t; }
		if(p > xlo) xlo = p;
		if(q < xhi) xhi = q;
	}
	return (xlo, xhi);
}

# ── strokes ────────────────────────────────────────────────

line(dst: ref Image, p0, p1: Point, w: int, src: ref Image)
{
	polyline(dst, array[] of {p0, p1}, w, src);
}

polyline(dst: ref Image, pts: array of Point, w: int, src: ref Image)
{
	if(len pts < 2)
		return;
	if(w < 1)
		w = 1;
	bb := clipbb(dst, ptsbb(pts).inset(-(w + 2)));
	W := bb.dx(); H := bb.dy();
	if(W <= 0 || H <= 0)
		return;
	cov := array[W*H] of { * => byte 0 };
	hw := real w / 2.0;
	for(i := 0; i < len pts - 1; i++)
		segment(cov, W, H,
			real (pts[i].x - bb.min.x), real (pts[i].y - bb.min.y),
			real (pts[i+1].x - bb.min.x), real (pts[i+1].y - bb.min.y), hw);
	cover(dst, bb, src, cov);
}

# Round-capped stroke of half-width hw, max'd into cov.  Each row
# visits only the pixels that can lie within hw+BAND of the segment.
segment(cov: array of byte, W, H: int, x0, y0, x1, y1, hw: real)
{
	vx := x1 - x0; vy := y1 - y0;
	len2 := vx*vx + vy*vy;
	D := hw + BAND;
	loy := int (fmin(y0, y1) - D); if(loy < 0) loy = 0;
	hiy := int (fmax(y0, y1) + D); if(hiy >= H) hiy = H - 1;
	for(y := loy; y <= hiy; y++) {
		py := real y + 0.5;
		(a, b) := rowspan(py, x0, y0, x1, y1, D, fmin(x0, x1) - D, fmax(x0, x1) + D);
		ia := int (a - 0.5); if(ia < 0) ia = 0;
		ib := int (b + 0.5); if(ib >= W) ib = W - 1;
		row := y * W;
		for(x := ia; x <= ib; x++) {
			px := real x + 0.5;
			t := 0.0;
			if(len2 > 0.0) {
				t = ((px - x0)*vx + (py - y0)*vy) / len2;
				if(t < 0.0) t = 0.0;
				else if(t > 1.0) t = 1.0;
			}
			dx := px - (x0 + t*vx); dy := py - (y0 + t*vy);
			c := cov01(math->sqrt(dx*dx + dy*dy) - hw);
			if(c > cov[row + x])
				cov[row + x] = c;
		}
	}
}

fmin(a, b: real): real { if(a < b) return a; return b; }
fmax(a, b: real): real { if(a > b) return a; return b; }

# ── ellipses ───────────────────────────────────────────────

ring(dst: ref Image, c: Point, a, b, w: int, src: ref Image)
{
	if(w < 1)
		w = 1;
	ell(dst, c, a, b, w, src);
}

disc(dst: ref Image, c: Point, a, b: int, src: ref Image)
{
	ell(dst, c, a, b, 0, src);
}

# Shared ellipse coverage: w > 0 hollows a ring of that width.  The
# distance to the edge is the radial distance scaled to pixels by the
# local radius — exact for circles, a good approximation for moderate
# ellipses.  Each row visits only the band |d| <= hw+BAND: at most two
# short runs.  A disc's interior comes from Draw's fillellipse.
ell(dst: ref Image, c: Point, a, b, w: int, src: ref Image)
{
	if(a < 1 || b < 1)
		return;
	ow := w;
	if(ow < 0)
		ow = 0;
	bb := clipbb(dst, Rect((c.x - a, c.y - b), (c.x + a, c.y + b)).inset(-(ow + 2)));
	W := bb.dx(); H := bb.dy();
	if(W <= 0 || H <= 0)
		return;
	cx := real (c.x - bb.min.x); cy := real (c.y - bb.min.y);
	ra := real a; rb := real b;
	scale := ra;
	if(rb < ra)
		scale = rb;
	hw := real ow / 2.0;

	cov: array of byte;
	if(w == 0 && a > 2 && b > 2) {
		# the interior, shrunk to lie wholly inside; the band repaints the rim
		(m, cv) := newmask(W, H);
		if(m != nil) {
			m.fillellipse(c.sub(bb.min), a - 2, b - 2, display.white, (0, 0));
			m.readpixels(m.r, cv);
		}
		cov = cv;
	} else
		cov = array[W*H] of { * => byte 0 };

	# the band, in normalised radius; a disc's reaches inside the
	# shrunken interior so no pixel falls between the two
	rhi := 1.0 + (hw + BAND) / scale;
	rlo := 1.0 - (hw + BAND) / scale;
	if(w == 0)
		rlo = 1.0 - (BAND + 3.0) / scale;
	for(y := 0; y < H; y++) {
		dyn := (real y + 0.5 - cy) / rb;
		d2 := dyn * dyn;
		if(d2 > rhi * rhi)
			continue;
		xo := ra * math->sqrt(rhi*rhi - d2);	# outer half-span
		xi := -1.0;				# inner half-span; none: one run
		if(rlo > 0.0 && d2 < rlo * rlo)
			xi = ra * math->sqrt(rlo*rlo - d2);
		row := y * W;
		for(side := 0; side < 2; side++) {
			lo, hi: real;
			if(xi < 0.0) {
				if(side == 1)
					break;
				lo = cx - xo; hi = cx + xo;
			} else if(side == 0) {
				lo = cx - xo; hi = cx - xi;
			} else {
				lo = cx + xi; hi = cx + xo;
			}
			ia := int (lo - 1.0); if(ia < 0) ia = 0;
			ib := int (hi + 1.0); if(ib >= W) ib = W - 1;
			for(x := ia; x <= ib; x++) {
				dx := (real x + 0.5 - cx) / ra;
				d := (math->sqrt(dx*dx + d2) - 1.0) * scale;
				cv: byte;
				if(w == 0)
					cv = cov01(d);
				else {
					if(d < 0.0) d = -d;
					cv = cov01(d - hw);
				}
				cov[row + x] = cv;
			}
		}
	}
	cover(dst, bb, src, cov);
}

# ── polygons ───────────────────────────────────────────────

# Filled polygon, even-odd rule, anti-aliased.  Draw's fillpoly paints
# the interior into the mask; every pixel within BAND of an edge is then
# recomputed exactly — the even-odd crossing test for its side, the
# distance to the nearest edge for its coverage.  Cost: the area once,
# in C, plus the perimeter's band times the vertex count.
fillpoly(dst: ref Image, pts: array of Point, src: ref Image)
{
	if(len pts < 3)
		return;
	bb := clipbb(dst, ptsbb(pts).inset(-2));
	W := bb.dx(); H := bb.dy();
	if(W <= 0 || H <= 0)
		return;
	n := len pts;
	xs := array[n] of real;
	ys := array[n] of real;
	local := array[n] of Point;
	for(i := 0; i < n; i++) {
		local[i] = pts[i].sub(bb.min);
		xs[i] = real local[i].x;
		ys[i] = real local[i].y;
	}
	(m, cov) := newmask(W, H);
	if(m != nil) {
		m.fillpoly(local, 1, display.white, (0, 0));
		m.readpixels(m.r, cov);
	}

	# the band: pixels near an edge, each visited once below
	band := array[W*H] of { * => byte 0 };
	j := n - 1;
	for(i = 0; i < n; j = i++) {
		loy := int (fmin(ys[i], ys[j]) - BAND); if(loy < 0) loy = 0;
		hiy := int (fmax(ys[i], ys[j]) + BAND); if(hiy >= H) hiy = H - 1;
		for(y := loy; y <= hiy; y++) {
			(a, b) := rowspan(real y + 0.5, xs[j], ys[j], xs[i], ys[i], BAND,
				fmin(xs[i], xs[j]) - BAND, fmax(xs[i], xs[j]) + BAND);
			ia := int (a - 0.5); if(ia < 0) ia = 0;
			ib := int (b + 0.5); if(ib >= W) ib = W - 1;
			for(x := ia; x <= ib; x++)
				band[y*W + x] = byte 1;
		}
	}

	for(y := 0; y < H; y++) {
		row := y * W;
		py := real y + 0.5;
		for(x := 0; x < W; x++) {
			if(band[row + x] == byte 0)
				continue;
			px := real x + 0.5;
			inside := 0;
			dmin := 1.0e18;
			k := n - 1;
			for(i = 0; i < n; k = i++) {
				if((ys[i] > py) != (ys[k] > py) &&
				   px < (xs[k] - xs[i]) * (py - ys[i]) / (ys[k] - ys[i]) + xs[i])
					inside = !inside;
				vx := xs[k] - xs[i]; vy := ys[k] - ys[i];
				len2 := vx*vx + vy*vy;
				t := 0.0;
				if(len2 > 0.0) {
					t = ((px - xs[i])*vx + (py - ys[i])*vy) / len2;
					if(t < 0.0) t = 0.0;
					else if(t > 1.0) t = 1.0;
				}
				dx := px - (xs[i] + t*vx); dy := py - (ys[i] + t*vy);
				d2 := dx*dx + dy*dy;
				if(d2 < dmin)
					dmin = d2;
			}
			d := math->sqrt(dmin);
			if(inside)
				d = -d;
			cov[row + x] = cov01(d);
		}
	}
	cover(dst, bb, src, cov);
}
