#!/usr/bin/env bash
set -euo pipefail

# The installer owns the definition of a healthy installation. This wrapper
# only adds read-only reporting, staging, and the final directory swap.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$SCRIPT_DIR/install-speech-helpers.sh"
PREFIX=${INFERNODE_SPEECH_HOME:-"$HOME/.local/share/infernode-speech"}
STATUS_FILE=${INFERNODE_SPEECH_SETUP_STATUS:-/tmp/infernode-speech-setup.status}
CANCEL_FILE=${INFERNODE_SPEECH_SETUP_CANCEL:-/tmp/infernode-speech-setup.cancel}
MODE=setup

usage() {
  printf 'usage: %s [--setup|--check] [--status-file PATH] [--cancel-file PATH]\n' "$0" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --setup)
    MODE=setup
    shift
    ;;
  --check)
    MODE=check
    shift
    ;;
  --status-file)
    [ "$#" -ge 2 ] || { usage; exit 2; }
    STATUS_FILE=$2
    shift 2
    ;;
  --cancel-file)
    [ "$#" -ge 2 ] || { usage; exit 2; }
    CANCEL_FILE=$2
    shift 2
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
  esac
done

[ -n "$STATUS_FILE" ] || { printf 'speech setup: empty status path\n' >&2; exit 2; }
[ -n "$CANCEL_FILE" ] || { printf 'speech setup: empty cancel path\n' >&2; exit 2; }
[ -x "$INSTALLER" ] || {
  printf 'speech setup: installer is not available at %s\n' "$INSTALLER" >&2
  exit 1
}

STATUS_DIR=$(dirname "$STATUS_FILE")
mkdir -p "$STATUS_DIR"
LOCK="$STATUS_FILE.lock"
if [ -d "$LOCK" ]; then
  oldpid=""
  if [ -f "$LOCK/pid" ]; then
    oldpid=$(cat "$LOCK/pid" 2>/dev/null || true)
  fi
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    printf 'speech setup: another setup is already running\n' >&2
    exit 1
  fi
  rm -rf "$LOCK"
fi
mkdir "$LOCK"
printf '%s\n' "$$" >"$LOCK/pid"

STATE=running
PHASE=starting
PROGRESS=0
MESSAGE="Starting local speech setup"
DETAILS=()
DETAIL_LIMIT=16
CHECK_LOG=""
INSTALL_LOG=""
STAGE=""
BACKUP=""
HAD_OLD=0
ROLLBACK_NEEDED=0
INSTALL_PID=""

safe_line() {
  local line=$1
  case "$line" in
  *API_KEY*|*api_key*|*PASSWORD*|*password*|*TOKEN*|*token*|*SECRET*|*secret*|*Authorization*|*authorization*)
    printf '%s\n' 'installer output redacted'
    ;;
  *)
    printf '%s\n' "$line" | sed -E \
      -e 's#(https?://)[^/@[:space:]]+@#\1<redacted>@#g' \
      -e 's#([?&](api[-_]?key|access[-_]?token|token|secret|password|authorization)=)[^&[:space:]]+#\1<redacted>#g'
    ;;
  esac
}

