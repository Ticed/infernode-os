# Testing audio without a microphone or a speaker

Every audio and voice test used to need hardware in the room: a working
microphone, a quiet enough space, a person willing to talk to it, and a
capture gain that happened to suit whatever the test assumed. That makes
audio the least repeatable part of the tree. A failure could mean a
regression, or a fan, or an input volume someone changed last week
(INF-25 was the second of those, and it cost a day to prove it).

A **loopback audio device** removes all of it. It is a software audio
driver that presents one output and one input wired together: whatever
is played to the output arrives on the input, sample for sample. Point
InferNode's playback at it and its capture at the same device, and you
have a microphone that says exactly what the test tells it to say, on
every run, on any machine.

It is not a mock. The audio still crosses SDL3, CoreAudio, `/dev/audio`,
`speechshim9p`, the listen helper and the turn gate. Only the microphone,
the speaker and the room are gone. And nothing is hidden: route the
device to real speakers and you hear exactly what the test is playing.

## Install the driver

[BlackHole](https://github.com/ExistentialAudio/BlackHole) (MIT):

```sh
brew install --cask blackhole-2ch
```

It needs an administrator password once, and no application afterwards —
the driver carries audio on its own, which is what makes it safe to rely
on in an unattended run.

Rogue Amoeba's **Loopback** is also accepted when present, but it carries
audio only while the Loopback application is running, and its devices are
frequently configured to monitor to a physical output — in which case a
test that thinks it is silent plays out loud through your speakers.
Prefer BlackHole.

A freshly installed BlackHole device can come up **muted**, and a muted
device is a perfect impostor: it enumerates, it accepts playback, it
clocks the writes at real time, and it hands its input nothing but
zeros. Volume and mute are device properties, so a reboot does not clear
them. Unmute it once:

```sh
SwitchAudioSource -t output -s 'BlackHole 2ch'      # brew install switchaudio-osx
osascript -e 'set volume output volume 100' -e 'set volume without output muted'
SwitchAudioSource -t output -s 'MacBook Pro Speakers'
```

Check what was found:

```sh
tools/virtual-mic.sh --device      # the device the rig will use
tools/virtual-mic.sh --list        # every device InferNode can see
```

Override the choice with `INFERNODE_VIRTUAL_AUDIO_DEVICE='<name>'`.

## Choosing the device

Two environment variables select the host audio device before the
emulator starts:

```sh
export INFERNODE_AUDIO_IN='BlackHole 2ch'      # capture
export INFERNODE_AUDIO_OUT='BlackHole 2ch'     # playback
```

They must be set before `exec`, not written afterwards to `#A/audiodev`,
because the voice stack opens capture during startup. An unknown name is
not fatal: the emulator warns and falls back to the system default.

**Set both.** Pinning only the input leaves spoken replies on the host's
default output, so the test talks out loud through whatever is plugged
in. Pinning both keeps the whole run inside the driver.

`#A/audiodev` remains the way to change the device on a running system;
see [SPEECH-REMOTE-AUDIO.md](SPEECH-REMOTE-AUDIO.md).

## Speaking into a running InferNode

`tools/virtual-mic.sh` plays a file into the loopback device, which any
InferNode listening on that device hears as speech.

```sh
# terminal 1 — the thing under test
export INFERNODE_AUDIO_IN=$(tools/virtual-mic.sh --device)
export INFERNODE_AUDIO_OUT=$INFERNODE_AUDIO_IN
tools/speech-test.sh -w -d

# terminal 2 — say something to it
tools/virtual-mic.sh tests/fixtures/speech/elevenlabs/voice_submit.pcm
```

It takes raw 16 kHz mono signed 16-bit little-endian PCM (the format of
the committed fixtures) or anything `afconvert` can read — `.wav`,
`.m4a`, `.aiff` — which it converts first. That covers the whole
lucifer desktop too: launch it with the same two variables and drive
voice mode from the second terminal.

## The automated tests

Both run inside `tools/speech-regress.sh` on macOS and skip (exit 77)
when no loopback driver is installed.

| Test | What it proves |
| --- | --- |
| `tests/host/virtual_audio_loopback_test.sh` | A tone played by InferNode comes back through the device, concentrated at the frequency that was played. This is the rig checking its own carrier, and the only test in the tree that asserts playback produced a signal rather than that the write returned. |
| `tests/host/virtual_mic_speech_test.sh` | A committed speech fixture played into the device is transcribed by the live stack: partials stream, a turn commits, and the transcript carries the expected keywords. |
| `tests/host/virtual_voice_turn_test.sh` | A whole turn over one device: the wake word fires on audio that crossed it, the utterance commits, the spoken reply is recorded back off the device, and no second turn appears — so half-duplex suppression held while the reply was on the capture side. |
| `tests/host/gui_voice_turn_test.sh` | The same turn through the desktop, with the loopback device set as the machine's default input and output before it starts, so it is picked up like any headset. Every step is asserted by reading the window with OCR — the Voice tile lighting up, partials in the unsent turn, the "Sending in Ns" countdown counting down, the answer drawn on screen — and the spoken answer is recorded off the device, transcribed, and required to match the text on screen **word for word**. It also refuses to pass an answer that is an unparsed tool call: faithfully speaking a JSON object aloud is the failure, not a mitigation. |

The speech test is the one that could not exist before.
`elevenlabs_speech_e2e_test.py` feeds the same fixtures to the listen
helper over stdin, which proves the model and the gate but never touches
a device. Here the audio arrives the way a person's voice does — and
because a device never reaches end-of-file, a committed turn can only
have come from the silence gate, not from a flush at the end of input.

Point it at a different fixture with `VIRTUAL_MIC_FIXTURE=<id>`, where
the id is a row in `tests/fixtures/speech/elevenlabs/utterances.tsv`.

## Driving the desktop

`tests/host/gui_voice_turn_test.sh` runs the whole thing through the GUI:
it points the machine's default input and output at the loopback device,
boots the desktop with `lib/lucifer/boot-voicetest.sh`, presses Esc-V,
speaks, and reads the result off the screen.

Two small Swift helpers do the reading, built on demand into
`.omx/tmp/bin/`:

| Tool | What it does |
| --- | --- |
| `tools/mac/window-info.swift` | Lists on-screen windows with their owning pid, so a test captures the window of the emulator it started rather than one the window server has not finished retiring. |
| `tools/mac/ocr.swift` | Runs Vision text recognition over a screenshot, with bounding boxes. |
| `tools/mac/ui-probe.py` | Reads one frame of the InferNode window: the Voice tile's status and the text of the conversation pane. |
| `tools/mac/voice_session.py` | Drives the desktop — boot, Esc-V, wake word, speak, read the screen. Imported by the test; run it directly (`--watch`, `--say`) to see a turn happen. |
| `tools/mac/ui-timeline.py` | Times what the window draws to 0.05s, via screen recording. OCR polling cannot see a tile that flashes for 0.15s. |
| `tools/diagnose-virtual-audio.sh` | When the device is silent: separates the emulator's playback, its capture, the driver, and microphone authorization. |

Milestone screenshots land in `.omx/tmp/gui-voice/`, which is the first
place to look when the test fails: it captured what the screen actually
showed at the step that did not happen.

The test needs a logged-in desktop session whose terminal holds **Screen
Recording** (to read the window) and **Accessibility** (to press Esc-V)
permission. It skips without them, and skips on any machine with no LLM
endpoint to answer the turn.

## Limits

- **macOS only, for now.** Device selection lives in the SDL3 backend
  (`emu/MacOSX/audio-sdl3.c`). Other backends report `unsupported` from
  `#A/audiodev` and the tests skip. The design is a platform hook in
  `emu/port/audio.h`, so a Linux backend can register the same two
  functions and the rig works unchanged.
- **Microphone authorization still applies.** macOS gates capture per
  application, including from a virtual input, so an unapproved terminal
  records silence from BlackHole exactly as it would from a real
  microphone. The tests report that as a skip, not a pass.
- **The wake fixture needs the Kokoro helper to regenerate.**
  `tests/fixtures/speech/kokoro/hey_jarvis.pcm` is committed, and its
  `.meta` carries the one-line command that produced it. Use
  `USER_VOICE` (`bm_george`) from `tools/mac/voice_session.py`, not
  Veltro's `af_bella`. A different wake word means synthesizing a new
  one, and openWakeWord ships a pretrained model only for "hey jarvis".
