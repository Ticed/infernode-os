implement MsgInject;

# Deterministic test: when a message fires, msgwatch (Lucifer mode) injects the
# message-handling POLICY together with the message into activity 0's
# conversation input (fire-time skill loading, not system-prompt bloat).
# Reads one turn from /mnt/ui/activity/0/conversation/input and checks it
# carries both the policy and the message.

include "sys.m";
	sys: Sys;
include "draw.m";

MsgInject: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	# Standalone / runner invocation has no driver arg. inferno/msg_inject.sh
	# passes "msgreader" after setting up /mnt/ui.
	if(args == nil || tl args == nil || hd tl args == "-v")
		raise "skip:msg inject helper is driven by inferno/msg_inject.sh";
	fd := sys->open("/mnt/ui/activity/0/conversation/input", Sys->OREAD);
	if(fd == nil) {
		sys->print("MSGINJECT: FAIL cannot open activity-0 input: %r\n");
		raise "fail:no activity-0 input";
	}
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);	# blocks until msgwatch relays a turn
	if(n <= 0) {
		sys->print("MSGINJECT: FAIL empty read\n");
		return;
	}
	s := string buf[0:n];
	haspolicy := contains(s, "Message Policy");
	hasmsg := contains(s, "From:") || contains(s, "unread") || contains(s, "Subject");
	hasnoautosend := contains(s, "NEVER auto-send") || contains(s, "never auto-send");
	sys->print("MSGINJECT: len=%d policy=%d message=%d no-auto-send=%d\n", n, haspolicy, hasmsg, hasnoautosend);
	if(haspolicy && hasmsg && hasnoautosend)
		sys->print("MSGINJECT: PASS policy+message injected as one turn, no-auto-send present\n");
	else
		sys->print("MSGINJECT: FAIL (policy=%d message=%d no-auto-send=%d)\n", haspolicy, hasmsg, hasnoautosend);
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}