write_status() {
  local tmp="$STATUS_FILE.tmp.$$"
  {
    printf 'state=%s\n' "$STATE"
    printf 'phase=%s\n' "$PHASE"
    printf 'progress=%s\n' "$PROGRESS"
    printf 'message=%s\n' "$MESSAGE"
    for detail in "${DETAILS[@]}"; do
      printf 'detail=%s\n' "$detail"
    done
  } >"$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

publish_phase() {
  PHASE=$1
  PROGRESS=$2
  MESSAGE=$3
  printf 'phase=%s progress=%s %s\n' "$PHASE" "$PROGRESS" "$MESSAGE"
  write_status
}

publish_detail() {
  local detail
  detail=$(safe_line "$1")
  [ -n "$detail" ] || return 0
  if [ "${#detail}" -gt 180 ]; then
    detail="${detail:0:177}..."
  fi
  if [ "${#DETAILS[@]}" -ge "$DETAIL_LIMIT" ]; then
    DETAILS=("${DETAILS[@]:1}")
  fi
  DETAILS+=("$detail")
  printf '%s\n' "$detail"
  write_status
}

publish_file() {
  local file=$1
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    publish_detail "$line"
  done <"$file"
}

finish_failure() {
  local message=$1
  local next=$2
  STATE=failed
  MESSAGE="$message"
  publish_phase failed "$PROGRESS" "$MESSAGE"
  publish_detail "next: $next"
  exit 1
}

finish_cancelled() {
  STATE=cancelled
  MESSAGE="Setup cancelled; the previous installation was left unchanged"
  publish_phase cancelled "$PROGRESS" "$MESSAGE"
  publish_detail "next: press Prepare local speech again when you are ready"
  exit 130
}

cleanup() {
  if [ -n "$INSTALL_PID" ] && kill -0 "$INSTALL_PID" 2>/dev/null; then
    kill "$INSTALL_PID" 2>/dev/null || true
  fi
  if [ -n "$STAGE" ] && [ -e "$STAGE" ]; then
    rm -rf "$STAGE"
  fi
  if [ "$ROLLBACK_NEEDED" -eq 1 ]; then
    if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
      rm -rf "$PREFIX"
    fi
    if [ "$HAD_OLD" -eq 1 ] && [ -e "$BACKUP" ]; then
      mv "$BACKUP" "$PREFIX" 2>/dev/null || true
    fi
  fi
  [ -n "$CHECK_LOG" ] && rm -f "$CHECK_LOG"
  [ -n "$INSTALL_LOG" ] && rm -f "$INSTALL_LOG"
  [ -d "$LOCK" ] && rmdir "$LOCK" 2>/dev/null || true
  rm -f "$CANCEL_FILE"
}
trap cleanup EXIT HUP INT TERM

run_check() {
  local home=$1
  local output=$2
  if INFERNODE_SPEECH_HOME="$home" "$INSTALLER" --check >"$output" 2>&1; then
    return 0
  else
    return $?
  fi
}

CHECK_LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-speech-check.XXXXXX")
publish_phase checking 5 "Checking the existing local speech installation"
if run_check "$PREFIX" "$CHECK_LOG"; then
  CHECK_RC=0
else
  CHECK_RC=$?
fi
if [ "$CHECK_RC" -eq 0 ]; then
  publish_file "$CHECK_LOG"
  if [ "$MODE" = check ]; then
    STATE=complete
    publish_phase checked 100 "Local speech helpers are installed and passed helper checks"
    exit 0
  fi
  STATE=complete
  publish_phase complete 100 "Local speech helpers passed checks; nothing was changed"
  exit 0
fi
publish_file "$CHECK_LOG"
if [ "$MODE" = check ]; then
  STATE=incomplete
  publish_phase checked 100 "Local speech stack is incomplete"
  publish_detail "next: press Prepare local speech to install missing pieces"
  exit "$CHECK_RC"
fi

PARENT=$(dirname "$PREFIX")
BASE=$(basename "$PREFIX")
mkdir -p "$PARENT"
STAGE=$(mktemp -d "$PARENT/.${BASE}.setup.XXXXXX")
INSTALL_LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-speech-install.XXXXXX")
rm -f "$CANCEL_FILE"

publish_phase preparing 15 "Preparing an isolated staging directory; the existing stack is untouched"

publish_phase installing 30 "Installing the local Kokoro, wake-word, and STT helpers"
INFERNODE_SPEECH_HOME="$STAGE" "$INSTALLER" >"$INSTALL_LOG" 2>&1 &
INSTALL_PID=$!
while kill -0 "$INSTALL_PID" 2>/dev/null; do
  if [ -e "$CANCEL_FILE" ]; then
    rm -f "$CANCEL_FILE"
    kill "$INSTALL_PID" 2>/dev/null || true
    wait "$INSTALL_PID" 2>/dev/null || true
    INSTALL_PID=""
    publish_file "$INSTALL_LOG"
    finish_cancelled
  fi
  sleep 1
done
if wait "$INSTALL_PID"; then
  INSTALL_RC=0
else
  INSTALL_RC=$?
fi
INSTALL_PID=""
publish_file "$INSTALL_LOG"
if [ "$INSTALL_RC" -ne 0 ]; then
  finish_failure "The speech installer failed before the new stack was ready" \
    "read the failed stage above, fix that host requirement, and retry; the previous stack was left unchanged"
fi

STAGE_CHECK_LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-speech-stage-check.XXXXXX")
publish_phase verifying 75 "Verifying the staged helpers without using the microphone"
if ! run_check "$STAGE" "$STAGE_CHECK_LOG"; then
  publish_file "$STAGE_CHECK_LOG"
  rm -f "$STAGE_CHECK_LOG"
  finish_failure "The staged speech stack did not pass its read-only verification" \
    "fix the reported helper or model, then retry; the previous stack was left unchanged"
fi
rm -f "$STAGE_CHECK_LOG"
publish_detail "staged helpers passed the installer-owned verification"

if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
  HAD_OLD=1
  BACKUP="$PARENT/.${BASE}.previous.$$.$RANDOM"
  while [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; do
    BACKUP="$PARENT/.${BASE}.previous.$$.$RANDOM"
  done
fi
publish_phase committing 90 "Activating the verified stack without replacing it until verification passed"
if [ "$HAD_OLD" -eq 1 ]; then
  if ! mv "$PREFIX" "$BACKUP"; then
    finish_failure "Could not preserve the existing speech installation for the swap" \
      "check permissions for $PARENT and retry; no installation was changed"
  fi
fi
ROLLBACK_NEEDED=1
if ! mv "$STAGE" "$PREFIX"; then
  finish_failure "Could not activate the verified speech installation" \
    "check permissions for $PARENT and retry; the previous stack will be restored"
fi
STAGE=""

LIVE_CHECK_LOG=$(mktemp "${TMPDIR:-/tmp}/infernode-speech-live-check.XXXXXX")
publish_phase verifying 95 "Checking the active stack after activation"
if ! run_check "$PREFIX" "$LIVE_CHECK_LOG"; then
  publish_file "$LIVE_CHECK_LOG"
  rm -f "$LIVE_CHECK_LOG"
  finish_failure "The activated speech stack failed its final verification" \
    "retry after fixing the reported host requirement; the previous working stack was restored"
fi
publish_file "$LIVE_CHECK_LOG"
rm -f "$LIVE_CHECK_LOG"

ROLLBACK_NEEDED=0
if [ "$HAD_OLD" -eq 1 ]; then
  rm -rf "$BACKUP" 2>/dev/null || true
fi
STATE=complete
publish_phase complete 100 "Local speech helpers are installed and verified"
publish_detail "microphone: grant Lucia access in macOS Privacy & Security when prompted"
publish_detail "audio: helper checks do not test microphone or speaker behavior"
exit 0
