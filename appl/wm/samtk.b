implement Samtk;

include "sys.m";
sys: Sys;
sprint, FD: import sys;

include "draw.m";
draw:	Draw;
Point, Rect, Font: import draw;

include "samterm.m";
Context, Flayer, Text, Section: import Samterm;

include "tkclient.m";

include "lucitheme.m";

include "samtk.m";

ctxt: ref Context;

tk:	Tk;
tkclient:	Tkclient;

# sam is a single window, as in Plan 9.  The command window takes the
# top fifth; every other window on a file is a layer the user sweeps out
# with button 3 (a click instead of a sweep takes the space below the
# command window).  Layers overlap and the current one is drawn on top
# with a heavy border.  Here the window is a Tk toplevel holding one
# canvas, .c, and each layer is a frame, .c.f<id>, embedded in it as a
# canvas window item tagged f<id>.

tktop := array[] of {
	"canvas .c -borderwidth 0 -width 640 -height 480",
	"pack .Wm_t -fill x",
	"pack .c -fill both -expand 1",
	"pack propagate . 0",
	# Tk delivers <Configure> to pack slaves, not to the toplevel
	"bind .c <Configure> {send wmctl resize}",
	"update",
};

BORDER:	con 2;		# a layer's frame; coloured to show the current one
MINDX:	con 100;	# smallest layer a sweep may make, as in sam
MINDY:	con 40;

# colours from the Lucifer theme ("" keeps Tk's defaults)
textcolours := "";
canvasbg := "";
curborder := "#000000ff";	# the current layer
border := "#808080ff";		# every other layer
sweepcolour := "#ff0000ff";

col(rgba: int): string
{
	return sprint("#%06xff", (rgba >> 8) & 16rFFFFFF);
}

init(c: ref Context)
{
	ctxt = c;
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;

	tkclient = load Tkclient Tkclient->PATH;
	tkclient->init();

	lucitheme := load Lucitheme Lucitheme->PATH;
	if (lucitheme != nil) {
		th := lucitheme->gettheme();
		textcolours = sprint(" -background %s -foreground %s -selectbackground %s -selectforeground %s",
			col(th.editbg), col(th.edittext), col(th.accent), col(th.editbg));
		canvasbg = col(th.bg);
		curborder = col(th.accent);
		border = col(th.border);
		sweepcolour = col(th.accent);
	}

	scrollpos = scrolllines = 0;

	# both loaders of Samtk call init; the window is made once
	if (ctxt.top == nil)
		mktop();
}

# sam's one window
mktop()
{
	(t, wmctl) := tkclient->toplevel(ctxt.ctxt, nil, "Sam", Tkclient->Appl);
	ctxt.top = t;
	ctxt.wmctl = wmctl;
	ctxt.sweepc = chan[16] of string;
	tk->namechan(t, ctxt.wmctl, "wmctl");
	tk->namechan(t, ctxt.sweepc, "sweep");
	tkcmds(t, tktop);
	if (canvasbg != "")
		tk->cmd(t, ".c configure -background " + canvasbg);

	# Appl-mode toplevels are created hidden; reveal it and wire up
	# keyboard/mouse, or the window never appears and takes no input.
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	spawn pump(t);
	tk->cmd(t, "update");
	ctxt.size = canvassize();
	sys->fprint(ctxt.logfd, "mktop: canvas %d %d\n", ctxt.size.x, ctxt.size.y);
}

canvassize(): Point
{
	return (int tk->cmd(ctxt.top, ".c cget -actwidth"),
		int tk->cmd(ctxt.top, ".c cget -actheight"));
}

# issue a batch of Tk commands to one toplevel; formerly tkclient->tkcmds
tkcmds(t: ref Tk->Toplevel, cmds: array of string)
{
	for (i := 0; i < len cmds; i++) {
		e := tk->cmd(t, cmds[i]);
		if (e != nil && e[0] == '!')
			sys->fprint(ctxt.logfd, "tk: %s: %s\n", cmds[i], e);
	}
}

