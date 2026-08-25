# Workflow traps

Non-obvious ways this repository wastes an afternoon. Each of these has
cost one at least once. `CLAUDE.md` covers the rules; this covers the
surprises.

## Building

**`mk nuke` at the repo root deletes the tracked `dis/` runtime tree.**
Root nuke walks `$DIRS` (`$EMUDIRS` + `appl`). appl's nuke deletes
`$DISBIN`, and for appl that is committed `dis/` — about 900 `.dis`
files a fresh clone needs in order to boot. Afterward the emulator dies
with `panic: loading "/dis/emuinit.dis": ... does not exist`, and
`git status` shows a wall of deletions that look like a bad merge.
Nothing is permanently lost: `git checkout -- .` restores the tree.
`mk emunuke` walks `$EMUDIRS` only and is the safe emulator-only clean.
On Posix, root `mk nuke` now refuses unless `NUKE_DIS=1` is set.
`cd appl && mk nuke` is unguarded and still deletes `dis/`.

**An Android build poisons the next host build.** `build-android-apk.sh`
cross-compiles `lib9/`, `libmath/`, `libmp/`, `libsec/` **in place**,
leaving ELF/aarch64 `.o` files in those source directories. A later host
`mk` sees them as up to date, skips them, and `ar`s them into the macOS
`.a`. It surfaces as `ranlib: warning: archive member 'X.o' not a mach-o
file`, then `Undefined symbols for architecture arm64` (`_argv0`,
`_infgetwd`, `_isNaN`) when linking `limbo`.

```sh
# in each affected lib dir
mk nuke && mk install
# verify: want 0
find lib9 -name '*.o' -exec file {} \; | grep -c ELF
```

**`./makemk.sh` does not leave a usable `lib9.a`.** It builds only enough
of `lib9` for `mk` itself; the archive afterwards lacks `argv0` and
`infgetwd`, so `limbo` will not link until `lib9` gets its own
`mk nuke; mk install`. Bootstrap order that works in a fresh worktree:

```sh
./makemk.sh
for d in lib9 libbio libmath libmp libsec; do (cd $d && mk nuke && mk install); done
(cd limbo && mk install)
```

**Android SDK/NDK locations are discovered, not exported.** A standard
Android Studio install lives at `~/Library/Android/sdk` (NDK under
`ndk/<version>`, e.g. `29.0.14206865`) and does not set `ANDROID_HOME`
or `ANDROID_NDK_HOME`. `tools/android-speech-preflight.sh` searches that
path, `$ANDROID_HOME` / `$ANDROID_SDK_ROOT` / `$ANDROID_NDK_HOME`, and
the older `~/Android/Sdk` default, then writes `android-app/local.properties`.
A worktree without `MacOSX/arm64/bin` still cannot run the full APK
script — the preflight names the bootstrap — but Kotlin or manifest
changes can use `gradlew assembleDebug` because `jniLibs/` and
`assets/inferno-root/` are already staged.


## Building Limbo

**`mk install` in `appl/veltro` rebuilds every veltro module.** The
tracked `dis/veltro/*.dis` were built by a different limbo build, so
unrelated `.dis` files show up modified. `appl/cmd` and `tests` support
per-target `mk <name>.install`; `appl/veltro` does not, so restore the
unrelated ones with `git checkout` afterwards. `dis/veltro/ninepsrc.dis`
is installed but untracked — delete it.

**Running the emulator dirties `lib/lucifer/theme/current`.** It is
runtime state. Restore it before committing.

**A test that loads a server module in-process needs a `_marker`.** When
a test declares a second module interface carrying only `init`, limbo
conflates the two interfaces; adding `_marker: fn();` to the test's own
module declaration keeps them apart. Pattern in
`tests/speech9p_voice_test.b`.

## Testing

**Inferno's shell does not put write errors in `$status`.** `echo 'bogus'
> /dev/audioctl` reports success even when the device rejects the verb;
only a failure to *open* the redirect surfaces. Never use `$status` after
an `echo >` to prove a ctl write was accepted — read the value back, or
the claim is unfalsifiable. This produced a wrong root cause once
(INF-18).

**`dd` inside the emulator reports short reads.** `0+N records in` means
every read was short, so `bs*count` is **not** the byte count — write to
a real file and `stat` it. Size the sample so startup latency does not
dominate: a 3s sample measured 7% low where a 60s sample measured 1.4%
low.

**`speech_kokoro_test` prints PASS but the emulator never exits.**
Pre-existing, bisected to before the voice-mode work; bare
`/dev/audio` + `audioctl` writes exit cleanly, so it is something
specific to that test's two-server say path. Run it under `timeout` and
treat exit 124 with PASS output as a pass until it is root-caused.

**Two-server emulator tests must unmount both mounts in teardown**, or
the emulator never halts.

**A merge leaves test bytecode stale, and a stale test fails as though the
code were broken.** The `post-merge` hook does not reliably rebuild
`dis/tests/*.dis`. There is no `link typecheck` error to warn you when no
`.m` interface changed, because the test's expectations are compiled into
the bytecode: after the `/n/speech` to `/mnt/speech` migration,
`voice_scripts_test` failed two assertions that check the scripts name
`/mnt/speech/ctl` — which they do. The binary still expected `/n/speech/ctl`
(INF-63). Five test binaries were stale on that merge, including the
migration's own new `veltro_security_test`. Before believing any test
failure on a freshly merged tree, compare timestamps:

```sh
for b in tests/*_test.b; do d=dis/tests/$(basename $b .b).dis
  [ -f "$d" ] && [ "$b" -nt "$d" ] && echo "STALE $d"; done
```

The danger is not the lost time. It is that the obvious reading of those
failures is "the change is broken", which leads to editing correct code so
it matches a stale test.

**A test fixture under `/tmp` outlives the emulator.** `-r.` roots the
emulator at the checkout, so an in-emu `/tmp/x` is the host's `tmp/x` and
is still there on the next run. Where a test waits for a state file to
reach a value, the previous run's record is already in place when the
wait begins — and a poll that reads before it sleeps matches it at once,
so the test races past the process it meant to wait for. This made
`remote_speech_topology_test/CaptureWatcherRecovery` alternate
fail/pass/fail/pass indefinitely, each run's outcome fixed by the record
the run before it left (INF-57). Remove the file the wait reads before
starting whatever writes it; cleaning up at the end does not help,
because a killed run never reaches its teardown.

**speech9p tests fake the host helpers through ctl** — `wakebin
/bin/echo ...`, `wakebin /bin/sh -c "sleep 2; echo ..."`. Nested quoting
through `runcmd`/`devcmd` is mangled but tolerated, because `sh -c`
ignores the extra positional arguments.

That is not only a test convenience: it is what those keys *are*.
`kokorobin`, `whisperstreambin` and `wakebin` hold whole command lines,
so writing one is equivalent to running a host command and no value
validation can make it safe — an attempt to constrain them to paths
turned 12 passing tests red. They are closed by `seal on` at the end of
boot instead (INF-56, `docs/SPEECH-ARCHITECTURE.md` §10.8). Read this
entry before hardening anything on the speech ctl.

**Do not run the full suite unless asked.** `./run-tests.sh` takes 30–60+
minutes here, several tests hang in a non-tty environment, and
`interop_test` aborts the emulator on macOS (LibreSSL DSA), killing the
in-emu runner midway. Run the tests for the modules you touched, plus
their neighbours.
