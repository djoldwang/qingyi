#!/bin/bash
set -euo pipefail
qingyi_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$qingyi_root/Tools/setup-signing.sh"
qingyi_input="${1:?Usage: test-signing.sh installer.zip [updated-installer.zip]}"
qingyi_identity="$(tr -d '[:space:]' < "$qingyi_root/Signing/identity.sha1")"
qingyi_keychain="${QINGYI_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
qingyi_requirement="identifier \"com.laowang.qingyi\" and certificate leaf = H\"$qingyi_identity\""
qingyi_work="$(mktemp -d "${TMPDIR:-/tmp}/qingyi-signing-test.XXXXXX")"
trap 'rm -rf "$qingyi_work"' EXIT
ditto -x -k "$qingyi_input" "$qingyi_work/base"
qingyi_base="$qingyi_work/base/轻译.app"
qingyi_next="$qingyi_work/next/轻译.app"
ditto --norsrc --noextattr "$qingyi_base" "$qingyi_next"
qingyi_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$qingyi_next/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((qingyi_build + 1))" "$qingyi_next/Contents/Info.plist"
codesign --force --sign "$qingyi_identity" --keychain "$qingyi_keychain" \
  --timestamp=none --identifier com.laowang.qingyi \
  --requirements "=designated => $qingyi_requirement" "$qingyi_next"
for qingyi_app in "$qingyi_base" "$qingyi_next"; do
  codesign --verify --strict -R "=$qingyi_requirement" "$qingyi_app"
done
echo 'PASS both builds validate against the same certificate-pinned application identity'
qingyi_base_dr="$(codesign -d -r- "$qingyi_base" 2>&1 | awk '/designated =>/{sub(/^# /, "");print}')"
qingyi_next_dr="$(codesign -d -r- "$qingyi_next" 2>&1 | awk '/designated =>/{sub(/^# /, "");print}')"
test -n "$qingyi_base_dr" && test "$qingyi_base_dr" = "$qingyi_next_dr"
echo 'PASS designated requirements remain identical after an update'
qingyi_base_hash="$(codesign -d --verbose=4 "$qingyi_base" 2>&1 | sed -n 's/^CDHash=//p')"
qingyi_next_hash="$(codesign -d --verbose=4 "$qingyi_next" 2>&1 | sed -n 's/^CDHash=//p')"
test -n "$qingyi_base_hash" && test -n "$qingyi_next_hash" && test "$qingyi_base_hash" != "$qingyi_next_hash"
echo 'PASS the updated code hash changes independently of the stable identity'
codesign -d --extract-certificates="$qingyi_work/leaf" "$qingyi_next"
cmp "$qingyi_root/Signing/Qingyi.cer" "$qingyi_work/leaf0"
echo 'PASS the distributed certificate matches the pinned public certificate'
ditto --norsrc --noextattr "$qingyi_base" "$qingyi_work/other/轻译.app"
codesign --force --sign - --identifier com.laowang.qingyi "$qingyi_work/other/轻译.app"
if codesign --verify --strict -R "=$qingyi_requirement" "$qingyi_work/other/轻译.app" >/dev/null 2>&1; then
  echo 'FAIL an ad-hoc replacement unexpectedly matched the fixed identity' >&2; exit 1
fi
echo 'PASS an ad-hoc replacement with the same app identifier is rejected'
if [ "$#" -gt 1 ]; then
  ditto -c -k --keepParent --norsrc --noextattr "$qingyi_next" "$2"
  printf 'Verified update installer: %s (build %s)\n' "$2" "$((qingyi_build + 1))"
fi
