implement Scenefs;

#
# scenefs — serve a live 2-D scene: its objects, a shared camera, a
# clock with record and replay.  docs/scene-design.md §3; man/4/scenefs.
#
#	mount {scenefs [-r recording]} /mnt/scene
#
# The tree (all text; stanza files are one attr=value per line):
#
#	ctl		(w)  one command per write line:
#			     center A B | zoom Z | fit | follow ID | unfollow
#			     select ID | deselect
#			     play | pause | seek T | rate R | live | step [DT]
#			     clear
#	view		(r)  "frame F center A B zoom Z sel ID follow ID fit N"
#			     (N is a pending fit request, 0 when none)
#	status		(r)  "mode M t T t0 T0 t1 T1 rate R gen G entities N
#			      features N layers N records N"
#	event		(r)  blocking; one event per read, each open its own
#			     cursor: "gen G", "select ID", "time T", "view ..."
#	log		(w)  records (§3.2), one per line; a write is seen whole,
#			     and a bad record stops it (the lines before stand)
#	history		(r)  every record so far, with its clock: a recording
#	meta		(rw) the scene's stanza (frame=, units=, title=, ...)
#	time		(rw) the scene clock
#	entities/	(rw) one stanza file per entity: create, write, remove
#	features/	(rw) likewise
#	layers/		(rw) likewise
#
# A stanza write lands at its offset and takes effect at once.  Every
# change is appended to the history, stamped with the clock; seek/play/
# step show the scene as the history says it was (the run since the last
# clear), while producers keep changing the live scene underneath; `live`
# rejoins it, as does playing up to the end.  The playhead lives
# here, not in the viewers, so every viewer of a scene is in step.
#
# scenefs holds no authority beyond the files it serves: the only file
# it opens is the recording named by -r.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
include "string.m";
	str: String;
include "scene.m";
	scene: Scene;
	Model, Cam, Obj: import scene;

Scenefs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qview, Qstatus, Qevent, Qlog, Qhistory, Qmeta, Qtime,
Qentdir, Qfeatdir, Qlayerdir: con iota;
Qobj: con 16;		# + kind; the object's slot is path >> 8

LIVE, PAUSED, PLAYING: con iota;
modenames := array[] of {"live", "paused", "playing"};

TICKMS: con 100;
EVMAX: con 64;

stderr: ref Sys->FD;
user: string;
srv: ref Styxserver;
lk: chan of int;

live: ref Model;	# what producers last wrote
shown: ref Model;	# what is served (== live in live mode)
cam: ref Cam;
fitseq := 1;
fitpending := 1;	# a fit asked for and not yet answered (only a viewer
			# knows its size); a fresh scene asks for one
mode := LIVE;
rate := 1.0;
pt := 0.0;		# playhead time
sgen := 0;		# bumped whenever what is served changes

# the recording
# The history is one byte buffer (what history serves) and the offset of
# each record in it: two objects the collector need not look inside,
# rather than one string per record, which it would walk for ever.
hoff: array of int;
nhist := 0;
lastclear := 0;		# index of the last "clear": replay starts there
hidx := 0;		# replay cursor into hist (records applied to shown)
lastrect := 0.0;	# clock value of the last "time" record written
hasrect := 0;
t0 := 0.0;
hast0 := 0;
histb: array of byte;	# the history as served, grown in place
nhistb := 0;

# object slots: qid path <-> (kind, id), append-only
slotids: array of array of string;
nslots: array of int;
slotlook: array of array of list of (string, int);