# A new layer.  tp is set for the command window, which gets its own
# button 2 menu; the first one made is placed at the top of the window,
# any other is swept out by the user, as in sam.
newflayer(tag, tp: int): ref Flayer
{
	t := ctxt.top;
	r: Rect;
	if (tp && ctxt.cmd == nil)
		r = cmdrect();
	else
		r = getrect();

	id := ctxt.nextid++;
	w := ".c.f" + string id;
	n := chanadd();
	tk->namechan(t, ctxt.menu3sel[n], "menu3_" + string id);
	tk->namechan(t, ctxt.menu2sel[n], "menu2_" + string id);
	tk->namechan(t, ctxt.buttonsel[n], "button1_" + string id);
	tk->namechan(t, ctxt.keysel[n], "keys_" + string id);
	tk->namechan(t, ctxt.scrollsel[n], "scroll_" + string id);

	tkcmds(t, array[] of {
		"frame " + w + " -borderwidth " + string BORDER + " -relief flat -background " + border,
		"scrollbar " + w + ".s -command {send scroll_" + string id + "}",
		"text " + w + ".t -borderwidth 0" + textcolours,
		"pack " + w + ".s -side left -fill y",
		"pack " + w + ".t -fill both -expand 1",
		sprint(".c create window %d %d -window %s -anchor nw -tags f%d", r.min.x, r.min.y, w, id),
	});
	if (tp)
		mkmenu2c(w, id);
	else
		mkmenu2(w, id);
	mkmenu3(w, id);
	bindlayer(w, id, 0);
	if (tp && ctxt.cmd == nil)	# button 3 on the bare canvas
		tk->cmd(t, "bind .c <ButtonPress-3> {" + w + ".m3 post %X %Y; grab set " + w + ".m3}");

	f := ref Flayer(
		tag,		# tag
		t,		# t
		"",		# tkwin
		(0, 0),		# scope
		(0, 0),		# dot
		0,		# width
		lineheight(w),	# lineheigth
		1,		# lines
		(0, 1),		# scrollbar
		-1,		# typepoint
		id,		# id
		w,		# w
		r		# r
	);
	place(f, r);
	ctxt.flayers[n] = f;
	sys->fprint(ctxt.logfd, "newflayer: %s at %d %d %d %d, %d lines\n",
		w, r.min.x, r.min.y, r.max.x, r.max.y, f.lines);
	return f;
}

# the bindings of a layer's text and scrollbar
bindlayer(w: string, id: int, sweeping: int)
{
	t := ctxt.top;
	sid := string id;
	tkcmds(t, array[] of {
		"bind " + w + ".t <Key> {send keys_" + sid + " {%A}}",
		"bind " + w + ".t <Key-\b> {send keys_" + sid + " {%A}}",
		"bind " + w + ".s <ButtonRelease-1> +{send scroll_" + sid + " %s %b %y}",
		"bind " + w + ".t <ButtonPress-1> +{send button1_" + sid + " %s %b %x %y}",
		"bind " + w + ".t <ButtonRelease-1> +{send button1_" + sid + " %s %b %x %y}",
		"bind " + w + ".t <Double-ButtonPress-1> {send button1_" + sid + " 2 %b %x %y}",
		"bind " + w + ".t <Double-ButtonRelease-1> {send button1_" + sid + " 3 %b %x %y}",
		"bind " + w + ".t <ButtonPress-2> {" + w + ".m2 post %X %Y; grab set " + w + ".m2}",
	});
	sweepbind(w + ".t", w + ".m3", sweeping);
	sweepbind(w + ".s", w + ".m3", sweeping);
	sweepbind(w, w + ".m3", sweeping);
}

# Button 3 on w posts menu m, or, while a layer is being swept out,
# reports to getrect.  Neither text nor scrollbar uses button 3 itself,
# so these bindings can be replaced and restored freely.
sweepbind(w, m: string, sweeping: int)
{
	t := ctxt.top;
	if (sweeping) {
		tk->cmd(t, "bind " + w + " <ButtonPress-3> {send sweep p %X %Y}");
		tk->cmd(t, "bind " + w + " <Motion-Button-3> {send sweep m %X %Y}");
		tk->cmd(t, "bind " + w + " <ButtonRelease-3> {send sweep r %X %Y}");
	} else {
		tk->cmd(t, "bind " + w + " <ButtonPress-3> {" + m + " post %X %Y; grab set " + m + "}");
		tk->cmd(t, "bind " + w + " <Motion-Button-3> {}");
		tk->cmd(t, "bind " + w + " <ButtonRelease-3> {}");
	}
}

# the height of a line of text in layer w
lineheight(w: string): int
{
	h := 0;
	fname := tk->cmd(ctxt.top, w + ".t cget -font");
	if (fname != nil && fname[0] != '!' && ctxt.ctxt != nil && ctxt.ctxt.display != nil) {
		f := Font.open(ctxt.ctxt.display, fname);
		if (f != nil)
			h = f.height;
	}
	if (h <= 0)
		h = 16;
	return h;
}

