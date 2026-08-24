implement SpeechshimTest;

#
# speechshim9p provider contract test. Fake host helpers stand in for the
# external installs. The load-bearing case is CancelKillsSay: cancel must
# kill the synthesizing helper process (devcmd "kill"), so a blocked say
# completes promptly instead of running out the helper — that bound is what
# makes barge-in silence fast with real TTS.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

ShimSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SpeechshimTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with ShimSrv
};

SRCFILE: con "/tests/speechshim_test.b";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
MNT: con "/tmp/speechshim_test";
PCMFILE: con "/tmp/speechshim_test_pcm";
OUTPCM: con "/tmp/speechshim_test_out_pcm";
BADPCM: con "/tmp/speechshim_test_badpcm";
WAKEPID: con "/tmp/speechshim_suppressed_wake.pid";

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

filesize(path: string): int
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return -1;
	return int d.length;
}

pathexists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
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

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

readproc(path: string, ch: chan of string)
{
	ch <-= readfile(path);
}

makepcm(path: string, nsamp, sample: int): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	buf := array[nsamp * 2] of byte;
	for(i := 0; i < nsamp; i++) {
		buf[i * 2] = byte (sample & 16rff);
		buf[i * 2 + 1] = byte ((sample >> 8) & 16rff);
	}
	return sys->write(fd, buf, len buf);
}

startserver()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	srv := load ShimSrv SHIMPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speechshim9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speechshim9p" :: "-m" :: MNT :: nil);
	sys->sleep(300);
}

testFiles(t: ref T)
{
	files := array[] of {"ctl", "listen", "wake", "say", "cancel", "chime", "voices", "level"};
	for(i := 0; i < len files; i++)
		t.assert(pathexists(MNT + "/" + files[i]), files[i] + " should exist");
}

# Deterministic PCM fixtures exercise the same provider telemetry the GUI
# consumes. The sleeping helpers hold each path active long enough to sample
# it without a physical microphone or speaker.
testLevelTelemetry(t: ref T)
{
	t.assert(makepcm(PCMFILE, 65536, 16384) > 0,
		"create nonzero capture PCM fixture");
	fd := sys->create(OUTPCM, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create playback sink");
	if(fd == nil)
		return;
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "capturedev " + PCMFILE) > 0,
		"configure fixture capture");
	t.assert(writefile(MNT + "/ctl", "micmode device") > 0,
		"configure device-fed capture");
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"sleep 2; head -c 8 > /dev/null; echo final level input\"") > 0,
		"configure delayed stdin consumer");
	listench := chan of string;
	spawn readproc(MNT + "/listen", listench);
	sys->sleep(400);
	level := readfile(MNT + "/level");
	t.assert(hassubstr(level, "mode=input"),
		"capture PCM publishes input mode before a transcript");
	t.assert(!hassubstr(level, "input-rms=0 "),
		"nonzero capture PCM publishes nonzero RMS");
	t.assert(hassubstr(level, "output-rms=0 output-peak=0"),
		"input telemetry does not claim playback");
	got := <-listench;
	t.assert(hassubstr(got, "final level input"),
		"fixture capture still reaches the STT helper");

	t.assert(writefile(MNT + "/ctl", "audiodev " + OUTPCM) > 0,
		"configure fixture playback sink");
	t.assert(writefile(MNT + "/ctl", "duplex half") > 0,
		"configure half duplex");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"printf 0123456789; sleep 2\"") > 0,
		"configure delayed PCM synthesizer");
	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "open say for playback telemetry");
	if(sayfd != nil) {
		b := array of byte "meter test";
		t.assert(sys->write(sayfd, b, len b) > 0, "start fixture playback");
		# Process startup can take a few scheduler quanta. Poll the PCM
		# condition itself rather than baking host timing into the test.
		for(i := 0; i < 15; i++) {
			sys->sleep(100);
			level = readfile(MNT + "/level");
			if(hassubstr(level, "mode=output") &&
					!hassubstr(level, "output-rms=0 "))
				break;
		}
		t.assert(hassubstr(level, "mode=output"),
			"TTS PCM publishes the distinct output mode");
		t.log("sampled playback telemetry: " + level);
		t.assert(!hassubstr(level, "output-rms=0 "),
			"nonzero TTS PCM publishes nonzero RMS");
		t.assert(hassubstr(level, "input-rms=0 input-peak=0"),
			"half duplex never publishes simultaneous input activity");
		t.assert(writefile(MNT + "/cancel", "cancel") > 0,
			"cancel fixture playback");
		sys->seek(sayfd, big 0, Sys->SEEKSTART);
		buf := array[512] of byte;
		sys->read(sayfd, buf, len buf);
		sys->sleep(100);
		level = readfile(MNT + "/level");
		t.assert(hassubstr(level, "output-rms=0 output-peak=0"),
			"cancel clears playback telemetry");
	}

	writefile(MNT + "/ctl", "kokorobin /bin/echo");
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "micmode helper");
	writefile(MNT + "/ctl", "capturedev default");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

