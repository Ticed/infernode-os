#!/dis/sh.dis
# Deterministic retry-exhaustion and cleanup probe for speech-capture.

load std
load expr

port=$1
tag=$2
source=/tmp/capture-exhaust-source-$tag
mountpoint=/tmp/capture-exhaust-mount-$tag
state=/tmp/capture-exhaust-$tag.state
ctl=/tmp/capture-exhaust-$tag.ctl
watchfile=$state^.watcher
addr='tcp!127.0.0.1!'$port

rm -rf $source $mountpoint
rm -f $state $ctl $watchfile
mkdir -p $source
echo sentinel > $source/sentinel
echo audio > $source/audio
listen -As 'tcp!*!'$port {export $source} &
sleep 1
echo ready > $ctl

run /lib/voice/speech-capture $addr $mountpoint 2 $state $ctl
tries=0
while {! grep '^connected capture ' $state > /dev/null} {
	tries=${expr $tries 1 +}
	if {~ $tries 10} {
		echo CAPTURE_INITIAL_FAILED
		exit initial
	}
	sleep 1
}
echo CAPTURE_INITIAL

rm -f $source/audio
tries=0
while {! grep '^failed capture ' $state > /dev/null} {
	tries=${expr $tries 1 +}
	if {~ $tries 10} {
		echo CAPTURE_EXHAUSTION_TIMEOUT
		exit timeout
	}
	sleep 1
}
echo CAPTURE_EXHAUSTED

if {ftest -e $mountpoint/sentinel} {
	echo STALE_CAPTURE_MOUNT
} {
	echo CAPTURE_MOUNT_CLEAN
}
if {ftest -e $watchfile} {
	echo STALE_CAPTURE_WATCHER
} {
	echo CAPTURE_WATCHER_CLEAN
}
