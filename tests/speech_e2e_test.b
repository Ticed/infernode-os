implement SpeechE2ETest;

#
# Composed voice-mode integration test. The real Lucia, LLM, speech9p,
# speechshim9p, lucibridge, and voicemode services run together. External
# speech models are replaced by tests/host/speech_e2e_helper.sh, and the
# OpenAI-compatible endpoint is supplied by speech_e2e_test.sh.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";
	arg: Arg;

include "testing.m";
	testing: Testing;
	T: import testing;

Command: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

SpeechE2ETest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();
};

SRCFILE: con "/tests/speech_e2e_test.b";

passed := 0;
failed := 0;
skipped := 0;

apiurl: string;
hoststate: string;
infernostate: string;
helper: string;

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
	n := sys->write(fd, b, len b);
	fd = nil;
	return n;
}

createfile(path: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	fd = nil;
	return 0;
}

createwithdata(path, data: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return -1;
	b := array of byte data;
	n := sys->write(fd, b, len b);
	fd = nil;
	return n;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16384] of byte;
	n := sys->pread(fd, buf, len buf, big 0);
	fd = nil;
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

contains(s, sub: string): int
{
	if(s == nil || sub == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}

pathexists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

waitpath(path: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(pathexists(path))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

waitcontains(path, sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(contains(readfile(path), sub))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' ||
			s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

waitmode(want: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 25) {
		if(strip(readfile("/mnt/ui/input-mode")) == want)
			return 1;
		sys->sleep(25);
	}
	return 0;
}

conversationrolecount(role, sub: string): int
{
	n := 0;
	for(i := 0; i < 128; i++) {
		path := "/mnt/ui/activity/0/conversation/" + string i;
		if(!pathexists(path))
			break;
		msg := readfile(path);
		if(contains(msg, "role=" + role) && contains(msg, sub))
			n++;
	}
	return n;
}

waitconversationrole(role, sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(conversationrolecount(role, sub) > 0)
			return 1;
		sys->sleep(50);
	}
	return 0;
}

clearfixtures()
{
	sys->remove(infernostate + "/wake.next");
	sys->remove(infernostate + "/wake.next.tmp");
	sys->remove(infernostate + "/wake.armed");
	sys->remove(infernostate + "/wake.consumed");
	sys->remove(infernostate + "/listen.next");
	sys->remove(infernostate + "/listen.next.tmp");
	sys->remove(infernostate + "/listen.armed");
	sys->remove(infernostate + "/listen.consumed");
}

# Create dest as a new directory entry so a waiter that armed against a
# missing or empty path cannot hold the inode we publish (INF-34).
publishfixture(path, data: string): int
{
	tmp := path + ".tmp";
	sys->remove(tmp);
	if(createwithdata(tmp, data) <= 0)
		return -1;
	name := path;
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/') {
			name = path[i + 1:];
			break;
		}
	nd := sys->nulldir;
	nd.name = name;
	sys->remove(path);
	if(sys->wstat(tmp, nd) < 0)
		return -1;
	return 1;
}

# Arm is observed, then the fixture is published, then consume is
# observed. Sending is the voicemode transition; its timeout is only a
# safety net (INF-34).
scriptvoiceturn(t: ref T, listen, why: string)
{
	clearfixtures();
	t.assert(writefile("/mnt/ui/voice-control", "on source=compose-button") > 0,
		why + " voice mode entered");
	if(!waitpath(infernostate + "/wake.armed", 8000))
		t.fatal(why + " wake helper armed");
	t.assert(publishfixture(infernostate + "/wake.next", "wake e2e 0.99\n") > 0,
		why + " wake event scripted");
	if(!waitpath(infernostate + "/wake.consumed", 8000))
		t.fatal(why + " wake helper consumed");
	if(!waitpath(infernostate + "/listen.armed", 8000))
		t.fatal(why + " listen helper armed");
	t.assert(publishfixture(infernostate + "/listen.next", listen) > 0,
		why + " transcript scripted");
	if(!waitpath(infernostate + "/listen.consumed", 8000))
		t.fatal(why + " listen helper consumed");
	if(!waitcontains("/mnt/ui/activity/0/conversation/draft-status",
			"Sending", 3000))
		t.fatal(why + " reached grace window");
}

resourcecontains(sub: string): int
{
	for(i := 0; i < 20; i++) {
		resource := readfile("/mnt/ui/activity/0/context/resources/" + string i);
		if(resource == nil)
			break;
		if(contains(resource, sub))
			return 1;
	}
	return 0;
}

waitresource(sub: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 50) {
		if(resourcecontains(sub))
			return 1;
		sys->sleep(50);
	}
	return 0;
}