testConfig(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakeword hey lucia") > 0, "wakeword accepted");
	t.assert(writefile(MNT + "/ctl", "wakethreshold 0.7") > 0, "wakethreshold accepted");
	t.assert(writefile(MNT + "/ctl", "voice am_adam") > 0, "voice accepted");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "wakeword hey lucia"), "ctl reports wakeword");
	t.assert(hassubstr(ctl, "wakethreshold 0.7"), "ctl reports wakethreshold");
	t.assert(hassubstr(ctl, "voice am_adam"), "ctl reports voice");
}

# A one-shot helper exits after printing its event; the shim must restart
# it on the next read so wake stays armed across events.
testAudioRouting(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev /dev/audio"), "default playback device");
	t.assert(hassubstr(ctl, "micmode helper"), "default capture mode");
	t.assert(hassubstr(ctl, "capturerate 16000"), "default capture rate");

	t.assert(writefile(MNT + "/ctl", "audiodev /n/phone/audio") > 0, "audiodev accepted");
	t.assert(writefile(MNT + "/ctl", "capturerate 24000") > 0, "capturerate accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev /n/phone/audio"), "ctl reports audiodev");
	t.assert(hassubstr(ctl, "capturerate 24000"), "ctl reports capturerate");

	# Invalid values fail their ctl writes and leave the prior state intact.
	t.assert(writefile(MNT + "/ctl", "micmode banana") <= 0,
		"invalid micmode rejected");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "micmode helper"), "invalid micmode not applied");

	writefile(MNT + "/ctl", "audiodev /dev/audio");
	writefile(MNT + "/ctl", "capturerate 16000");
}

testPlaybackRates(t: ref T)
{
	# Inferno's default audio device has a fixed rate table. Every advertised
	# rate is accepted and an unsupported rate fails without changing state.
	rates := array[] of {8000, 11025, 16000, 22050, 44100};
	for(i := 0; i < len rates; i++) {
		cmd := "rate " + string rates[i];
		t.assert(writefile(MNT + "/ctl", cmd) == len cmd,
			sys->sprint("/dev/audio accepts %d Hz", rates[i]));
		t.assert(hassubstr(readfile(MNT + "/ctl"), cmd),
			sys->sprint("ctl reports accepted %d Hz", rates[i]));
	}

	t.assert(writefile(MNT + "/ctl", "rate 24000") < 0,
		"/dev/audio rejects unsupported 24000 Hz");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "rate 44100"),
		"rejected default-device rate does not change configured rate");

	# A namespaced/remote device may support rates outside #A's fixed table.
	t.assert(writefile(MNT + "/ctl", "audiodev " + PCMFILE) > 0,
		"non-default playback device accepted");
	t.assert(writefile(MNT + "/ctl", "rate 24000") > 0,
		"non-default playback device retains broader rate capability");
	t.assert(writefile(MNT + "/ctl", "audiodev /dev/audio") < 0,
		"cannot select /dev/audio while an unsupported rate is configured");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev " + PCMFILE),
		"rejected device switch preserves the capable non-default device");
	t.assert(hassubstr(ctl, "rate 24000"),
		"rejected device switch preserves the configured remote rate");

	writefile(MNT + "/ctl", "rate 22050");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

