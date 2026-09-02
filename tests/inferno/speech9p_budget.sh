#!/dis/sh.dis
# Cumulative hear budget, API spend/consent, and policy namespace split.
# The hear bound must compose: N starts are refused once remaining is 0.
# Do not read /hear — that would open the microphone.
load std
path=(/dis .)

/dis/veltro/speech9p.dis -m /tmp/speech-budget >[2] /dev/null &
/dis/veltro/speech9p.dis -e api -k dummy -m /tmp/speech-api >[2] /dev/null &
/dis/veltro/speech9p.dis -e api -k dummy -u http://127.0.0.1:1 -m /tmp/speech-http >[2] /dev/null &
sleep 2
if {! ftest -e /tmp/speech-budget/budget} {
	echo 'SPEECH-BUDGET FAIL: cmd speech9p did not serve budget'
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech-budget
}
if {! /tests/speech_budget_probe.dis} {
	kill Speech9p Styx > /dev/null >[2] /dev/null
	raise fail:speech-budget
}
kill Speech9p Styx > /dev/null >[2] /dev/null
echo SPEECH-BUDGET PASS
