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

# The mode token of a level record, or "unreadable" when the read failed.
modeof(s: string): string
{
	if(s == nil)
		return "unreadable";
	(n, flds) := sys->tokenize(s, " \t\n\r");
	for(; flds != nil; flds = tl flds) {
		f := hd flds;
		if(len f > 5 && f[0:5] == "mode=")
			return f[5:];
	}
	n = n;
	return "nomode";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	path := "/n/speech/level";
	everyms := 50;
	forms := 20000;
	args = tl args;
	if(args != nil) { path = hd args; args = tl args; }
	if(args != nil) { everyms = int hd args; args = tl args; }
	if(args != nil) { forms = int hd args; args = tl args; }

	t0 := sys->millisec();
	last := "";
	laststart := 0;
	for(;;) {
		now := sys->millisec() - t0;
		if(now >= forms)
			break;
		m := modeof(readfile(path));
		if(m != last) {
			if(last != "")
				sys->print("LEVEL run %s %d ms (%d..%d)\n",
					last, now - laststart, laststart, now);
			sys->print("LEVEL %6d ms mode=%s\n", now, m);
			last = m;
			laststart = now;
		}
		sys->sleep(everyms);
	}
	sys->print("LEVEL run %s %d ms (%d..end)\n", last, forms - laststart, laststart);
	sys->print("LEVEL done\n");
}