testPlaybackCtlFailure(t: ref T)
{
	# Leave repeated local runs deterministic even though the ctl fixture is
	# deliberately created read-only.
	sys->remove(BADPCM + "ctl");
	sys->remove(BADPCM);
	fd := sys->create(BADPCM, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake playback device");
	if(fd == nil)
		return;
	fd = nil;
	ctlfd := sys->create(BADPCM + "ctl", Sys->OREAD, 8r444);
	t.assert(ctlfd != nil, "create inaccessible fake playback ctl");
	if(ctlfd == nil)
		return;
	ctlfd = nil;

	t.assert(writefile(MNT + "/ctl", "audiodev " + BADPCM) > 0,
		"fake playback device accepted");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"printf 0123456789\"") > 0,
		"configure fake synthesizer");
	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens for ctl failure test");
	if(sayfd != nil) {
		b := array of byte "hello";
		t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
		sys->seek(sayfd, big 0, Sys->SEEKSTART);
		buf := array[512] of byte;
		n := sys->read(sayfd, buf, len buf);
		result := "";
		if(n > 0)
			result = string buf[0:n];
		t.assert(hassubstr(result, "error: cannot open " + BADPCM + "ctl"),
			"playback reports audio ctl configuration failure");
	}

	writefile(MNT + "/ctl", "kokorobin /bin/echo");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

testDuplexConfig(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex full"), "default duplex is full");
	t.assert(writefile(MNT + "/ctl", "duplex half") > 0, "duplex half accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex half"), "ctl reports duplex half");
	t.assert(writefile(MNT + "/ctl", "duplex full") > 0, "duplex full accepted");
	t.assert(writefile(MNT + "/ctl", "duplex banana") <= 0,
		"invalid duplex rejected");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplex full"), "invalid duplex not applied");
}

# The suppression window is what actually keeps our own speech out of the
# microphone; `duplex half` alone reopened the mic the instant the last sample
# was accepted by the device, which is well before it has been heard.
testSuppressionWindowConfig(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	# Defaults must leave local capture behaving as before: a tail long
	# enough for room decay (measured ~235ms on the physical rig) and no
	# transport compensation, since local capture has none to compensate.
	t.assert(hassubstr(ctl, "duplextail 300"), "default duplextail is 300ms");
	t.assert(hassubstr(ctl, "capturedelay 0"), "default capturedelay is 0");

	t.assert(writefile(MNT + "/ctl", "duplextail 450") > 0,
		"duplextail accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplextail 450"), "ctl reports duplextail");
	t.assert(writefile(MNT + "/ctl", "capturedelay 2500") > 0,
		"capturedelay accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "capturedelay 2500"), "ctl reports capturedelay");

	t.assert(writefile(MNT + "/ctl", "duplextail 99999") <= 0,
		"out-of-range duplextail rejected");
	t.assert(writefile(MNT + "/ctl", "capturedelay -1") <= 0,
		"negative capturedelay rejected");
	ctl = readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "duplextail 450"),
		"rejected duplextail not applied");
	t.assert(hassubstr(ctl, "capturedelay 2500"),
		"rejected capturedelay not applied");

	writefile(MNT + "/ctl", "duplextail 300");
	writefile(MNT + "/ctl", "capturedelay 0");
}

