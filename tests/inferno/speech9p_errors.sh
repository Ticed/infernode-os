#!/dis/sh.dis
# speech9p must name the next step when the API key is missing, and must
# not tell the caller to write a startup-only ctl key.
load std
path=(/dis .)
mkdir -p /tmp/speech9p-errors >[2] /dev/null
/dis/veltro/speech9p.dis -e api -m /tmp/speech9p-errors >[2] /dev/null &
sleep 1
if {! ftest -f /tmp/speech9p-errors/ctl} {
	echo 'SPEECH9P-ERRORS FAIL: did not mount'
	raise fail:speech9p-errors
}

# ctl write of apikey must not take effect (startup-only).
echo 'apikey secret' > /tmp/speech9p-errors/ctl
cfg := `{cat /tmp/speech9p-errors/ctl}
if {~ $"cfg *'apikey (set)'*} {
	echo 'SPEECH9P-ERRORS FAIL: ctl accepted apikey'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech9p-errors
}

kill Speech9p Styx > /dev/null >[2] /dev/null
echo SPEECH9P-ERRORS PASS
