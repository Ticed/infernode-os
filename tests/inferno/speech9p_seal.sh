#!/dis/sh.dis
# speech9p -U starts unsealed; seal on closes host-command keys one-way.
# Default start is covered by speech9p_security.sh (already sealed).
load std
path=(/dis .)

rm /tmp/speech9p-seal/ctl >[2] /dev/null
unmount /tmp/speech9p-seal >[2] /dev/null
/dis/veltro/speech9p.dis -U -e cmd -m /tmp/speech9p-seal >[2] /dev/null &
ready=()
for n in 0 1 2 3 4 5 6 7 8 9 {
	if {~ $#ready 0} {
		if {ftest -f /tmp/speech9p-seal/ctl} {
			ready=1
		} {
			sleep 1
		}
	}
}
if {! ~ $ready 1} {
	echo 'SPEECH9P-SEAL FAIL: unsealed server did not publish ctl'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}

cfg := `{cat /tmp/speech9p-seal/ctl}
if {! ~ $"cfg *'seal off'*} {
	echo 'SPEECH9P-SEAL FAIL: -U did not start unsealed'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}

echo 'cmdtts /bin/echo unsealed-ok' > /tmp/speech9p-seal/ctl
cfg = `{cat /tmp/speech9p-seal/ctl}
if {! ~ $"cfg *'cmdtts /bin/echo unsealed-ok'*} {
	echo 'SPEECH9P-SEAL FAIL: cmdtts was not writable before the seal'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}

echo seal on > /tmp/speech9p-seal/ctl
cfg = `{cat /tmp/speech9p-seal/ctl}
if {! ~ $"cfg *'seal on'*} {
	echo 'SPEECH9P-SEAL FAIL: seal on was not applied'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}

echo 'cmdtts /bin/echo pwned' > /tmp/speech9p-seal/ctl
echo 'engine api' > /tmp/speech9p-seal/ctl
echo 'apikey secret' > /tmp/speech9p-seal/ctl
echo seal off > /tmp/speech9p-seal/ctl
echo voice sealedvoice > /tmp/speech9p-seal/ctl
cfg = `{cat /tmp/speech9p-seal/ctl}
if {~ $"cfg *'pwned'*} {
	echo 'SPEECH9P-SEAL FAIL: cmdtts changed after the seal'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}
if {~ $"cfg *'engine api'*} {
	echo 'SPEECH9P-SEAL FAIL: engine changed after the seal'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}
if {~ $"cfg *'seal off'*} {
	echo 'SPEECH9P-SEAL FAIL: the seal was lifted'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}
if {! ~ $"cfg *'voice sealedvoice'*} {
	echo 'SPEECH9P-SEAL FAIL: voice was not writable after the seal'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}
if {! ~ $"cfg *'cmdtts /bin/echo unsealed-ok'*} {
	echo 'SPEECH9P-SEAL FAIL: sealed cmdtts was overwritten'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-seal
}

kill Speech9p Styx > /dev/null >[2] /dev/null
echo SPEECH9P-SEAL PASS
