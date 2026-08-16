# Remote Speech: 9P Audio Composition

> **Scope.** This document covers *remoting* — putting the speech server on a
> different host from the audio device, exploiting Plan 9 namespace
> composition. For the architecture of `speech9p` itself (file tree, engines,
> data flow, agent integration), see
> [SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md).
>
> **Phase 2 status.** The Mac-local voice mode
> ([SPEECH-VOICE-ONLY-PHASE1.md](SPEECH-VOICE-ONLY-PHASE1.md)) is Phase 1.
> Phase 2 starts from the functionally frozen Phase 1 implementation once its
> automated gates pass. Physical Mac/GUI acceptance may be deferred and combined
> with Phase 2 acceptance; it remains mandatory before the overarching voice
> feature merges into `dev`. The loadable `SpeechEngine` ABI, provider-backed
> module, namespace audio routing, and `lib/voice/speech-*` launch scripts are
> already implemented; Phase 2 is now the validation, hardening, and distribution
> milestone rather than a green-field remote-audio implementation.
>
> **Security status: development only.** The current examples use anonymous
> `listen -A` / `mount -A` connections and export the host's broad `/dev`
> tree. That does not preserve InferNode's intended narrow, per-process
> namespace capabilities: any client that can reach the listener receives more
> authority than speech needs. A firewall, NAT, or private overlay can reduce
> reachability, but it does not provide capability attenuation inside
> InferNode. Keep these topologies limited to trusted development environments
> until the post-Phase 2 security audit replaces the broad exports with
> authenticated, speech-specific namespaces.

## Phase 2 Definition and Gates

Phase 2 comprises:

1. Validate all three documented topologies with real hosts, including a Mac
   terminal and Jetson/other inference host, device permissions, disconnects,
   reconnects, latency, microphone capture, and playback.
2. Turn the existing launch scripts into a repeatable remote deployment recipe
   with explicit helper/model prerequisites and observable failure states.
3. Maintain a reproducible, pinned Parakeet EOU conversion helper and checksum
   manifest. The published F16 GGUF is fetched from an immutable repository
   revision and verified before use; Whisper remains the runtime fallback when
   the verified artifact or native build is unavailable.
4. Replace Phase 1's daemon-local one-follow-up latch with server-owned bounded
   queue state, visible depth, and queued-turn cancel/replace behavior.
5. Consider native 24000/48000 Hz audio only after topology validation; 22050
   Hz remains the supported default and higher rates are not a release blocker.

The exact wake phrase/model is intentionally not a Phase 2 acceptance item.

Automated loopback and mock coverage must precede each topology change. Work on
independent Phase 2 items continues when a particular gate reaches real
two-host audio or subjective GUI/latency judgement. Those human-only gates stay
open and are not marked complete from non-interactive tests.

Completing the functional Phase 2 gates does not make this transport
release-ready. A separate security-audit gate must verify authentication,
least-authority namespace exports, mount ownership and teardown, control-path
attenuation, and adversarial-client behaviour before the overarching voice
feature can merge into `dev`.

### Implemented Foundation

- `speechshim9p` takes playback and capture devices as namespace paths through
  `audiodev`, `capturedev`, and `micmode device`.
- `speech9p` forwards routing controls and consumes a single provider mount.
- The loadable `SpeechEngine` `.dis` contract and provider reference module are
  available in-tree.
- `/lib/voice/speech-terminal`, `speech-engine`, and `speech-capture` automate
  the current export, import, provider, and ctl wiring, including bounded
  startup retries, observable state, terminal/capture remount recovery, and
  explicit mount, listener, and helper cleanup on terminal failure.
- `remote_speech_topology_test` exercises provider and fake-audio TCP mounts,
  bounded initial failure, disconnect/remount, playback, and stdin capture in
  one emulator. It proves the namespace/dataflow contract, not real-host
  latency or device permissions.
- `tools/parakeet-eou.manifest` pins the converter, source checkpoint, and
  published F16 GGUF. The installer and `tools/convert-parakeet-eou.sh` reject
  artifacts whose size or SHA-256 does not match the manifest.
