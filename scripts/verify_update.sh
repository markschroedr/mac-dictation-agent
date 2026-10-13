#!/usr/bin/env bash
set -euo pipefail
# Build two signed releases first, then pass the older and newer ZIPs here.
[[ $# == 2 ]] || { echo "usage: $0 OLD.zip NEW.zip" >&2; exit 2; }
OLD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NEW="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ROOT="$(mktemp -d "${TMPDIR:-/tmp/}mac-dictation-update-e2e.XXXXXX")"
LABEL="com.markschroedr.mac-dictation.$(uuidgen).update-test"
SERVER_PID=""
cleanup() {
  if [[ -f "$ROOT/valid.log" ]]; then
    UPDATE_JOB="$(awk '/Detached activation job:/ {print $NF}' "$ROOT/valid.log")"
    if [[ "$UPDATE_JOB" == com.markschroedr.mac-dictation.update-* ]]; then
      launchctl bootout "gui/$(id -u)/$UPDATE_JOB" 2>/dev/null || true
    fi
  fi
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
  echo "E2E artifact: $ROOT/e2e.log"
}
trap cleanup EXIT
exec > >(tee "$ROOT/e2e.log") 2>&1
[[ -f "$OLD.sig" && -f "$NEW.sig" ]] || { echo "Both archives must be signed" >&2; exit 1; }
ditto -x -k "$OLD" "$ROOT/old"
OLD_PACKAGE=("$ROOT/old"/*)
OLD_VERSION="$(<"${OLD_PACKAGE[0]}/runtime/VERSION")"
NEW_VERSION="$(basename "$NEW" | awk -F'Mac-Dictation-Agent-' '{print $2}' | sed 's/-macOS-arm64.zip$//')"
export MAC_DICTATION_DATA_ROOT="$ROOT/data"
export MAC_DICTATION_APP_DIR="$ROOT/Applications/MacDictationAgent.app"
export MAC_DICTATION_PLIST="$ROOT/test.plist"
export MAC_DICTATION_LAUNCH_AGENT_LABEL="$LABEL"
export MAC_DICTATION_UPDATE_E2E=1
export MAC_DICTATION_INSTALL_EXTRAS=0 MAC_DICTATION_WARM_MODELS=0
export MAC_DICTATION_PREBUILT_APP="${OLD_PACKAGE[0]}/MacDictationAgent.app"
export MAC_DICTATION_API_PORT=18797
# An ephemeral localhost feed serves valid bytes or deliberately corrupts them.
cat > "$ROOT/feed.py" <<'PYTHON'
import http.server, json, pathlib, sys
root, archive, version = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        mode = (root / 'mode').read_text().strip()
        base = f'http://127.0.0.1:{self.server.server_port}'
        if self.path == '/latest':
            data = json.dumps(dict(tag_name='v'+version, draft=False, prerelease=False, assets=[
                dict(name=archive.name, browser_download_url=base+'/archive'),
                dict(name=archive.name+'.sig', browser_download_url=base+'/signature')])).encode()
        elif self.path == '/archive':
            data = archive.read_bytes() + (b'tampered' if mode == 'tampered' else b'')
        elif self.path == '/signature':
            data = pathlib.Path(str(archive)+'.sig').read_bytes()
            if mode == 'wrong-signature': data = bytes([data[0] ^ 1]) + data[1:]
        else:
            self.send_error(404); return
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PYTHON
printf valid > "$ROOT/mode"
uv run --no-project python "$ROOT/feed.py" "$ROOT" "$NEW" "$NEW_VERSION" > "$ROOT/feed.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do [[ ! -f "$ROOT/port" ]] || break; sleep 0.1; done
export MAC_DICTATION_UPDATE_FEED_URL="http://127.0.0.1:$(<"$ROOT/port")/latest"
bash "${OLD_PACKAGE[0]}/runtime/scripts/install_launch_agent.sh"
export MAC_DICTATION_AGENT_ROOT="$(readlink "$ROOT/data/runtime")"
BIN="$MAC_DICTATION_APP_DIR/Contents/MacOS/MacDictationAgent"
pid() { launchctl print "gui/$(id -u)/$LABEL" | awk '$1 == "pid" && $2 == "=" {print $3}'; }
OLD_PID="$(pid)"
codesign -d -r- "$MAC_DICTATION_APP_DIR" > "$ROOT/old-requirement" 2>&1
for mode in tampered wrong-signature; do
  printf '%s' "$mode" > "$ROOT/mode"
  if "$BIN" --update-e2e > "$ROOT/$mode.log" 2>&1; then echo "Corrupt update was accepted"; exit 1; fi
  grep -q 'signature is invalid' "$ROOT/$mode.log"
  [[ "$(pid)" == "$OLD_PID" ]]
  [[ "$(plutil -extract CFBundleShortVersionString raw "$MAC_DICTATION_APP_DIR/Contents/Info.plist")" == "$OLD_VERSION" ]]
  echo "PASS $mode rejected; old app PID $OLD_PID still running"
done
printf valid > "$ROOT/mode"
"$BIN" --update-e2e | tee "$ROOT/valid.log"
WORKSPACE="$(awk '/Detached activation submitted:/ {sub(/\/update.log$/, "", $NF); print $NF}' "$ROOT/valid.log")"
for _ in {1..300}; do
  if grep -q 'Installed and started:' "$WORKSPACE/update.log" && [[ "$(plutil -extract CFBundleShortVersionString raw "$MAC_DICTATION_APP_DIR/Contents/Info.plist" 2>/dev/null || true)" == "$NEW_VERSION" ]]; then break; fi
  sleep 0.1
done
grep -q 'Installed and started:' "$WORKSPACE/update.log"
for _ in {1..100}; do [[ ! -f "$WORKSPACE/update.log.result" ]] || break; sleep 0.1; done
[[ "$(<"$WORKSPACE/update.log.result")" == installed ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$MAC_DICTATION_APP_DIR/Contents/Info.plist")" == "$NEW_VERSION" ]]
NEW_PID="$(pid)"; [[ -n "$NEW_PID" && "$NEW_PID" != "$OLD_PID" ]]
[[ "$(ps -p "$NEW_PID" -o comm=)" == "$BIN" ]]
codesign -d -r- "$MAC_DICTATION_APP_DIR" > "$ROOT/new-requirement" 2>&1
diff <(grep 'designated =>' "$ROOT/old-requirement") <(grep 'designated =>' "$ROOT/new-requirement")
grep -q 'certificate leaf = H' "$ROOT/new-requirement"
if xattr -p com.apple.quarantine "$WORKSPACE/release.zip" 2>/dev/null; then echo "Download was quarantined"; exit 1; fi
if xattr -p com.apple.quarantine "$MAC_DICTATION_APP_DIR" 2>/dev/null; then echo "Installed app was quarantined"; exit 1; fi
[[ -d "$MAC_DICTATION_AGENT_ROOT" ]]
[[ "$(find "$ROOT/data/runtimes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 2 ]]
echo "PASS $OLD_VERSION → $NEW_VERSION; detached activation started PID $NEW_PID"
echo "PASS identical certificate-pinned designated requirements, no quarantine, rollback runtime retained"
