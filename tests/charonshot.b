implement Charonshot;

#
# charonshot - render one URL with Charon, headlessly, to an image file.
#
#	charonshot [-o] [-d] width[xheight] outimg url
#
# Renders with the new engine (page(2): parse, style, lay out, paint)
# or, with -o, drives the old Charon's -render mode.  -d prints the box
# tree (kind node x y w h) on standard error.  With just a
# width the canvas is up to Maxheight tall and the image is cropped to the
# page, so long pages are captured whole; with widthxheight the viewport is
# exactly that and the whole of it is written, as for conformance
# fixtures.  Extracted page text lands in outimg+".txt".
#
# Host wrapper: tools/charon-shot.sh (decodes the image to PNG).
# When run as emu's initial program it halts the emulator when done,
# since Charon's helper processes would otherwise keep it alive.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "web/dom.m";
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
include "web/page.m";
	layout: Layout;
	page: Page;
	Pg: import page;

Charonshot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

CharonMod: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Maxheight: con 12000;
dumpboxes := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr := sys->fildes(2);

	argv = tl argv;
	old := 0;
	while(argv != nil && len hd argv == 2 && (hd argv)[0] == '-') {
		case hd argv {
		"-o" => old = 1;
		"-d" => dumpboxes = 1;
		}
		argv = tl argv;
	}
	if(len argv != 3) {
		sys->fprint(stderr, "usage: charonshot [-o] width[xheight] outimg url\n");
		halt();
		raise "fail:usage";
	}
	width := hd argv;
	height := string Maxheight;
	crop := "1";
	for(i := 0; i < len width; i++)
		if(width[i] == 'x') {
			height = width[i+1:];
			width = width[0:i];
			crop = "0";
			break;
		}
	outimg := hd tl argv;
	url := hd tl tl argv;

	disp := Display.allocate(nil);
	if(disp == nil) {
		sys->fprint(stderr, "charonshot: no display: %r\n");
		halt();
		raise "fail:display";
	}
	if(!old) {
		err := newengine(disp, int width, int height, crop == "1", outimg, url);
		if(err != nil)
			sys->fprint(stderr, "charonshot: %s\n", err);
		halt();
		return;
	}
	ch := load CharonMod "/dis/charon.dis";
	if(ch == nil) {
		sys->fprint(stderr, "charonshot: cannot load charon: %r\n");
		halt();
		raise "fail:load";
	}
	args := "charon" :: "-render" :: "1"
		:: "-renderout" :: outimg
		:: "-defaultwidth" :: width
		:: "-defaultheight" :: height
		:: "-rendercrop" :: crop
		:: "-doscripts" :: "0"
		:: url :: nil;
	# Charon's render path ends in finish(), which exits the process
	# rather than returning, so wait for the child to go away.
	wfd := sys->open(sys->sprint("/prog/%d/wait", sys->pctl(0, nil)), Sys->OREAD);
	spawn run(ch, ref Draw->Context(disp, nil, nil), args);
	if(wfd != nil) {
		buf := array[256] of byte;
		n := sys->read(wfd, buf, len buf);
		if(n > 0) {
			# "pid module status"; status is empty on a clean exit
			(nil, fl) := sys->tokenize(string buf[0:n], " ");
			if(len fl > 2 && len hd tl tl fl > 2)
				sys->fprint(stderr, "charonshot: %s\n", string buf[0:n]);
		}
	}
	halt();
}

run(ch: CharonMod, ctxt: ref Draw->Context, args: list of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	ch->init(ctxt, args);
}

Command: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

# http(s) comes through webfs; start one if there isn't one already.
startwebfs(): string
{
	if(sys->open("/mnt/web/clone", Sys->OREAD) != nil)
		return nil;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return sys->sprint("cannot load webfs: %r");
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		if(sys->open("/mnt/web/clone", Sys->OREAD) != nil)
			return nil;
		sys->sleep(20);
	}
	return "webfs did not start";
}

newengine(disp: ref Display, w, h, crop: int, outimg, url: string): string
{
	page = load Page Page->PATH;
	if(page == nil)
		return sys->sprint("cannot load %s: %r", Page->PATH);
	if((ierr := page->init(disp)) != nil)
		return ierr;
	layout = load Layout Layout->PATH;
	layout->init(disp);
	if(len url > 4 && url[0:4] == "http" && (werr := startwebfs()) != nil)
		return werr;
	vh := h;
	if(crop)
		vh = 768;	# a viewport for vh units; the image is the page
	t0 := sys->millisec();
	(p, err) := page->open(url, w, vh);
	if(p == nil)
		return err;
	t1 := sys->millisec();
	if(crop) {
		h = p.pageheight();
		if(h < 1)
			h = 1;
		if(h > Maxheight)
			h = Maxheight;
	}
	img := disp.newimage(Rect((0, 0), (w, h)), Draw->XRGB32, 0, Draw->White);
	if(img == nil)
		return sys->sprint("cannot allocate %dx%d image: %r", w, h);
	p.paint(img, Point(0, 0));
	if(dumpboxes)
		sys->fprint(sys->fildes(2), "%s", layout->dump(p.root));
	t2 := sys->millisec();
	fd := sys->create(outimg, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", outimg);
	if(disp.writeimage(fd, img) < 0)
		return sys->sprint("writeimage: %r");
	for(l := p.errors; l != nil; l = tl l)
		sys->fprint(sys->fildes(2), "charonshot: %s\n", hd l);
	if(sys->open("/env/charonshot-timing", Sys->OREAD) != nil)
		sys->fprint(sys->fildes(2), "load+layout %d ms, paint %d ms\n", t1-t0, t2-t1);
	return nil;
}

halt()
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}