# put layer fl at r (canvas coordinates) and size its text to fit
place(fl: ref Flayer, r: Rect)
{
	fl.r = r;
	tkcmds(ctxt.top, array[] of {
		sprint(".c coords f%d %d %d", fl.id, r.min.x, r.min.y),
		sprint(".c itemconfigure f%d -width %d -height %d", fl.id,
			r.dx() - 2*BORDER, r.dy() - 2*BORDER),
		"update",
	});
	resize(fl);
}

# The command window's place when sam starts: the top fifth.
cmdrect(): Rect
{
	sz := canvassize();
	ctxt.size = sz;
	return ((0, 0), (sz.x, sz.y/5));
}

# Have the user sweep out a rectangle for a new layer with button 3,
# as sam's getr does.  A click rather than a sweep takes the whole
# window less the command window, on the side of it clicked.  Anything
# too small for a window gets that too: here a layer cannot fail to be
# made.
getrect(): Rect
{
	t := ctxt.top;
	# stale reports from an earlier sweep
	drain: for (;;) alt {
	<-ctxt.sweepc =>
		;
	* =>
		break drain;
	}
	sweeping(1);
	tk->cmd(t, "cursor -bitmap cursor.win; update");

	p0, p1: Point;
	down := 0;
	for (;;) {
		(n, l) := sys->tokenize(<-ctxt.sweepc, " ");
		if (n != 3)
			continue;
		p := Point(int tk->cmd(t, ".c canvasx " + hd tl l),
			int tk->cmd(t, ".c canvasy " + hd tl tl l));
		case hd l {
		"p" =>
			p0 = p1 = p;
			down = 1;
			tk->cmd(t, sprint(".c create rectangle %d %d %d %d -outline %s -width 2 -tags sweep",
				p.x, p.y, p.x, p.y, sweepcolour));
			tk->cmd(t, ".c raise sweep; update");
			continue;
		"m" =>
			if (down) {
				p1 = p;
				tk->cmd(t, sprint(".c coords sweep %d %d %d %d; update",
					p0.x, p0.y, p1.x, p1.y));
			}
			continue;
		"r" =>
			if (!down)
				continue;
			p1 = p;
		* =>
			continue;
		}
		break;
	}
	tk->cmd(t, ".c delete sweep");
	sweeping(0);
	if (ctxt.lock)
		tk->cmd(t, "cursor -bitmap cursor.wait; update");
	else
		tk->cmd(t, "cursor -default; update");
	return sweptrect(Rect(p0, p1).canon());
}

sweeping(on: int)
{
	# the bare canvas posts the command window's menu
	m := ".c.f0.m3";
	if (ctxt.cmd != nil && ctxt.cmd.flayers != nil)
		m = (hd ctxt.cmd.flayers).w + ".m3";
	sweepbind(".c", m, on);
	for (i := 0; i < len ctxt.flayers; i++) {
		fl := ctxt.flayers[i];
		if (fl == nil)
			continue;
		sweepbind(fl.w + ".t", fl.w + ".m3", on);
		sweepbind(fl.w + ".s", fl.w + ".m3", on);
		sweepbind(fl.w, fl.w + ".m3", on);
	}
}

# sam's getr: what a sweep from r means
sweptrect(r: Rect): Rect
{
	sz := canvassize();
	screen := Rect((0, 0), sz);
	if (r.dx() <= 5 && r.dy() <= 5) {
		p := r.min;
		r = screen;
		if (ctxt.cmd != nil && len ctxt.cmd.flayers == 1) {
			c := (hd ctxt.cmd.flayers).r;
			if (p.y <= c.min.y)
				r.max.y = c.min.y;
			else if (p.y >= c.max.y)
				r.min.y = c.max.y;
			if (p.x <= c.min.x)
				r.max.x = c.min.x;
			else if (p.x >= c.max.x)
				r.min.x = c.max.x;
		}
	}
	(r, nil) = r.clip(screen);
	if (r.dx() > MINDX && r.dy() > MINDY)
		return r;
	# too small: below the command window, or all of it
	r = screen;
	if (ctxt.cmd != nil && ctxt.cmd.flayers != nil)
		r.min.y = (hd ctxt.cmd.flayers).r.max.y;
	if (r.dx() > MINDX && r.dy() > MINDY)
		return r;
	return screen;
}

# button 3 "resize": sweep a new place for a layer
reshape(fl: ref Flayer)
{
	place(fl, getrect());
	tk->cmd(ctxt.top, sprint(".c raise f%d; update", fl.id));
}

