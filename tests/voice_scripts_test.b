implement VoiceScriptsTest;

#
# voice_scripts_test — pin the shape of the voice/* rc scripts so a
# refactor doesn't silently drop the audioctl buffer-cap writes
# (INFR-194) or change the mount/cat structure (INFR-195's prewarm
# lives inside the listen block; if someone moves it out the bridge
# regresses to "phone-mic-can't-reach-Mac-speaker").
#
# These are not full integration tests — those need real audio
# hardware + TCC permission on macOS and a connected phone, which is
# tracked separately. What this test catches: someone edits one of
# the rc scripts and accidentally removes a load-bearing line.
#
# What's verified:
#   - lib/voice/listen exists, loads std, binds devaudio, writes
#     both buffer-cap verbs to /dev/audioctl, calls listen.
#   - lib/voice/dial exists, binds devaudio, writes buffer-cap
#     verbs, calls mount.
#   - lib/voice/test-tone exists (single-shell loopback recipe).
#   - speech-terminal / speech-engine / speech-capture automate the documented
#     remote speech namespace topologies without embedding host policy.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

VoiceScriptsTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/voice_scripts_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" => ;
	"fail:skip"  => ;
	* => t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Read the whole script file into a single string. Bails the test with
# fail:fatal if the file is missing — that's a stronger signal than
# "well, this assertion would have passed if the file had existed."
script_contents(t: ref T, path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) {
		t.fatal(sys->sprint("%s not present", path));
		raise "fail:fatal";
	}
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) break;
		out += string buf[:n];
	}
	return out;
}

contains(haystack, needle: string): int
{
	if(len needle == 0) return 1;
	for(i := 0; i + len needle <= len haystack; i++)
		if(haystack[i:i+len needle] == needle)
			return 1;
	return 0;
}

testListenShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/listen");
	t.assert(contains(s, "load std"),
		"voice/listen loads the std sh module");
	t.assert(contains(s, "bind -a '#A' /dev"),
		"voice/listen binds devaudio onto /dev");
	t.assert(contains(s, "play_buffer_ms 100"),
		"voice/listen writes INFR-194 playback buffer cap");
	t.assert(contains(s, "rec_buffer_ms 100"),
		"voice/listen writes INFR-194 capture buffer cap");
	t.assert(contains(s, "listen "),
		"voice/listen calls listen builtin");
	t.assert(contains(s, "export /dev"),
		"voice/listen exports /dev");
	t.assert(contains(s, "endpointfile=$2") &&
		contains(s, "echo $net > "),
		"voice/listen can publish its announce endpoint for supervision");
}

testDialShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/dial");
	t.assert(contains(s, "load std"),
		"voice/dial loads the std sh module");
	t.assert(contains(s, "bind -a '#A' /dev"),
		"voice/dial binds devaudio onto /dev");
	t.assert(contains(s, "play_buffer_ms 100"),
		"voice/dial writes INFR-194 playback buffer cap");
	t.assert(contains(s, "rec_buffer_ms 100"),
		"voice/dial writes INFR-194 capture buffer cap");
	t.assert(contains(s, "mount "),
		"voice/dial calls mount");
	t.assert(contains(s, "/n/voice/audio"),
		"voice/dial references the mounted /n/voice/audio file");
	t.assert(contains(s, "/dev/audio"),
		"voice/dial references the local /dev/audio file");
}

testTestToneShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/test-tone");
	t.assert(contains(s, "audiotone"),
		"voice/test-tone invokes audiotone");
	t.assert(contains(s, "tcp!127.0.0.1!"),
		"voice/test-tone targets the loopback");
}

testSpeechTerminalShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-terminal");
	t.assert(contains(s, "run /lib/voice/speech-terminal"),
		"speech-terminal documents the namespace-preserving entrypoint");
	t.assert(contains(s, "sh /lib/voice/listen"),
		"speech-terminal exports local audio through voice/listen");
	t.assert(contains(s, "mount -A $engine $provider"),
		"speech-terminal mounts the remote provider");
	t.assert(contains(s, "ctlfile=/n/speech/ctl") &&
		contains(s, "writectl 'provider '^$provider $ctlfile"),
		"speech-terminal selects the mounted provider");
	t.assert(contains(s, "writectl 'duplex half' $ctlfile"),
		"speech-terminal preserves the half-duplex default");
	t.assert(contains(s, "writectl 'duplex half' $provider/ctl"),
		"speech-terminal requires the remote provider to accept half-duplex");
	t.assert(contains(s, "fn routeprovider") &&
		contains(s, "setstate failed control $result"),
		"speech-terminal reports routing failure instead of connected");
	t.assert(contains(s, "watchprovider"),
		"speech-terminal monitors and remounts a disconnected provider");
	t.assert(contains(s, "connected provider"),
		"speech-terminal exposes its connection state");
	t.assert(contains(s, "mounttries=30"),
		"speech-terminal bounds its initial mount attempts");
	t.assert(contains(s, "rm -f $statefile"),
		"speech-terminal replaces state records without stale suffixes");
	t.assert(contains(s, "echo hangup > $listenerctl/ctl") &&
		contains(s, "echo killgrp >/prog/$terminal_pid/ctl"),
		"speech-terminal closes its listener endpoint and process group");
}

testSpeechEngineShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-engine");
	t.assert(contains(s, "mount -A $terminal $termmnt"),
		"speech-engine imports terminal audio");
	t.assert(contains(s, "/dis/veltro/speechshim9p.dis -m $provider"),
		"speech-engine starts a provider at an isolated mount");
	t.assert(contains(s, "writectl 'audiodev '^$termmnt'/audio' $provider/ctl"),
		"speech-engine routes playback and default capture through imported audio");
	t.assert(contains(s, "writectl 'micmode device' $provider/ctl"),
		"speech-engine enables namespace-backed PCM capture");
	t.assert(contains(s, "listen -As $addr"),
		"speech-engine keeps the provider listener attached for runtime state");
	t.assert(contains(s, "export $provider"),
		"speech-engine exports the provider contract");
	t.assert(contains(s, "failed provider listener"),
		"speech-engine exposes a runtime listener failure");
	t.assert(contains(s, "mounttries=30"),
		"speech-engine bounds its initial terminal mount attempts");
	t.assert(contains(s, "rm -f $statefile"),
		"speech-engine replaces state records without stale suffixes");
	t.assert(contains(s, "fn cleanupengine") &&
		contains(s, "echo killgrp >/prog/$shim_pid/ctl"),
		"speech-engine tears down its mounts and shim process group");
}

testSpeechCaptureShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-capture");
	t.assert(contains(s, "mount -A $capture $capturemnt"),
		"speech-capture imports a remote device tree");
	t.assert(contains(s, "ctlfile=/n/speech/ctl"),
		"speech-capture defaults to the installed speech control file");
	t.assert(contains(s, "echo capturedev $capturemnt/audio > $ctlfile"),
		"speech-capture changes capture without changing playback");
	t.assert(contains(s, "echo micmode device > $ctlfile"),
		"speech-capture enables device-fed helpers");
	t.assert(contains(s, "watchcapture"),
		"speech-capture monitors and remounts a disconnected audio export");
	t.assert(contains(s, "connected capture"),
		"speech-capture exposes its connection state");
	t.assert(contains(s, "rm -f $statefile"),
		"speech-capture replaces state records without stale suffixes");
	t.assert(contains(s, "fn cleanupcapture") &&
		contains(s, "watchfile=$statefile^.watcher"),
		"speech-capture exposes and removes its supervised watcher state");
}

testSpeechPhoneShape(t: ref T)
{
	s := script_contents(t, "/lib/voice/speech-phone");
	t.assert(contains(s, "port=17010"),
		"speech-phone has the documented default port");
	t.assert(contains(s, "listen -A 'tcp!*!'$port"),
		"speech-phone exports through the explicit unauthenticated dev listener");
	t.assert(contains(s, "{export /dev}"),
		"speech-phone exports only the device tree");
	t.assert(contains(s, "trusted networks only"),
		"speech-phone identifies the development security boundary");
}

testSpeechTestUsesInstalledCtl(t: ref T)
{
	launcher := script_contents(t, "/tools/speech-test.sh");
	t.assert(contains(launcher, "speech.ctl.sh"),
		"headless speech test discovers the installer-selected ctl file");
	t.assert(contains(launcher, "speech-test-ctl.XXXXXX") &&
		contains(launcher, "configfile=\"/tmp/"),
		"headless speech test stages host ctl inside the emulator root");
	t.assert(contains(launcher, "-C"),
		"headless speech test passes the selected ctl file to speechtest");

	boot := script_contents(t, "/lib/lucifer/boot.sh");
	t.assert(contains(boot, "$speechhelperbin^/../speech.ctl.sh"),
		"GUI speech test prefers the ctl file adjacent to its helper bin");
}

testVoiceDraftPresentation(t: ref T)
{
	conv := script_contents(t, "/appl/cmd/luciconv.b");
	t.assert(contains(conv, "draft-status"),
		"conversation reads the voice draft status");
	t.assert(contains(conv, "voice-draft"),
		"voice hypotheses render as a conversation turn");
	t.assert(contains(conv, "not sent"),
		"the pending voice turn is explicitly marked unsent");
	t.assert(contains(conv, "voiceactive() && k != 0"),
		"keyboard compose edits are locked while voice owns the turn");
	t.assert(contains(conv, "conversation/voicequeue"),
		"conversation reads the server-owned follow-up queue state");
	t.assert(contains(conv, "Queued follow-up - not sent"),
		"queued follow-up renders as a visibly unsent conversation tile");
	t.assert(contains(conv, "if(action == \"Cancel\")") &&
		contains(conv, "replace \" + queueeditbuf"),
		"queued follow-up exposes queue-scoped cancel and atomic replace");
	t.assert(contains(conv, "queueeditbuf: string") &&
		contains(conv, "typed compose is untouched"),
		"replacement editing stays isolated from the typed compose buffer");
	t.assert(contains(conv, "state=disconnected\\n"),
		"a missing queue mount becomes an explicit disconnected state");

	boot := script_contents(t, "/appl/cmd/lucifer.b");
	t.assert(contains(boot, "convEvCh <-= ev"),
		"global input-mode changes reach the conversation UI");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2),
			"cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();

	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("ListenShape", testListenShape);
	run("DialShape", testDialShape);
	run("TestToneShape", testTestToneShape);
	run("SpeechTerminalShape", testSpeechTerminalShape);
	run("SpeechEngineShape", testSpeechEngineShape);
	run("SpeechCaptureShape", testSpeechCaptureShape);
	run("SpeechPhoneShape", testSpeechPhoneShape);
	run("SpeechTestUsesInstalledCtl", testSpeechTestUsesInstalledCtl);
	run("VoiceDraftPresentation", testVoiceDraftPresentation);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