# event cursors
Evq: adt {
	fid:	int;
	q:	list of string;	# oldest first
	n:	int;
	pending: ref Tmsg.Read;
};
evqs: list of ref Evq;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	scene = load Scene Scene->PATH;
	str = load String String->PATH;
	if(str == nil || styx == nil || styxservers == nil || scene == nil || bufio == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("scenefs [-r recording]");
	rec: string;
	while((c := arg->opt()) != 0)
		case c {
		'r' =>	rec = arg->earg();
		'D' =>	styxservers->traceset(1);
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";

	live = Model.new();
	shown = live;
	cam = Cam.new(((0, 0), (0, 0)));
	hoff = array[1024] of int;
	histb = array[65536] of byte;
	slotids = array[3] of array of string;
	nslots = array[3] of {* => 0};
	slotlook = array[3] of array of list of (string, int);
	for(k := 0; k < 3; k++) {
		slotids[k] = array[64] of string;
		slotlook[k] = array[257] of list of (string, int);
	}
	lk = chan[1] of int;

	if(rec != nil) {
		b := bufio->open(rec, Bufio->OREAD);
		if(b == nil)
			fatal(sys->sprint("cannot open %s: %r", rec));
		n := 0;
		while((line := b.gets('\n')) != nil) {
			n++;
			line = trim(line);
			if(line == "" || line[0] == '#')
				continue;
			if((err := live.apply(line)) != nil) {
				sys->fprint(stderr, "scenefs: %s:%d: %s\n", rec, n, err);
				continue;
			}
			record(line);
		}
		# a recording opens paused at its start, ready to play
		mode = PAUSED;
		pt = t0;
		rebuild();
	}

	navops := chan of ref Navop;
	spawn navigator(navops);
	tc: chan of ref Tmsg;
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navops), big Qroot);
	tick := chan of int;
	spawn ticker(tick);
	serve(tc, tick);
}

lock()
{
	lk <-= 1;
}

unlock()
{
	<-lk;
}

ticker(c: chan of int)
{
	for(;;) {
		sys->sleep(TICKMS);
		c <-= 1;
	}
}

serve(tc: chan of ref Tmsg, tick: chan of int)
{
	for(;;) alt {
	<-tick =>
		if(mode == PLAYING) {
			lock();
			advance(pt + rate * real TICKMS / 1000.0);
			if(hidx >= nhist && pt >= lastrect) {	# caught up: rejoin live
				mode = LIVE;
				shown = live;
				sgen++;
			}
			unlock();
			post("time " + fmt(pt));
		}
	tmsg := <-tc =>
		if(tmsg == nil)
			exit;
		pick tm := tmsg {
		Readerror =>
			exit;
		Flush =>
			cancelpending(tm.oldtag);
			srv.reply(ref Rmsg.Flush(tm.tag));
		Open =>
			c := srv.open(tm);
			if(c == nil)
				break;
			if(int c.path == Qevent)
				evqs = ref Evq(c.fid, nil, 0, nil) :: evqs;
			# a truncating open starts the file afresh; otherwise
			# writes land in the current contents at their offset
			if(tm.mode & Sys->OTRUNC && writable(c.path))
				wbufs = ref Wbuf(c.fid, array[0] of byte) :: wbufs;
		Create =>
			docreate(tm);
		Read =>
			doread(tm);
		Write =>
			dowrite(tm);
		Clunk =>
			c := srv.getfid(tm.fid);
			if(c != nil) {
				if(TYPE(c.path) == Qlog && (lb := getwbuf(c.fid)) != nil) {
					lock();
					change(trim(string lb.buf));
					unlock();
					changed();
				}
				dropwbuf(c.fid);
				if(int c.path == Qevent)
					dropevq(c.fid);
			}
			srv.clunk(tm);
		Remove =>
			doremove(tm);
		* =>
			srv.default(tmsg);
		}
	}
}

# ── reads ──────────────────────────────────────────────────