# The window changed size: scale every layer with it, as sam does.
# Returns 0 if nothing moved.
reshapeall(): int
{
	sz := canvassize();
	old := ctxt.size;
	if (sz.x <= 0 || sz.y <= 0 || sz.eq(old))
		return 0;
	ctxt.size = sz;
	for (i := 0; i < len ctxt.flayers; i++) {
		fl := ctxt.flayers[i];
		if (fl == nil)
			continue;
		r := fl.r;
		if (old.x > 0 && old.y > 0)
			r = Rect((r.min.x*sz.x/old.x, r.min.y*sz.y/old.y),
				(r.max.x*sz.x/old.x, r.max.y*sz.y/old.y));
		place(fl, r);
	}
	return 1;
}

menu2str := array [] of {
	"cut",
	"paste",
	"snarf",
	"look",
#	"exch",
	"send",		# storage for last pattern
};

menu3str := array [] of {
	"new",
	"zerox",
	"resize",
	"close",
	"write",
};

# button 2 in the command window
mkmenu2c(w: string, id: int)
{
	menus := array [NMENU2+1] of string;

	menus[0] = "menu " + w + ".m2";
	for (i := 0; i < NMENU2; i++)
		menus[i+1] = addmenuitem(w + ".m2", "menu2_" + string id, menu2str[i], menu2str[i]);
	tkcmds(ctxt.top, menus);
}

# button 2 in a file: the last entry searches for the last pattern
mkmenu2(w: string, id: int)
{
	menus := array [NMENU2+1] of string;

	menus[0] = "menu " + w + ".m2";
	for (i := 0; i < NMENU2-1; i++)
		menus[i+1] = addmenuitem(w + ".m2", "menu2_" + string id, menu2str[i], menu2str[i]);
	menus[NMENU2] = addmenuitem(w + ".m2", "menu2_" + string id, "/" + lastpat, "search");
	tkcmds(ctxt.top, menus);
}

# button 3: the commands, then every file
mkmenu3(w: string, id: int)
{
	menus := array [NMENU3+len ctxt.menus+1] of string;

	menus[0] = "menu " + w + ".m3";
	for (i := 0; i < NMENU3; i++)
		menus[i+1] = addmenuitem(w + ".m3", "menu3_" + string id, menu3str[i], menu3str[i]);
	for (i = 0; i < len ctxt.menus; i++)
		menus[i+NMENU3+1] = addmenuitem(w + ".m3", "menu3_" + string id,
			filelabel(i), "file " + string ctxt.menus[i].tag);
	tkcmds(ctxt.top, menus);
}

addmenuitem(m, c, label, cmd: string): string
{
	return sprint("%s add command -text %s -command {send %s %s}",
		m, tk->quote(label), c, cmd);
}

# the name of a file; an unnamed file still needs a label
menulabel(s: string): string
{
	if (s == "")
		return Unnamed;
	return s;
}

# A file's entry in the button 3 menu, as sam shows it: ' if modified,
# - with no window, + with one, * with several, and . if current.
filelabel(i: int): string
{
	m := ctxt.menus[i];
	t := m.text;
	if (ctxt.cmd != nil && t == ctxt.cmd)
		return menulabel(m.name);
	mod := ' ';
	win := '-';
	cur := ' ';
	if (t != nil) {
		if (t.state & (Samterm->Dirty|Samterm->LDirty))
			mod = '\'';
		if (len t.flayers == 1)
			win = '+';
		else if (len t.flayers > 1)
			win = '*';
		if (ctxt.work != nil && ctxt.work.t != nil && ctxt.work.tag == t.tag)
			cur = '.';
	}
	s := "   ";
	s[0] = mod;
	s[1] = win;
	s[2] = cur;
	return s + " " + menulabel(m.name);
}

# bring every layer's button 3 file list up to date
relabel()
{
	for (j := 0; j < len ctxt.flayers; j++) {
		fl := ctxt.flayers[j];
		if (fl == nil)
			continue;
		for (i := 0; i < len ctxt.menus; i++)
			tk->cmd(ctxt.top, sprint("%s.m3 entryconfigure %d -text %s",
				fl.w, i + NMENU3, tk->quote(filelabel(i))));
	}
}

menuins(pos: int, nil: string)
{
	for (i := 0; i < len ctxt.flayers; i++) {
		fl := ctxt.flayers[i];
		tk->cmd(ctxt.top, sprint("%s.m3 insert %d command -text %s -command {send menu3_%d file %d}",
			fl.w, pos + NMENU3, tk->quote(filelabel(pos)), fl.id, ctxt.menus[pos].tag));
	}
}

