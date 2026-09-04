#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
INSTALL_ROOT="${MAC_DICTATION_INSTALL_ROOT:-$DATA_ROOT/runtime}"
LAUNCH_AGENT_LABEL="${MAC_DICTATION_LAUNCH_AGENT_LABEL:-com.markschroedr.mac-dictation}"
PLIST="${MAC_DICTATION_PLIST:-$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist}"
APP_DIR="${MAC_DICTATION_APP_DIR:-$HOME/Applications/MacDictationAgent.app}"
APP_BIN="$APP_DIR/Contents/MacOS/MacDictationAgent"
if [[ -f "$PLIST" ]]; then
  [[ "$(plutil -extract ProgramArguments.0 raw "$PLIST")" == "$APP_BIN" ]] || {
    echo "LaunchAgent belongs to another app; refusing uninstall" >&2; exit 1;
  }
  INSTALL_ROOT="$(plutil -extract EnvironmentVariables.MAC_DICTATION_AGENT_ROOT raw "$PLIST")"
  DATA_ROOT="$(plutil -extract EnvironmentVariables.MAC_DICTATION_DATA_ROOT raw "$PLIST")"
fi
PERMANENT_TRANSCRIBER="$INSTALL_ROOT/vendor/permanent-transcriber/.venv/bin/permanent-transcriber"
if [[ -x "$PERMANENT_TRANSCRIBER" ]]; then
  STATUS="$(PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT/permanent-transcriber" "$PERMANENT_TRANSCRIBER" status)"
  RUNNING=0
  for field in capture.running workers.quick.running workers.relaxed.running; do
    if [[ "$(plutil -extract "$field" raw -o - - <<< "$STATUS")" == true ]]; then RUNNING=1; fi
  done
  if [[ "$RUNNING" == 1 ]]; then
    PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT/permanent-transcriber" "$PERMANENT_TRANSCRIBER" stop
  fi
fi
launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
while read -r pid; do
  [[ -n "$pid" ]] || continue
  if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$APP_BIN" ]]; then
    kill -TERM "$pid"
    for _ in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "App did not stop; uninstall aborted" >&2; exit 1
    fi
  fi
done < <(pgrep -x MacDictationAgent || true)
ARCHIVE="$DATA_ROOT/uninstalled/$(uuidgen)"
mkdir -p "$ARCHIVE"
if [[ -f "$PLIST" ]]; then mv "$PLIST" "$ARCHIVE/launch.plist"; fi
if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$ARCHIVE/MacDictationAgent.app"; fi
echo "App and launch configuration archived in: $ARCHIVE"
echo "Recordings, transcripts, credentials, models, and runtime remain in: $DATA_ROOT"