startmodule(t: ref T, path, name: string, args: list of string)
{
	cmd := load Command path;
	if(cmd == nil)
		t.fatal("cannot load " + path + ": " + sys->sprint("%r"));
	spawn cmd->init(nil, name :: args);
}

preparemounts()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create("/mnt", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/n", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/ui", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/llm", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/speechshim", Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create("/mnt/speech", Sys->OREAD, Sys->DMDIR | 8r755);

	# These directories live on the host and outlive the emulator, so a
	# control file left in one by an earlier run is a plain file. waitpath
	# is then satisfied before the server mounts, and every configuration
	# write that follows lands in that file and returns success without
	# reaching the server (INF-61). Only a mount may create these, so
	# remove any that survived; the failure is otherwise self-perpetuating,
	# because the lost write recreates the file that loses the next one.
	sys->remove("/mnt/ui/ctl");
	sys->remove("/mnt/llm/new");
	sys->remove("/mnt/speechshim/ctl");
	sys->remove("/mnt/speech/ctl");
}

startstack(t: ref T)
{
	preparemounts();

	startmodule(t, "/dis/luciuisrv.dis", "luciuisrv", "-m" :: "/mnt/ui" :: nil);
	t.assert(waitpath("/mnt/ui/ctl", 3000), "luciuisrv mounted");

	startmodule(t, "/dis/veltro/speechshim9p.dis", "speechshim9p",
		"-m" :: "/mnt/speechshim" :: nil);
	t.assert(waitpath("/mnt/speechshim/ctl", 3000), "speechshim9p mounted");

	cmd := "/bin/sh " + helper;
	t.assert(writefile("/mnt/speechshim/ctl",
		"wakebin " + cmd + " wake " + hoststate) > 0, "fake wake helper configured");
	t.assert(writefile("/mnt/speechshim/ctl",
		"whisperstreambin " + cmd + " listen " + hoststate) > 0,
		"fake listen helper configured");
	t.assert(writefile("/mnt/speechshim/ctl",
		"kokorobin " + cmd + " say " + hoststate) > 0, "fake TTS helper configured");
	t.assert(createfile(infernostate + "/audio.pcm") >= 0, "fake audio sink created");
	t.assert(writefile("/mnt/speechshim/ctl", "audiodev " + infernostate + "/audio.pcm") > 0,
		"fake audio sink configured");
	t.assert(writefile("/mnt/speechshim/ctl", "duplex half") > 0,
		"half-duplex provider configured");

	startmodule(t, "/dis/veltro/speech9p.dis", "speech9p",
		"-m" :: "/mnt/speech" :: "-e" :: "kokoro" :: nil);
	t.assert(waitpath("/mnt/speech/ctl", 3000), "speech9p mounted");
	t.assert(writefile("/mnt/speech/ctl", "provider /mnt/speechshim") > 0,
		"speechshim selected as provider");

	startmodule(t, "/dis/llmsrv.dis", "llmsrv",
		"-m" :: "/mnt/llm" :: "-b" :: "openai" :: "-u" :: apiurl ::
		"-M" :: "ci-voice-e2e" :: "-r" :: "low" :: nil);
	t.assert(waitpath("/mnt/llm/new", 3000), "llmsrv mounted");

	# lucibridge deliberately validates deployment configuration before it
	# trusts /mnt/llm. Overlay a private OpenAI configuration in this test
	# namespace; never read or modify the host user's real configuration.
	config := "mode=local\nbackend=openai\nurl=" + apiurl +
		"\nmodel=ci-voice-e2e\ntemperature=0.2\n";
	t.assert(createwithdata(infernostate + "/llm.ndb", config) > 0,
		"private LLM configuration created");
	t.assert(sys->bind(infernostate + "/llm.ndb", "/lib/ndb/llm", Sys->MREPL) >= 0,
		"private LLM configuration bound");

	t.assert(writefile("/mnt/ui/ctl", "activity create VoiceE2E") > 0,
		"Lucia activity created");
	t.assert(waitpath("/mnt/ui/activity/0/conversation/voiceinput", 3000),
		"voice input endpoint created");

	startmodule(t, "/dis/lucibridge.dis", "lucibridge",
		"-s" :: "-n" :: "3" :: "-a" :: "0" :: nil);
	t.assert(waitresource("label=Voice", 8000),
		"lucibridge initialized its LLM session and speech resource");

}

startvoicemode(t: ref T)
{
	startmodule(t, "/dis/voicemode.dis", "voicemode",
		"-g" :: "300" :: "-q" :: "650" :: "-t" :: "20000" ::
		"-w" :: "50" :: "-u" :: "/mnt/ui" :: "-s" :: "/mnt/speech" :: nil);
	sys->sleep(300);
}