menudel(pos: int)
{
	for (i := 0; i < len ctxt.flayers; i++)
		tk->cmd(ctxt.top, sprint("%s.m3 delete %d", ctxt.flayers[i].w, pos + NMENU3));
}

lastpat := "";

hsetpat(s: string)
{
	lastpat = s;
	for (i := 0; i < len ctxt.flayers; i++) {
		fl := ctxt.flayers[i];
		if (fl.tag != ctxt.cmd.tag)
			tk->cmd(ctxt.top, fl.w + ".m2 entryconfigure " + string Search
				+ " -text " + tk->quote("/" + s));
	}
}

titlectl(menu: string)
{
	tkclient->wmctl(ctxt.top, menu);
}

# make fl the layer on top, with the heavy border and the keyboard
flraise(t: ref Text, fl: ref Flayer)
{
	t.flayers = fl :: dellist(t.flayers, fl);
	top := ctxt.top;
	if (ctxt.which != nil && ctxt.which != fl && ctxt.which.t != nil)
		tk->cmd(top, ctxt.which.w + " configure -background " + border);
	tk->cmd(top, fl.w + " configure -background " + curborder);
	tk->cmd(top, sprint(".c raise f%d; focus %s.t; update", fl.id, fl.w));
}

dellist(fls: list of ref Flayer, fl: ref Flayer): list of ref Flayer
{
	if (fls == nil) return nil;
	if (hd fls == fl) return dellist(tl fls, fl);
	return hd fls :: dellist(tl fls, fl);
}

append(fls: list of ref Flayer, fl: ref Flayer): list of ref Flayer
{
	if (fls == nil) return fl :: nil;
	return hd fls :: append(tl fls, fl);
}

focus(fl: ref Flayer)
{
	tk->cmd(ctxt.top, "focus " + fl.w + ".t; update");
}

newcur(t: ref Text, fl: ref Flayer)
{
	if (ctxt.which == fl) return;
	flraise(t, fl);
	ctxt.which = fl;
	if (t != ctxt.cmd)
		ctxt.work = fl;
	relabel();
}

# A file's name or state changed.  Layers have no titles; the button 3
# menu shows the state, as in sam.  The window is titled with the file
# being worked on.
settitle(t: ref Text, s: string)
{
	for (fls := t.flayers; fls != nil; fls = tl fls)
		(hd fls).tkwin = s;
	relabel();
	title := "Sam";
	if (ctxt.work != nil && ctxt.work.t != nil && ctxt.work.tkwin != "")
		title += " " + ctxt.work.tkwin;
	tkclient->settitle(ctxt.top, title);
}

resize(fl: ref Flayer)
{
	fl.width = int tk->cmd(ctxt.top, fl.w + ".t cget -actwidth");
	fl.lines = int tk->cmd(ctxt.top, fl.w + ".t cget -actheight") / fl.lineheigth;
	if (fl.lines < 1)
		fl.lines = 1;
}

allflayers(s: string)
{
	tk->cmd(ctxt.top, s);
}

setdot(fl: ref Flayer, l1, l2: int)
{
	tk->cmd(fl.t, fl.w + ".t tag remove sel 0.0 end");

	fl.dot.first = l1;
	fl.dot.last = l2;
	if (l2 <= fl.scope.first)
		tk->cmd(fl.t, fl.w + ".t mark set insert 0.0");
	else if (fl.scope.last <= l1)
		tk->cmd(fl.t, fl.w + ".t mark set insert end");
	else {
		tk->cmd(fl.t, fl.w + sprint(".t mark set insert 0.0+%dchars",
				l1-fl.scope.first));
		if (l1 != l2)
			tk->cmd(fl.t, fl.w + sprint(".t tag add sel 0.0+%dchars 0.0+%dchars",
				l1-fl.scope.first,
				l2-fl.scope.first));
	}
	tk->cmd(fl.t, "update");
}

panic(s: string)
{
	stderr := sys->fildes(2);
	sys->fprint(stderr, "Panic: %s\n", s);
	f := sys->sprint("#p/%d/ctl", ctxt.pgrp);
	if ((fd := sys->open(f, sys->OWRITE)) != nil)
		sys->write(fd, array of byte "killgrp\n", 8);
	exit;
}

