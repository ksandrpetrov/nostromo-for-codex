#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: $0 <app-bundle>"
  exit 64
fi

app_dir=$1
if [[ ! -d "$app_dir/Contents" ]]; then
  print -u2 "App bundle not found: $app_dir"
  exit 66
fi

signing_name="Nostromo Codex Local Development"
signing_dir="$HOME/Library/Application Support/Nostromo Codex/Signing"
signing_keychain="$signing_dir/LocalCodeSigning.keychain-db"
signing_password_file="$signing_dir/.keychain-password"

mkdir -p "$signing_dir"
chmod 700 "$signing_dir"

if [[ -e "$signing_keychain" && ! -f "$signing_password_file" ]] \
    || [[ ! -e "$signing_keychain" && -e "$signing_password_file" ]]
then
  print -u2 "Incomplete local signing identity in: $signing_dir"
  print -u2 "Move that directory aside and rerun the build."
  exit 78
fi

if [[ ! -e "$signing_keychain" ]]; then
  bootstrap_dir=$(mktemp -d /tmp/nostromo-codesign.XXXXXX)
  bootstrap_password=$(openssl rand -hex 32)
  password_temp="$signing_dir/.keychain-password.$$"

  cleanup_bootstrap() {
    find "$bootstrap_dir" -depth -delete 2>/dev/null || true
    if [[ -e "$password_temp" ]]; then
      find "$password_temp" -delete 2>/dev/null || true
    fi
  }
  trap cleanup_bootstrap EXIT INT TERM

  openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -x509 \
    -sha256 \
    -days 3650 \
    -subj "/CN=$signing_name/O=Nostromo Codex/" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$bootstrap_dir/key.pem" \
    -out "$bootstrap_dir/cert.pem" \
    >/dev/null 2>&1
  openssl pkcs12 \
    -export \
    -legacy \
    -inkey "$bootstrap_dir/key.pem" \
    -in "$bootstrap_dir/cert.pem" \
    -name "$signing_name" \
    -passout "pass:$bootstrap_password" \
    -out "$bootstrap_dir/identity.p12"

  security create-keychain -p "$bootstrap_password" "$signing_keychain"
  security unlock-keychain -p "$bootstrap_password" "$signing_keychain"
  security set-keychain-settings -lut 21600 "$signing_keychain"
  security import "$bootstrap_dir/identity.p12" \
    -k "$signing_keychain" \
    -P "$bootstrap_password" \
    -T /usr/bin/codesign \
    >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$bootstrap_password" \
    "$signing_keychain" \
    >/dev/null
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$signing_keychain" \
    "$bootstrap_dir/cert.pem"

  umask 077
  print -rn -- "$bootstrap_password" > "$password_temp"
  mv "$password_temp" "$signing_password_file"
  chmod 600 "$signing_password_file"

  cleanup_bootstrap
  trap - EXIT INT TERM
fi

chmod 600 "$signing_keychain"
signing_password=$(<"$signing_password_file")
security unlock-keychain -p "$signing_password" "$signing_keychain"

current_keychains=("${(@f)$(security list-keychains -d user \
  | sed -E 's/^[[:space:]]*"//; s/"$//')}")

restore_keychain_search_list() {
  security list-keychains -d user -s "${current_keychains[@]}" >/dev/null
}
trap restore_keychain_search_list EXIT INT TERM

security list-keychains -d user -s \
  "${current_keychains[@]}" \
  "$signing_keychain"

identity_hash=$(security find-identity -v -p codesigning "$signing_keychain" \
  | awk -v name="\"$signing_name\"" '$0 ~ name { print $2; exit }')
if [[ -z "$identity_hash" ]]; then
  print -u2 "Local code-signing identity is unavailable: $signing_name"
  exit 69
fi

codesign \
  --force \
  --deep \
  --sign "$identity_hash" \
  --keychain "$signing_keychain" \
  --timestamp=none \
  "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

requirement=$(codesign -d -r- "$app_dir" 2>&1)
if [[ "$requirement" != *'identifier "dev.aleksandr.nostromo-codex"'* ]] \
    || [[ "$requirement" != *"certificate root"* ]]
then
  print -u2 "Signed app does not have the expected stable designated requirement."
  exit 70
fi