testComposedTurn(t: ref T)
{
	startstack(t);

	# Exercise the same semantic endpoint used by every visible entry surface.
	# /voice-control is observable, so this remains headless while still proving
	# the resulting UI mode and source attribution rather than source-text grep.
	sources := "context-chip" :: "compose-button" :: "ctrl-space" ::
		"escape-v" :: "alt-v" :: "slash-command" :: nil;
	for(; sources != nil; sources = tl sources) {
		source := hd sources;
		t.assert(writefile("/mnt/ui/voice-control", "on source=" + source) > 0,
			source + " enters voice mode");
		t.assert(waitmode("v", 1000), source + " produced voice input mode");
		t.assert(waitcontains("/mnt/ui/voice-control", "source=" + source, 1000),
			source + " was captured by the UI server");
		t.assert(writefile("/mnt/ui/voice-control", "off source=escape") > 0,
			"Escape exits after " + source);
		t.assert(waitmode("k", 1000), "keyboard restored after " + source);
	}

	# Start the resident daemon only after the pure entry/exit surface matrix.
	# Rapidly arming real wake helpers is not part of that UI contract and would
	# make the later cancellation scenario depend on discarded helper processes.
	startvoicemode(t);

	# Enter a final, wait until it is pending in the grace window, then model
	# Lucifer's unconditional Escape path. The turn must never reach Lucia.
	scriptvoiceturn(t,
		"partial confidence=940 Cancel this pending voice message\n" +
		"final confidence=940 Cancel this pending voice message.\n",
		"cancel");
	t.assert(writefile("/mnt/ui/voice-control", "off source=escape") > 0,
		"Escape cancellation sent promptly");
	t.assert(waitmode("k", 1000), "Escape restored keyboard mode promptly");
	t.assert(waitcontains("/mnt/speechshim/ctl", "mic off", 3000),
		"microphone released after Escape cancel");
	sys->sleep(200);
	t.asserteq(conversationrolecount("human", "Cancel this pending voice message"), 0,
		"Escape prevented the pending voice turn from submitting");
	t.assertseq(strip(readfile("/mnt/ui/activity/0/conversation/draft")), "",
		"Escape cleared the pending voice draft");
	t.assertseq(strip(readfile("/mnt/ui/activity/0/conversation/draft-status")), "",
		"Escape left no leftover Sending status");

	scriptvoiceturn(t,
		"partial confidence=940 Reply with exactly local LLM working\n" +
		"final confidence=940 Reply with exactly: local LLM working.\n",
		"composed");

	t.assert(waitconversationrole("human", "local LLM working", 8000),
		"final transcript submitted to lucibridge");
	t.assert(waitconversationrole("veltro", "local LLM working", 12000),
		"local OpenAI response returned to Lucia");
	t.assert(waitcontains(infernostate + "/say.log", "local LLM working", 8000),
		"assistant response reached speech provider");
	t.asserteq(conversationrolecount("human", "local LLM working"), 1,
		"final transcript submitted exactly once");
	t.assert(waitresource("label=Voice", 3000),
		"Voice lifecycle resource is present");

	t.assert(writefile("/mnt/ui/voice-control", "off source=escape") > 0,
		"keyboard mode restored");
	t.assert(waitcontains("/mnt/speechshim/ctl", "mic off", 3000),
		"microphone released after composed turn");

	# A plain keyboard turn after voice exit proves that lucibridge is no longer
	# gating typed input and the normal conversation path recovered.
	t.assert(writefile("/mnt/ui/activity/0/conversation/input",
		"Keyboard recovery marker.") > 0, "keyboard turn written after voice exit");
	t.assert(waitconversationrole("human", "Keyboard recovery marker", 5000),
		"keyboard input recovered after voice mode");
	for(waited := 0; conversationrolecount("veltro", "local LLM working") < 2 && waited < 8000; waited += 50)
		sys->sleep(50);
	t.assert(conversationrolecount("veltro", "local LLM working") >= 2,
		"keyboard recovery turn received an assistant reply");
}

testNeedsWrapper(t: ref T)
{
	t.skip("requires tests/host/speech_e2e_test.sh");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();

	arg = load Arg Arg->PATH;
	if(arg == nil) {
		sys->fprint(sys->fildes(2), "cannot load arg: %r\n");
		raise "fail:load";
	}
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		'u' => apiurl = arg->earg();
		'H' => hoststate = arg->earg();
		'I' => infernostate = arg->earg();
		'X' => helper = arg->earg();
		'v' => testing->verbose(1);
		* => ;
		}

	if(apiurl == nil || hoststate == nil || infernostate == nil || helper == nil)
		run("HostWrapperRequired", testNeedsWrapper);
	else
		run("ComposedVoiceTurn", testComposedTurn);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