whichmenu(tag: int): int
{
	for (i := 0; i < len ctxt.menus; i++)
		if (ctxt.menus[i].tag == tag)
			return i;
	return -1;
}

whichtext(tag: int): int
{
	for (i := 0; i < len ctxt.texts; i++)
		if (ctxt.texts[i].tag == tag)
			return i;
	return -1;
}

setscrollbar(t: ref Text, fl: ref Flayer)
{
	ll := real t.nrunes;
	f1 := 0.0; f2 := 1.0;
	if (ll != 0.0) {
		f1 = real fl.scope.first / ll;
		if (fl.scope.last > t.nrunes)
			f2 = 1.0;
		else
			f2 = real fl.scope.last / ll;
	}
	fl.scrollbar = fl.scope;
	tk->cmd(fl.t, fl.w + sprint(".s set %f %f; update", f1, f2));
}

buttonselect(fl: ref Flayer, s: string): int
{
	tag := fl.tag;
	if ((i := whichtext(tag)) < 0) panic("buttonselect: whichtext");
	t := ctxt.texts[i];

	(n, l) := sys->tokenize(s, " ");
	if (n != 4) panic("buttonselect");

	# ignore mouse down -- wait for mouse up
	if (hd l == "1" || hd l == "3") return 0;

	if (ctxt.which != fl) {
		if (t != ctxt.cmd)
			ctxt.work = fl;
		newcur(t, fl);
#		setdot(fl, fl.dot.first, fl.dot.first);
		return 0;
	}

	if (hd l == "2") {
		# Double click
		l = tl tl l;
		s = tk->cmd(fl.t, fl.w + ".t index @" + hd l + "," + hd tl l);
		fl.dot.first = fl.dot.last = coord2pos(t, fl, s);
		return 1;
	}

	rg := tk->cmd(fl.t, fl.w + ".t tag ranges sel");
	if (rg == "") {
		# Nothing selected, find insertion point
		l = tl tl l;
		s = tk->cmd(fl.t, fl.w + ".t index @" + hd l + "," + hd tl l);
		fl.dot.first = fl.dot.last = coord2pos(t, fl, s);
	} else {
		(n, l) = sys->tokenize(rg, " ");
		#if (n == 4 && hd tl l == hd tl tl l)
		#	lst := hd tl tl tl l;
		#else if (n != 2) panic("buttonselect: tag ranges");
		#else lst = hd tl l;
		# We only have one contiguous selection, so, take the
		# first as dot.first and the last as dot.last
		fst:=hd l;
		lst:=fst;
		while(l!=nil){
			lst=hd l;
			l = tl l;
		}
		fl.dot.first = coord2pos(t, fl, fst);
		fl.dot.last = coord2pos(t, fl, lst);
		tk->cmd(fl.t, fl.w + ".t mark set insert " + fst);
		tk->cmd(fl.t, "update");
	}
	return 0;
}

coord2pos(t: ref Text, fl: ref Flayer, s: string): int
{
	x, y: int;

	(n, l) := sys->tokenize(s, ".");
	if (n != 2) panic("coord2pos");
	y = (int hd l) - 1;
	x = int hd tl l;
	if (x == 0 && y == 0) return fl.scope.first;
	first := fl.scope.first;
	for (scts := t.sects; scts != nil; scts = tl scts) {
		sct := hd scts;
		if (first >= sct.nrunes) {
			first -= sct.nrunes;
			continue;
		}
		if (first > 0) i := first; else i = 0;
		while (i < len sct.text) {
			if (y) {
				if (sct.text[i++] == '\n') y--;
			} else {
				if (x <= 1)
					return fl.scope.first - first + i + x;
				if (sct.text[i++] == '\n') panic("coord2pos");
				x--;
			}
		}
		if (len sct.text < sct.nrunes) panic("coord2pos: hole");
		first -= sct.nrunes;
	}
	if (x <= 0 && y == 0) return t.nrunes;
	panic("coord2pos: can't find");
	return(-1);
}

scrollpos, scrolllines: int;

