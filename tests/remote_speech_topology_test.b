implement RemoteSpeechTopologyTest;

#
# One-emulator network loopback for the Phase 2 remote speech topology.
# Two independent 9P listeners stand in for the terminal and engine hosts:
# the provider is reached over one TCP mount and its fake audio device over
# another.  This proves the namespace routing without audio hardware or host
# speech models, including bounded failure and a clean client remount.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";
	sh: Sh;

include "testing.m";
	testing: Testing;
	T: import testing;

ShimSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

RemoteSpeechTopologyTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE: con "/tests/remote_speech_topology_test.b";
SHIMPATH: con "/dis/veltro/speechshim9p.dis";
AUDIODIR: con "/tmp/remote_speech_audio";
AUDIOFILE: con AUDIODIR + "/audio";
CAPTUREDIR: con "/tmp/remote_speech_capture_audio";
CAPTUREFILE: con CAPTUREDIR + "/audio";
TERMMNT: con "/tmp/remote_speech_term";
SHIMMNT: con "/tmp/remote_speech_shim";
REMOTEMNT: con "/tmp/remote_speech_provider";
CAPTUREMNT: con "/tmp/remote_speech_capture_watch";
CAPTURESTATE: con "/tmp/remote_speech_capture_watch.state";
CAPTURECTL: con "/tmp/remote_speech_capture_watch.ctl";

audioaddr: string;
provideraddr: string;
captureaddr: string;
deadaddr: string;
audioport: int;
providerport: int;
captureport: int;

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
	"fail:fatal" => ;
	"fail:skip" => ;
	* => t.failed = 1;
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
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[:n];
}

