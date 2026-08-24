implement SayqDrainTest;

#
# INF-45: the desktop speaks through /mnt/speech/sayq (lucibridge speaktext),
# not /mnt/speech/say. Both funnel into speech9p's dosay -> sayprovider ->
# the shim's say, but speech9p.sayprovider opens the shim say TWICE — one
# fid for the write (clunked immediately) and a fresh fid for the read.
# The shim tracks the in-flight say's completion per-fid, so that read
# never parks on it and returns "" instantly — long before playback drains.
#
# This test drives the exact transaction a client like lucibridge issues:
# open sayq ORDWR, write, seek 0, read. It asserts the completion read
# actually waits for the queued playback drain rather than returning the
# instant the helper's stdout closes.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Srv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SayqDrainTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE: con "/tests/sayq_drain_test.b";
SRVPATH: con "/dis/veltro/speech9p.dis";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
MNT: con "/tmp/sayq_drain_test";
SHIMMNT: con "/tmp/sayq_drain_test_shim";
OUTPCM: con "/tmp/sayq_drain_out";

passed := 0;
failed := 0;
skipped := 0;

_marker() {}

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

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

hassubstr(s, sub: string): int
{
	if(s == nil || sub == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

startserver()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(SHIMMNT, Sys->OREAD, Sys->DMDIR | 8r755);
	shim := load Srv SHIMPATH;
	if(shim == nil) {
		sys->fprint(sys->fildes(2), "cannot load speechshim9p: %r\n");
		raise "fail:load";
	}
	spawn shim->init(nil, "speechshim9p" :: "-m" :: SHIMMNT :: nil);
	srv := load Srv SRVPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speech9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speech9p" :: "-m" :: MNT :: "-e" :: "kokoro" :: "-v" :: "af_bella" :: nil);
	sys->sleep(300);
	writefile(MNT + "/ctl", "provider " + SHIMMNT);
}

# The transaction the desktop issues (lucibridge speaktext, and the same
# shape speechtest/speech9p say uses on the provider). One ORDWR fid:
# write the text, seek 0, read the completion status.
#
# With a fake helper that emits 2s of PCM instantly, a completion that
# returns on helper EOF finishes in <100ms; one that waits for the device
# to drain takes ~2s. INF-45 is the former.
testSayqCompletionWaitsForDrain(t: ref T)
{
	fd := sys->create(OUTPCM, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create playback sink");
	if(fd == nil)
		return;
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "audiodev " + OUTPCM) > 0,
		"route playback to a scratch sink");
	t.assert(writefile(MNT + "/ctl", "rate 8000") > 0, "8kHz for a 2s clip");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"dd if=/dev/zero bs=32000 count=1 2>/dev/null\"") > 0,
		"configure instant 2s PCM helper");

	sayfd := sys->open(MNT + "/sayq", Sys->ORDWR);
	t.assert(sayfd != nil, "sayq opens for the transaction");
	if(sayfd == nil)
		return;
	b := array of byte "INF-45 sayq drain probe";
	t0 := sys->millisec();
	t.assert(sys->write(sayfd, b, len b) > 0, "sayq write accepted");
	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	st := array[512] of byte;
	n := sys->read(sayfd, st, len st);
	elapsed := sys->millisec() - t0;
	t.log(sys->sprint("sayq completion returned in %d ms", elapsed));
	if(n > 0)
		t.log("sayq status: " + string st[0:n]);
	t.assert(elapsed >= 1700,
		"sayq completion waits for the queued 2s drain, not helper EOF");
	t.assert(elapsed < 6000, "sayq drain wait does not hang past the clip");
}

killmodule(name: string)
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			pid := dirs[i].name;
			status := readfile("/prog/" + pid + "/status");
			if(!hassubstr(status, name))
				continue;
			ctl := sys->open("/prog/" + pid + "/ctl", Sys->OWRITE);
			if(ctl != nil)
				sys->fprint(ctl, "killgrp");
		}
	}
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];
}

teardown()
{
	sys->unmount(nil, MNT);
	sys->sleep(100);
	sys->unmount(nil, SHIMMNT);
	sys->sleep(100);
	killmodule("Speechshim9p");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil)
		raise "fail:load testing";
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	startserver();
	run("SayqCompletionWaitsForDrain", testSayqCompletionWaitsForDrain);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