scroll(fl: ref Flayer, s: string): (int, int)
{
	tag := fl.tag;
	if ((i := whichtext(tag)) < 0) panic("scroll: whichtext");
	t := ctxt.texts[i];
	(n, l) := sys->tokenize(s, " ");
	height := fl.scrollbar.last - fl.scrollbar.first;
	length := t.nrunes;
	case (hd l) {
	"0" =>
		if (n != 3) panic("scroll: format");
		return (scrollpos, scrolllines);
	"moveto" =>
		if (n != 2) panic("scroll: format");
		f := real hd tl l;
		if (f < 0.0) f = 0.0;
		if (f > 1.0) f = 1.0;
		scrollpos = int (f * real length) - height/2;
		scrolllines = 1;
	"scroll" =>
		if (n != 3) panic("scroll: format");
		l = tl l;
		n = int hd l;
		case(hd tl l) {
		"page" =>
			if (n < 0) {
				scrollpos = fl.scrollbar.first;
				scrolllines = fl.lines;
				break;
			}
			scrollpos = fl.scrollbar.last;
			scrolllines = 0;
		"unit" =>
			if (n < 0) {
				scrollpos = fl.scrollbar.first - 1;
				scrolllines = 1;
				break;
			}
			(p, q) := rasplines(t.sects, fl.scrollbar.first, 1);
			if (p > 0) {
				scrollpos = p;
				scrolllines = 0;
			} else {
				scrollpos = fl.scrollbar.first;
				scrolllines = 0;
			}
		}
	* =>
		panic("scroll: input");
	}
	if (scrollpos > length)
		scrollpos = length;
	if (scrollpos < 0) {
		scrollpos = 0;
		scrolllines = 0;
	}
	if (length != 0)
		tk->cmd(fl.t, fl.w + sprint(".s set %f %f",
			real scrollpos / real length,
			real (scrollpos + height) / real length));
	else
		tk->cmd(fl.t, fl.w + ".s set 0.0 1.0");
	tk->cmd(fl.t, "update");
	return (-1, -1);
}

flclear(fl: ref Flayer)
{
	tk->cmd(fl.t, fl.w + ".t delete 0.0 end");
	tk->cmd(fl.t, "update");
}

flinsert(fl: ref Flayer, l: int, s: string)
{
	offset := l-fl.scope.first;
	tk->cmd(fl.t, fl.w + ".t insert 0.0+" + string offset + "chars '" + s);
	setdot(fl, fl.dot.first, fl.dot.last);
}

fldelexcess(fl: ref Flayer)
{
	tk->cmd(fl.t, fl.w + ".t delete " + string (fl.lines+1) + ".0 end");
}

fldelete(fl: ref Flayer, l1, l2: int)
{
	s: string;
	if (l1 <= fl.scope.first) {
		if (l2 >= fl.scope.last) {
			s = fl.w + sprint(".t delete 0.0 end");
			fl.scope.first = fl.scope.last = l1;
		} else {
			s = fl.w + sprint(".t delete 0.0 0.0+%dchars",
				l2 - fl.scope.first);
			fl.scope.last -= l2 - l1;
			fl.scope.first = l1;
		}
	} else {
		if (l2 >= fl.scope.last) {
			s = fl.w + sprint(".t delete 0.0+%dchars end",
				l1 - fl.scope.first);
			fl.scope.last = l1;
		} else {
			s = fl.w + sprint(".t delete 0.0+%dchars 0.0+%dchars",
				l1 - fl.scope.first, l2 - fl.scope.first);
			fl.scope.last -= l2 - l1;	
		}
	}
	if (fl.dot.first >= l2) fl.dot.first -= l2-l1;
	else if (fl.dot.first > l1) fl.dot.first = l1;
	if (fl.dot.last >= l2) fl.dot.last -= l2-l1;
	else if (fl.dot.last > l1) fl.dot.last = l1;
	tk->cmd(fl.t, s);
	setdot(fl, fl.dot.first, fl.dot.last);
	tk->cmd(fl.t, "update");
}

# Calculate position forward or backward nlines lines from pos.
# If lines > 0 count forward, if lines < 0 count backward.\
# Returns a pair, (position, nlines).  Nlines is the remaining
# number of lines to be found.  If non-zero, beginning or end of
# rasp was encountered while still counting, or a hole was
# encountered.  In the former case, position will be 0 or nrunes,
# in the latter case, position will be set to -1.
# To search to the beginning of the current line, set nlines to -1;

