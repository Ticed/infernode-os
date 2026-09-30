implement Charonshot;

#
# charonshot - render one URL with Charon, headlessly, to an image file.
#
#	charonshot width[xheight] outimg url
#
# Drives Charon's -render mode: fetch, lay out once, draw the frame to an
# off-screen canvas, write it with Display.writeimage, exit.  With just a
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
	Display: import draw;

Charonshot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

CharonMod: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Maxheight: con 12000;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr := sys->fildes(2);

	if(len argv != 4) {
		sys->fprint(stderr, "usage: charonshot width outimg url\n");
		halt();
		raise "fail:usage";
	}
	argv = tl argv;
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

halt()
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}
