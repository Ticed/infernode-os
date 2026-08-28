#!/bin/sh
# Install git hooks from hooks/ into .git/hooks/
# Run once after clone: ./hooks/install.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKDIR="$(git -C "$ROOT" rev-parse --git-path hooks 2>/dev/null)" || {
    echo "cannot locate the Git hooks directory" >&2
    exit 2
}
case "$HOOKDIR" in
    /*) ;;
    *) HOOKDIR="$ROOT/$HOOKDIR" ;;
esac
if [ ! -d "$HOOKDIR" ]; then
    echo "Git hooks directory is missing: $HOOKDIR" >&2
    exit 2
fi

# Iterate every executable file in hooks/ except install.sh itself.
# Avoids having to update this loop each time a new hook is added.
for hook in "$ROOT"/hooks/*; do
    name="$(basename "$hook")"
    case "$name" in
        install.sh|*.md|*.txt) continue ;;
    esac
    [ -f "$hook" ] || continue
    cp "$hook" "$HOOKDIR/$name"
    chmod +x "$HOOKDIR/$name"
    echo "installed $name"
done
