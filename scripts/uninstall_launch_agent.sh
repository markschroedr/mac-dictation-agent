#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
INSTALL_ROOT="${MAC_DICTATION_INSTALL_ROOT:-$DATA_ROOT/runtime}"
PERMANENT_TRANSCRIBER="$INSTALL_ROOT/vendor/permanent-transcriber/.venv/bin/permanent-transcriber"
LAUNCH_AGENT_LABEL="${MAC_DICTATION_LAUNCH_AGENT_LABEL:-com.markschroedr.mac-dictation}"
PLIST="${MAC_DICTATION_PLIST:-$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist}"
APP_DIR="${MAC_DICTATION_APP_DIR:-$HOME/Applications/MacDictationAgent.app}"

stop_exact_process_path() {
  local executable_path="$1"
  local pid command
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$executable_path" || "$command" == "$executable_path "* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(ps -axo pid=)
}

if [[ -x "$PERMANENT_TRANSCRIBER" ]]; then
  PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT/permanent-transcriber" \
    "$PERMANENT_TRANSCRIBER" stop >/dev/null 2>&1 || true
fi

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
stop_exact_process_path "$APP_DIR/Contents/Helpers/FluidDictationService"
stop_exact_process_path "$INSTALL_ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker"
rm -f "$PLIST"
rm -rf "$APP_DIR"
echo "uninstalled: $PLIST"
echo "runtime data was left in: $DATA_ROOT"
