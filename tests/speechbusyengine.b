implement SpeechEngine;

include "sys.m";
	sys: Sys;

include "speech.m";

MARKER: con "/tmp/speechbusyengine.started";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "busy test engine";
}

caps(): int
{
	return Speech->CAPTTS;
}

configure(nil: ref Speech->Config): string
{
	return nil;
}

voices(): list of string
{
	return nil;
}

synthesize(nil: string): ref Speech->TTSResult
{
	fd := sys->create(MARKER, Sys->OWRITE, 8r644);
	fd = nil;
	sys->sleep(1500);
	fmt := ref Speech->AudioFmt(22050, 1, 16, "pcm");
	return ref Speech->TTSResult(nil, fmt, nil);
}

recognize(nil: array of byte, nil: ref Speech->AudioFmt): ref Speech->STTResult
{
	return ref Speech->STTResult(nil, "not supported");
}
