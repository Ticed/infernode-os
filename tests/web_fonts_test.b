implement WebFontsTest;

#
# Fonts for the web engine: downloaded faces (@font-face) in TrueType
# and WOFF, family matching, metrics for ex and ch.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "outlinefont.m";
include "web/fonts.m";
	fonts: Fonts;
	Typeface: import fonts;

WebFontsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/web_fonts_test.b";
DIR: con "/tests/web/fonts/";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception e {
	"fail:fatal" or "fail:skip" =>
		;
	"*" =>
		t.error("exception: " + e);
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

readfile(f: string): array of byte
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	b := array[int d.length] of byte;
	n := sys->read(fd, b, len b);
	return b[0:n];
}

# Ahem: every glyph an em square, ascent 0.8em; x-height 0.8em
testAhem(t: ref T)
{
	fonts->clearfaces();
	t.assertnil(fonts->addface("ahem", 400, 0, nil, readfile(DIR + "Ahem.ttf")), "add Ahem");
	f := fonts->face("ahem" :: "serif" :: nil, 400, 0, 20.0);
	t.assert(f != nil, "face");
	t.asserteq(int f.width("xxxx"), 80, "four em squares");
	t.asserteq(int f.xheight(), 16, "x-height 0.8em");
	t.asserteq(int f.ascent, 16, "ascent");
	b := fonts->face("ahem" :: nil, 700, 1, 20.0);
	t.asserteq(int b.width("x"), 20, "the only face serves bold italic too");
	n := fonts->face("nosuch" :: "serif" :: nil, 400, 0, 20.0);
	t.assert(n.parts == nil, "an unknown family falls back to the shipped faces");
}

testWOFF(t: ref T)
{
	fonts->clearfaces();
	t.assertnil(fonts->addface("ahemw", 400, 0, nil, readfile(DIR + "Ahem.woff")), "add Ahem.woff");
	f := fonts->face("ahemw" :: nil, 400, 0, 20.0);
	t.assert(f != nil && f.parts != nil, "face from the WOFF");
	t.asserteq(int f.width("xxxx"), 80, "same metrics as the TrueType");
	t.asserteq(int f.xheight(), 16, "x-height");
	t.assertnotnil(fonts->addface("bad", 400, 0, nil, array of byte "wOFFgarbage"), "a broken WOFF is an error");
}

# a family's faces split by unicode-range: each character from the face
# that has it, the rest from the next family
testRanges(t: ref T)
{
	fonts->clearfaces();
	ahem := readfile(DIR + "Ahem.ttf");
	t.assertnil(fonts->addface("split", 400, 0, array[] of {'a', 'z'}, ahem), "lower case part");
	f := fonts->face("split" :: "sans-serif" :: nil, 400, 0, 20.0);
	t.asserteq(int f.width("ab"), 40, "in range: Ahem");
	t.assert(int f.width("AB") != 40, "out of range: the next family");
}

# CSS font matching: the nearest weight, preferring heavier for bold
testWeights(t: ref T)
{
	fonts->clearfaces();
	ahem := readfile(DIR + "Ahem.ttf");
	dv := readfile(Fonts->DIR + "/DejaVuSans.ttf");
	fonts->addface("w", 300, 0, nil, ahem);
	fonts->addface("w", 800, 0, nil, dv);
	t.asserteq(int fonts->face("w" :: nil, 400, 0, 20.0).width("x"), 20, "400 takes 300 (lighter first)");
	t.assert(int fonts->face("w" :: nil, 600, 0, 20.0).width("x") != 20, "600 takes 800 (heavier first)");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	testing = load Testing Testing->PATH;
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	fonts = load Fonts Fonts->PATH;
	if(fonts == nil || (err := fonts->init(Display.allocate(nil))) != nil) {
		sys->fprint(sys->fildes(2), "cannot load fonts: %r\n");
		raise "fail:load";
	}
	run("Ahem", testAhem);
	run("WOFF", testWOFF);
	run("Ranges", testRanges);
	run("Weights", testWeights);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
