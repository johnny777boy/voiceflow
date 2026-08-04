#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity in a dedicated
# keychain, so macOS privacy grants (Microphone, Speech, Accessibility, Input
# Monitoring) PERSIST across rebuilds. Without this, ad-hoc signing changes the
# app's code identity every build and macOS forgets every permission.
#
# The cert is self-signed and untrusted (fine for a personal, locally-run app);
# `codesign` accepts it and TCC keys on the stable certificate. Run once; then
# Scripts/build_app.sh picks it up automatically.
set -e

KC="voiceflow-signing.keychain"
KPASS="voiceflow"          # protects a throwaway local dev cert only — not sensitive
CN="VoiceFlow Local Signing"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

security create-keychain -p "$KPASS" "$KC" 2>/dev/null || echo "keychain already exists"
security set-keychain-settings "$KC"          # no auto-lock
security unlock-keychain -p "$KPASS" "$KC"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$CN"; then
  echo "Signing identity '$CN' already exists."
else
  cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/vf.key" -out "$TMP/vf.crt" \
    -days 3650 -config "$TMP/openssl.cnf" -extensions v3
  openssl pkcs12 -export -inkey "$TMP/vf.key" -in "$TMP/vf.crt" -out "$TMP/vf.p12" \
    -passout pass:"$KPASS" -name "$CN"
  security import "$TMP/vf.p12" -k "$KC" -P "$KPASS" -T /usr/bin/codesign -T /usr/bin/security
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KPASS" "$KC" >/dev/null
  echo "Created signing identity '$CN'."
fi

# Ensure the keychain is on the user search list so codesign can find it.
CURRENT=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
case "$CURRENT" in
  *"$KC"*) : ;;
  *) security list-keychains -d user -s "$KC" $CURRENT ;;
esac

echo "Done. Rebuild with ./Scripts/build_app.sh — permissions will now persist."
