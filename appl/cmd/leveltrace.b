implement Leveltrace;

#
# leveltrace - sample /n/speech/level and report what mode it was in.
#
# The voice meter's label is chosen from the mode field of that file
# (luciconv.b drawvoicemeter), so this reports the same signal the label
# follows, with the sampling rate as the only limit on resolution.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Leveltrace: module
{
	PATH: con "/dis/leveltrace.dis";
	init: fn(nil: ref Draw->Context, args: list of string);
};

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

# One field from a level record, or dflt when missing.
fieldof(s, key, dflt: string): string
{
	if(s == nil)
		return dflt;
	prefix := key + "=";
	plen := len prefix;
	(n, flds) := sys->tokenize(s, " \t\n\r");
	for(; flds != nil; flds = tl flds) {
		f := hd flds;
		if(len f >= plen && f[0:plen] == prefix)
			return f[plen:];
	}
	n = n;
	return dflt;
}

# The mode token of a level record, or "unreadable" when the read failed.
modeof(s: string): string
{
	if(s == nil)
		return "unreadable";
	m := fieldof(s, "mode", "");
	if(m == "")
		return "nomode";
	return m;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	path := "/n/speech/level";
	everyms := 50;
	forms := 20000;
	tickms := 1000;
	args = tl args;
	if(args != nil) { path = hd args; args = tl args; }
	if(args != nil) { everyms = int hd args; args = tl args; }
	if(args != nil) { forms = int hd args; args = tl args; }
	if(args != nil) { tickms = int hd args; args = tl args; }

	t0 := sys->millisec();
	last := "";
	laststart := 0;
	lasttick := -tickms;
	for(;;) {
		now := sys->millisec() - t0;
		if(now >= forms)
			break;
		rec := readfile(path);
		m := modeof(rec);
		if(m != last) {
			if(last != "")
				sys->print("LEVEL %s run %s %d ms (%d..%d)\n",
					path, last, now - laststart, laststart, now);
			sys->print("LEVEL %s %6d ms mode=%s in=%s inpeak=%s out=%s outpeak=%s\n",
				path, now, m,
				fieldof(rec, "input-rms", "-"),
				fieldof(rec, "input-peak", "-"),
				fieldof(rec, "output-rms", "-"),
				fieldof(rec, "output-peak", "-"));
			last = m;
			laststart = now;
		} else if(tickms == 0 || now - lasttick >= tickms) {
			sys->print("LEVEL %s %6d ms tick mode=%s in=%s inpeak=%s out=%s outpeak=%s\n",
				path, now, m,
				fieldof(rec, "input-rms", "-"),
				fieldof(rec, "input-peak", "-"),
				fieldof(rec, "output-rms", "-"),
				fieldof(rec, "output-peak", "-"));
			lasttick = now;
		}
		sys->sleep(everyms);
	}
	sys->print("LEVEL %s run %s %d ms (%d..end)\n", path, last, forms - laststart, laststart);
	sys->print("LEVEL %s done\n", path);
}
