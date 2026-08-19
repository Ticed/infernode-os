implement VoicemeterTest;

#
# Contract for the voice-meter height map in luciconv.b (INF-44).
# The function here must stay identical to voicemeterlevel() there.
#
# Calibrated to /n/speech/level as delivered on the test rig
# (BlackHole both sides, default system volume): input-rms p50=3
# p90=11 max=15. Linear h = maxh*rms/1000 draws every value there
# as 0-1px at maxh≈30; a dB map from 1..25 fills the bank for the
# arriving range and leaves the top for louder turns.
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

MeterFloor: con 1;
MeterFull: con 25;

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
	# Feed as delivered on the rig (BlackHole, default volume):
	# input-rms p50=3 p90=11 max=15. Each must use real bar height.
	l3 := barh(3, 30, 0);
	t.assert(l3 >= 6 && l3 <= 12,
		sys->sprint("listen rms=3 -> %d, want 6..12", l3));
	l11 := barh(11, 30, 0);
	t.assert(l11 >= 18 && l11 <= 26,
		sys->sprint("listen rms=11 -> %d, want 18..26", l11));
	l15 := barh(15, 30, 0);
	t.assert(l15 >= 21, sys->sprint("listen rms=15 -> %d, want >= 21", l15));

	# Speaking: the same curve, halved for the centre-out shape.
	s11 := barh(11, 30, 1);
	t.assert(s11 >= 9 && s11 <= 13,
		sys->sprint("speak rms=11 after h/2 -> %d, want 9..13", s11));
	s3 := barh(3, 30, 1);
	t.assert(s3 >= 3, sys->sprint("speak rms=3 after h/2 -> %d, want >= 3", s3));
}

testFullDoesNotOverflow(t: ref T)
{
	t.asserteq(barh(25, 30, 0), 30, "rms=full fills listening height");
	t.asserteq(barh(1000, 30, 0), 30, "clipped full-scale still fits");
	t.asserteq(barh(25, 30, 1), 15, "rms=full speaking is half height");
	# Measured rig max (15) stays under the full-scale peg.
	t.assert(barh(15, 30, 0) < 30, "rig max rms=15 must not peg");
}

testMonotonicNonDecreasing(t: ref T)
{
	prev := 0;
	for(raw := 0; raw <= 60; raw++) {
		h := barh(raw, 30, 0);
		if(h < prev)
			t.assert(0, sys->sprint("dB map drops at raw=%d (%d < %d)", raw, h, prev));
		prev = h;
	}
}

testLinearWouldStayFlat(t: ref T)
{
	# Guard against reverting to linear /1000: that map is 0-1px
	# for the whole arriving range at maxh=30.
	t.assert(30 * 15 / 1000 <= 1, "linear rig max is still 0-1px");
	t.assert(barh(15, 30, 0) > 30 * 15 / 1000,
		"dB map is taller than linear at rig max rms=15");
}

testSubFloorIsOnePixel(t: ref T)
{
	t.asserteq(barh(1, 30, 0), 1, "floor-adjacent listen is 1px, not empty");
	t.asserteq(barh(1, 30, 1), 1, "floor-adjacent speak clamps after h/2");
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
	run("MonotonicNonDecreasing", testMonotonicNonDecreasing);
	run("LinearWouldStayFlat", testLinearWouldStayFlat);
	run("SubFloorIsOnePixel", testSubFloorIsOnePixel);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