# After playback the level record must say the microphone is still shut and
# for how long. Without this the suppression window is invisible, and the
# 2026-08-16 rig failure looked like "STT randomly transcribes the assistant".
testSuppressionObservable(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;
	writefile(MNT + "/ctl", "audiodev " + PCMFILE);
	writefile(MNT + "/ctl", "duplex half");
	writefile(MNT + "/ctl", "duplextail 800");

	t.assert(writefile(MNT + "/chime", "done") > 0, "chime accepted");
	# The "done" chime is a single 140ms note, short enough to sit entirely
	# in the device buffer. Wait past the note itself but well inside the
	# 800ms tail: playback is over, so the old code would have reopened the
	# microphone here, and `mode=suppressed` is exactly what it could not
	# report.
	sys->sleep(400);
	level := readfile(MNT + "/level");
	t.assert(hassubstr(level, "mode=suppressed"),
		"mic stays shut after playback ends, within the tail");
	t.assert(hassubstr(level, "suppress-remaining-ms="),
		"level exposes the remaining suppression window");

	sys->sleep(1200);
	level = readfile(MNT + "/level");
	t.assert(!hassubstr(level, "mode=suppressed"),
		"suppression window ends on its own");

	# Negative control: with no tail configured the same chime must not
	# leave the window open. Without this the assertions above would still
	# pass if suppression were simply always on.
	writefile(MNT + "/ctl", "duplextail 0");
	t.assert(writefile(MNT + "/chime", "done") > 0, "second chime accepted");
	sys->sleep(400);
	level = readfile(MNT + "/level");
	t.assert(!hassubstr(level, "mode=suppressed"),
		"duplextail 0 restores the immediate reopen");

	writefile(MNT + "/ctl", "duplextail 300");
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

# A TTS helper does not start speaking the moment it is asked to. The
# suppression window has to run from the first sample that reaches the
# device, so helper startup is not mistaken for elapsed playback.
testSayStartupNotCountedAsPlayback(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;
	writefile(MNT + "/ctl", "audiodev " + PCMFILE);
	writefile(MNT + "/ctl", "rate 8000");
	writefile(MNT + "/ctl", "duplex half");
	writefile(MNT + "/ctl", "duplextail 300");
	writefile(MNT + "/ctl", "capturedelay 0");

	# Two seconds of startup, then two seconds of audio (32000 bytes at
	# 8kHz s16 mono). The scratch audiodev accepts every write at once, so
	# all of it is still unplayed when the write loop ends.
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"sleep 2; dd if=/dev/zero bs=32000 count=1\"") > 0,
		"slow-starting say helper accepted");
	t.assert(writefile(MNT + "/say", "hello") > 0, "say accepted");

	# say is asynchronous. After startup (2s) the scratch audiodev
	# accepts the 2s clip at once, so the write loop is over and the
	# unplayed remainder is still audible: mode must stay output, not
	# drop to suppressed, until that drain completes.
	sys->sleep(3000);
	level := readfile(MNT + "/level");
	t.assert(hassubstr(level, "mode=output"),
		"unplayed remainder still reports output, not suppressed");

	sys->sleep(2000);
	level = readfile(MNT + "/level");
	t.assert(!hassubstr(level, "mode=output"),
		"output ends once the audio has drained");
	t.assert(!hassubstr(level, "mode=suppressed"),
		"window still ends once the audio has drained");

	writefile(MNT + "/ctl", "rate 22050");
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

testChimeAccepted(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;
	t.assert(writefile(MNT + "/ctl", "audiodev " + PCMFILE) > 0, "audiodev scratch accepted");
	t.assert(writefile(MNT + "/chime", "wake") > 0, "wake chime write accepted");
	sys->sleep(500);
	t.assert(filesize(PCMFILE) > 0, "chime wrote PCM bytes");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

# micmode device: the shim itself reads PCM from the capture device and
# feeds the listen helper's stdin — the property that makes a 9P-imported
# microphone (remote instance, Android phone) work like the local one. A
# plain file stands in for the device; the fake helper consumes 8 bytes of
# stdin before emitting its record, so the record proves audio actually
# flowed capture-device → pump → helper stdin.
testDeviceCapture(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake capture device");
	if(fd == nil)
		return;
	b := array of byte "0123456789abcdef";
	sys->write(fd, b, len b);
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "capturedev " + PCMFILE) > 0, "capturedev accepted");
	t.assert(writefile(MNT + "/ctl", "micmode device") > 0, "micmode device accepted");
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"head -c 8 > /dev/null; echo final device audio heard\"") > 0,
		"configure stdin-consuming fake listen helper");

	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final device audio heard"),
		"helper fed from the capture device produced its record");

	# The shim, not deployment-specific ctl text, owns the stdin contract.
	# This prevents device mode from accidentally reopening the helper's host mic.
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/echo final device argv") > 0,
		"configure argv-reporting device listen helper");
	listen = readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "--stdin --model"),
		"device listen helper receives stdin and model flags");
	t.assert(hassubstr(listen, "--rate 16000 --chans 1"),
		"device listen helper receives capture format");

	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake device argv") > 0,
		"configure argv-reporting device wake helper");
	wake := readfile(MNT + "/wake");
	t.assert(hassubstr(wake, "--stdin --word hey lucia --threshold 0.7 --rate 16000"),
		"device wake helper receives stdin, phrase, threshold, and rate");

	# Restore defaults for the remaining tests.
	writefile(MNT + "/ctl", "micmode helper");
	writefile(MNT + "/ctl", "capturedev default");
}

