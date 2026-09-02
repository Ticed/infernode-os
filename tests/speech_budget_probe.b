implement SpeechBudgetProbe;

#
# Probe used by tests/inferno/speech9p_budget.sh after speech9p is mounted.
# Proves the cumulative hear budget composes across repeated starts,
# API spend is metered, plain HTTP and API hear fail closed, and
# policy/ is absent from an agent namespace.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "nsconstruct.m";
	nsc: NsConstruct;

SpeechBudgetProbe: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

CMD: con "/tmp/speech-budget";
API: con "/tmp/speech-api";
HTTP: con "/tmp/speech-http";

fail(msg: string)
{
	sys->print("SPEECH-BUDGET FAIL: %s\n", msg);
	raise "fail:speech-budget";
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

wr(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

contains(s, sub: string): int
{
	if(s == nil || len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

runspeech()
{
	mod := load Command "/dis/veltro/speech9p.dis";
	if(mod == nil) {
		sys->fprint(sys->fildes(2), "cannot load speech9p: %r\n");
		return;
	}
	mod->init(nil, "speech9p" :: "-m" :: "/n/speech" :: nil);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	if(!exists(CMD + "/budget") || !exists(CMD + "/policy/ctl") ||
	   !exists(CMD + "/hear"))
		fail("cmd speech9p missing budget/policy/hear");

	got := rd(CMD + "/budget");
	if(!contains(got, "hear 60000 60000") || !contains(got, "api 0 0") ||
	   !contains(got, "http deny") || !contains(got, "apihear deny"))
		fail("default budget: " + got);

	if(wr(CMD + "/budget", "hear 1 1\n") >= 0)
		fail("agent-visible budget file accepted a write");

	if(wr(CMD + "/policy/ctl", "hear 10000 10000\n") < 0)
		fail(sys->sprint("cannot set hear budget: %r"));

	# N repeated starts must compose. Do not read hear: that would
	# open the microphone. The lease is taken on write.
	if(wr(CMD + "/hear", "start 5000") < 0)
		fail(sys->sprint("first hear start refused: %r"));
	if(wr(CMD + "/hear", "start 5000") < 0)
		fail(sys->sprint("second hear start refused: %r"));
	if(wr(CMD + "/hear", "start 5000") >= 0)
		fail("third hear start accepted after cumulative budget spent");
	got = rd(CMD + "/budget");
	if(!contains(got, "hear 0 10000"))
		fail("hear budget did not compose to zero: " + got);
	if(wr(CMD + "/hear", "start 1") >= 0)
		fail("hear start accepted with remaining 0");

	if(!exists(API + "/say") || !exists(HTTP + "/say"))
		fail("api speech9p mounts missing");

	if(wr(API + "/say", "hello") >= 0)
		fail("api say accepted with zero api budget");
	if(wr(API + "/hear", "start 1000") >= 0)
		fail("api hear accepted while apihear deny");
	got = rd(API + "/budget");
	if(!contains(got, "hear 60000 60000"))
		fail("denied api hear charged hear budget: " + got);

	if(wr(API + "/policy/ctl", "api 1 1\n") < 0)
		fail(sys->sprint("cannot set api budget: %r"));
	if(wr(API + "/say", "hello") < 0)
		fail(sys->sprint("api say refused with remaining budget: %r"));
	if(wr(API + "/say", "hello") >= 0)
		fail("second api say accepted after api budget spent");
	got = rd(API + "/budget");
	if(!contains(got, "api 0 1"))
		fail("api budget did not compose to zero: " + got);

	if(wr(API + "/policy/ctl", "apihear allow\napi 1 1\n") < 0)
		fail(sys->sprint("cannot allow apihear: %r"));
	if(wr(API + "/hear", "start 1000") < 0)
		fail(sys->sprint("api hear refused after apihear allow: %r"));

	if(wr(HTTP + "/policy/ctl", "api 5 5\n") < 0)
		fail(sys->sprint("cannot set http api budget: %r"));
	if(wr(HTTP + "/say", "hello") >= 0)
		fail("plain http api say accepted");

	nstest();
}

nstest()
{
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil)
		fail("load nsconstruct");
	nsc->init();

	if(!exists("/n/speech/hear")) {
		spawn runspeech();
		sys->sleep(1500);
	}
	if(!exists("/n/speech/policy/ctl") || !exists("/n/speech/budget"))
		fail("/n/speech missing policy/budget for namespace probe");

	if(!nsc->speechcontrolpath("/n/speech/policy") ||
	   !nsc->speechcontrolpath("/n/speech/policy/ctl") ||
	   nsc->speechcontrolpath("/n/speech/hear") ||
	   nsc->speechcontrolpath("/n/speech/budget"))
		fail("speechcontrolpath predicate is wrong");

	caps := ref NsConstruct->Capabilities("hear" :: nil, "/n/speech" :: nil,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil)
		fail("restrictns: " + err);

	if(!exists("/n/speech/hear") || !exists("/n/speech/say") ||
	   !exists("/n/speech/budget") || !exists("/n/speech/ctl") ||
	   !exists("/n/speech/voices"))
		fail("agent speech surface missing after restrictns");
	if(exists("/n/speech/policy") || exists("/n/speech/policy/ctl"))
		fail("speech policy visible in agent namespace");
}
