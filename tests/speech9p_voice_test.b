implement Speech9pVoiceTest;

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Speech9pSrv: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Speech9pVoiceTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with Speech9pSrv
};

SRCFILE: con "/tests/speech9p_voice_test.b";
SRVPATH: con "/dis/veltro/speech9p.dis";
MNT: con "/tmp/speech9p_voice_test";
PARAKEETMNT: con "/tmp/parakeet_voice_mount";

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

strip(s: string): string
{
	if(s == nil)
		return nil;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

createfile(path, data: string): int
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
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

writesayread(path, data: string): string
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return nil;
	b := array of byte data;
	if(sys->write(fd, b, len b) < 0)
		return nil;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];
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

startserver()
{
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(PARAKEETMNT, Sys->OREAD, Sys->DMDIR | 8r755);
	srv := load Speech9pSrv SRVPATH;
	if(srv == nil) {
		sys->fprint(sys->fildes(2), "cannot load speech9p: %r\n");
		raise "fail:load";
	}
	spawn srv->init(nil, "speech9p" :: "-m" :: MNT :: "-P" :: PARAKEETMNT :: "-e" :: "kokoro" :: "-v" :: "af_bella" :: nil);
	sys->sleep(300);
}

testFiles(t: ref T)
{
	files := array[] of {
		"ctl", "say", "sayq", "hear", "listen", "wake", "cancel", "voices", "level"
	};
	for(i := 0; i < len files; i++)
		t.assert(pathexists(MNT + "/" + files[i]), files[i] + " should exist");
}

testLevelProxy(t: ref T)
{
	record := "mode=input input-rms=321 input-peak=654 output-rms=0 output-peak=0 capture-rate=16000 playback-rate=22050\n";
	t.assert(createfile(PARAKEETMNT + "/level", record) > 0,
		"create provider telemetry fixture");
	level := readfile(MNT + "/level");
	t.assert(level == record,
		"speech9p re-exports provider PCM telemetry unchanged");

	t.assert(sys->remove(PARAKEETMNT + "/level") >= 0,
		"remove optional provider telemetry");
	t.assert(writefile(MNT + "/ctl", "capturerate 24000") > 0,
		"capture telemetry rate accepted");
	t.assert(writefile(MNT + "/ctl", "rate 24000") > 0,
		"playback telemetry rate accepted");
	level = readfile(MNT + "/level");
	t.assert(hassubstr(level, "mode=idle input-rms=0 input-peak=0 output-rms=0 output-peak=0"),
		"provider without level degrades to truthful idle telemetry");
	t.assert(hassubstr(level, "capture-rate=24000 playback-rate=24000"),
		"fallback telemetry reports configured rates");
	writefile(MNT + "/ctl", "capturerate 16000");
	writefile(MNT + "/ctl", "rate 22050");
}

testConfig(t: ref T)
{
	ctl := readfile(MNT + "/ctl");
	t.assert(ctl != nil, "ctl should be readable");
	t.assert(ctl != nil && len ctl > 0, "ctl should not be empty");
	t.assert(writefile(MNT + "/ctl", "engine kokoro") > 0, "engine kokoro accepted");
	t.assert(writefile(MNT + "/ctl", "voice af_bella") > 0, "voice accepted");
	t.assert(writefile(MNT + "/ctl", "kokorobin /bin/echo") > 0, "kokoro helper accepted");
	t.assert(writefile(MNT + "/ctl", "ttsengine piper") > 0, "tts engine accepted");
	t.assert(writefile(MNT + "/ctl", "listenengine whisper") > 0, "listen engine accepted");
	t.assert(writefile(MNT + "/ctl", "whisperstreambin /bin/echo final test transcript") > 0,
		"streaming helper accepted");
	t.assert(writefile(MNT + "/ctl", "wakebin /bin/echo wake score=1.0") > 0,
		"wake helper accepted");
	t.assert(writefile(MNT + "/ctl", "wakeword hey lucia") > 0, "wake word accepted");
	t.assert(writefile(MNT + "/ctl", "wakethreshold 0.7") > 0, "wake threshold accepted");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0, "parakeet mount accepted");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten " + PARAKEETMNT + "/listen") > 0,
		"parakeet listen mount accepted");
	t.assert(writefile(MNT + "/ctl", "pipersay " + PARAKEETMNT + "/say") > 0,
		"piper say mount accepted");
	ctl = readfile(MNT + "/ctl");
	t.assert(ctl != nil && len ctl > 0, "ctl remains readable after config writes");
	t.assert(hassubstr(ctl, "engine kokoro"), "ctl reports kokoro engine");
	t.assert(hassubstr(ctl, "kokorobin /bin/echo"), "ctl reports kokoro helper");
	t.assert(hassubstr(ctl, "ttsengine piper"), "ctl reports tts engine");
	t.assert(hassubstr(ctl, "listenengine whisper"), "ctl reports listen engine");
	t.assert(hassubstr(ctl, "wakeword hey lucia"), "ctl reports wake word");
	t.assert(hassubstr(ctl, "wakethreshold 0.7"), "ctl reports wake threshold");
	t.assert(hassubstr(ctl, "parakeetmount " + PARAKEETMNT), "ctl reports parakeet mount");
	t.assert(hassubstr(ctl, "parakeetlisten " + PARAKEETMNT + "/listen"),
		"ctl reports parakeet listen mount");
	t.assert(hassubstr(ctl, "pipersay " + PARAKEETMNT + "/say"),
		"ctl reports piper say mount");
}

