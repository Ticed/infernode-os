implement VoicemeterTest;

#
# Contract for the voice-meter height map in luciconv.b (INF-44).
# The function here must stay identical to voicemeterlevel() there.
#
# Measured /n/speech/level speech energy (pcmlevel, 0..1000):
#   listen (elevenlabs fixtures): p50=46 p90=72 max=90
#   speak  (kokoro TTS):          p50=56-74 p90=95-111 max=215
#   live BlackHole+afplay listen: p50=3 p90=11 max=15 (attenuated path)
# Linear h = maxh*rms/1000 draws all of those as 1px at maxh≈30.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "math.m";
	math: Math;

include "testing.m";
	testing: Testing;
	T: import testing;

VoicemeterTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/voicemeter_test.b";

MeterFloor: con 8;
MeterFull: con 400;

passed := 0;
failed := 0;
skipped := 0;

voicemeterlevel(raw: int): int
{
	if(raw <= 0)
		return 0;
	if(raw < MeterFloor)
		return 1;
	if(raw >= MeterFull)
		return 1000;
	mapped := int (1000.0 * math->log10(real raw / real MeterFloor) /
		math->log10(real MeterFull / real MeterFloor));
	if(mapped < 1)
		mapped = 1;
	if(mapped > 1000)
		mapped = 1000;
	return mapped;
}

# Height of one bar after shape=100 (no profile attenuation).
barh(raw, maxh, speaking: int): int
{
	level := voicemeterlevel(raw);
	h := maxh * level / 1000;
	if(speaking)
		h /= 2;
	if(level > 0 && h < 1)
		h = 1;
	return h;
}

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	"*" =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

testSilenceIsZero(t: ref T)
{
	t.asserteq(barh(0, 30, 0), 0, "silence draws no listening bar");
	t.asserteq(barh(0, 30, 1), 0, "silence draws no speaking bar");
}

testMeasuredSpeechUsesHeight(t: ref T)
{
	# Source-PCM range, not the attenuated BlackHole+afplay path.
	# Diagnosis: rms=20 at maxh=30 was 1px linear.
	lh := barh(20, 30, 0);
	t.assert(lh >= 6, sys->sprint("listen rms=20 -> %d, want >= 6", lh));
	t.assert(lh <= 12, sys->sprint("listen rms=20 -> %d, want <= 12", lh));

	lp50 := barh(46, 30, 0);
	t.assert(lp50 >= 12, sys->sprint("listen p50=46 -> %d, want >= 12", lp50));
	sp50 := barh(70, 30, 1);
	t.assert(sp50 >= 7, sys->sprint("speak p50=70 after h/2 -> %d, want >= 7", sp50));

	sh := barh(20, 30, 1);
	t.assert(sh >= 3, sys->sprint("speak rms=20 after h/2 -> %d, want >= 3", sh));
}

testFullDoesNotOverflow(t: ref T)
{
	t.asserteq(barh(400, 30, 0), 30, "rms=full fills listening height");
	t.asserteq(barh(1000, 30, 0), 30, "clipped full-scale still fits");
	t.asserteq(barh(400, 30, 1), 15, "rms=full speaking is half height");
	# Loudest measured kokoro window is 215: must not peg.
	loud := barh(215, 30, 0);
	t.assert(loud < 30, sys->sprint("speak max=215 -> %d, must not peg", loud));
	t.assert(loud >= 20, sys->sprint("speak max=215 -> %d, want >= 20", loud));
}

testLinearWouldStayFlat(t: ref T)
{
	# Guard against reverting to linear /1000: that map is 1px
	# for every measured speech value at maxh=30.
	t.assert(30 * 46 / 1000 <= 1, "linear listen p50 is still 1px");
	t.assert(barh(46, 30, 0) > 30 * 46 / 1000,
		"dB map is taller than linear at listen p50");
}

testSubFloorIsOnePixel(t: ref T)
{
	t.asserteq(barh(1, 30, 0), 1, "sub-floor listen is 1px, not empty");
	t.asserteq(barh(1, 30, 1), 1, "sub-floor speak clamps after h/2");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("SilenceIsZero", testSilenceIsZero);
	run("MeasuredSpeechUsesHeight", testMeasuredSpeechUsesHeight);
	run("FullDoesNotOverflow", testFullDoesNotOverflow);
	run("LinearWouldStayFlat", testLinearWouldStayFlat);
	run("SubFloorIsOnePixel", testSubFloorIsOnePixel);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
