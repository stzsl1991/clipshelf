#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077
signing_dir="$PWD/.signing"
signing_keychain="$signing_dir/ClipShelf.keychain-db"
mkdir -p "$signing_dir"
if [[ ! -f "$signing_dir/password" ]]; then /usr/bin/openssl rand -hex 32 > "$signing_dir/password"; fi
signing_password=$(<"$signing_dir/password")
if [[ ! -f "$signing_keychain" ]]; then
  cat > "$signing_dir/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = Shulin ClipShelf Local Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
  /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$signing_dir/certificate.cnf" -keyout "$signing_dir/key.pem" -out "$signing_dir/cert.pem" 2> "$signing_dir/certificate.log"
  /usr/bin/openssl pkcs12 -export -inkey "$signing_dir/key.pem" -in "$signing_dir/cert.pem" \
    -out "$signing_dir/identity.p12" -passout "file:$signing_dir/password"
  /usr/bin/security create-keychain -p "$signing_password" "$signing_keychain"
  /usr/bin/security import "$signing_dir/identity.p12" -k "$signing_keychain" -P "$signing_password" -T /usr/bin/codesign > "$signing_dir/import.log"
  /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$signing_password" "$signing_keychain" > "$signing_dir/partition.log"
fi
/usr/bin/security unlock-keychain -p "$signing_password" "$signing_keychain"
# No trusted-root installation or system trust setting changes. The certificate
# only identifies this project's builds; it is not an Apple Developer ID.
/usr/bin/python3 - "$signing_keychain" "$1" <<'PY'
import pathlib, shlex, subprocess, sys
keychain, app = sys.argv[1:]
original = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
try:
    # codesign still resolves identities through the search list even when a
    # keychain is specified. Restore the user's exact list after signing.
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original, keychain], check=True)
    subprocess.run(['codesign', '--force', '--sign', 'Shulin ClipShelf Local Signing', '--keychain', keychain,
                    '--timestamp=none', '--identifier', 'com.shulin.ClipShelf', app], check=True)
finally:
    subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *original], check=True)
PY
/usr/bin/codesign --verify --strict "$1"
rm -f "$signing_dir/key.pem" "$signing_dir/identity.p12"