# speech9p no longer runs helper binaries itself: listen and wake are
# consumed from the configured provider mount (speechshim9p, a parakeet
# export, or — as here — plain files standing in for a provider).
testListenWakeHelpers(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "provider " + PARAKEETMNT) > 0,
		"configure provider mount");
	t.assert(createfile(PARAKEETMNT + "/ctl", "") >= 0,
		"create fake provider ctl file");
	t.assert(writefile(MNT + "/ctl", "whispermodel /tmp/ggml-test.bin") > 0,
		"whisper model accepted");
	providerctl := readfile(PARAKEETMNT + "/ctl");
	t.assert(hassubstr(providerctl, "whispermodel /tmp/ggml-test.bin"),
		"whisper model forwarded to provider");
	t.assert(createfile(PARAKEETMNT + "/listen", "final helper transcript\n") > 0,
		"create fake provider listen file");
	t.assert(createfile(PARAKEETMNT + "/wake", "wake hey_lucia 0.88\n") > 0,
		"create fake provider wake file");

	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final helper transcript"),
		"listen returns provider stream output");
	wake := readfile(MNT + "/wake");
	t.assert(hassubstr(wake, "wake hey_lucia"),
		"wake returns provider event");
}

testParakeetListenMount(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "listenengine parakeet") > 0,
		"configure parakeet listen engine");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0,
		"configure parakeet mount prefix");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten " + PARAKEETMNT + "/listen") > 0,
		"configure parakeet listen file");
	t.assert(createfile(PARAKEETMNT + "/listen", "final parakeet transcript\n") > 0,
		"create fake mounted parakeet listen file");
	listen := readfile(MNT + "/listen");
	t.assert(hassubstr(listen, "final parakeet transcript"),
		"listen returns mounted parakeet stream output");

	t.assert(writefile(MNT + "/ctl", "listenengine whisper") > 0,
		"restore default listen engine for later tests");
}

testPiperSayMount(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "ttsengine piper") > 0,
		"configure piper tts engine");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0,
		"configure parakeet mount prefix");
	t.assert(createfile(PARAKEETMNT + "/say", "") >= 0,
		"create fake mounted piper say file");
	result := writesayread(MNT + "/say", "mounted piper tts");
	t.assert(hassubstr(result, "mounted piper tts"),
		"say returns mounted piper say status");
	written := readfile(PARAKEETMNT + "/say");
	t.assert(hassubstr(written, "mounted piper tts"),
		"speech9p delegated say write to mounted piper say file");
	t.assert(writefile(MNT + "/ctl", "ttsengine engine") > 0,
		"restore default tts engine for later tests");
}

# Match lucibridge's completion-aware client contract: sayq is opened ORDWR,
# written once, rewound, and read for the terminal status of that utterance.
testSayqCompletion(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "ttsengine piper") > 0,
		"configure piper tts engine");
	t.assert(writefile(MNT + "/ctl", "parakeetmount " + PARAKEETMNT) > 0,
		"configure parakeet mount prefix");
	t.assert(createfile(PARAKEETMNT + "/say", "") >= 0,
		"create fake mounted piper say file");
	result := writesayread(MNT + "/sayq", "completion aware speech");
	t.assert(result != nil && len result > 0,
		"sayq returns a terminal completion status");
	written := readfile(PARAKEETMNT + "/say");
	t.assert(hassubstr(written, "completion aware speech"),
		"sayq delivered text to the fake provider");
	t.assert(writefile(MNT + "/ctl", "ttsengine engine") > 0,
		"restore default tts engine");
}

