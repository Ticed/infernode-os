# Testing voice and audio

How to verify anything that involves a microphone, a speaker, or voice
mode in this repository, and what is already known to be broken.

Voice work has one property nothing else here has: **every claim it makes
is a promise to the user's eyes and ears.** A log line saying a sound was
made is not evidence that a sound was made, and a headless pass says
nothing about whether the interface drew anything. So the verification
ladder runs from cheap and narrow to slow and whole, and the top of it is
a test that reads the screen and listens to the speaker.

## The short version

```sh
tools/diagnose-virtual-audio.sh          # is the audio path alive at all?
bash tests/host/gui_voice_turn_test.sh   # a whole turn, verified on screen
```

Lead with the GUI test when reporting voice work. The headless tests
below still run and still catch things, but they cannot tell you that the
countdown was drawn.

## What each test proves

All of these skip (exit 77) rather than fail when the machine cannot run
them — no loopback driver, no speech helpers, no LLM, no display.

| Test | What only it can prove |
| --- | --- |
| `tests/host/virtual_audio_loopback_test.sh` | A tone played by InferNode comes back through the audio device, concentrated at the frequency played. The rig checking its own carrier — and the only test that asserts playback produced a *signal* rather than that the write returned. |
| `tests/host/virtual_mic_speech_test.sh` | A committed speech fixture played into the device is transcribed by the live stack. The capture path itself: `elevenlabs_speech_e2e_test.py` feeds the same fixtures over stdin, which proves the model and the gate but never touches a device. |
| `tests/host/virtual_voice_turn_test.sh` | A whole turn on one device — wake word, utterance, spoken reply — plus half-duplex suppression: the reply is on the capture side the instant it plays, so if suppression lapsed the stack would transcribe its own voice and answer itself. |
| `tests/host/gui_voice_turn_test.sh` | The same turn through the desktop, asserted on the pixels: the Voice tile lighting up, partials in the unsent turn, the "Sending in Ns" countdown counting, the answer drawn — and the spoken answer recorded off the device and required to match the screen **word for word**. |

## The tools

| Tool | Use it for |
| --- | --- |
| `tools/diagnose-virtual-audio.sh` | Silence. Walks the ladder that separates the emulator's playback, the emulator's capture, the driver, and microphone authorization, and prints a verdict. Start here. |
| `tools/virtual-audio.sh` | Sourced library: find a loopback device, enumerate what InferNode sees, make a tone, measure a recording's energy at one frequency. |
| `tools/virtual-mic.sh` | Speak into a running InferNode without speaking: plays a file into the loopback device. |
| `tools/transcribe-pcm.sh` | Turn a recording back into text with the same local STT helper the stack uses. How you check what was actually said. |
| `tools/mac/voice_session.py` | Drive the desktop: boot it, enter voice mode, say the wake word, speak a request, read the screen. Importable, and runnable on its own (`--watch`) to print every state the screen goes through. |
| `tools/mac/ui-probe.py` | One frame of the window: the Voice tile's status and the conversation pane's text. |
| `tools/mac/ui-timeline.py` (`tools/ui-timeline`) | Sub-second UI timing via screen recording. Emits one TSV row per frame (`t`, accent, blue, tile). `--check` fails if a signal is visible for less than `--dwell` (default 0.30s) or the pane blanks at send. OCR polling cannot see these events. |
| `tools/mac/window-info.swift`, `ocr.swift` | The screen readers, built on demand into `.omx/tmp/bin/`. |

Milestone screenshots from the GUI test land in `.omx/tmp/gui-voice/`.
When it fails, look there first: it captured what the screen actually
showed at the step that did not happen.

## Traps

Each of these cost real time at least once.

**A muted device is a perfect impostor.** It enumerates on both sides,
accepts playback, clocks writes at real time, and hands its input
nothing but zeros. Volume and mute are device properties, so they survive
reboots and are invisible to `#A/audiodev`. First suspect for any
silence; `tools/diagnose-virtual-audio.sh` ends by telling you how to
clear it.