hassubstr(s, sub: string): int
{
	if(s == nil || sub == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

filesize(path: string): big
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return big -1;
	return d.length;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

waitfile(path: string, limit: int): int
{
	for(i := 0; i < limit; i++) {
		if(exists(path))
			return 1;
		sys->sleep(100);
	}
	return exists(path);
}

hasprefix(s, prefix: string): int
{
	return s != nil && len s >= len prefix && s[:len prefix] == prefix;
}

waitprefix(path, prefix: string, limit: int): int
{
	for(i := 0; i < limit; i++) {
		if(hasprefix(readfile(path), prefix))
			return 1;
		sys->sleep(100);
	}
	return hasprefix(readfile(path), prefix);
}

mount9p(addr, mnt: string): string
{
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return sys->sprint("dial %s: %r", addr);
	sys->create(mnt, Sys->OREAD, Sys->DMDIR | 8r755);
	if(sys->mount(conn.dfd, nil, mnt, Sys->MREPL | Sys->MCREATE, "") < 0)
		return sys->sprint("mount %s: %r", addr);
	return nil;
}

waitmount(addr, mnt: string, limit: int): string
{
	err := "not attempted";
	for(i := 0; i < limit; i++) {
		err = mount9p(addr, mnt);
		if(err == nil)
			return nil;
		sys->sleep(100);
	}
	return err;
}

mountproc(addr, mnt: string, ch: chan of string)
{
	ch <-= mount9p(addr, mnt);
}

timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

starttopology(t: ref T)
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(AUDIODIR, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(CAPTUREDIR, Sys->OREAD, Sys->DMDIR | 8r755);
	fd := sys->create(AUDIOFILE, Sys->OWRITE, 8r666);
	t.assert(fd != nil, "create deterministic fake audio device");
	if(fd == nil)
		return;
	b := array of byte "0123456789abcdef";
	sys->write(fd, b, len b);
	fd = nil;
	fd = sys->create(CAPTUREFILE, Sys->OWRITE, 8r666);
	t.assert(fd != nil, "create dedicated watcher audio endpoint");
	if(fd != nil)
		sys->write(fd, b, len b);
	fd = nil;

	shim := load ShimSrv SHIMPATH;
	if(shim == nil) {
		t.fatal(sys->sprint("cannot load speechshim9p: %r"));
		raise "fail:fatal";
	}
	spawn shim->init(nil, "speechshim9p" :: "-m" :: SHIMMNT :: nil);
	sys->sleep(300);

	err := sh->system(nil,
		"load std; listen -As 'tcp!*!" + string audioport + "' {export " + AUDIODIR + "} &; " +
		"echo $apid > /tmp/remote_speech_audio_listener.pid; " +
		"listen -As 'tcp!*!" + string providerport + "' {export " + SHIMMNT + "} &; " +
		"echo $apid > /tmp/remote_speech_provider_listener.pid; " +
		"listen -As 'tcp!*!" + string captureport + "' {export " + CAPTUREDIR + "} &; " +
		"echo $apid > /tmp/remote_speech_capture_listener.pid");
	t.assert(err == nil, "start loopback audio and provider listeners");
	if(err != nil)
		return;

	err = waitmount(audioaddr, TERMMNT, 30);
	t.assert(err == nil, "mount terminal audio export over TCP 9P");
	if(err != nil)
		return;

	t.assert(writefile(SHIMMNT + "/ctl", "audiodev " + TERMMNT + "/audio") > 0,
		"route provider playback through imported audio");
	t.assert(writefile(SHIMMNT + "/ctl", "capturedev " + TERMMNT + "/audio") > 0,
		"route provider capture through imported audio");
	t.assert(writefile(SHIMMNT + "/ctl", "micmode device") > 0,
		"select namespace-backed capture");

	err = waitmount(provideraddr, REMOTEMNT, 30);
	t.assert(err == nil, "mount speech provider export over TCP 9P");
}

testInitialMountFailureBounded(t: ref T)
{
	result := chan of string;
	timed := chan of int;
	spawn mountproc(deadaddr, "/tmp/remote_speech_dead", result);
	spawn timer(timed, 2000);
	alt {
	err := <-result =>
		t.assert(err != nil, "initial mount reports a connection error");
	<-timed =>
		t.fatal("initial mount did not fail within two seconds");
		raise "fail:fatal";
	}
}

testRemoteRoutingAndReconnect(t: ref T)
{
	ctl := readfile(REMOTEMNT + "/ctl");
	t.assert(hassubstr(ctl, "audiodev " + TERMMNT + "/audio"),
		"remote provider exposes imported playback route");
	t.assert(hassubstr(ctl, "capturedev " + TERMMNT + "/audio"),
		"remote provider exposes imported capture route");

	before := filesize(AUDIOFILE);
	t.assert(writefile(REMOTEMNT + "/chime", "wake") > 0,
		"remote chime accepts a write");
	sys->sleep(500);
	t.assert(filesize(AUDIOFILE) > before,
		"provider playback crossed both provider and audio 9P mounts");

	t.assert(writefile(REMOTEMNT + "/ctl",
		"whisperstreambin /bin/sh -c \"head -c 8 > /dev/null; echo final remote topology audio\"") > 0,
		"configure deterministic stdin-consuming STT helper");
	listen := readfile(REMOTEMNT + "/listen");
	t.assert(hassubstr(listen, "final remote topology audio"),
		"capture PCM crossed the audio mount into the remote provider helper");

	t.assert(sys->unmount(nil, REMOTEMNT) >= 0, "disconnect provider mount");
	result := chan of string;
	timed := chan of int;
	spawn mountproc(provideraddr, REMOTEMNT, result);
	spawn timer(timed, 2000);
	alt {
	err := <-result =>
		t.assert(err == nil, "provider remount succeeds after disconnect");
	<-timed =>
		t.fatal("provider remount did not complete within two seconds");
		raise "fail:fatal";
	}
	ctl = readfile(REMOTEMNT + "/ctl");
	t.assert(hassubstr(ctl, "micmode device"),
		"provider configuration survives client disconnect and reconnect");
	t.assert(writefile(REMOTEMNT + "/chime", "wake") > 0,
		"provider is usable after reconnect");
}

# Exercise the launcher's recovery loop rather than remounting in the test.
# The test removes and restores the exported fake audio endpoint;
# speech-capture must observe the broken route, remount its private namespace,
# rewrite speech ctl, and publish the recovered connected state.
testCaptureWatcherRecovery(t: ref T)
{
	# The launcher writes its first record only once it is running, and
	# waitprefix reads before it sleeps. A state file still holding the
	# previous run's "connected capture" would satisfy the first wait below
	# instantly, and the test would then remove the audio endpoint while the
	# launcher was still starting - which its own startup check reports as
	# "failed audio", leaving no watcher for the rest of the test. Start
	# from no record, so every wait can only match one this run wrote.
	sys->remove(CAPTURESTATE);
	sys->remove(CAPTURESTATE + ".watcher");

	fd := sys->create(CAPTURECTL, Sys->OWRITE, 8r666);
	t.assert(fd != nil, "create deterministic speech ctl sink");
	fd = nil;
	# A previous run leaves "connected capture ..." in the shared state
	# file.  waitprefix does a prefix match, so the first wait would return
	# on that stale line before the freshly launched speech-capture has
	# finished its own install mount; the test would then remove the
	# exported audio mid-install, speech-capture would fail with a
	# failed-audio state, and every later state wait would time out.
	# Start from a clean state so the wait observes this run's own watcher.
	sys->remove(CAPTURESTATE);
	sys->remove(CAPTURESTATE + ".watcher");
	err := sh->system(nil, "sh /lib/voice/speech-capture " + captureaddr + " " +
		CAPTUREMNT + " 3 " + CAPTURESTATE + " " + CAPTURECTL + " &");
	t.assert(err == nil, "speech-capture launcher connects to loopback audio");
	ready := waitprefix(CAPTURESTATE, "connected capture " + captureaddr, 30);
	if(!ready)
		t.log("initial capture state: " + readfile(CAPTURESTATE));
	t.assert(ready,
		"speech-capture reports its initial live mount");
	if(!ready)
		return;

	t.assert(sys->remove(CAPTUREFILE) >= 0,
		"remove the exported fake audio endpoint");
	disconnected := waitprefix(CAPTURESTATE, "disconnected capture " + captureaddr, 30);
	if(!disconnected)
		t.log("post-disconnect capture state: " + readfile(CAPTURESTATE));
	t.assert(disconnected,
		"watcher publishes the missing remote audio state");
	waiting := waitprefix(CAPTURESTATE, "waiting audio " + CAPTUREMNT + "/audio", 30);
	if(!waiting)
		t.log("sustained-missing capture state: " + readfile(CAPTURESTATE));
	t.assert(waiting,
		"watcher does not mark a mount connected while remote audio is absent");
	sys->sleep(300);
	t.assert(hasprefix(readfile(CAPTURESTATE), "waiting audio "),
		"sustained missing audio remains an observable retry state");
	fd = sys->create(CAPTUREFILE, Sys->OWRITE, 8r666);
	t.assert(fd != nil, "restore the exported fake audio endpoint");
	if(fd != nil) {
		b := array of byte "0123456789abcdef";
		sys->write(fd, b, len b);
	}
	fd = nil;
	t.assert(waitprefix(CAPTURESTATE, "connected capture " + captureaddr, 40),
		"speech-capture watcher remounts after the audio endpoint returns");
	state := readfile(CAPTURESTATE);
	t.assert(hassubstr(state, "connected capture " + captureaddr),
		"watcher publishes the recovered connected state");
	routed := hassubstr(state, "device " + CAPTUREMNT + "/audio");
	if(!routed)
		t.log("recovered capture state: " + state);
	t.assert(routed,
		"connected state confirms routing was reapplied after remount");
}

killlistener(path: string)
{
	pid := readfile(path);
	(n, flds) := sys->tokenize(pid, " \t\r\n");
	if(n != 1)
		return;
	fd := sys->open("/prog/" + hd flds + "/ctl", Sys->OWRITE);
	if(fd != nil) {
		b := array of byte "killgrp";
		sys->write(fd, b, len b);
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sh = load Sh Sh->PATH;
	testing = load Testing Testing->PATH;
	if(sh == nil || testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load test modules: %r\n");
		raise "fail:load";
	}
	sh->initialise();
	testing->init();
	audioport = 20110;
	providerport = audioport + 1;
	captureport = audioport + 2;
	audioaddr = "tcp!127.0.0.1!" + string audioport;
	provideraddr = "tcp!127.0.0.1!" + string providerport;
	captureaddr = "tcp!127.0.0.1!" + string captureport;
	deadaddr = "tcp!127.0.0.1!" + string (captureport + 1);

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
		else if(hd a == "-p" && tl a != nil) {
			a = tl a;
			audioport = int hd a;
		}
	}
	providerport = audioport + 1;
	captureport = audioport + 2;
	audioaddr = "tcp!127.0.0.1!" + string audioport;
	provideraddr = "tcp!127.0.0.1!" + string providerport;
	captureaddr = "tcp!127.0.0.1!" + string captureport;
	deadaddr = "tcp!127.0.0.1!" + string (captureport + 1);

	setup := testing->newTsrc("TopologySetup", SRCFILE);
	starttopology(setup);
	if(testing->done(setup))
		passed++;
	else
		failed++;

	if(failed == 0) {
		run("InitialMountFailureBounded", testInitialMountFailureBounded);
		run("RemoteRoutingAndReconnect", testRemoteRoutingAndReconnect);
		run("CaptureWatcherRecovery", testCaptureWatcherRecovery);
	}

	result := testing->summary(passed, failed, skipped);
	killlistener("/tmp/remote_speech_audio_listener.pid");
	killlistener("/tmp/remote_speech_provider_listener.pid");
	killlistener("/tmp/remote_speech_capture_listener.pid");
	if(result > 0)
		raise "fail:tests failed";
}