testDisEngineModule(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "provider " + PARAKEETMNT) > 0,
		"configure module provider mount");
	t.assert(createfile(PARAKEETMNT + "/say", "") >= 0,
		"create module provider say file");
	t.assert(createfile(PARAKEETMNT + "/listen", "final module transcript\n") > 0,
		"create module provider listen file");
	t.assert(createfile(PARAKEETMNT + "/voices", "module_voice\n") > 0,
		"create module provider voices file");
	t.assert(writefile(MNT + "/ctl",
		"module /dis/veltro/speechprovider.dis") > 0,
		"load provider-backed SpeechEngine module");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "engine module"),
		"ctl reports dynamically loaded engine selection");
	t.assert(hassubstr(ctl, "modulename provider"),
		"ctl reports loaded module name");
	voices := readfile(MNT + "/voices");
	t.assert(hassubstr(voices, "module_voice"),
		"voices are supplied by the loaded module");
	result := writesayread(MNT + "/sayq", "module-backed speech");
	t.assert(hassubstr(result, "ok"),
		"module-backed sayq returns terminal status");
	written := readfile(PARAKEETMNT + "/say");
	t.assert(hassubstr(written, "module-backed speech"),
		"loaded module delegated speech through its provider namespace");
	t.assert(writefile(MNT + "/ctl", "engine kokoro") > 0,
		"restore provider engine for later tests");
}

testCancel(t: ref T)
{
	t.assert(writefile(MNT + "/cancel", "cancel") > 0, "cancel write accepted");
	state := strip(readfile(MNT + "/cancel"));
	t.assert(state == "cancel pending" || state == "idle",
		"cancel state should be readable");
}

# The seal closes these keys once boot has configured them — but boot writes
# them first, replaying a file it found on the host, so the values themselves
# have to be safe. Each one is spliced into an `exec /bin/sh -c \'...\'` line
# when the helper starts, which makes a value with a `;` in it a host command.
# This runs before the seal, where the seal cannot help.
# boot hands the installer's speech.ctl to the ctl as one write rather than
# executing it, so a write carrying several records has to apply all of them.
# Blank lines and # comments are skipped; the first bad record stops the run.
testMultiRecordCtlWrite(t: ref T)
{
	block := "# written by the installer\n" +
		"\n" +
		"voice af_heart\n" +
		"rate 22050\n";
	t.assert(writefile(MNT + "/ctl", block) > 0, "multi-record write accepted");
	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "voice af_heart"), "first record applied");
	t.assert(hassubstr(ctl, "rate 22050"), "second record applied");

	bad := "voice af_bella\nwakethreshold $(echo 1)\n";
	t.assert(writefile(MNT + "/ctl", bad) < 0, "a bad record fails the write");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "voice af_bella"),
		"records before the bad one still applied");

	writefile(MNT + "/ctl", "rate 16000");
}

testHelperKeyValuesValidated(t: ref T)
{
	# kokorobin, whisperstreambin and wakebin are excluded on purpose: those
	# three hold a command line, arguments and all, and the suite configures
	# fake helpers as `/bin/sh -c "..."`. They stay closed by the seal instead.
	# These three are not commands — a model path, a phrase and a number — so
	# they can be checked.
	hostile := array[] of {
		"whispermodel /tmp/m.bin; echo INJECTED",
		"whispermodel /tmp/m.bin`echo INJECTED`",
		"wakeword hey \"; echo INJECTED; \"",
		"wakeword $(echo hey)",
		"wakethreshold 0.5; echo INJECTED",
		"wakethreshold $(echo 1)",
	};
	for(i := 0; i < len hostile; i++)
		t.assert(writefile(MNT + "/ctl", hostile[i]) < 0,
			"refused before the seal: " + hostile[i]);

	t.assert(!hassubstr(readfile(MNT + "/ctl"), "INJECTED"),
		"no part of a refused value reaches the config");

	# What boot.sh itself writes has to keep working, including the ..
	# component in the model path.
	legit := array[] of {
		"whispermodel /opt/speech/bin/../models/ggml-base.en.bin",
		"wakeword hey jarvis",
		"wakethreshold 0.5",
	};
	for(j := 0; j < len legit; j++)
		t.assert(writefile(MNT + "/ctl", legit[j]) > 0,
			"accepted: " + legit[j]);
}