doread(tm: ref Tmsg.Read)
{
	c := srv.getfid(tm.fid);
	if(c == nil || !c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	p := c.path;
	case TYPE(p) {
	Qroot or Qentdir or Qfeatdir or Qlayerdir =>
		srv.read(tm);
	Qctl or Qlog =>
		srv.reply(styxservers->readstr(tm, ""));
	Qview =>
		srv.reply(styxservers->readstr(tm, viewtext() + "\n"));
	Qstatus =>
		srv.reply(styxservers->readstr(tm, statustext() + "\n"));
	Qmeta =>
		lock();
		s := shown.metatext();
		unlock();
		srv.reply(styxservers->readstr(tm, s));
	Qtime =>
		s := "";
		if(shown.hast)
			s = fmt(shown.t) + "\n";
		srv.reply(styxservers->readstr(tm, s));
	Qhistory =>
		srv.reply(styxservers->readbytes(tm, histb[0:nhistb]));
	Qevent =>
		q := getevq(c.fid);
		if(q == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "lost event cursor"));
			return;
		}
		if(q.pending != nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
			return;
		}
		if(q.q == nil) {
			q.pending = tm;
			return;
		}
		srv.reply(evreply(tm, q));
	* =>
		if(TYPE(p) >= Qobj && TYPE(p) < Qobj + 3) {
			lock();
			o := shown.find(TYPE(p) - Qobj, slotid(p));
			s := "";
			if(o != nil)
				s = o.text();
			unlock();
			if(o == nil)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Enotfound));
			else
				srv.reply(styxservers->readstr(tm, s));
			return;
		}
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
	}
}

viewtext(): string
{
	lock();
	s := cam.text(shown) + " fit " + string fitpending;
	unlock();
	return s;
}

statustext(): string
{
	lock();
	t := 0.0;
	if(shown.hast)
		t = shown.t;
	s := sys->sprint("mode %s t %s t0 %s t1 %s rate %s gen %d entities %d features %d layers %d records %d",
		modenames[mode], fmt(t), fmt(t0), fmt(lastrect), fmt(rate), sgen,
		shown.count(Scene->ENT), shown.count(Scene->FEAT), shown.count(Scene->LAYER), nhist);
	unlock();
	return s;
}

# ── writes ─────────────────────────────────────────────────

writable(p: big): int
{
	t := TYPE(p);
	return t == Qmeta || t == Qtime || t >= Qobj && t < Qobj + 3;
}

dowrite(tm: ref Tmsg.Write)
{
	c := srv.getfid(tm.fid);
	if(c == nil || !c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	case TYPE(c.path) {
	Qctl =>
		err: string;
		(nil, lines) := sys->tokenize(string tm.data, "\n");
		for(; lines != nil && err == nil; lines = tl lines)
			err = ctl(trim(hd lines));
		if(err != nil)
			srv.reply(ref Rmsg.Error(tm.tag, err));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	Qlog =>
		# a long write reaches us split at the iounit: hold a partial
		# last line until the rest arrives
		# (in bytes: the split may fall inside a UTF-8 sequence)
		lerr: string;
		data := tm.data;
		if((lb := getwbuf(c.fid)) != nil) {
			nd := array[len lb.buf + len data] of byte;
			nd[0:] = lb.buf;
			nd[len lb.buf:] = data;
			data = nd;
			dropwbuf(c.fid);
		}
		for(e := len data; e > 0 && data[e-1] != byte '\n'; e--)
			;
		if(e < len data)
			wbufs = ref Wbuf(c.fid, data[e:]) :: wbufs;
		text := string data[0:e];
		lock();
		(nil, llines) := sys->tokenize(text, "\n");
		for(; llines != nil && lerr == nil; llines = tl llines)
			lerr = change(trim(hd llines));
		unlock();
		changed();
		if(lerr != nil)
			srv.reply(ref Rmsg.Error(tm.tag, lerr));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	* =>
		if(!writable(c.path)) {
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			return;
		}
		# Stanza files behave as files: the write lands at its offset
		# in the current contents and the result applies at once, so
		# echo >, echo >> and a multi-write editor all do what they say.
		wb := getwbuf(c.fid);
		if(wb == nil) {
			wb = ref Wbuf(c.fid, array of byte filetext(c.path));
			wbufs = wb :: wbufs;
		}
		off := int tm.offset;
		if(off > len wb.buf)
			off = len wb.buf;
		end := off + len tm.data;
		if(end > len wb.buf) {
			nb := array[end] of byte;
			nb[0:] = wb.buf;
			wb.buf = nb;
		}
		wb.buf[off:] = tm.data;
		err := applyfile(c.path, string wb.buf);
		if(err != nil)
			srv.reply(ref Rmsg.Error(tm.tag, err));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	}
}

Wbuf: adt {
	fid:	int;
	buf:	array of byte;
};
wbufs: list of ref Wbuf;

getwbuf(fid: int): ref Wbuf
{
	for(l := wbufs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropwbuf(fid: int)
{
	nl: list of ref Wbuf;
	for(l := wbufs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	wbufs = nl;
}

# The live contents of a writable file (what a non-truncating write edits).
filetext(p: big): string
{
	lock();
	s := "";
	case TYPE(p) {
	Qmeta =>
		s = live.metatext();
	Qtime =>
		if(live.hast)
			s = fmt(live.t) + "\n";
	* =>
		if((o := live.find(TYPE(p) - Qobj, slotid(p))) != nil)
			s = o.text();
	}
	unlock();
	return s;
}

# A stanza file's new contents, applied as one record.
applyfile(p: big, text: string): string
{
	rec: string;
	t := TYPE(p);
	lock();
	case t {
	Qmeta =>
		rec = recline("meta" :: nil, scene->stanza(text));
	Qtime =>
		v := trim(text);
		if(v == "") {
			unlock();
			return nil;
		}
		rec = "time " + v;
	* =>
		k := t - Qobj;
		rec = recline(scene->kindname(k) :: slotid(p) :: nil, scene->stanza(text));
	}
	err := change(rec);
	unlock();
	changed();
	return err;
}

recline(head: list of string, kv: list of (string, string)): string
{
	l := rev(head);
	for(; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		l = (k + "=" + v) :: l;
	}
	return quotedl(rev(l));
}

docreate(tm: ref Tmsg.Create)
{
	c := srv.getfid(tm.fid);
	if(c == nil || c.isopen) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	k := -1;
	case TYPE(c.path) {
	Qentdir =>	k = Scene->ENT;
	Qfeatdir =>	k = Scene->FEAT;
	Qlayerdir =>	k = Scene->LAYER;
	}
	if(k < 0 || tm.perm & Sys->DMDIR) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		return;
	}
	if(!goodname(tm.name)) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ename));
		return;
	}
	lock();
	if(live.find(k, tm.name) == nil)
		change(scene->kindname(k) + " " + quotedl(tm.name :: nil));
	q := Qid(objpath(k, tm.name), 0, Sys->QTFILE);
	unlock();
	changed();
	c.open(tm.mode, q);
	wbufs = ref Wbuf(c.fid, array[0] of byte) :: wbufs;
	srv.reply(ref Rmsg.Create(tm.tag, q, srv.iounit()));
}