testWakeRestarts(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake fake-model 0.91") > 0,
		"configure fake wake helper");
	first := readfile(MNT + "/wake");
	t.assert(hassubstr(first, "wake fake-model 0.91"), "first wake event delivered");
	t.assert(hassubstr(first, "--word hey lucia --threshold 0.7"),
		"multiword wake phrase and threshold reach helper argv");
	second := readfile(MNT + "/wake");
	t.assert(hassubstr(second, "wake fake-model 0.91"),
		"helper restarted for second wake event");
}

testListenRecords(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final shim transcript") > 0,
		"configure fake listen helper");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final shim transcript"), "listen record delivered");
}

# `mic off` (written by voicemode on voice-mode exit) must kill the running
# mic-side helper and complete a pending read with an error instead of
# restarting it — the microphone is only open during a voice session. The
# next read re-arms it without any further ctl write.
testMicOffReleasesHelpers(t: ref T)
{
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"echo partial armed; sleep 30\"") > 0,
		"configure blocking fake listen helper");
	first := readfile(MNT + "/listen");
	t.assert(hassubstr(first, "partial armed"), "helper armed by first read");

	pendch := chan of string;
	spawn readproc(MNT + "/listen", pendch);
	sys->sleep(300);	# let the read block in the helper

	t0 := sys->millisec();
	t.assert(writefile(MNT + "/ctl", "mic off") > 0, "mic off accepted");
	tmo := chan[1] of int;
	spawn timer(tmo, 4000);
	got := "";
	alt {
	got = <-pendch =>
		;
	<-tmo =>
		;
	}
	t1 := sys->millisec();
	t.assert(hassubstr(got, "error: mic off"),
		"pending listen read completes instead of restarting the helper");
	t.assert(t1 - t0 < 3000, "mic off killed the helper promptly (no 30s run-out)");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "mic off"), "ctl reports mic off");

	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final rearmed") > 0,
		"configure fake listen helper for re-arm");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final rearmed"), "next listen read re-arms the mic");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "mic on"), "ctl reports mic on after re-arm");
}

# `listen off` (written by voicemode at the end of each voice turn) must stop
# only the STT helper: a pending listen read completes with an error instead
# of restarting it, wake reads keep working, and the next listen read re-arms
# STT without any further ctl write. This is what keeps between-turn speech
# (ambient talk, the assistant's own TTS) from queuing as stale records that
# replay into the next turn.
testListenOffStopsListenHelper(t: ref T)
{
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"echo partial turn; sleep 30\"") > 0,
		"configure blocking fake listen helper");
	first := readfile(MNT + "/listen");
	t.assert(hassubstr(first, "partial turn"), "helper armed by first read");

	pendch := chan of string;
	spawn readproc(MNT + "/listen", pendch);
	sys->sleep(300);	# let the read block in the helper

	t0 := sys->millisec();
	t.assert(writefile(MNT + "/ctl", "listen off") > 0, "listen off accepted");
	tmo := chan[1] of int;
	spawn timer(tmo, 4000);
	got := "";
	alt {
	got = <-pendch =>
		;
	<-tmo =>
		;
	}
	t1 := sys->millisec();
	t.assert(hassubstr(got, "error: listen off"),
		"pending listen read completes instead of restarting the helper");
	t.assert(t1 - t0 < 3000, "listen off killed the helper promptly (no 30s run-out)");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "listen off"), "ctl reports listen off");

	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake still-armed 0.9") > 0,
		"configure fake wake helper");
	wake := readfile(MNT + "/wake");
	t.assert(hassubstr(wake, "wake still-armed"), "wake read unaffected by listen off");

	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final listen rearmed") > 0,
		"configure fake listen helper for re-arm");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final listen rearmed"), "next listen read re-arms STT");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "listen on"), "ctl reports listen on after re-arm");
}

# A helper that cannot start (not installed, not on PATH) exits immediately
# with its reason on stderr. That reason must reach the client: a bare
# "wake helper exited" gives the user nothing to act on, which is exactly how
# a misconfigured install came to look like "the button does nothing".
testHelperErrorNamesCause(t: ref T)
{
	t.assert(writefile(MNT + "/ctl",
		"wakebin infernode-no-such-helper-xyz") > 0,
		"configure a wake helper that does not exist");
	err := readfile(MNT + "/wake");
	t.assert(hassubstr(err, "error:"), "missing wake helper reports an error");
	t.assert(hassubstr(err, "not found"),
		"error carries the helper's stderr, not just 'helper exited'");
}