rasplines(scts: list of ref Section, pos, nlines: int): (int, int)
{
	p, i: int;
	if (nlines < 0) {
		if (scts != nil) {
			sct := hd scts; scts = tl scts;
			if (pos > sct.nrunes) {
				(p, nlines) =
				    rasplines(scts, pos - sct.nrunes, nlines);
				if (p < 0) return (p, nlines);
				pos = p + sct.nrunes;
				if (nlines == 0) return (pos, 0);
			}
			if (pos > len sct.text) return (-1, nlines);
			for (p = pos-1; p >= 0; p--) {
				if (sct.text[p] == '\n') nlines++;
				if (nlines == 0) return (p+1, 0);
			}
		}
		return (0, nlines);
	} else {
		p = 0;
		while (scts != nil) {
			sct := hd scts; scts = tl scts;
			if (pos < sct.nrunes) {
				for (i = pos; i < len sct.text; i++) {
					if (sct.text[i] == '\n') nlines--;
					if (nlines == 0) return (p+i+1, 0);
				}
				if (i < sct.nrunes) return (-1, nlines);
			}
			pos -= sct.nrunes;
			if (pos < 0) pos = 0;
			p += sct.nrunes;
		}
		return (p, nlines);
	}
}


# Feed the window's keyboard, mouse and window-manager traffic to Tk.
# Tk turns them into the bindings' sends (keys_<id>, button1_<id>,
# sweep ...), which samterm's main loop and getrect read.  A separate
# process, so input keeps reaching Tk while the main loop waits for the
# host or for a sweep; Tk's send never blocks (it queues), so this
# cannot deadlock against the main loop's tk->cmd calls.
pump(t: ref Tk->Toplevel)
{
	for(;;) alt {
	c := <-t.ctxt.kbd =>
		tk->keyboard(t, c);
	p := <-t.ctxt.ptr =>
		tk->pointer(t, *p);
	c := <-t.ctxt.ctl or
	c = <-t.wreq =>
		tkclient->wmctl(t, c);
	}
}

# a slot for a new layer in ctxt.flayers and its channel arrays
chanadd(): int
{
	l := len ctxt.flayers;

	keysel := array [l+1] of chan of string;
	keysel[0:] = ctxt.keysel;
	keysel[l] = chan of string;
	ctxt.keysel = keysel;
	scrollsel := array [l+1] of chan of string;
	scrollsel[0:] = ctxt.scrollsel;
	scrollsel[l] = chan of string;
	ctxt.scrollsel = scrollsel;
	buttonsel := array [l+1] of chan of string;
	buttonsel[0:] = ctxt.buttonsel;
	buttonsel[l] = chan of string;
	ctxt.buttonsel = buttonsel;
	menu2sel := array [l+1] of chan of string;
	menu2sel[0:] = ctxt.menu2sel;
	menu2sel[l] = chan of string;
	ctxt.menu2sel = menu2sel;
	menu3sel := array [l+1] of chan of string;
	menu3sel[0:] = ctxt.menu3sel;
	menu3sel[l] = chan of string;
	ctxt.menu3sel = menu3sel;
	flayers := array [l+1] of ref Flayer;
	flayers[0:] = ctxt.flayers;
	flayers[l] = nil;
	ctxt.flayers = flayers;
	return l;
}

# remove layer n: its widgets, and its slot
chandel(n: int)
{
	l := len ctxt.flayers;
	if (n >= l)
		panic("chandel");

	fl := ctxt.flayers[n];
	if (fl != nil) {
		tkcmds(ctxt.top, array[] of {
			sprint(".c delete f%d", fl.id),
			"destroy " + fl.w + ".m2 " + fl.w + ".m3 " + fl.w,
			"update",
		});
	}

	keysel := array [l-1] of chan of string;
	keysel[0:] = ctxt.keysel[0:n];
	keysel[n:] = ctxt.keysel[n+1:];
	ctxt.keysel = keysel;
	scrollsel := array [l-1] of chan of string;
	scrollsel[0:] = ctxt.scrollsel[0:n];
	scrollsel[n:] = ctxt.scrollsel[n+1:];
	ctxt.scrollsel = scrollsel;
	buttonsel := array [l-1] of chan of string;
	buttonsel[0:] = ctxt.buttonsel[0:n];
	buttonsel[n:] = ctxt.buttonsel[n+1:];
	ctxt.buttonsel = buttonsel;
	menu2sel := array [l-1] of chan of string;
	menu2sel[0:] = ctxt.menu2sel[0:n];
	menu2sel[n:] = ctxt.menu2sel[n+1:];
	ctxt.menu2sel = menu2sel;
	menu3sel := array [l-1] of chan of string;
	menu3sel[0:] = ctxt.menu3sel[0:n];
	menu3sel[n:] = ctxt.menu3sel[n+1:];
	ctxt.menu3sel = menu3sel;
	flayers := array [l-1] of ref Flayer;
	flayers[0:] = ctxt.flayers[0:n];
	flayers[n:] = ctxt.flayers[n+1:];
	ctxt.flayers = flayers;
}
