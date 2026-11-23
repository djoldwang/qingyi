#!/bin/bash
set -euo pipefail
qingyi_root="$(cd "$(dirname "$0")" && pwd)"
bash "$qingyi_root/Tools/setup-signing.sh"
qingyi_identity="$(tr -d '[:space:]' < "$qingyi_root/Signing/identity.sha1")"
qingyi_keychain="${QINGYI_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
qingyi_requirement="identifier \"com.laowang.qingyi\" and certificate leaf = H\"$qingyi_identity\""
qingyi_output="${1:-$(dirname "$qingyi_root")/轻译.app}"
qingyi_cache="${TMPDIR:-/tmp}/qingyi-swift-cache"
qingyi_staging="$(mktemp -d "${TMPDIR:-/tmp}/qingyi-build.XXXXXX")"
trap 'rm -rf "$qingyi_staging"' EXIT
qingyi_app="$qingyi_staging/轻译.app"
mkdir -p "$qingyi_cache" "$qingyi_app/Contents/MacOS" "$qingyi_app/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$qingyi_cache" \
  "$qingyi_root"/Sources/*.swift -o "$qingyi_app/Contents/MacOS/Qingyi" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Carbon \
  -framework WebKit -framework Security -framework CryptoKit -framework Network -framework NaturalLanguage -framework ServiceManagement -framework Vision
cp "$qingyi_root/Resources/Info.plist" "$qingyi_app/Contents/Info.plist"
if [ -f "$qingyi_root/Resources/AppIcon.icns" ]; then cp "$qingyi_root/Resources/AppIcon.icns" "$qingyi_app/Contents/Resources/AppIcon.icns"; fi
cp "$qingyi_root/LICENSE" "$qingyi_root/THIRD_PARTY_NOTICES.md" "$qingyi_app/Contents/Resources/"
# Sign on a local temporary volume: File Provider adds incompatible FinderInfo in Documents.
codesign --force --sign "$qingyi_identity" --keychain "$qingyi_keychain" \
  --timestamp=none --identifier com.laowang.qingyi \
  --requirements "=designated => $qingyi_requirement" "$qingyi_app"
codesign --verify --strict -R "=$qingyi_requirement" "$qingyi_app"
ditto -c -k --keepParent --norsrc --noextattr "$qingyi_app" "${qingyi_output%.app}-macOS.zip"
# The default build leaves only a ZIP. A loose second .app in Documents is indexed
# by Spotlight/Launch Services and creates a duplicate icon next to the installed app.
if [ "$#" -gt 0 ]; then
  ditto --norsrc --noextattr "$qingyi_app" "$qingyi_output"
  printf 'Built app: %s\n' "$qingyi_output"
fi
printf 'Clean installer archive: %s\n' "${qingyi_output%.app}-macOS.zip"
