#!/usr/bin/env bash
set -euo pipefail
# Invoked by an independent, one-shot launchd job, not a child of the app job.
RUNTIME="$1"
LOG="$2"
JOB="$3"
if ! MAC_DICTATION_SAFE_UPDATE=1 /bin/bash "$RUNTIME/scripts/install_launch_agent.sh" --activate >> "$LOG" 2>&1; then
  printf failed > "$LOG.result"
  /usr/bin/osascript - "$LOG" <<'APPLESCRIPT'
on run args
  display alert "Mac Dictation Agent update failed" message ("The previous installation was kept or restored. Details: " & item 1 of args) as critical
end run
APPLESCRIPT
else
  printf installed > "$LOG.result"
fi
# The submitted job has no KeepAlive. Remove its registration after it finishes.
/bin/launchctl remove "$JOB"
