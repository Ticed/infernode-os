# Workflow traps

Non-obvious ways this repository wastes an afternoon. Each of these has
cost one at least once. `CONTRIBUTING.md` covers the rules; this covers
the surprises.

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

**A failed macOS build can leave `include/version.h` rewritten.**
`build-macos-sdl3.sh` stamps the version before compiling; if the build
then fails, the stamped file stays behind and shows up as an unrelated
modification in the next `git status`. The script now restores it on
failure.

## Building Limbo

**`mk install` in `appl/veltro` rebuilds every veltro module.** The
tracked `dis/veltro/*.dis` were built by a different limbo build, so
unrelated `.dis` files show up modified. `appl/cmd` and `tests` support
per-target `mk <name>.install`; `appl/veltro` does not, so restore the
unrelated ones with `git checkout` afterwards.

## Testing

**Stale test bytecode fails as though the code were broken.** The
`post-merge` hook does not reliably rebuild `dis/tests/*.dis`, and there
is no `link typecheck` error to warn you when no `.m` interface changed:
a test's expectations are compiled into its bytecode, so a binary built
before a rename still asserts the old name while the source asserts the
new one. The failure names the assertion, not the staleness, which sends
you into the wrong file. `run-tests.sh` now refuses to run when any
`dis/tests/*.dis` is older than its source.