# Provider aliases must stay below the configured provider root even while
# boot is still applying its startup configuration. The seal closes the keys
# later, but it cannot repair a path accepted before the seal.
testProviderPathsConfined(t: ref T)
{
	t.assert(writefile(MNT + "/ctl", "provider " + PARAKEETMNT) > 0,
		"configure provider root");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten " + PARAKEETMNT + "/listen") > 0,
		"provider listen path accepted");
	t.assert(writefile(MNT + "/ctl", "pipersay " + PARAKEETMNT + "/say") > 0,
		"provider say path accepted");
	t.assert(writefile(MNT + "/ctl", "parakeetlisten /tmp/speech9p-outside/listen") < 0,
		"provider listen path outside root refused");
	t.assert(writefile(MNT + "/ctl", "pipersay /tmp/speech9p-outside/say") < 0,
		"provider say path outside root refused");
	t.assert(writefile(MNT + "/ctl", "provider /tmp/speech9p-outside") < 0,
		"provider root outside declared mount refused");
	t.assert(writefile(MNT + "/ctl", "provider " + PARAKEETMNT) > 0,
		"restore provider root");
}

# These keys choose what code runs: the engine, the host helper
# commands forwarded to the provider, the .dis module, and the provider tree
# the say/listen files are proxied from. Writing one is equivalent to running a
# host command, so they are operator configuration, closed by `seal on` once
# boot has configured them.
#
# Runs last: the seal is one-way, so any test needing one of these keys must
# already have run.
testSealedKeysRefused(t: ref T)
{
	t.assert(hassubstr(readfile(MNT + "/ctl"), "seal off"), "starts unsealed");
	t.assert(writefile(MNT + "/ctl", "seal on") > 0, "seal accepted");
	t.assert(hassubstr(readfile(MNT + "/ctl"), "seal on"), "seal is observable");

	closed := array[] of {
		"whispermodel /tmp/m.bin; echo INF56INJECTED",
		"kokorobin /bin/sh -c \"echo INF56INJECTED\"",
		"whisperstreambin /bin/echo INF56INJECTED",
		"wakebin /bin/echo INF56INJECTED",
		"wakeword hey \"; echo INF56INJECTED; \"",
		"wakethreshold 0.5; echo INF56INJECTED",
		"engine cmd",
		"module /dis/veltro/speechprovider.dis",
		"provider /tmp/INF56INJECTED",
		"parakeetmount /tmp/INF56INJECTED",
		"parakeetlisten /tmp/INF56INJECTED/listen",
		"pipersay /tmp/INF56INJECTED/say",
	};
	for(i := 0; i < len closed; i++)
		t.assert(writefile(MNT + "/ctl", closed[i]) < 0,
			"refused after seal: " + closed[i]);

	ctl := readfile(MNT + "/ctl");
	t.assert(hassubstr(ctl, "provider " + PARAKEETMNT + "\n"),
		"a refused write leaves the provider mount unchanged");
	t.assert(!hassubstr(ctl, "INF56INJECTED"),
		"no part of a refused value reaches the config");
	t.assert(!hassubstr(readfile(PARAKEETMNT + "/ctl"), "INF56INJECTED"),
		"no refused value is forwarded to the provider");

	# One-way, and the inert knobs the say/hear tools need stay writable.
	t.assert(writefile(MNT + "/ctl", "seal off") < 0, "the seal cannot be lifted");
	t.assert(writefile(MNT + "/ctl", "voice af_bella") > 0, "voice still writable");
	t.assert(writefile(MNT + "/ctl", "rate 16000") > 0, "rate still writable");
	t.assert(writefile(MNT + "/ctl", "mic off") > 0, "mic still writable");
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
	run("ListenWakeHelpers", testListenWakeHelpers);
	run("LevelProxy", testLevelProxy);
	run("ParakeetListenMount", testParakeetListenMount);
	run("PiperSayMount", testPiperSayMount);
	run("SayqCompletion", testSayqCompletion);
	run("DisEngineModule", testDisEngineModule);
	run("Cancel", testCancel);
	run("MultiRecordCtlWrite", testMultiRecordCtlWrite);
	run("HelperKeyValuesValidated", testHelperKeyValuesValidated);
	run("ProviderPathsConfined", testProviderPathsConfined);
	run("SealedKeysRefused", testSealedKeysRefused);

	teardown();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