- `luciuisrv` owns the one-entry follow-up queue. Its read-only
  `conversation/voicequeue` record exposes `depth`, `capacity`, `state`, and
  the display-only queued `text`; `conversation/voicequeue-ctl` accepts
  `cancel` or `replace <text>`. States are `empty`, `queued`, `delivering`,
  `delivered`, `rejected`, `cancelled`, and `replaced`; Lucia locally presents
  `disconnected` when the authoritative record cannot be read. Reading the
  status never consumes the queued turn. `voicemode` no longer treats a local
  latch as the queue authority.
- Lucia renders the queued transcript as an explicitly unsent conversation
  tile with persistent depth/capacity, queue-scoped Cancel, and an isolated
  replacement editor. Atomic replacement never consumes or mutates the typed
  compose buffer or the active speech draft.

### Deferred Human Gates

These gates do not block starting or continuing independent Phase 2 work. They
do block final Phase 2 acceptance and the overarching voice-feature merge into
`dev`:

- Real cross-host audio with two machines and their device/network permissions.
- Jetson or equivalent remote helper/model installation and sustained use.
- Physical confirmation of queue/backpressure UX and disconnect/recovery
  behaviour; the namespace and renderer contracts are automated.

## Current Design

`speech9p` presents the stable speech interface at `/n/speech` and consumes a
single **provider mount** (default `/n/speechshim`, served by `speechshim9p`)
for all streaming voice I/O — see the provider contract in
[SPEECH-ARCHITECTURE.md](SPEECH-ARCHITECTURE.md). Two properties make
remoting a pure composition exercise:

1. **The provider is a mount.** `echo 'provider /n/x' > /n/speech/ctl`
   points the whole voice pipeline (listen, wake, kokoro say, cancel) at any
   namespace serving the contract — local shim, parakeet export, or a mount
   from another Infernode instance across the network.
2. **The provider's audio I/O is namespace paths.** `speechshim9p` plays
   through `audiodev` (default `/dev/audio`) and, in `micmode device`,
   captures s16le PCM from `capturedev` (default: `audiodev`) and pumps it
   into the STT/wake helpers' stdin. An imported `/dev/audio` from another
   machine drops in with one ctl write — no `bind` required.

The default deployment assumes the user is physically at the machine running
the stack; the topologies below relocate the pieces.

---

## The Three Topologies

### 1. Everything local (default)

What `lib/lucifer/boot.sh` sets up: `speechshim9p` + `speech9p` on the local
machine, provider `/n/speechshim`, helpers (whisper.cpp stream, Kokoro,
openWakeWord) installed on the local host, `micmode helper` so the helper
CLIs grab the local microphone directly. A parakeet export mounted at
`/n/parakeet` is the same topology with a different provider value.

### 2. Remote processing, local microphone and speakers

The local machine is the I/O terminal; a beefier host (Jetson, second
Infernode instance) runs STT/TTS. Audio is forwarded from the local mic and
played on the local speakers, but everything stays a locally mounted
namespace.

```
Local terminal (mic + speakers)          Remote engine (helpers installed)
───────────────────────────────          ─────────────────────────────────
listen -A 'tcp!*!17010' export /dev ───► mount ... /n/term
                                         speechshim9p &
                                         listen -A 'tcp!*!17019' export /n/speechshim
mount -A 'tcp!<remote>!17019' /n/remotespeech ◄──┘
echo 'provider /n/remotespeech' > /n/speech/ctl
echo 'audiodev /n/term/audio' > /n/speech/ctl     # resolved in the REMOTE namespace
echo 'micmode device' > /n/speech/ctl
```

**Local — export the audio device, mount the remote provider:**
```sh
listen -A 'tcp!*!17010' export /dev &
mount -A 'tcp!<remote-ip>!17019' /n/remotespeech
echo 'provider /n/remotespeech' > /n/speech/ctl
```

**Remote — import the terminal's audio, serve the provider:**
```sh
mount -A 'tcp!<local-ip>!17010' /n/term
speechshim9p &
listen -A 'tcp!*!17019' export /n/speechshim &
```

