# Remote desktop: using a headless InferNode from another one's screen

A Raspberry Pi in a cupboard, a Jetson, a QEMU guest: InferNode machines
often have no screen. From any InferNode that has one, `cpu(1)` runs
programs **on** the headless machine that draw **on** your screen:

```
cpu tcp!pi.local wm/wm wm/sh
```

opens a window that is the other machine's desktop. The window manager
and the shell in it run over there; your machine lends only its screen,
mouse and keyboard.

This is stock Inferno, not a new protocol. `cpu` exports your namespace
to the other machine over an authenticated, encrypted 9P connection;
`auxi/rstyxd` there binds your `/dev` over its own, so its programs open
your `/dev/draw`, `/dev/pointer` and `/dev/keyboard`. Everything else it
touches — files, network, CPU — is its own.

The two machines are called the **viewer** (has the screen, runs `cpu`)
and the **node** (headless, runs the listener). Either can be hosted
(macOS, Linux, Windows) or bare metal, though a bare-metal node is the
usual case.

## What you need

- A **signer**: one key that certifies who is who. Every machine that
  takes part gets a certificate from it, and a node accepts only
  callers whose certificates it signed. Make it once, on a machine you
  keep (your desktop InferNode), and never copy it anywhere.
- A **certificate for you** on the viewer, and **one for the node** on
  the node.
- The node's **listener** turned on. It is off by default on every
  install.

The whole setup is about ten minutes. Once done, each session is one
command.

## 1. Make the signer and the certificates (once, on your desktop)

In a shell in your desktop InferNode (Lucifer's shell, or `sh -l` in an
emulator). `/usr/$user` there is durable: on a hosted install it is
`~/.infernode/usr/<your login>` on the host, outside the app.

```
auth/createsignerkey -f /usr/$user/keyring/signer $user-signer
auth/mkauthinfo -k 'key=signer' $user /usr/$user/keyring/default
auth/mkauthinfo -k 'key=signer' mynode /usr/$user/keyring/node-mynode
```

1. Creates the signer. It stays in your keyring, readable by you only.
2. Issues your certificate as `keyring/default`, which is where `cpu`
   looks. If you already have a `default` you use for something else,
   give this one the name of the node's address instead (`cpu` tries
   `keyring/<the address you dial>` first) — for example
   `'/usr/'$user'/keyring/tcp!192.168.1.50'`.
3. Issues the node's certificate. Use the node's name; this is the one
   file that goes to the node.

Quote `'key=signer'`: unquoted, the Inferno shell reads it as a
variable assignment. `mkauthinfo -e ddmmyyyy` sets an expiry.

## 2. Turn on the node

### A bare-metal node (Raspberry Pi)

Power it off and put its SD card in any computer. On the card's boot
partition:

1. Copy the node's certificate to `usr/inferno/keyring/default`
   (create the directories if they are not there). On a Mac with a
   hosted InferNode, the file from step 1 is
   `~/.infernode/usr/<you>/keyring/node-mynode`.
2. Create a file `cpulisten`. Empty means the standard port,
   `tcp!*!rstyx` (6668); or put an address on its first line, e.g.
   `tcp!*!17030`.

Put the card back and boot. The console says

```
boot: cpu listener on tcp!*!rstyx (AES-256 + SHA-256, certificate /usr/inferno/keyring/default)
```

or, if the certificate is missing, that it is **not** starting and why.
Delete `cpulisten` to turn it off again.

### A hosted node

Copy the node's certificate to `/usr/$user/keyring/default` on that
machine (or keep it elsewhere and pass `-k file`), then in its shell:

```
listen -a aes_256_cbc -a sha256 'tcp!*!rstyx' auxi/rstyxd &
```

It lasts as long as that emulator. The host's firewall may ask to allow
incoming connections on port 6668.

## 3. Connect (each time)

The viewer's own desktop is busy drawing itself, so use a **second
emulator as the viewer window** — on macOS with the downloaded app:

```sh
/Applications/InferNode.app/Contents/MacOS/emu -c1 -g1024x768 \
    -r/Applications/InferNode.app/Contents/Resources \
    sh -l -c 'cpu tcp!192.168.1.50 wm/wm wm/sh'
```

(the same from a source tree: `./emu/MacOSX/o.emu …` or
`./emu/Linux/o.emu …` with `-r$PWD`). The window that opens is the
node's desktop: its window manager, and a shell running on the node.
The first connection takes a few seconds for the handshake. Closing
the node's window manager ends the session.

The address must be one the viewer can reach: a laptop on guest Wi-Fi
often cannot reach a wired address on another network, and the other
way round. `cpu tcp!host!port` names a non-standard port; the default
is `rstyx`.

## What a session can and cannot do

- **Authenticated both ways.** The node accepts only certificates from
  your signer, and you know you reached the node you certified.
  Programs on the node run as your certificate's name, which is also
  what your `/dev/user` says — keep them the same (step 1 does), or
  programs that check, like acme, refuse to work.
- **Encrypted and tamper-evident.** AES-256 for the whole session, and
  a SHA-256 MAC on every record, so bytes altered or cut on the way are
  an error rather than a surprise. `cpu` asks for both by default; a
  bare-metal node's listener requires both and refuses cleartext,
  cipher-only and MAC-only callers.
- **A desktop's powers, no more** (bare metal). The listener starts in
  the desktop's narrowed namespace: a session can run programs and use
  the node's files, but has no raw card, no GPIO pins and no
  `/dev/sysctl` — it cannot rewrite the card or reboot the machine.
  That is what the serial and network consoles are for
  ([BAREMETAL.md](BAREMETAL.md) section 7).
- **Revoking** means a new signer and new certificates; there is no
  revocation list. Treat the signer like the master key it is.

## When it does not work

| message | meaning |
|-|-|
| `cpu: cannot find certificate in /usr/…/keyring/` | No `default` and no file named for the address you dialled (step 1). |
| `cpu: authentication failed: pk doesn't match certificate` | Your certificate and the node's come from different signers — often a node still holding an old key. |
| `unsupported client algorithm: none` (on the node) | The viewer asked for cleartext; drop `-C none`. |
| `client omitted required integrity algorithm` (on the node) | The viewer asked for encryption without the SHA-256 MAC: an older release's `cpu -C aes_256_cbc`. Use `cpu -C 'aes_256_cbc sha256'`. |
| `cpu: dial: … timed out` | The viewer cannot reach that address and port: network, firewall, or the listener is not running. |
| `boot: /n/dos/cpulisten is set but …/keyring/default is missing` | Step 2.1 not done, or the file is in the wrong directory. |
| acme: `can't mount /mnt/acme` | Your certificate's name differs from your user name on the viewer (step 1). |
| a blank window, slow to paint | Every screen update is a network round trip; Wi-Fi is several times slower than a cable. |

## Releases before this document

**Starting the viewer stops your running InferNode.** Before the fix
for this, the login profile (`sh -l`) killed whatever held the
secstore port, which is your other InferNode: opening a viewer this
way closed your Lucifer desktop. On such a release, quit the desktop
before starting a viewer.

Older releases also need three things done by hand: `bind -a '#i' /dev`
before `cpu` (its draw-device bind named the wrong device); `cpu -C
'aes_256_cbc sha256'` (it defaulted to cleartext); and `mkauthinfo … > file`
instead of a file argument (it ignored it). Bare-metal kernels before
the `cpulisten` card file need the listener started by hand from the
serial or network console:
`mkdir /tmp/client; bind -a /tmp /n; listen -a aes_256_cbc -a sha256 'tcp!*!rstyx' auxi/rstyxd &`.