**Prefer BlackHole to Rogue Amoeba Loopback.** A Loopback device carries
audio only while its application runs, and is often configured to monitor
to a physical output — so a test that believes it is silent plays out
loud, and one that passes may be capturing system audio rather than
proving device selection worked.

**Device selection happens before boot.** `INFERNODE_AUDIO_IN` /
`INFERNODE_AUDIO_OUT`, or the machine's default devices, are read when
the emulator opens capture — during startup. Switching afterwards changes
nothing, and `#A/audiodev` is the only way to move a running system.

**Set both directions.** Pinning only the input leaves spoken replies on
the host's default output, so the test talks out loud through whatever is
plugged in.

**Say the wake word, then wait to be told it is listening.** Playing the
wake word and the request as one stream loses the first words of the
request: the listen session opens on the wake event, part-way through the
sentence. If you must join them, keep the join well under the turn gate's
800 ms silence window — otherwise the desktop commits "hey jarvis" as a
turn of its own, answers it, and *that* reply's half-duplex suppression
swallows the request behind it.

**The window server lists dead windows.** Match a window to the pid of
the process you started (`window-info` prints it), or you will capture a
window whose process is gone and get failures that look like GUI bugs.

**A window still taking focus drops keystrokes.** Press Esc-V until the
screen shows it landed rather than pressing once.

**OCR and speech recognition each mangle a glyph now and then.** `l`, `I`
and `1` draw identically in this font. Fold confusable glyphs on both
sides of a comparison — that is a statement about the reader, not
leniency about the content — and never lower a threshold to make a
mismatch go away.

**"Reply with exactly ..." is a tool-call test, not a voice test.** It
asks the model to use the `say` tool, so a weak model fails it for
reasons that have nothing to do with audio. Use a conversational request
for voice-path coverage.

**Poll for state; never sleep a guessed interval.** The one thing with no
state to poll is "the speaking has stopped", which is measured as
trailing silence on the device.

**Concurrent capture starves.** Two capture streams from the emulator on
one virtual device split the audio badly. Recording a reply from the host
with ffmpeg alongside the desktop's own capture works; a second emulator
capture does not.

## Known defects

Open at the time of writing, listed so nobody re-discovers them. All
were found by driving the desktop.

| Issue | Symptom |
| --- | --- |
| INF-27 | An unparsed tool call is drawn as the answer and read aloud — the audio transcribes as "name say parameters text ...". The GUI test fails on it deliberately: faithfully speaking JSON is the failure, not a mitigation. |
| INF-28 | Every voice turn also leaves a "Queued follow-up — not sent — delivered — 0/1" block carrying the transcript of the turn that was already answered. |
| INF-29 | The speaking indicator covers a fraction of the speech (2.3s of a 10.2s answer), flaps through five states in one turn, and its progress bar draws as a broken dashed line. |
| INF-31 | No progressive view of what is being spoken, mirroring the user's partials. Wish, not a defect. |

## Prerequisites

```sh
brew install --cask blackhole-2ch          # the loopback device
brew install ffmpeg switchaudio-osx        # recording, and default-device switching
tools/install-speech-helpers.sh            # STT, TTS, wake word
```

The GUI test additionally needs an LLM endpoint (any OpenAI-shaped URL;
it reads `~/.infernode/lib/ndb/llm` for the configured model and falls
back to whatever the endpoint serves), the Xcode command line tools, and
a logged-in desktop session whose terminal holds **Screen Recording** and
**Accessibility** permission.

`lib/lucifer/boot-voicetest.sh` is the boot the GUI test uses: the real
stack, real LLM, real helpers, with no password prompt.

## Fixtures

- `tests/fixtures/speech/elevenlabs/` — utterances with expected
  keywords in `utterances.tsv`, generated by
  `tools/generate-elevenlabs-speech-fixtures.py` (needs an API key).
- `tests/fixtures/speech/kokoro/` — synthesized locally with the Kokoro
  helper, no key and no network. Each `.meta` carries the one-line
  command that produced it. `hey_jarvis.pcm` is the wake word;
  openWakeWord ships a pretrained model only for "hey jarvis".
