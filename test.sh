#!/bin/bash
set -euo pipefail
qingyi_root="$(cd "$(dirname "$0")" && pwd)"
qingyi_work="${TMPDIR:-/tmp}/qingyi-tests"
mkdir -p "$qingyi_work"
umask 077
openssl genrsa -out "$qingyi_work/test-key.pem" 2048 2>/dev/null
trap 'rm -f "$qingyi_work/test-key.pem"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$qingyi_work/cache" \
  "$qingyi_root/Sources/Core.swift" "$qingyi_root/Sources/Identity.swift" "$qingyi_root/Sources/ChatGPT.swift" \
  "$qingyi_root/Sources/Selection.swift" "$qingyi_root/Sources/Interface.swift" "$qingyi_root/Tests/Tests.swift" \
  "$qingyi_root/Sources/CustomAPI.swift" "$qingyi_root/Sources/CustomAPIViews.swift" "$qingyi_root/Tests/CustomAPITests.swift" \
  "$qingyi_root/Sources/TemporaryModels.swift" "$qingyi_root/Tests/TemporaryModelTests.swift" \
  "$qingyi_root/Tests/NativeModelMenuFixture.swift" \
  "$qingyi_root/Sources/TranslationWindow.swift" \
  "$qingyi_root/Sources/Settings.swift" \
  "$qingyi_root/Sources/SettingsReturn.swift" \
  "$qingyi_root/Tests/SettingsTests.swift" \
  "$qingyi_root/Tests/ReleaseTests.swift" \
  "$qingyi_root/Tests/NativeSettingsFixture.swift" \
  -o "$qingyi_work/QingyiTests" -framework AppKit -framework SwiftUI -framework Carbon -framework Security \
  -framework CryptoKit -framework Network -framework NaturalLanguage -framework ApplicationServices -framework ServiceManagement
"$qingyi_work/QingyiTests" --rsa-fixture "$qingyi_work/test-key.pem" "$@"
