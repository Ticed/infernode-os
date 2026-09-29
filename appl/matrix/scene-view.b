implement SceneView;

#
# scene-view — a Matrix display module that draws a 2-D scene
# (docs/scene-design.md): entities, features and layers in a geo or xy
# frame, over time.
#
# The mount is a scene directory.  When it is a scenefs (it has a
# status file) the view is live and shared: update() reloads only when
# status reports a new gen, the camera follows the server's view, and
# this pane's own pan/zoom/select are written back to its ctl, so every
# viewer — and any agent reading view or event — sees the same picture.
# A plain directory (the geo-map contract) works too: it is rescanned
# on a count+mtime change and the camera is local.
#
# Composition usage:
#	top scene-view /mnt/scene
#
# Input: drag pans; wheel zooms about the pointer; click selects;
# + - zoom; h j k l pan; f fits; space play/pause; . , step
# forward/back one tick; L rejoins live.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect, Pointer: import drawm;
include "scene.m";
	scene: Scene;
	Model, Cam, Trails: import scene;
include "matrix.m";

SceneView: module
{
	init:	fn(display: ref Display, font: ref Font, mount: string): string;
	resize:	fn(r: Rect);
	update:	fn(): int;
	draw:	fn(dst: ref Image);
	pointer:	fn(p: ref Pointer): int;
	key:	fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
	interval:	fn(): int;
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
served := 0;		# the mount is a scenefs
m: ref Model;
cam: ref Cam;
trails: ref Trails;
lastgen := -1;
lastscan := "";
lastview := "";
fitseq := 0;		# the last fit request this pane answered
pendfit := 0;		# the request the server shows (0: none)
fitted := 0;		# plain directory: fitted once, locally
mode := "";
lastt := 0.0;

# pointer state
dragging := 0;
moved := 0;
lastp, downp: Point;
chipdown := 0;

interval(): int
{
	return 100;
}

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	scene = load Scene Scene->PATH;
	if(scene == nil)
		return sys->sprint("scene-view: cannot load %s: %r", Scene->PATH);
	display_g = display;
	font_g = font;
	mountpath = mount;
	scene->init(display, font);
	cam = Cam.new(Rect((0, 0), (0, 0)));
	trails = Trails.new();
	m = Model.new();
	return nil;
}

retheme(display: ref Display)
{
	display_g = display;
	scene->retheme();
}

resize(r: Rect)
{
	cam.r = r;
	if(!served && !fitted && m != nil)
		fitted = dofit(0);
}

shutdown()
{
	m = nil;
	trails = nil;
}

# ── update ─────────────────────────────────────────────────

update(): int
{
	dirty := 0;
	if(!served) {
		# a scenefs may be mounted after we start (Matrix loads
		# display modules before services): keep looking
		(ok, nil) := sys->stat(mountpath + "/status");
		if(ok >= 0) {
			served = 1;
			lastview = "";
		}
	}
	if(served) {
		st := readfile(mountpath + "/status");
		(gen, md) := parsestatus(st);
		if(md != mode) {	# the HUD shows it
			mode = md;
			dirty = 1;
		}
		if(gen != lastgen) {
			lastgen = gen;
			reload();
			dirty = 1;
		}
		if(!dragging) {
			v := readfile(mountpath + "/view");
			if(v != lastview) {
				lastview = v;
				if(cam.parse(v))
					dirty = 1;
				pendfit = int fieldafter(v, "fit");
			}
		}
		# Answer a fit request (a fresh scene makes one) once there is
		# data to fit; a pane joining a scene whose camera is already
		# set adopts it instead.
		if(pendfit > 0 && pendfit != fitseq && dofit(1)) {
			fitseq = pendfit;
			dirty = 1;
		}
	} else {
		sc := scanall();
		if(sc != lastscan) {
			lastscan = sc;
			reload();
			dirty = 1;
		}
	}
	if(cam.follow != nil && (e := m.find(Scene->ENT, cam.follow)) != nil && e.haspos &&
	   (e.a != cam.ca || e.b != cam.cb)) {
		cam.ca = e.a;
		cam.cb = e.b;
		dirty = 1;
	}
	return dirty;
}

reload()
{
	nm := Model.read(mountpath);
	if(nm.hast && m.hast && nm.t < lastt)	# time went backwards: a seek
		trails.reset();
	lastt = nm.t;
	m = nm;
	trails.note(m);
	if(!served && !fitted)
		fitted = dofit(0);
}

# Fit locally (only this pane knows its size); with share set, publish
# the result as the scene's view.  0 if there is nothing to fit yet.
dofit(share: int): int
{
	if(cam.r.dx() <= 0 || m == nil)
		return 0;
	(ok, nil, nil, nil, nil) := m.extent();
	if(!ok)
		return 0;
	cam.fit(m);
	if(share)
		sendcam();
	return 1;
}

sendcam()
{
	if(!served)
		return;

	ctl(sys->sprint("center %s %s\nzoom %s", fmtr(cam.ca), fmtr(cam.cb), fmtr(cam.zoom)));
}

ctl(s: string)
{
	if(!served)
		return;
	fd := sys->open(mountpath + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines)
		sys->fprint(fd, "%s", hd lines);
}

