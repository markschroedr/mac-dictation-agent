#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/VERSION")"
DIST_ROOT="${MAC_DICTATION_DIST_ROOT:-$SOURCE_ROOT/dist}"
ARCHIVE_NAME="Mac-Dictation-Agent-$VERSION-macOS-arm64"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mac-dictation-release.XXXXXX")"
PRODUCT_ROOT="$STAGING_ROOT/$ARCHIVE_NAME"
RUNTIME_ROOT="$PRODUCT_ROOT/runtime"
ARCHIVE_PATH="$DIST_ROOT/$ARCHIVE_NAME.zip"

trap 'echo "release workspace: $STAGING_ROOT"' EXIT

for dependency in rsync ditto shasum; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "missing required command: $dependency" >&2
    exit 1
  fi
done

[[ ! -e "$ARCHIVE_PATH" && ! -e "$ARCHIVE_PATH.sha256" ]] || { echo "Release artifacts already exist; preserve them before rebuilding" >&2; exit 1; }
mkdir -p \
  "$PRODUCT_ROOT" \
  "$RUNTIME_ROOT/asr_worker" \
  "$RUNTIME_ROOT/supertonic_worker" \
  "$RUNTIME_ROOT/vendor/permanent-transcriber" \
  "$RUNTIME_ROOT/scripts" \
  "$RUNTIME_ROOT/docs" \
  "$RUNTIME_ROOT/THIRD_PARTY_LICENSES" \
  "$RUNTIME_ROOT/assets" \
  "$PRODUCT_ROOT/docs" \
  "$PRODUCT_ROOT/THIRD_PARTY_LICENSES" \
  "$PRODUCT_ROOT/assets" \
  "$DIST_ROOT"

MAC_DICTATION_APP_DIR="$PRODUCT_ROOT/MacDictationAgent.app" \
  "$SOURCE_ROOT/scripts/build_app_bundle.sh"

rsync -a \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude 'tests' \
  --exclude '*.log' \
  "$SOURCE_ROOT/asr_worker/" "$RUNTIME_ROOT/asr_worker/"
rsync -a \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude '*.log' \
  "$SOURCE_ROOT/supertonic_worker/" "$RUNTIME_ROOT/supertonic_worker/"
rsync -a \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude '.pytest_cache' \
  --exclude 'tests' \
  --exclude '*.log' \
  "$SOURCE_ROOT/vendor/permanent-transcriber/" "$RUNTIME_ROOT/vendor/permanent-transcriber/"
rsync -a \
  "$SOURCE_ROOT/scripts/install_launch_agent.sh" \
  "$SOURCE_ROOT/scripts/uninstall_launch_agent.sh" \
  "$SOURCE_ROOT/scripts/batch_transcribe.sh" \
  "$RUNTIME_ROOT/scripts/"
rsync -a \
  "$SOURCE_ROOT/LICENSE" \
  "$SOURCE_ROOT/README.md" \
  "$SOURCE_ROOT/THIRD_PARTY_NOTICES.md" \
  "$SOURCE_ROOT/CHANGELOG.md" \
  "$SOURCE_ROOT/VERSION" \
  "$RUNTIME_ROOT/"
rsync -a \
  "$SOURCE_ROOT/docs/PRIVACY.md" \
  "$SOURCE_ROOT/docs/USAGE.md" \
  "$SOURCE_ROOT/docs/BENCHMARKS.md" \
  "$RUNTIME_ROOT/docs/"
rsync -a \
  "$SOURCE_ROOT/THIRD_PARTY_LICENSES/" \
  "$RUNTIME_ROOT/THIRD_PARTY_LICENSES/"
rsync -a \
  --exclude 'demo/raw' \
  "$SOURCE_ROOT/assets/" \
  "$RUNTIME_ROOT/assets/"
rsync -a \
  "$SOURCE_ROOT/LICENSE" \
  "$SOURCE_ROOT/README.md" \
  "$SOURCE_ROOT/THIRD_PARTY_NOTICES.md" \
  "$SOURCE_ROOT/CHANGELOG.md" \
  "$PRODUCT_ROOT/"
rsync -a \
  "$SOURCE_ROOT/docs/PRIVACY.md" \
  "$SOURCE_ROOT/docs/USAGE.md" \
  "$SOURCE_ROOT/docs/BENCHMARKS.md" \
  "$PRODUCT_ROOT/docs/"
rsync -a \
  "$SOURCE_ROOT/THIRD_PARTY_LICENSES/" \
  "$PRODUCT_ROOT/THIRD_PARTY_LICENSES/"
rsync -a \
  --exclude 'demo/raw' \
  "$SOURCE_ROOT/assets/" \
  "$PRODUCT_ROOT/assets/"

cat > "$PRODUCT_ROOT/Install Mac Dictation Agent.command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAC_DICTATION_PREBUILT_APP="$PACKAGE_ROOT/MacDictationAgent.app" \
MAC_DICTATION_INSTALL_EXTRAS="0" \
  /bin/bash "$PACKAGE_ROOT/runtime/scripts/install_launch_agent.sh"

echo
echo "Installation complete. Look for the microphone icon in the menu bar."
SCRIPT

cat > "$PRODUCT_ROOT/Install Optional Tools.command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v uv >/dev/null 2>&1 || ! command -v ffmpeg >/dev/null 2>&1; then
  echo "File transcription, continuous recording, and local text-to-speech need uv and ffmpeg."
  echo
  echo "Install them with Homebrew, then run this installer again:"
  echo "  brew install uv ffmpeg"
  echo
  read -r -p "Press Return to close."
  exit 1
fi

MAC_DICTATION_PREBUILT_APP="$PACKAGE_ROOT/MacDictationAgent.app" \
MAC_DICTATION_INSTALL_EXTRAS="1" \
  /bin/bash "$PACKAGE_ROOT/runtime/scripts/install_launch_agent.sh"

echo
echo "Optional tools installed. Models will download when you first use each workflow."
SCRIPT

cat > "$PRODUCT_ROOT/Uninstall Mac Dictation Agent.command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
/bin/bash "$PACKAGE_ROOT/runtime/scripts/uninstall_launch_agent.sh"
SCRIPT

chmod +x \
  "$PRODUCT_ROOT/Install Mac Dictation Agent.command" \
  "$PRODUCT_ROOT/Install Optional Tools.command" \
  "$PRODUCT_ROOT/Uninstall Mac Dictation Agent.command"

xattr -cr "$PRODUCT_ROOT" 2>/dev/null || true
ditto -c -k --norsrc --keepParent "$PRODUCT_ROOT" "$ARCHIVE_PATH"
(
  cd "$DIST_ROOT"
  shasum -a 256 "$(basename "$ARCHIVE_PATH")" > "$(basename "$ARCHIVE_PATH").sha256"
)

echo "release archive: $ARCHIVE_PATH"
echo "checksum: $ARCHIVE_PATH.sha256"
