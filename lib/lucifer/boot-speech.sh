#!/dis/sh.dis
# Canonical sealed speech bootstrap.
#
# Lucifer boot runs this before tools9p. lib/sh/profile does not start a
# speech server. Engine is declared on the command line; speech9p seals
# host-command keys before the mount is published. `seal on` here is the
# observable close of the sequence (idempotent if the server already sealed
# itself).
#
# A bare desktop shell does not get speech from profile. Start speech9p
# yourself if you want it outside Lucifer; the default start is sealed.
load std

mkdir -p /tmp >[2] /dev/null
> /tmp/speech9p.log
/dis/veltro/speech9p.dis -e cmd >[2] /tmp/speech9p.log &

ready=()
for n in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 {
	if {~ $#ready 0} {
		if {ftest -f /n/speech/ctl} {
			ready=1
		} {
			sleep 1
		}
	}
}
if {~ $ready 1} {
	echo seal on > /n/speech/ctl
} {
	echo 'boot: speech9p did not publish /n/speech/ctl'
}
