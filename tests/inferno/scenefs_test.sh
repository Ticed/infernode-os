#!/dis/sh.dis
#
# Namespace-contract test for scenefs(4): the tree, the record wire,
# stanza files that behave as files, the history as a recording, the
# playhead (seek and live), the shared camera, event, and refusals.
#

load std

if {! ftest -f /dis/scenefs.dis} {
	raise 'skip:scenefs.dis not built'
}

S=/tmp/scenefs_test
mkdir -p $S
mount -c {scenefs} $S
if {! ftest -f $S/status} {
	raise 'fail:scenefs did not mount'
}

for (f in ctl view status event log history meta time) {
	if {! ftest -f $S/$f} {
		raise 'fail:'^$f^' missing'
	}
}
for (d in entities features layers) {
	if {! ftest -d $S/$d} {
		raise 'fail:'^$d^'/ missing'
	}
}

# A fresh scene asks its viewers for a fit.
v=`{cat $S/view}
if {! ~ ${index 13 $v} 1} {
	raise 'fail:a fresh scene should ask for a fit: '^$"v
}

# The record wire.
echo 'meta frame=xy units=m ''title=Test run''' > $S/log
echo 'time 0' > $S/log
echo 'ent a x=0 y=0 group=blue' > $S/log
echo 'time 1' > $S/log
echo 'ent a x=10 y=5 group=blue' > $S/log
echo 'time 2' > $S/log
echo 'ent a x=20 y=15 group=blue' > $S/log

v=`{grep '^title=' $S/meta}
if {! ~ $"v 'title=Test run'} {
	raise 'fail:meta: '^$"v
}
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=20'} {
	raise 'fail:entity a after three updates: '^$"v
}

# Stanza files behave as files: > replaces, >> appends, rm removes.
echo 'x=100' > $S/entities/c
echo 'y=50' >> $S/entities/c
v=`{cat $S/entities/c}
if {! ~ $"v 'x=100 y=50'} {
	raise 'fail:entities/c after > and >>: '^$"v
}
echo 'ent b x=1 y=1' > $S/log
rm $S/entities/b
if {ftest -f $S/entities/b} {
	raise 'fail:rm did not remove entities/b'
}

# Status and history.
v=`{cat $S/status}
if {! ~ ${index 2 $v} live} {
	raise 'fail:mode: '^$"v
}
if {! ~ ${index 4 $v} 2} {
	raise 'fail:clock: '^$"v
}
n=`{grep '^time ' $S/history | wc -l}
if {! ~ $n 3} {
	raise 'fail:history time records: '^$"n
}

# The playhead: seek shows the past; live rejoins.
echo seek 1 > $S/ctl
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=10'} {
	raise 'fail:after seek 1, entity a: '^$"v
}
if {ftest -f $S/entities/c} {
	raise 'fail:entities/c exists at t=1, before it was written'
}
v=`{cat $S/status}
if {! ~ ${index 2 $v} paused} {
	raise 'fail:mode after seek: '^$"v
}
echo live > $S/ctl
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=20'} {
	raise 'fail:after live, entity a: '^$"v
}

# The shared camera.
echo 'center 5 6' > $S/ctl
echo 'zoom -1' > $S/ctl
echo 'follow a' > $S/ctl
v=`{cat $S/view}
if {! ~ $"v 'frame xy center 5 6 zoom -1 sel - follow a fit 0'} {
	raise 'fail:view: '^$"v
}

# event: selects reach a reader, and a second blocking read on the same
# open file gets the next event (events are a stream, not a file).
# (A select also moves the shared view, so a view event follows it.)
{ sleep 1; echo 'select a' > $S/ctl } &
v=`{ { read; read } < $S/event }
if {! ~ ${index 1 $v}^' '^${index 2 $v}^' '^${index 3 $v} 'select a view'} {
	raise 'fail:event: '^$"v
}

# A new run after a clear: pause shows the latest state, not the old run's.
echo clear > $S/log
echo 'time 0' > $S/log
echo 'ent a x=500 y=0' > $S/log
echo 'time 1' > $S/log
echo 'ent a x=501 y=0' > $S/log
echo pause > $S/ctl
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=501'} {
	raise 'fail:pause after a restart, entity a: '^$"v
}
echo 'seek 0' > $S/ctl
v=`{grep '^x=' $S/entities/a}
if {! ~ $"v 'x=500'} {
	raise 'fail:seek within the new run, entity a: '^$"v
}
echo live > $S/ctl

# Refusals answer with an error.
if {echo frobnicate > $S/ctl >[2] /dev/null} {
	raise 'fail:unknown ctl command accepted'
}
if {echo 'zoom' > $S/ctl >[2] /dev/null} {
	raise 'fail:zoom without a value accepted'
}
if {echo 'nonsense record' > $S/log >[2] /dev/null} {
	raise 'fail:unknown record accepted'
}

# A replayable recording.
cat $S/history > /tmp/scenefs_test.scene
rm -f /tmp/scenefs_test.scene
unmount $S
echo PASS