# Cancel must kill the helper process: with a fake synthesizer that would
# block for 8 seconds, the pending say read has to complete within a couple
# of seconds of the cancel write.
testCancelKillsSay(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/sh -c \"sleep 8\"") > 0,
		"configure blocking fake synthesizer");

	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens");
	if(sayfd == nil)
		return;
	b := array of byte "hello";
	t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
	sys->sleep(500);	# let the helper start

	t0 := sys->millisec();
	t.assert(writefile(MNT + "/cancel", "cancel") > 0,
		"cancel write served while synthesizing");
	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	n := sys->read(sayfd, buf, len buf);
	t1 := sys->millisec();
	t.assert(n >= 0, "say status readable after cancel");
	t.assert(t1 - t0 < 4000, "cancel killed the helper (no 8s run-out)");
}

testHalfDuplexSwallowsWakeDuringSay(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;

	t.assert(writefile(MNT + "/ctl", "audiodev " + PCMFILE) > 0, "audiodev scratch accepted");
	t.assert(writefile(MNT + "/ctl", "duplex half") > 0, "duplex half accepted");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"printf 0123456789; sleep 2; printf abcdef\"") > 0,
		"configure slow fake synthesizer");
	t.assert(writefile(MNT + "/ctl",
		"wakebin /bin/sh -c \"rm -f " + WAKEPID + "; echo wake cleanup\"") > 0,
		"configure suppressed-helper marker cleanup");
	readfile(MNT + "/wake");
	t.assert(writefile(MNT + "/ctl",
		"wakebin /bin/sh -c \"if [ ! -e " + WAKEPID + " ]; then echo $$ > " +
		WAKEPID + "; fi; echo wake fake-model 0.92; sleep 30\"") > 0,
		"configure long-lived fake wake helper");

	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens");
	if(sayfd == nil)
		return;
	b := array of byte "hello";
	t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
	sys->sleep(300);	# let dosay enter its playback loop

	wakech := chan of string;
	spawn readproc(MNT + "/wake", wakech);
	tmo := chan[1] of int;
	spawn timer(tmo, 900);
	early := "";
	alt {
	early = <-wakech =>
		;
	<-tmo =>
		;
	}
	t.assert(early == "", "wake read suppressed during half-duplex playback");

	tmo2 := chan[1] of int;
	spawn timer(tmo2, 5000);
	got := "";
	alt {
	got = <-wakech =>
		;
	<-tmo2 =>
		;
	}
	t.assert(hassubstr(got, "wake fake-model 0.92"),
		"wake read completes after playback");

	# Replacing wakebin kills the active post-playback helper. Probe the PID
	# retained by the first, suppressed helper: it must already be gone.
	t.assert(writefile(MNT + "/ctl",
		"wakebin /bin/sh -c \"if kill -0 $(cat " + WAKEPID +
		") 2>/dev/null; then echo wake leaked; else echo wake cleaned; fi; rm -f " +
		WAKEPID + "\"") > 0, "configure suppressed-helper probe");
	probe := readfile(MNT + "/wake");
	t.assert(hassubstr(probe, "wake cleaned"),
		"suppressed wake helper terminated before restart");

	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	buf := array[512] of byte;
	sys->read(sayfd, buf, len buf);
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

