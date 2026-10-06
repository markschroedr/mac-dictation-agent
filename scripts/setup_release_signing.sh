#!/usr/bin/env bash
set -euo pipefail
umask 077
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$HOME/.config/mac-dictation-agent-release"
mkdir -p "$ROOT"
chmod 700 "$ROOT"
# Refuse partial/existing setup rather than silently rotating an identity.
[[ ! -e "$ROOT/signing.keychain-db" && ! -e "$ROOT/code-signing.key" && ! -e "$ROOT/update-private.key" ]] || {
  echo "Signing material already exists. Preserve it; do not regenerate release identity." >&2; exit 1;
}
OPENSSL="$(command -v openssl)"
"$OPENSSL" version | grep -q '^OpenSSL 3' || {
  echo "Release signing setup needs OpenSSL 3 (brew install openssl@3). Put it on PATH first." >&2; exit 1;
}
"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -nodes -days 7300 \
  -subj '/CN=Mac Dictation Agent Release' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' \
  -keyout "$ROOT/code-signing.key" -out "$ROOT/code-signing.crt"
"$OPENSSL" rand -hex 32 > "$ROOT/keychain-password"
PASSWORD="$(<"$ROOT/keychain-password")"
"$OPENSSL" pkcs12 -export -legacy -inkey "$ROOT/code-signing.key" -in "$ROOT/code-signing.crt" \
  -out "$ROOT/code-signing.p12" -passout "pass:$PASSWORD"
KEYCHAINS=()
while IFS= read -r path; do
  path="${path#*\"}"; path="${path%\"*}"
  KEYCHAINS+=("$path")
done < <(security list-keychains -d user)
security create-keychain -p "$PASSWORD" "$ROOT/signing.keychain-db"
# create-keychain adds itself to search paths. Restore the exact previous list.
security list-keychains -d user -s "${KEYCHAINS[@]}"
security set-keychain-settings "$ROOT/signing.keychain-db"
security unlock-keychain -p "$PASSWORD" "$ROOT/signing.keychain-db"
security import "$ROOT/code-signing.p12" -k "$ROOT/signing.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$ROOT/signing.keychain-db" >/dev/null
"$OPENSSL" x509 -in "$ROOT/code-signing.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' > "$ROOT/identity"
swift "$SOURCE_ROOT/scripts/release_signing.swift" generate
printf 'Private release material: %s\nBack up this entire directory encrypted and offline. Keep both identities for all future releases.\n' "$ROOT"