**Audio routing (writable from the local side — `speech9p` forwards these
keys to the provider's `ctl`):**
```sh
echo 'audiodev /n/term/audio' > /n/speech/ctl
echo 'micmode device' > /n/speech/ctl
```

Now the remote shim synthesizes and recognizes, but reads its PCM from —
and plays it back to — the terminal's audio device over 9P. Note the
`audiodev` value is a path in the *remote* shim's namespace.

The same topology is automated by two launch scripts:

```sh
# Remote engine first:
sh /lib/voice/speech-engine tcp!<local-ip>!17010

# Local terminal second:
run /lib/voice/speech-terminal tcp!<remote-ip>!17019
```

The terminal script reuses `/lib/voice/listen` (including audio pre-warm and
buffer caps), mounts the exported provider, selects it in `/n/speech/ctl`, and
requires both the mounted provider and `speech9p` to accept `duplex half`
before publishing a connected state. It must be entered with the Inferno
shell's `run` builtin, not as a child `sh` process, so the provider mount stays
in the current namespace and remains visible to `speech9p`. The engine script
imports the terminal device tree, starts
an isolated `speechshim9p` mount, selects device-fed PCM, and exports the
provider contract. Optional port and mount arguments are documented in each
script's usage header. Initial network mounts retry once per second for 30
attempts by default (the attempt count is an optional argument). The terminal
then monitors the provider mount and remounts it after a disconnect. Its
current state is readable at `/tmp/speech-terminal.state`; an optional sixth
argument overrides `/n/speech/ctl` for isolated tests or alternate speech
stacks. The engine writes startup and listener state to
`/tmp/speech-engine.state`. Both paths can be overridden by their documented
state-file arguments.

`speech-terminal` gives `/lib/voice/listen` a private endpoint-state path so
terminal failure can close the actual announced TCP endpoint before stopping
the listener process group. `/lib/voice/listen` accepts that optional second
argument for supervised callers; ordinary one-argument use is unchanged.

### 3. Remote capture device (e.g. Infernode on an Android phone)

The phone contributes only its microphone; processing and playback stay
wherever topology 1 or 2 put them. A Tailscale address is preferred because it
is stable across Wi-Fi changes; a same-LAN Wi-Fi address is the fallback.

Build and start the Android frontend from the Mac:

```sh
./build-android-apk.sh --gui sdl3 --abi arm64-v8a
tools/android-speech-frontend.sh --install
```

Pass `--device <adb-serial>` when more than one Android device is attached, or
`--ip <phone-address>` to override the automatic `tailscale0`/`wlan0`
detection. The tool grants `RECORD_AUDIO`, launches the real SDL activity in
`speech-export` mode, and waits until TCP port 17010 is reachable. The SDL
activity is required: `/dev/audio` uses SDL3's Android AAudio backend, so the
legacy interactive-shell activity is not a valid audio-service host.

#### Microphone authorization is a separate condition from reachability

Android silences an app's microphone whenever the app stops being "in use".
Capture then fails in the one way nothing reports: `/dev/audio` still answers
every read at full rate, and every sample is zero. The 9P export is healthy,
the mount succeeds, the port is reachable — and the STT helper simply waits,
because digital silence is indistinguishable from a quiet room. A standardized
acoustic fixture run therefore *times out* rather than failing.

Measured on a physical Android 13 device, before the fix: with the SDL activity
visible, `dumpsys audio` reported `not silenced` and the captured PCM was ~94%
non-zero; pressing HOME flipped the same recording session to `silenced` about
a second later, and every subsequent sample was exactly zero.

Two mechanisms keep capture authorized for a whole session:

- `InfernodeSpeechMicService`, a foreground service declared with
  `android:foregroundServiceType="microphone"`. It captures nothing itself; it
  holds the authorization so the activity's AAudio stream keeps receiving real
  samples after the activity stops being visible. The activity starts it from
  `onResume` — starting it while genuinely visible is what converts the
  while-in-use grant into one the service keeps.
- `FLAG_KEEP_SCREEN_ON` plus show-over-lock-screen in `speech-export` mode, so
  the ordinary screen timeout never backgrounds the session in the first place.

`tools/android-speech-frontend.sh` refuses to report readiness unless the
foreground service is held and any *live* recording session is `not silenced`.
`dumpsys audio` prints a historical event log rather than current state, so the
launcher only trusts `rec start` / `rec update` lines; a `rec stop` or
`rec release` describes a session that has already ended and says nothing about
the microphone the next run will get.

Inside the Android Inferno namespace, that launch mode is equivalent to:

```sh
sh /lib/voice/speech-phone 17010
```

`speech-phone` keeps `listen -A 'tcp!*!17010' {export /dev}` in the foreground.
The `-A` export is intentionally unauthenticated for Phase 2 development. Use
it only on a trusted local or Tailscale network; it is not the final security
architecture.

**Processing host (local machine in topology 1, remote engine in topology 2)
— import the phone's audio and use it for capture only:**
```sh
mount -A 'tcp!<phone-ip>!17010' /n/phone
echo 'capturedev /n/phone/audio' > /n/speech/ctl
echo 'micmode device' > /n/speech/ctl
```

`capturedev` overrides capture without touching playback: the wake word and
speech come from the phone's mic while TTS still plays through `audiodev`
(the local speakers, or wherever topology 2 pointed it). Write
`capturedev default` to fall back to `audiodev` again.

#### Keeping spoken output out of the microphone

Playback and microphone share a room in this topology, so `duplex half` is
required — but on its own it is not sufficient, and the way it fails is silent.
`playing` clears when the last sample is *accepted* by the audio device, which
is well before it has been heard, so the microphone reopens into the tail of
our own speech and the STT helper transcribes it as the user. On the physical
rig this put the assistant's reply at the head of the next turn's transcript.

Three knobs now bound that window, all in the provider:

| ctl key | Default | Covers |
| --- | --- | --- |
| `duplex half` | `full` | suppress capture while playing at all |
| `duplextail <ms>` | `300` | device drain + room reverberation after playback |
| `capturedelay <ms>` | `0` | transport delay before samples reach the pump |

`duplextail` defaults to 300 ms because the measured decay on the Mac +
Android rig was ~235 ms; the shim additionally holds the window for whatever
audio it handed the device but the device cannot have played yet.

**`capturedelay` matters enormously for topology 3 and not at all for
topology 1.** Local capture arrives immediately, so `0` is right. The Android
9P path does not: bracketed on the physical rig, `capturedelay 1500` still let
the tail of the reply through, while `2500` was clean across repeated turns.
That implies roughly **two seconds** of capture latency through AAudio, 9P over
Wi-Fi and emu buffering — far too large for `duplextail` to absorb, and worth
knowing independently of echo because it bounds conversational responsiveness.

```sh
echo 'duplex half' > /n/speech/ctl
echo 'capturedelay 2500' > /n/speech/ctl   # phone capture; leave 0 when local
```

The value is topology- and network-specific and there is currently no way to
measure it from outside the shim: playback tools do not emit at invocation, and
a read of the capture stream carries no indication of when those samples were
taken. In-band calibration is tracked separately. Until then, treat 2500 ms as
a starting point for a phone on Wi-Fi and raise it if the assistant's own words
appear in a transcript.

The current suppression state is observable in the provider's `level` file as
`mode=suppressed` with `suppress-remaining-ms=<n>`, distinct from `mode=output`
(actively playing) so an operator can tell "still shut" from "still talking".

On the processing host, the import and ctl writes are automated as:

```sh
sh /lib/voice/speech-capture tcp!<phone-ip>!17010
```

For an isolated headless proof before attaching the route to a running Lucia
desktop:

```sh
tools/speech-test.sh \
  -M 'tcp!<phone-ip>!17010 /n/phone' \
  -c 'capturedev /n/phone/audio' -c 'micmode device' -e -n 1
```

The wrapper stages the installed `speech.ctl.sh` inside the emulator root, so
the helper configuration does not depend on an ambient `/n/local` host mount.

The capture script uses the same bounded initial retry and background remount
behaviour. Its state is readable at `/tmp/speech-capture.state` (or the fourth
argument), so a missing device, a disconnect, and a successful reconnect are
observable without scraping process output. A fifth argument can override the
default `/n/speech/ctl` path for isolated tests or alternate speech stacks.

### Automated Loopback Coverage

`remote_speech_topology_test` runs a hardware-free, one-emulator TCP loopback.
It exports a deterministic fake audio file over one 9P listener, routes a
`speechshim9p` provider through that mount, exports the provider over a second
listener, and mounts it as a remote client. The test proves playback and
device-fed capture cross both mounts, an unused endpoint fails within a bound,
and the provider works after a raw client disconnect and remount. It also runs
the real `speech-capture` launcher, removes and restores its exported fake
audio endpoint, and proves its watcher observes the failure, remounts, reapplies
capture routing, and reports the recovered state. It is included in
`tools/speech-regress.sh`. The host-side `remote_speech_scripts_test.sh` runs
the provider and terminal in separate emulator processes, kills the provider
emulator so its TCP connection genuinely closes, restarts it on the same
address, and proves the real `speech-terminal` watcher retries, remounts,
reapplies provider selection and half-duplex routing through `speech9p`, and
performs a provider operation without restarting the terminal emulator.

The same host test also forces mounted-tree failures, rejected routing,
provider-listener failure after shim startup, capture retry exhaustion, and
terminal retry exhaustion. It asserts that remote mounts disappear, shim and
watcher helpers exit, and listener ports can be rebound. Finally, it kills and
reaps a successful terminal emulator as the faithful host service-supervision
substitute and proves a replacement service can immediately own the released
audio port. `tcp_test` separately proves that `hangup` closes an announced TCP
socket and permits immediate reuse; this guards the network primitive on which
listener cleanup depends.

### Automated Lifecycle Matrix

| Topology / transition | Automated owner | Required verdict |
| --- | --- | --- |
| Local provider and local fake audio: provider routing, playback, capture, raw client disconnect/remount | `remote_speech_topology_test` | Data crosses the mounted provider/audio paths once; remount remains usable. |
| Any remote role: unreachable initial endpoint and bounded startup | `remote_speech_topology_test`, `remote_speech_scripts_test.sh` | Retry count terminates, `failed ...` replaces stale state bytes, and the launcher returns. |
| Remote engine: mounted terminal lacks audio | `remote_speech_scripts_test.sh` | `failed audio`; terminal mount is absent afterward. |
| Remote engine: provider listener fails after shim startup | `remote_speech_scripts_test.sh` | Terminal/provider mounts are absent and no `Speechshim9p` worker remains. |
| Remote engine/local audio: provider rejects required ctl routing | `remote_speech_scripts_test.sh` | Terminal fails closed and does not publish `connected`. |
| Remote engine/local audio: provider process dies, restarts at the same address | `remote_speech_scripts_test.sh` | Ordered connected -> waiting -> connected transition, routing reapplied, post-remount provider write succeeds. |
| Remote engine/local audio: provider does not return before retry exhaustion | `remote_speech_scripts_test.sh` | `failed provider`; provider mount and listener endpoint are absent, and the audio port accepts a replacement export. |
| Remote capture: audio endpoint disappears and returns | `remote_speech_topology_test` | Disconnected/waiting states remain truthful; remount and capture routing recover. |
| Remote capture: audio endpoint remains absent through retry exhaustion | `remote_speech_scripts_test.sh` | `failed capture`; capture mount and watcher sidecar are absent. |
| Host service cancellation | `remote_speech_scripts_test.sh` | Terminal emulator is killed and reaped; a replacement process binds and serves the same audio port. |
| TCP announce teardown | `tcp_test` (`AnnounceHangupReleasesPort`) | `hangup` closes an announced socket and a second announce on the same address succeeds. |
| Any topology: spoken output must not re-enter capture | `speechshim_test` (`SuppressionWindowConfig`, `SuppressionObservable`) | `duplextail`/`capturedelay` are ctl-settable and bounded; the mic stays shut after playback ends and reopens on its own; `duplextail 0` restores the immediate reopen. |
| Remote capture: Android microphone authorization | `android_speech_frontend_test.sh` | The manifest declares the `microphone` foreground-service type, `speech-export` mode holds that service and keeps the screen on, and the launcher refuses to report readiness when the service is absent or a live session is `silenced` — while ignoring a `silenced` verdict from an ended session. |

The matrix covers deterministic, non-physical lifecycle transitions. New
remote lifecycle behaviour must either extend an existing owner or add a row
with an automated verdict before it is treated as implemented.

This is network transport and namespace-composition evidence, not the deferred
two-host acceptance gate: both emulator kernels still run on one host, without
physical audio devices, host permissions, real network loss, terminal-provider
recovery across separate machines, or host service-manager behaviour.

### Why It Works

The shim calls `open()` and `read()`/`write()` on the paths it was given.
Those are ordinary namespace lookups: after a 9P import, they transparently
hit the other machine's audio hardware. This is standard Plan 9 namespace
composition — location transparency falls out of the model rather than
being bolted on as a special case. The provider contract adds the same
property one level up: the entire speech engine is itself just a mount.
The optional provider `level` file travels through the same mount, so Lucia's
input/playback meters reflect PCM processed on the audio host without a
second telemetry protocol. Missing telemetry degrades to a zeroed idle record.

---

## Current GUI / Veltro Limitations (Future Work)

The final step — mounting the remote speech service — is **already supported** by the
catalog `[+]` button (`mountresource()` calls `sys->dial()` + `sys->mount()`). A catalog
entry with the Jetson's address handles it. The audio routing itself is now plain ctl
writes (`audiodev`, `capturedev`, `micmode` — no `bind` step remains), so once the
mounts exist, any shell or agent that can write `/n/speech/ctl` can rewire the audio
path.

What is still **not supported** by any GUI or agent pathway is the setup on the other
hosts:

| Step | Manual? | GUI? | Veltro? |
|------|---------|------|---------|
| `listen export /dev` on the mic/speaker host | `speech-terminal` | ✗ | ✗ |
| `mount` terminal/phone audio on the engine host | `speech-engine` / `speech-capture` | ✗ | ✗ |
| `speechshim9p &` + export on the engine host | `speech-engine` | ✗ | ✗ |
| Mount remote provider locally | via catalog `[+]` | ✓ | ✗ |
| `provider` / `audiodev` / `capturedev` / `micmode` ctl writes | yes (one-liners) | ✗ | ✓ (shell tool) |

### What Would Enable Full GUI/Agent Control

1. **`rcmd` / `ssh` tool** — to start services on the remote machine from Veltro. Without
   this, Veltro cannot set up the engine-host side at all.

2. **Catalog multi-step connect** — extend the catalog entry format to support a sequence
   of setup actions (dial, mount, ctl writes, spawn) rather than a single dial+mount. A
   "Speech on Jetson" catalog entry could encode the full setup — including the
   `provider` and audio-routing ctl writes — and execute it on `[+]`.

3. **Mount path for catalog entries** — `mountresource()` currently mounts to
   `/tmp/veltro/mnt/<slug>`. Since the provider mount point is itself a ctl value
   (`provider <path>`), this is a one-write fixup rather than a blocker.

### Recommended Approach (When Implementing)

Option A — **Launch script automation** (implemented):
`/lib/voice/speech-terminal`, `/lib/voice/speech-engine`, and
`/lib/voice/speech-capture` perform the exports, mounts, provider startup, and ctl
writes. The scripts intentionally remain explicit operator commands; they do not
invent a remote-control authority or store remote credentials.

Option B — **Catalog multi-step connect** (proper GUI solution):
Extend `CatalogEntry` with a `setup: list of string` field. Each entry is a command
(`listen`, `mount`, `echo ... > ctl`, `exec`) run in sequence on `[+]`. The catalog
file format gains a `setup=` attribute. `mountresource()` runs the setup sequence
before the final mount. This generalises beyond speech to any multi-step remote service.

Option C — **`rcmd` tool** (Veltro-native solution):
Give the agent the tool it needs: `rcmd host cmd` runs a command on a remote Inferno
instance via authenticated 9P exec. The local half is already covered — the shell tool
can perform the mounts and ctl writes. Then Veltro can set up the full pipeline
autonomously once it knows the remote host address.
