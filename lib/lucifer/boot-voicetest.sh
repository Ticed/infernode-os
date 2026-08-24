# GUI voice boot for end-to-end tests — the full lucifer desktop with the
# real voice path: wake word, live partials, the send countdown, an LLM
# turn, and the answer spoken back. Unlike boot-speechtest.sh nothing is
# canned here; the only concession to a test is that it does not stop for
# a password.
#
# Invoked by tests/host/gui_voice_turn_test.sh as:
#
#   sh -l /lib/lucifer/boot-voicetest.sh <helpers-bin|-> <ndb-dir|->
#
# $1  HOST path to the speech-helpers bin dir from
#     tools/install-speech-helpers.sh ('-' = leave helpers unconfigured)
# $2  an Inferno directory to bind over /lib/ndb ('-' = use the user's
#     own configuration). A test uses this to name the model it will
#     hold the answer to, without touching ~/.infernode.

if {! ~ $1 -} {
	speechhelperbin = $1
}
if {! ~ $2 -} {
	bind -bc $2 /lib/ndb
	echo 'boot-voicetest: /lib/ndb from' $2
}

# Nothing here needs secstore keys: the LLM backend is a local
# OpenAI-shaped endpoint, which llmsrv dials without factotum.
skiplogon = 1
echo 'boot-voicetest: live voice mode (skiplogon=1)'

run /lib/lucifer/boot.sh
