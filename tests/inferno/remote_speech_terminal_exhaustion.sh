#!/dis/sh.dis
# Client-side driver for terminal retry exhaustion and listener cleanup.

load std
load expr

provideraddr=$1
audioport=$2
providermnt=$3
statefile=$4
speechmnt=$5
tag=$6
rebind=/tmp/terminal-exhaust-rebind-$tag

mkdir -p $speechmnt
/dis/veltro/speech9p.dis -m $speechmnt &
while {! ftest -e $speechmnt/ctl} {
	sleep 1
}

run /lib/voice/speech-terminal $provideraddr $audioport $providermnt 2 $statefile $speechmnt/ctl
while {! grep '^connected provider ' $statefile > /dev/null} {
	sleep 1
}
echo TERMINAL_EXHAUST_INITIAL

while {! grep '^failed provider ' $statefile > /dev/null} {
	sleep 1
}
echo TERMINAL_EXHAUSTED
if {ftest -e $providermnt/ctl} {
	echo STALE_TERMINAL_PROVIDER_MOUNT
} {
	echo TERMINAL_PROVIDER_MOUNT_CLEAN
}
if {ftest -e $statefile^.listener} {
	echo STALE_TERMINAL_ENDPOINT
} {
	echo TERMINAL_ENDPOINT_CLEAN
}

mkdir -p $rebind
echo TERMINAL_REBOUND_$tag > $rebind/token
echo TERMINAL_EXHAUST_REBIND_READY
listen -As 'tcp!*!'$audioport {export $rebind}