# INF-43. During half-duplex playback the microphone carries the assistant's
# own reply. The STT transcribes it, so every record arriving mid-playback is
# suspect: the reply must never surface as a turn, but a spoken "cancel" must
# get through or the user cannot interrupt.
#
# `cancel on` is that narrow window, and this pins both of its edges against a
# helper that emits reply-shaped text ahead of the cancel word. Phase 1 is the
# negative control and also the pre-fix behaviour: with the window shut, the
# reply text is what comes back.
#
# The pump half of the fix - feeding the STT helper through the suppressed
# window in `micmode device` - has no hermetic seam here: a fake helper's
# stdin reports EOF rather than blocking when the pump withholds audio, so
# "was it fed" cannot be told apart from "helper ran early". See INF-50.
testSpokenCancelDuringPlayback(t: ref T)
{
	fd := sys->create(PCMFILE, Sys->OWRITE, 8r644);
	t.assert(fd != nil, "create fake audio device");
	if(fd == nil)
		return;
	fd = nil;

	writefile(MNT + "/ctl", "audiodev " + PCMFILE);
	writefile(MNT + "/ctl", "duplex half");
	t.assert(writefile(MNT + "/ctl",
		"kokorobin /bin/sh -c \"printf 0123456789; sleep 4; printf abcdef\"") > 0,
		"configure slow fake synthesizer");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "cancel off"),
		"the spoken-cancel window is shut by default");

	sayfd := sys->open(MNT + "/say", Sys->ORDWR);
	t.assert(sayfd != nil, "say opens");
	if(sayfd == nil)
		return;
	b := array of byte "hello";
	t.assert(sys->write(sayfd, b, len b) > 0, "say write accepted");
	sys->sleep(300);	# let dosay enter its playback loop

	# Phase 1, the default. Every record passes through untouched, so the
	# helper's first line - the assistant's own reply - is what a reader
	# gets. This is the behaviour the fix must leave alone.
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"echo final I am Veltro; " +
		"echo final cancel; sleep 30\"") > 0,
		"configure reply-then-cancel fake listen helper");
	t.assert(hassubstr(readfile(MNT + "/level"), "mode=output"),
		"playback is still running, so capture is suppressed");
	off := readfile(MNT + "/listen");
	t.assert(hassubstr(off, "I am Veltro"),
		"cancel off leaves the listen stream unfiltered");

	# Phase 2, the window open. Restarting the helper clears the records
	# phase 1 left buffered, so this read cannot be answered from them.
	t.assert(writefile(MNT + "/ctl", "cancel on") > 0, "cancel on accepted");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "cancel on"), "ctl reports cancel on");
	t.assert(writefile(MNT + "/ctl",
		"whisperstreambin /bin/sh -c \"echo final I am Veltro; " +
		"echo final cancel; sleep 30\"") > 0,
		"restart the fake listen helper");
	t.assert(hassubstr(readfile(MNT + "/level"), "mode=output"),
		"playback is still running for the second read");

	listench := chan of string;
	spawn readproc(MNT + "/listen", listench);
	tmo := chan[1] of int;
	spawn timer(tmo, 3000);
	heard := "";
	alt {
	heard = <-listench =>
		;
	<-tmo =>
		;
	}
	t.assert(hassubstr(heard, "final cancel"),
		"a spoken cancel reaches the reader during playback");
	t.assert(!hassubstr(heard, "I am Veltro"),
		"the assistant's own reply is not offered as a transcript");

	writefile(MNT + "/ctl", "cancel off");
	writefile(MNT + "/ctl", "mic off");
	writefile(MNT + "/ctl", "mic on");
	sys->seek(sayfd, big 0, Sys->SEEKSTART);
	rbuf := array[512] of byte;
	sys->read(sayfd, rbuf, len rbuf);
	sayfd = nil;
	writefile(MNT + "/ctl", "duplex full");
	writefile(MNT + "/ctl", "audiodev /dev/audio");
}

teardown()
{
	sys->unmount(nil, MNT);
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
	run("Files", testFiles);
	run("Config", testConfig);
	run("AudioRouting", testAudioRouting);
	run("PlaybackRates", testPlaybackRates);
	run("PlaybackCtlFailure", testPlaybackCtlFailure);
	run("DuplexConfig", testDuplexConfig);
	run("SuppressionWindowConfig", testSuppressionWindowConfig);
	run("SuppressionObservable", testSuppressionObservable);
	run("SayStartupNotCountedAsPlayback", testSayStartupNotCountedAsPlayback);
	run("ChimeAccepted", testChimeAccepted);
	run("WakeRestarts", testWakeRestarts);
	run("ListenRecords", testListenRecords);
	run("MicOffReleasesHelpers", testMicOffReleasesHelpers);
	run("ListenOffStopsListenHelper", testListenOffStopsListenHelper);
	run("DeviceCapture", testDeviceCapture);
	run("LevelTelemetry", testLevelTelemetry);
	run("CancelKillsSay", testCancelKillsSay);
	run("HalfDuplexSwallowsWakeDuringSay", testHalfDuplexSwallowsWakeDuringSay);
	run("SpokenCancelDuringPlayback", testSpokenCancelDuringPlayback);
	run("HelperErrorNamesCause", testHelperErrorNamesCause);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
