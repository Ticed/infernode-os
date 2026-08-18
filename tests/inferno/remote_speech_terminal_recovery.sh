#!/dis/sh.dis
# Client-side driver for the host multi-emulator provider restart test.

load std

provideraddr=$1
audioport=$2
providermnt=$3
statefile=$4
speechmnt=$5

mkdir -p $speechmnt
/dis/veltro/speech9p.dis -m $speechmnt &
while {! ftest -e $speechmnt/ctl} {
	sleep 1
}

run /lib/voice/speech-terminal $provideraddr $audioport $providermnt 15 $statefile $speechmnt/ctl
while {! ftest -e $providermnt/ctl} {
	sleep 1
}
if {! grep 'provider '$providermnt $speechmnt/ctl > /dev/null} {
	echo TERMINAL_ROUTING_FAILED
	exit routing
}
if {! grep 'duplex half' $providermnt/ctl > /dev/null} {
	echo TERMINAL_ROUTING_FAILED
	exit routing
}
echo TERMINAL_INITIAL

while {! grep '^waiting provider ' $statefile > /dev/null} {
	sleep 1
}
echo TERMINAL_WAITING

while {! grep '^connected provider ' $statefile > /dev/null} {
	sleep 1
}
while {! ftest -e $providermnt/ctl} {
	sleep 1
}

if {! grep 'provider '$providermnt $speechmnt/ctl > /dev/null} {
	echo PROVIDER_OPERATION_FAILED
} {if {! grep 'duplex half' $providermnt/ctl > /dev/null} {
	echo PROVIDER_OPERATION_FAILED
} {if {echo restart > $providermnt/chime} {
	echo PROVIDER_OPERATION_OK
} {
	echo PROVIDER_OPERATION_FAILED
}}}
sleep 30
