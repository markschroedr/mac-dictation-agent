#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
INSTALL_ROOT="${MAC_DICTATION_INSTALL_ROOT:-$DATA_ROOT/runtime}"
MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$DATA_ROOT/models}"
FLUID_MODEL_ROOT="${MAC_DICTATION_FLUID_MODEL_ROOT:-$MODEL_ROOT/fluid-audio}"
SUPERTONIC_TTS_MODEL_ROOT="${MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT:-$MODEL_ROOT/supertonic-3}"
LOCAL_TTS_IDLE_SECONDS="${MAC_DICTATION_TTS_IDLE_SECONDS:-300}"
LAUNCH_AGENT_LABEL="${MAC_DICTATION_LAUNCH_AGENT_LABEL:-com.markschroedr.mac-dictation}"
PLIST="${MAC_DICTATION_PLIST:-$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist}"
APP_DIR="${MAC_DICTATION_APP_DIR:-$HOME/Applications/MacDictationAgent.app}"
PREBUILT_APP="${MAC_DICTATION_PREBUILT_APP:-}"
ACTIVATE="${MAC_DICTATION_ACTIVATE:-1}"
WARM_MODELS="${MAC_DICTATION_WARM_MODELS:-0}"
ASR_PORT="${MAC_DICTATION_ASR_PORT:-8766}"
INSTALL_EXTRAS="${MAC_DICTATION_INSTALL_EXTRAS:-1}"
APP_BIN="$APP_DIR/Contents/MacOS/MacDictationAgent"
APP_HELPER="$APP_DIR/Contents/Helpers/FluidDictationService"