doremove(tm: ref Tmsg.Remove)
{
	c := srv.getfid(tm.fid);
	if(c == nil) {
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	t := TYPE(c.path);
	if(t < Qobj || t >= Qobj + 3) {
		dropwbuf(c.fid);
		if(t == Qevent)
			dropevq(c.fid);
		srv.delfid(c);
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		return;
	}
	lock();
	err := change("del " + scene->kindname(t - Qobj) + " " + quotedl(slotid(c.path) :: nil));
	unlock();
	changed();
	dropwbuf(c.fid);
	srv.delfid(c);
	if(err != nil)
		srv.reply(ref Rmsg.Error(tm.tag, err));
	else
		srv.reply(ref Rmsg.Remove(tm.tag));
}

# ── the model and its history ──────────────────────────────

# Apply one record to the live scene and record it.  Called locked.
change(rec: string): string
{
	if(rec == "" || rec[0] == '#')
		return nil;
	ot := live.t;
	oh := live.hast;
	if((err := live.apply(rec)) != nil)
		return err;
	if(len rec >= 5 && rec[0:5] == "time ") {
		if(oh && live.t == ot)
			return nil;	# no news
	}
	record(rec);
	if(mode == LIVE)
		sgen++;
	return nil;
}

# Append to the history, stamping it with the clock when that moved.
record(rec: string)
{
	if(len rec >= 5 && rec[0:5] == "time ") {
		if(!hast0) {
			t0 = live.t;
			hast0 = 1;
		}
		lastrect = live.t;
		hasrect = 1;
		push("time " + fmt(live.t));
		return;
	}
	if(live.hast && (!hasrect || live.t != lastrect)) {
		lastrect = live.t;
		hasrect = 1;
		push("time " + fmt(live.t));
	}
	push(rec);
}

push(s: string)
{
	if(nhist == len hoff) {
		nh := array[2 * len hoff] of int;
		nh[0:] = hoff;
		hoff = nh;
	}
	if(s == "clear")
		lastclear = nhist;
	hoff[nhist++] = nhistb;
	b := array of byte (s + "\n");
	if(nhistb + len b > len histb) {
		n := 2 * len histb;
		if(n < nhistb + len b)
			n = nhistb + len b + 4096;
		nb := array[n] of byte;
		nb[0:] = histb[0:nhistb];
		histb = nb;
	}
	histb[nhistb:] = b;
	nhistb += len b;
}

# Record i of the history, without its newline.
hist(i: int): string
{
	e := nhistb;
	if(i + 1 < nhist)
		e = hoff[i + 1];
	return string histb[hoff[i]:e - 1];
}

# After a (batch of) change(s): tell the watchers.
changed()
{
	if(mode == LIVE)
		post("gen " + string sgen);
}

# Leave live mode: the shown scene becomes a replay at t.  Locked.
detach(t: real)
{
	if(t == live.t) {	# the common case, pause: a copy of live, exact
		shown = Model.new();
		(nil, lines) := sys->tokenize(live.dump(), "\n");
		for(; lines != nil; lines = tl lines)
			shown.apply(hd lines);
		hidx = nhist;
		pt = t;
		sgen++;
		return;
	}
	pt = t;
	rebuild();
}

# Rebuild the shown scene from the history up to the playhead.  Locked.
rebuild()
{
	shown = Model.new();
	hidx = lastclear;
	advance(pt);
}

# Move the playhead forward to t, applying history records.  Locked.
advance(t: real)
{
	if(t < pt) {
		pt = t;
		rebuild();
		return;
	}
	pt = t;
	while(hidx < nhist) {
		r := hist(hidx);
		if(len r > 5 && r[0:5] == "time " && real r[5:] > pt)
			break;
		shown.apply(r);
		hidx++;
	}
	if(!shown.hast || shown.t < pt)
		shown.settime(pt);
	sgen++;
}

# ── ctl ────────────────────────────────────────────────────

ctl(line: string): string
{
	if(line == "")
		return nil;
	(n, toks) := sys->tokenize(line, " \t");
	verb := hd toks;
	args := tl toks;
	arg1 := "";
	if(args != nil)
		arg1 = hd args;
	camchange := 0;
	case verb {
	"center" =>
		if(n != 3)
			return "usage: center A B";
		lock();
		cam.ca = real arg1;
		cam.cb = real hd tl args;
		fitpending = 0;
		unlock();
		camchange = 1;
	"zoom" =>
		if(n != 2)
			return "usage: zoom Z";
		lock();
		cam.zoom = real arg1;
		fitpending = 0;
		unlock();
		camchange = 1;
	"fit" =>
		fitseq++;
		fitpending = fitseq;
		camchange = 1;
	"follow" =>
		if(n != 2)
			return "usage: follow ID";
		cam.follow = arg1;
		camchange = 1;
	"unfollow" =>
		cam.follow = nil;
		camchange = 1;
	"select" =>
		if(n != 2)
			return "usage: select ID";
		cam.sel = arg1;
		post("select " + arg1);
		camchange = 1;
	"deselect" =>
		cam.sel = nil;
		post("select -");
		camchange = 1;
	"play" =>
		lock();
		if(mode == LIVE) {	# play from where live is, i.e. nothing to do
			unlock();
			return nil;
		}
		mode = PLAYING;
		unlock();
	"pause" =>
		lock();
		if(mode == LIVE)
			detach(live.t);
		mode = PAUSED;
		unlock();
	"seek" =>
		if(n != 2)
			return "usage: seek T";
		lock();
		if(mode == LIVE)
			detach(real arg1);
		else
			advance(real arg1);
		mode = PAUSED;
		unlock();
		post("time " + fmt(pt));
	"step" =>
		lock();
		if(mode == LIVE)
			detach(live.t);
		mode = PAUSED;
		if(n >= 2)
			advance(pt + real arg1);
		else
			advance(nexttime());
		unlock();
		post("time " + fmt(pt));
	"rate" =>
		if(n != 2 || real arg1 <= 0.0)
			return "usage: rate R (R > 0)";
		rate = real arg1;
	"live" =>
		lock();
		mode = LIVE;
		shown = live;
		sgen++;
		unlock();
	"clear" =>
		lock();
		change("clear");
		unlock();
	* =>
		return "unknown command: " + verb;
	}
	if(camchange)
		post("view " + viewtext());
	else
		post("gen " + string sgen);
	return nil;
}

# The clock value of the next time record after the playhead.
nexttime(): real
{
	for(i := hidx; i < nhist; i++) {
		r := hist(i);
		if(len r > 5 && r[0:5] == "time " && real r[5:] > pt)
			return real r[5:];
	}
	return pt;
}

# ── events ─────────────────────────────────────────────────

post(ev: string)
{
	for(l := evqs; l != nil; l = tl l) {
		q := hd l;
		if(q.pending != nil && q.q == nil) {
			q.pending.offset = big 0;	# events are a stream, not a file
			srv.reply(styxservers->readstr(q.pending, ev + "\n"));
			q.pending = nil;
			continue;
		}
		# coalesce: a newer gen/time/view replaces a queued one of its kind
		(nil, w) := sys->tokenize(ev, " ");
		kind := hd w;
		if(kind == "gen" || kind == "time" || kind == "view") {
			nq: list of string;
			for(ql := q.q; ql != nil; ql = tl ql) {
				(nil, qw) := sys->tokenize(hd ql, " ");
				if(hd qw != kind)
					nq = hd ql :: nq;
				else
					q.n--;
			}
			q.q = revs(nq);
		}
		q.q = appends(q.q, ev);
		q.n++;
		while(q.n > EVMAX) {
			q.q = tl q.q;
			q.n--;
		}
	}
}

evreply(tm: ref Tmsg.Read, q: ref Evq): ref Rmsg
{
	ev := hd q.q;
	q.q = tl q.q;
	q.n--;
	tm.offset = big 0;
	return styxservers->readstr(tm, ev + "\n");
}

getevq(fid: int): ref Evq
{
	for(l := evqs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

dropevq(fid: int)
{
	nl: list of ref Evq;
	for(l := evqs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	evqs = nl;
}

cancelpending(tag: int)
{
	for(l := evqs; l != nil; l = tl l)
		if((q := hd l).pending != nil && q.pending.tag == tag)
			q.pending = nil;
}

# ── the namespace ──────────────────────────────────────────

TYPE(p: big): int
{
	return int (p & big 16rFF);
}

slotid(p: big): string
{
	k := TYPE(p) - Qobj;
	s := int (p >> 8);
	if(k < 0 || k >= 3 || s >= nslots[k])
		return nil;
	return slotids[k][s];
}

objpath(k: int, id: string): big
{
	h := strhash(id) % len slotlook[k];
	for(l := slotlook[k][h]; l != nil; l = tl l) {
		(sid, s) := hd l;
		if(sid == id)
			return (big s << 8) | big (Qobj + k);
	}
	if(nslots[k] == len slotids[k]) {
		na := array[2 * len slotids[k]] of string;
		na[0:] = slotids[k];
		slotids[k] = na;
	}
	s := nslots[k]++;
	slotids[k][s] = id;
	slotlook[k][h] = (id, s) :: slotlook[k][h];
	return (big s << 8) | big (Qobj + k);
}

dir(p: big, name: string, perm: int, length: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = name;
	d.uid = d.gid = user;
	d.qid = Qid(p, 0, Sys->QTFILE);
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	d.length = big length;
	return d;
}

# Called locked.
dirgen(p: big): ref Sys->Dir
{
	case TYPE(p) {
	Qroot =>	return dir(p, ".", Sys->DMDIR|8r775, 0);
	Qctl =>	return dir(p, "ctl", 8r222, 0);
	Qview =>	return dir(p, "view", 8r444, 0);
	Qstatus =>	return dir(p, "status", 8r444, 0);
	Qevent =>	return dir(p, "event", 8r444, 0);
	Qlog =>	return dir(p, "log", 8r222, 0);
	Qhistory =>	return dir(p, "history", 8r444, 0);
	Qmeta =>	return dir(p, "meta", 8r664, len array of byte shown.metatext());
	Qtime =>	return dir(p, "time", 8r664, 0);
	Qentdir =>	return dir(p, "entities", Sys->DMDIR|8r775, 0);
	Qfeatdir =>	return dir(p, "features", Sys->DMDIR|8r775, 0);
	Qlayerdir =>	return dir(p, "layers", Sys->DMDIR|8r775, 0);
	}
	t := TYPE(p);
	if(t >= Qobj && t < Qobj + 3) {
		id := slotid(p);
		o := shown.find(t - Qobj, id);
		if(o == nil)
			return nil;
		return dir(p, id, 8r664, len array of byte o.text());
	}
	return nil;
}

rootents := array[] of {Qctl, Qview, Qstatus, Qevent, Qlog, Qhistory, Qmeta, Qtime,
	Qentdir, Qfeatdir, Qlayerdir};

# The entries of a directory.  Called locked.
entries(p: big): array of big
{
	case TYPE(p) {
	Qroot =>
		a := array[len rootents] of big;
		for(i := 0; i < len rootents; i++)
			a[i] = big rootents[i];
		return a;
	Qentdir or Qfeatdir or Qlayerdir =>
		k := TYPE(p) - Qentdir;
		objs := shown.objs(k);
		a := array[len objs] of big;
		for(i := 0; i < len objs; i++)
			a[i] = objpath(k, objs[i].id);
		return a;
	}
	return nil;
}

navigator(c: chan of ref Navop)
{
	while((m := <-c) != nil) {
		lock();
		pick n := m {
		Stat =>
			d := dirgen(n.path);
			if(d == nil)
				n.reply <-= (nil, Styxservers->Enotfound);
			else
				n.reply <-= (d, nil);
		Walk =>
			n.reply <-= walk(n.path, n.name);
		Readdir =>
			a := entries(n.path);
			j := 0;
			for(i := 0; i < len a && j < n.offset + n.count; i++) {
				d := dirgen(a[i]);
				if(d == nil)
					continue;
				if(j++ >= n.offset)
					n.reply <-= (d, nil);
			}
			n.reply <-= (nil, nil);
		}
		unlock();
	}
}

walk(p: big, name: string): (ref Sys->Dir, string)
{
	t := TYPE(p);
	if(name == "..") {
		if(t >= Qobj && t < Qobj + 3)
			return (dirgen(big (Qentdir + t - Qobj)), nil);
		return (dirgen(big Qroot), nil);
	}
	case t {
	Qroot =>
		for(i := 0; i < len rootents; i++) {
			d := dirgen(big rootents[i]);
			if(d.name == name)
				return (d, nil);
		}
	Qentdir or Qfeatdir or Qlayerdir =>
		k := t - Qentdir;
		if(shown.find(k, name) != nil)
			return (dirgen(objpath(k, name)), nil);
	* =>
		return (nil, Styxservers->Enotdir);
	}
	return (nil, Styxservers->Enotfound);
}

# ── helpers ────────────────────────────────────────────────

goodname(s: string): int
{
	if(s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '/' || s[i] < 16r20)
			return 0;
	return 1;
}

quotedl(l: list of string): string
{
	return str->quoted(l);
}

fmt(v: real): string
{
	if(v == real int v)
		return string int v;
	s := sys->sprint("%.9f", v);
	while(len s > 1 && s[len s - 1] == '0')
		s = s[0:len s - 1];
	if(s[len s - 1] == '.')
		s = s[0:len s - 1];
	return s;
}

strhash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = (h * 31 + s[i]) & 16r7FFFFFF;
	return h;
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revs(l: list of string): list of string
{
	return rev(l);
}

appends(l: list of string, s: string): list of string
{
	return rev(s :: rev(l));
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

fatal(s: string)
{
	sys->fprint(stderr, "scenefs: %s\n", s);
	raise "fail:error";
}
