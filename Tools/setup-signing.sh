#!/bin/bash
set -euo pipefail
qingyi_root="$(cd "$(dirname "$0")/.." && pwd)"
qingyi_signing="$qingyi_root/Signing"
qingyi_keychain="${QINGYI_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

# The pin and certificate are public. The private key stays in the keychain.
if [ -f "$qingyi_signing/identity.sha1" ]; then
  qingyi_identity="$(tr -d '[:space:]' < "$qingyi_signing/identity.sha1")"
  if ! [[ "$qingyi_identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo '签名指纹格式无效；停止，避免改变轻译身份。' >&2; exit 1
  fi
  qingyi_identities="$(security find-identity -p codesigning "$qingyi_keychain" | tr '[:lower:]' '[:upper:]')"
  qingyi_identity="$(printf '%s' "$qingyi_identity" | tr '[:lower:]' '[:upper:]')"
  if [[ "$qingyi_identities" != *"$qingyi_identity"* ]]; then
    echo '钥匙串中没有匹配的 Qingyi 签名私钥。请恢复原签名身份，不要重新生成证书。' >&2; exit 1
  fi
  printf 'Fixed signing identity: %s\n' "$qingyi_identity"
  exit 0
fi

if [ "${1:-}" != '--create' ]; then
  echo '尚未配置固定签名。首次设置需明确运行：bash Tools/setup-signing.sh --create' >&2; exit 1
fi
if security find-certificate -c Qingyi "$qingyi_keychain" >/dev/null 2>&1; then
  echo '已存在名称包含 Qingyi 的证书；停止以免重复创建，请先核对原证书。' >&2; exit 1
fi

umask 077
qingyi_work="$(mktemp -d "${TMPDIR:-/tmp}/qingyi-signing.XXXXXX")"
trap 'rm -rf "$qingyi_work"' EXIT
xcrun swiftc -suppress-warnings "$qingyi_root/Tools/import-signing.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/qingyi-signing-cache" \
  -o "$qingyi_work/import-signing" -framework Security
cat > "$qingyi_work/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
x509_extensions = code_signing
[subject]
CN = Qingyi
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$qingyi_work/certificate.cnf" -keyout "$qingyi_work/private.pem" \
  -out "$qingyi_work/certificate.pem" 2> "$qingyi_work/openssl.log"
openssl rand -hex 32 > "$qingyi_work/transport-password"
openssl pkcs12 -export -name Qingyi -in "$qingyi_work/certificate.pem" \
  -inkey "$qingyi_work/private.pem" -out "$qingyi_work/identity.p12" \
  -passout "file:$qingyi_work/transport-password"
# Non-extractable imported key; only codesign gets an explicit key access ACL.
"$qingyi_work/import-signing" "$qingyi_work/identity.p12" "$qingyi_work/transport-password" "$qingyi_keychain"
mkdir -p "$qingyi_signing"
openssl x509 -in "$qingyi_work/certificate.pem" -outform DER -out "$qingyi_signing/Qingyi.cer"
openssl x509 -in "$qingyi_work/certificate.pem" -noout -fingerprint -sha1 \
  | sed 's/.*=//;s/://g' > "$qingyi_signing/identity.sha1"
printf 'Created Qingyi code-signing identity. Private key remains in the login keychain.\n'
