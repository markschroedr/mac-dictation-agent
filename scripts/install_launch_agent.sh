#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Preparation writes only a new, persistent runtime directory. Virtual environments
# stay at this path after activation; moving them would break their entry points.
if [[ "${1:-}" != "--activate" ]]; then
  [[ $# == 0 ]] || { echo "usage: $0 [--activate]" >&2; exit 2; }
  DATA_ROOT="${MAC_DICTATION_DATA_ROOT:-$HOME/Library/Application Support/Mac Dictation Agent}"
  ROOT="${MAC_DICTATION_INSTALL_ROOT:-$DATA_ROOT/runtimes/$(uuidgen)}"
  APP_DIR="${MAC_DICTATION_APP_DIR:-$HOME/Applications/MacDictationAgent.app}"
  LABEL="${MAC_DICTATION_LAUNCH_AGENT_LABEL:-com.markschroedr.mac-dictation}"
  PLIST="${MAC_DICTATION_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
  MODEL_ROOT="${MAC_DICTATION_MODEL_ROOT:-$DATA_ROOT/models}"
  FLUID_ROOT="${MAC_DICTATION_FLUID_MODEL_ROOT:-$MODEL_ROOT/fluid-audio}"
  TTS_ROOT="${MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT:-$MODEL_ROOT/supertonic-3}"
  EXTRAS="${MAC_DICTATION_INSTALL_EXTRAS:-1}"
  PREBUILT="${MAC_DICTATION_PREBUILT_APP:-}"
  [[ ! -e "$ROOT" && ! -L "$ROOT" ]] || { echo "Preparation requires a new runtime directory: $ROOT" >&2; exit 1; }
  for dependency in rsync codesign plutil; do
    command -v "$dependency" >/dev/null || { echo "Missing tool: $dependency" >&2; exit 1; }
  done
  if [[ "$EXTRAS" == 1 ]]; then
    for dependency in uv ffmpeg; do
      command -v "$dependency" >/dev/null || { echo "Install optional tools first: brew install uv ffmpeg" >&2; exit 1; }
    done
  fi
  mkdir -p "$ROOT/vendor"
  # Explicit product allowlist. Never mirror a checkout or delete destination data.
  for directory in asr_worker supertonic_worker scripts docs; do
    rsync -a --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
      --exclude '*.log' --exclude .env --exclude tts.env \
      "$SOURCE_ROOT/$directory/" "$ROOT/$directory/"
  done
  rsync -a --exclude .venv --exclude __pycache__ --exclude .pytest_cache \
    --exclude .state --exclude storage --exclude '*.log' \
    "$SOURCE_ROOT/vendor/permanent-transcriber/" "$ROOT/vendor/permanent-transcriber/"
  for file in LICENSE README.md THIRD_PARTY_NOTICES.md CHANGELOG.md VERSION; do
    cp "$SOURCE_ROOT/$file" "$ROOT/$file"
  done
  for directory in THIRD_PARTY_LICENSES assets; do
    if [[ -d "$SOURCE_ROOT/$directory" ]]; then
      rsync -a --exclude raw "$SOURCE_ROOT/$directory/" "$ROOT/$directory/"
    fi
  done
  if [[ "$EXTRAS" == 1 ]]; then
    for project in asr_worker supertonic_worker vendor/permanent-transcriber; do
      (cd "$ROOT/$project" && uv sync --frozen)
    done
  fi
  if [[ -n "$PREBUILT" ]]; then
    codesign --verify --deep --strict "$PREBUILT"
    rsync -a "$PREBUILT/" "$ROOT/MacDictationAgent.app/"
  else
    MAC_DICTATION_APP_DIR="$ROOT/MacDictationAgent.app" \
      bash "$SOURCE_ROOT/scripts/build_app_bundle.sh"
  fi
  codesign --verify --deep --strict "$ROOT/MacDictationAgent.app"
  [[ -x "$ROOT/MacDictationAgent.app/Contents/MacOS/MacDictationAgent" ]]
  [[ -x "$ROOT/MacDictationAgent.app/Contents/Helpers/FluidDictationService" ]]

  PLAN="$ROOT/installation.plist"
  plutil -create xml1 "$PLAN"
  plutil -insert TargetApp -string "$APP_DIR" "$PLAN"
  plutil -insert TargetPlist -string "$PLIST" "$PLAN"
  plutil -insert DataRoot -string "$DATA_ROOT" "$PLAN"
  plutil -insert RuntimeLink -string "$DATA_ROOT/runtime" "$PLAN"
  STAGED_PLIST="$ROOT/launch.plist"
  plutil -create xml1 "$STAGED_PLIST"
  plutil -insert Label -string "$LABEL" "$STAGED_PLIST"
  plutil -insert ProgramArguments -json '[]' "$STAGED_PLIST"
  plutil -insert ProgramArguments.0 -string "$APP_DIR/Contents/MacOS/MacDictationAgent" "$STAGED_PLIST"
  plutil -insert EnvironmentVariables -json '{}' "$STAGED_PLIST"
  add_env() { plutil -insert "EnvironmentVariables.$1" -string "$2" "$STAGED_PLIST"; }
  add_env PATH "$PATH"
  add_env MAC_DICTATION_AGENT_ROOT "$ROOT"
  add_env MAC_DICTATION_DATA_ROOT "$DATA_ROOT"
  add_env MAC_DICTATION_MODEL_ROOT "$MODEL_ROOT"
  add_env MAC_DICTATION_FLUID_MODEL_ROOT "$FLUID_ROOT"
  add_env MAC_DICTATION_FLUID_SERVICE_BIN "$APP_DIR/Contents/Helpers/FluidDictationService"
  add_env MAC_DICTATION_SUPERTONIC_TTS_SERVICE_BIN "$ROOT/supertonic_worker/.venv/bin/supertonic-tts-worker"
  add_env MAC_DICTATION_SUPERTONIC_TTS_MODEL_ROOT "$TTS_ROOT"
  add_env MAC_DICTATION_TTS_IDLE_SECONDS "${MAC_DICTATION_TTS_IDLE_SECONDS:-300}"
  add_env MAC_DICTATION_ASR_PORT "${MAC_DICTATION_ASR_PORT:-8766}"
  add_env MAC_DICTATION_LAUNCH_AGENT_LABEL "$LABEL"
  plutil -insert RunAtLoad -bool true "$STAGED_PLIST"
  plutil -insert KeepAlive -bool true "$STAGED_PLIST"
  plutil -insert StandardOutPath -string "$DATA_ROOT/logs/agent.out.log" "$STAGED_PLIST"
  plutil -insert StandardErrorPath -string "$DATA_ROOT/logs/agent.err.log" "$STAGED_PLIST"
  # Credentials belong to the data root, not replaceable application code.
  ln -s "$DATA_ROOT/tts.env" "$ROOT/tts.env"
  plutil -lint "$PLAN" "$STAGED_PLIST"
  echo "Prepared runtime: $ROOT"
  echo "Activate with: bash \"$ROOT/scripts/install_launch_agent.sh\" --activate"
  if [[ "${MAC_DICTATION_ACTIVATE:-1}" != 1 ]]; then
    echo "Preparation only. No app, service, launch configuration, or existing data was changed."
    exit 0
  fi
  exec bash "$ROOT/scripts/install_launch_agent.sh" --activate
fi

# Activation is deliberately separate. A failed prepare cannot stop the live app.
ROOT="$SOURCE_ROOT"
PLAN="$ROOT/installation.plist"
[[ -f "$PLAN" && -d "$ROOT/MacDictationAgent.app" ]] || { echo "No prepared installation at $ROOT" >&2; exit 1; }
APP_DIR="$(plutil -extract TargetApp raw "$PLAN")"
PLIST="$(plutil -extract TargetPlist raw "$PLAN")"
DATA_ROOT="$(plutil -extract DataRoot raw "$PLAN")"
RUNTIME_LINK="$(plutil -extract RuntimeLink raw "$PLAN")"
LABEL="$(plutil -extract Label raw "$ROOT/launch.plist")"
[[ -n "$LABEL" && "$APP_DIR" == /*.app && "$PLIST" == /*.plist ]] || { echo "Invalid activation paths or label" >&2; exit 1; }
plutil -lint "$ROOT/launch.plist" >/dev/null
APP_BIN="$APP_DIR/Contents/MacOS/MacDictationAgent"
codesign --verify --deep --strict "$ROOT/MacDictationAgent.app"

# Refuse to take over a launch label that belongs to another executable.
if [[ -f "$PLIST" ]]; then
  OLD_BIN="$(plutil -extract ProgramArguments.0 raw "$PLIST")"
  OLD_LABEL="$(plutil -extract Label raw "$PLIST")"
  [[ "$OLD_LABEL" == "$LABEL" ]] || { echo "Existing LaunchAgent has a different label; migrate it explicitly" >&2; exit 1; }
  [[ "$OLD_BIN" == "$APP_BIN" ]] || { echo "LaunchAgent belongs to another app; refusing activation" >&2; exit 1; }
  OLD_ROOT="$(plutil -extract EnvironmentVariables.MAC_DICTATION_AGENT_ROOT raw "$PLIST")"
  OLD_DATA="$(plutil -extract EnvironmentVariables.MAC_DICTATION_DATA_ROOT raw "$PLIST")"
  OLD_TRANSCRIBER="$OLD_ROOT/vendor/permanent-transcriber/.venv/bin/permanent-transcriber"
fi

BACKUP="$DATA_ROOT/installation-backups/$(uuidgen)"
mkdir -p "$BACKUP" "$(dirname "$APP_DIR")" "$(dirname "$PLIST")" "$DATA_ROOT/logs"
if [[ -e "$RUNTIME_LINK" && ! -L "$RUNTIME_LINK" ]]; then
  echo "Legacy runtime directory needs explicit migration before activation: $RUNTIME_LINK" >&2
  exit 1
fi
# Refuse credential collisions instead of silently replacing either configuration.
if [[ -n "${OLD_ROOT:-}" && -f "$OLD_ROOT/tts.env" && -f "$DATA_ROOT/tts.env" ]]; then
  cmp -s "$OLD_ROOT/tts.env" "$DATA_ROOT/tts.env" || {
    echo "Credential files differ; reconcile them privately before activation" >&2; exit 1;
  }
fi
if [[ -n "${OLD_ROOT:-}" && -f "$OLD_ROOT/tts.env" && ! -e "$DATA_ROOT/tts.env" ]]; then
  cp -p "$OLD_ROOT/tts.env" "$DATA_ROOT/tts.env"
  chmod 600 "$DATA_ROOT/tts.env"
fi
# Preserve the complete previous app and launch configuration for rollback.
if [[ -f "$PLIST" ]]; then cp -p "$PLIST" "$BACKUP/launch.plist"; fi
if [[ -L "$RUNTIME_LINK" ]]; then readlink "$RUNTIME_LINK" > "$BACKUP/runtime-target"; fi
rollback() {
  local result=$?
  trap - ERR
  echo "Activation failed; restoring the previous installation from $BACKUP" >&2
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if [[ -d "$BACKUP/MacDictationAgent.app" ]]; then
    if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$ROOT/failed-application.app"; fi
    mv "$BACKUP/MacDictationAgent.app" "$APP_DIR"
  fi
  if [[ -L "$RUNTIME_LINK" ]]; then mv "$RUNTIME_LINK" "$BACKUP/failed-runtime-link"; fi
  if [[ -f "$BACKUP/runtime-target" ]]; then
    local previous
    IFS= read -r previous < "$BACKUP/runtime-target"
    ln -s "$previous" "$RUNTIME_LINK"
  fi
  if [[ -f "$BACKUP/launch.plist" ]]; then
    cp -p "$BACKUP/launch.plist" "$PLIST"
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || true
  elif [[ -f "$PLIST" ]]; then
    mv "$PLIST" "$BACKUP/failed-launch.plist"
  fi
  exit "$result"
}
if [[ -n "${OLD_TRANSCRIBER:-}" && -x "$OLD_TRANSCRIBER" ]]; then
  STATUS="$(PERMANENT_TRANSCRIBER_ROOT="$OLD_DATA/permanent-transcriber" "$OLD_TRANSCRIBER" status)"
  RUNNING=0
  for field in capture.running workers.quick.running workers.relaxed.running; do
    if [[ "$(plutil -extract "$field" raw -o - - <<< "$STATUS")" == true ]]; then RUNNING=1; fi
  done
  if [[ "$RUNNING" == 1 ]]; then
    # The transcriber validates process identity and drains durable segments.
    PERMANENT_TRANSCRIBER_ROOT="$OLD_DATA/permanent-transcriber" "$OLD_TRANSCRIBER" stop
  fi
fi
trap rollback ERR
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
while read -r pid; do
  [[ -n "$pid" ]] || continue
  executable="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  if [[ "$executable" == "$APP_BIN" ]]; then
    kill -TERM "$pid"
    for _ in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "App did not stop; activation aborted without replacing it" >&2
      false
    fi
  fi
done < <(pgrep -x MacDictationAgent || true)
if [[ -e "$APP_DIR" ]]; then mv "$APP_DIR" "$BACKUP/MacDictationAgent.app"; fi
mv "$ROOT/MacDictationAgent.app" "$APP_DIR"
cp "$ROOT/launch.plist" "$PLIST"
ln -s "$ROOT" "$DATA_ROOT/runtime-next-$$"
mv -h -f "$DATA_ROOT/runtime-next-$$" "$RUNTIME_LINK"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
STARTED=0
for _ in {1..100}; do
  NEW_PID="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" {print $3}' || true)"
  if [[ -n "$NEW_PID" && "$(ps -p "$NEW_PID" -o comm= 2>/dev/null || true)" == "$APP_BIN" ]]; then
    STARTED=1
    break
  fi
  sleep 0.1
done
[[ "$STARTED" == 1 ]] || { echo "Installed app did not start" >&2; false; }
trap - ERR
echo "Installed and started: $APP_DIR"
echo "Previous installation preserved: $BACKUP"
echo "Recordings, transcripts, and models remain in: $DATA_ROOT"
echo "Continuous recording is not restarted automatically."