stop_installed_processes() {
  local executable_name="$1"
  local executable_path="$2"
  local pid command
  local -a matching_pids=()

  while read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$executable_path" || "$command" == "$executable_path "* ]]; then
      matching_pids+=("$pid")
    fi
  done < <(pgrep -x "$executable_name" 2>/dev/null || true)

  ((${#matching_pids[@]} == 0)) && return
  kill -TERM "${matching_pids[@]}" 2>/dev/null || true
  for _ in {1..20}; do
    local -a survivors=()
    for pid in "${matching_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && survivors+=("$pid")
    done
    ((${#survivors[@]} == 0)) && return
    matching_pids=("${survivors[@]}")
    sleep 0.1
  done
  kill -KILL "${matching_pids[@]}" 2>/dev/null || true
}

stop_installed_process_path() {
  local executable_path="$1"
  local pid command
  local -a matching_pids=()

  while read -r pid command; do
    [[ -n "$pid" ]] || continue
    if [[
      "$command" == "$executable_path"
      || "$command" == "$executable_path "*
      || "$command" == *" $executable_path"
      || "$command" == *" $executable_path "*
    ]]; then
      matching_pids+=("$pid")
    fi
  done < <(ps -axo pid=,command= 2>/dev/null || true)

  ((${#matching_pids[@]} == 0)) && return
  kill -TERM "${matching_pids[@]}" 2>/dev/null || true
}

DEPENDENCIES=(rsync codesign curl)
if [[ "$INSTALL_EXTRAS" == "1" ]]; then
  DEPENDENCIES+=(uv ffmpeg)
fi
if [[ -z "$PREBUILT_APP" ]]; then
  DEPENDENCIES+=(swift iconutil)
fi
for dependency in "${DEPENDENCIES[@]}"; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "missing required command: $dependency" >&2
    exit 1
  fi
done

if [[ "${1:-}" != "--installed" && "$SOURCE_ROOT" != "$INSTALL_ROOT" ]]; then
  launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" 2>/dev/null || true
  stop_installed_processes "MacDictationAgent" "$APP_BIN"
  stop_installed_processes "FluidDictationService" "$APP_HELPER"
  stop_installed_process_path "$INSTALL_ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker"
  PERMANENT_WAS_STOPPED=0
  OLD_PERMANENT_TRANSCRIBER="$INSTALL_ROOT/vendor/permanent-transcriber/.venv/bin/permanent-transcriber"
  if [[ -x "$OLD_PERMANENT_TRANSCRIBER" ]]; then
    OLD_STATUS="$(PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT/permanent-transcriber" "$OLD_PERMANENT_TRANSCRIBER" status)"
    if printf '%s' "$OLD_STATUS" | /usr/bin/python3 -c '
import json
import sys

status = json.load(sys.stdin)
running = status["capture"]["running"] or any(worker["running"] for worker in status["workers"].values())
raise SystemExit(0 if running else 1)
'; then
      if ! PERMANENT_TRANSCRIBER_ROOT="$DATA_ROOT/permanent-transcriber" \
        "$OLD_PERMANENT_TRANSCRIBER" stop >/dev/null; then
        echo "could not stop continuous transcription; installation aborted" >&2
        exit 1
      fi
      PERMANENT_WAS_STOPPED=1
    fi
  fi
  if curl -fsS "http://127.0.0.1:$ASR_PORT/health" >/dev/null 2>&1; then
    curl -fsS -X POST "http://127.0.0.1:$ASR_PORT/shutdown" >/dev/null
    for _ in {1..200}; do
      if ! curl -fsS "http://127.0.0.1:$ASR_PORT/health" >/dev/null 2>&1; then
        break
      fi
      sleep 0.05
    done
    if curl -fsS "http://127.0.0.1:$ASR_PORT/health" >/dev/null 2>&1; then
      echo "could not stop the ASR worker; installation aborted" >&2
      exit 1
    fi
  fi
  mkdir -p "$INSTALL_ROOT"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "logs" \
    --exclude "tts.env" \
    --exclude "tts-audio" \
    --exclude "swift-agent/.build" \
    --exclude "swift-agent/.swiftpm" \
    --exclude "asr_worker/.venv" \
    --exclude "supertonic_worker/.venv" \
    --exclude "vendor/permanent-transcriber/.venv" \
    --exclude "asr_worker/__pycache__" \
    --exclude "asr_worker/test-worker.log" \
    --exclude "batch-output" \
    "$SOURCE_ROOT/" "$INSTALL_ROOT/"
  MAC_DICTATION_DATA_ROOT="$DATA_ROOT" \
    MAC_DICTATION_MODEL_ROOT="$MODEL_ROOT" \
    MAC_DICTATION_FLUID_MODEL_ROOT="$FLUID_MODEL_ROOT" \
    MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT="$SUPERTONIC_TTS_MODEL_ROOT" \
    MAC_DICTATION_TTS_IDLE_SECONDS="$LOCAL_TTS_IDLE_SECONDS" \
    MAC_DICTATION_LAUNCH_AGENT_LABEL="$LAUNCH_AGENT_LABEL" \
    MAC_DICTATION_PLIST="$PLIST" \
    MAC_DICTATION_APP_DIR="$APP_DIR" \
    MAC_DICTATION_PREBUILT_APP="$PREBUILT_APP" \
    MAC_DICTATION_ACTIVATE="$ACTIVATE" \
    MAC_DICTATION_WARM_MODELS="$WARM_MODELS" \
    MAC_DICTATION_ASR_PORT="$ASR_PORT" \
    MAC_DICTATION_INSTALL_EXTRAS="$INSTALL_EXTRAS" \
    MAC_DICTATION_PERMANENT_WAS_STOPPED="$PERMANENT_WAS_STOPPED" \
    exec /bin/bash "$INSTALL_ROOT/scripts/install_launch_agent.sh" --installed
fi

ROOT="$SOURCE_ROOT"
mkdir -p "$DATA_ROOT" "$MODEL_ROOT"
LOG_DIR="$DATA_ROOT/logs"
APP_HELPER="$APP_DIR/Contents/Helpers/FluidDictationService"
SUPERTONIC_TTS_WORKER_BIN="$ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker"
LEGACY_FLUID_MODEL_ROOT="$HOME/Library/Application Support/FluidAudio/Models"

mkdir -p \
  "$HOME/Library/LaunchAgents" \
  "$LOG_DIR" \
  "$FLUID_MODEL_ROOT" \
  "$SUPERTONIC_TTS_MODEL_ROOT"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
stop_installed_processes "MacDictationAgent" "$APP_BIN"
stop_installed_processes "FluidDictationService" "$APP_HELPER"
stop_installed_process_path "$SUPERTONIC_TTS_WORKER_BIN"
if [[ "$INSTALL_EXTRAS" == "1" ]]; then
  (cd "$ROOT/asr_worker" && uv sync --frozen)
  (cd "$ROOT/supertonic_worker" && uv sync --frozen)
  (cd "$ROOT/vendor/permanent-transcriber" && uv sync --frozen)
fi
if [[ "$INSTALL_EXTRAS" == "1" && "$WARM_MODELS" == "1" ]]; then
  echo "Downloading the Parakeet speech model if it is not already cached..."
  (cd "$ROOT/asr_worker" && MAC_DICTATION_MODEL_ROOT="$MODEL_ROOT" \
    uv run --project "$ROOT/asr_worker" python download_model.py)
fi
if [[ -n "$PREBUILT_APP" ]]; then
  if [[ ! -x "$PREBUILT_APP/Contents/MacOS/MacDictationAgent" ]]; then
    echo "prebuilt app is invalid: $PREBUILT_APP" >&2
    exit 1
  fi
  rm -rf "$APP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  rsync -a "$PREBUILT_APP/" "$APP_DIR/"
  xattr -cr "$APP_DIR" 2>/dev/null || true
  codesign --verify --deep --strict "$APP_DIR"
else
  MAC_DICTATION_APP_DIR="$APP_DIR" "$ROOT/scripts/build_app_bundle.sh"
fi
if [[ ! -d "$FLUID_MODEL_ROOT/parakeet-tdt-0.6b-v3" && -d "$LEGACY_FLUID_MODEL_ROOT/parakeet-tdt-0.6b-v3" ]]; then
  cp -R "$LEGACY_FLUID_MODEL_ROOT/parakeet-tdt-0.6b-v3" "$FLUID_MODEL_ROOT/"
fi
if [[ "$WARM_MODELS" == "1" ]]; then
  printf '%s\n%s\n' \
    '{"id":"install-warmup","action":"warmup","final":false}' \
    '{"id":"install-shutdown","action":"shutdown","final":false}' \
    | MAC_DICTATION_FLUID_MODEL_ROOT="$FLUID_MODEL_ROOT" "$APP_HELPER" \
        >/dev/null 2>>"$LOG_DIR/fluid-dictation-service.log"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BIN</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
	  <key>PATH</key>
	  <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	  <key>MAC_DICTATION_AGENT_ROOT</key>
	  <string>$ROOT</string>
	  <key>MAC_DICTATION_DATA_ROOT</key>
	  <string>$DATA_ROOT</string>
	  <key>MAC_DICTATION_MODEL_ROOT</key>
	  <string>$MODEL_ROOT</string>
	  <key>MAC_DICTATION_FLUID_MODEL_ROOT</key>
	  <string>$FLUID_MODEL_ROOT</string>
	  <key>MAC_DICTATION_FLUID_SERVICE_BIN</key>
	  <string>$APP_HELPER</string>
	  <key>MAC_DICTATION_SUPERTONIC_TTS_SERVICE_BIN</key>
	  <string>$SUPERTONIC_TTS_WORKER_BIN</string>
	  <key>MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT</key>
	  <string>$SUPERTONIC_TTS_MODEL_ROOT</string>
	  <key>MAC_DICTATION_TTS_IDLE_SECONDS</key>
	  <string>$LOCAL_TTS_IDLE_SECONDS</string>
	  <key>MAC_DICTATION_ASR_PORT</key>
	  <string>$ASR_PORT</string>
	  <key>MAC_DICTATION_LAUNCH_AGENT_LABEL</key>
	  <string>$LAUNCH_AGENT_LABEL</string>
	</dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agent.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agent.err.log</string>
</dict>
</plist>
PLIST

if [[ "$ACTIVATE" == "1" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl enable "gui/$(id -u)/$LAUNCH_AGENT_LABEL"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl kickstart "gui/$(id -u)/$LAUNCH_AGENT_LABEL"
  launchctl print "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null
  echo "installed and started: $PLIST"
else
  echo "installed without starting: $PLIST"
fi
echo "app bundle: $APP_DIR"
echo "dictation service: $APP_HELPER"
echo "local TTS service: $SUPERTONIC_TTS_WORKER_BIN"
if [[ "$INSTALL_EXTRAS" != "1" ]]; then
  echo "optional file transcription, continuous recording, and local TTS tools were not installed"
fi
if [[ "${MAC_DICTATION_PERMANENT_WAS_STOPPED:-0}" == "1" ]]; then
  echo "continuous transcription was stopped for the update; restart it from the menu bar"
fi