parsestatus(s: string): (int, string)
{
	g := fieldafter(s, "gen");
	if(g == nil)
		return (-1, nil);
	return (int g, fieldafter(s, "mode"));
}

fieldafter(s, k: string): string
{
	(nil, toks) := sys->tokenize(s, " \t\n");
	for(; toks != nil && tl toks != nil; toks = tl toks)
		if(hd toks == k)
			return hd tl toks;
	return nil;
}

# A plain directory's change signature: the clock, and per subdirectory
# the count, max mtime, and sum of versions and lengths.
scanall(): string
{
	s := "";
	(ok, d) := sys->stat(mountpath + "/meta");
	if(ok >= 0)
		s += sys->sprint("m%d ", d.mtime);
	# a synthetic server's files have no useful mtime or length (the
	# usual 9P convention): the clock's value catches every tick
	s += "t" + readfile(mountpath + "/time") + " ";
	for(k := Scene->ENT; k <= Scene->LAYER; k++) {
		fd := sys->open(mountpath + "/" + scene->dirname(k), Sys->OREAD);
		if(fd == nil)
			continue;
		n := 0; mx := 0; vs := big 0;
		for(;;) {
			(nd, da) := sys->dirread(fd);
			if(nd <= 0)
				break;
			for(i := 0; i < nd; i++) {
				n++;
				if(da[i].mtime > mx)
					mx = da[i].mtime;
				vs += big da[i].qid.vers + da[i].length;
			}
		}
		s += sys->sprint("%d:%d:%d:%bd ", k, n, mx, vs);
	}
	return s;
}

# ── draw ───────────────────────────────────────────────────

draw(dst: ref Image)
{
	extra := "";
	if(served && mode != nil && mode != "live")
		extra = mode;
	scene->render(dst, m, cam, trails, Scene->RHUD | Scene->RGRID | Scene->RCHIPS, extra);
}

# ── input ──────────────────────────────────────────────────

pointer(p: ref Pointer): int
{
	if(p.buttons & 1 && !dragging && !chipdown) {
		(zin, zout, zfit) := scene->chiprects(cam);
		if(zin.contains(p.xy)) {
			zoom(0.5, cam.r.min.add(cam.r.max).div(2));
			chipdown = 1;
			return 1;
		}
		if(zout.contains(p.xy)) {
			zoom(-0.5, cam.r.min.add(cam.r.max).div(2));
			chipdown = 1;
			return 1;
		}
		if(zfit.contains(p.xy)) {
			dofit(1);
			chipdown = 1;
			return 1;
		}
	}
	if(p.buttons == 0)
		chipdown = 0;
	if(chipdown)
		return 1;
	if(p.buttons & 1) {
		if(!dragging) {
			dragging = 1;
			moved = 0;
			downp = p.xy;
		} else {
			d := p.xy.sub(lastp);
			moved += iabs(d.x) + iabs(d.y);
			if(cam.follow != nil) {	# a drag takes the camera back
				cam.follow = nil;
				ctl("unfollow");
			}
			cam.pan(m, d.x, d.y);
		}
		lastp = p.xy;
		return 1;
	}
	if(dragging) {
		dragging = 0;
		if(moved < 4)
			select(scene->hit(m, cam, downp, 14));
		else
			sendcam();
		return 1;
	}
	if(p.buttons & 8) {
		zoom(0.25, p.xy);
		return 1;
	}
	if(p.buttons & 16) {
		zoom(-0.25, p.xy);
		return 1;
	}
	return 0;
}

zoom(dz: real, at: Point)
{
	cam.zoomat(m, at, dz);
	sendcam();
}

select(id: string)
{
	cam.sel = id;
	if(id == nil)
		ctl("deselect");
	else
		ctl("select " + id);
}

key(k: int): int
{
	case k {
	'+' or '=' =>	zoom(0.5, cam.r.min.add(cam.r.max).div(2));
	'-' or '_' =>	zoom(-0.5, cam.r.min.add(cam.r.max).div(2));
	'h' =>	cam.pan(m, 32, 0); sendcam();
	'l' =>	cam.pan(m, -32, 0); sendcam();
	'k' =>	cam.pan(m, 0, 32); sendcam();
	'j' =>	cam.pan(m, 0, -32); sendcam();
	'f' =>	dofit(1);
	' ' =>
		if(mode == "playing")
			ctl("pause");
		else
			ctl("play");
	'.' =>	ctl("step");
	',' =>	stepback();
	'L' =>	ctl("live");
	* =>	return 0;
	}
	return 1;
}

# Back one tick: to the previous clock value in the history, within
# the run since the last clear (as the server replays).
stepback()
{
	if(!served || !m.hast)
		return;
	h := readfile(mountpath + "/history");
	prev := -1.0;
	found := 0;
	(nil, lines) := sys->tokenize(h, "\n");
	for(; lines != nil; lines = tl lines) {
		l := hd lines;
		if(l == "clear")
			found = 0;
		else if(len l > 5 && l[0:5] == "time ") {
			t := real l[5:];
			if(t < m.t) {
				prev = t;
				found = 1;
			}
		}
	}
	if(found)
		ctl("seek " + fmtr(prev));
}

# ── helpers ────────────────────────────────────────────────

fmtr(v: real): string
{
	return sys->sprint("%.9g", v);
}

iabs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}
