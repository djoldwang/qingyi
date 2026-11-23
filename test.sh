#!/bin/bash
set -euo pipefail
qingyi_root="$(cd "$(dirname "$0")" && pwd)"
qingyi_work="${TMPDIR:-/tmp}/qingyi-tests"
mkdir -p "$qingyi_work"
umask 077
openssl genrsa -out "$qingyi_work/test-key.pem" 2048 2>/dev/null
trap 'rm -f "$qingyi_work/test-key.pem"' EXIT
python3 - "$qingyi_root/Sources/main.swift" "$qingyi_work/AppDelegateUnderTest.swift" <<'PYCODE'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text().split('\nif CommandLine.arguments.contains("--credential-check")')[0]
Path(sys.argv[2]).write_text(source)
PYCODE
xcrun swiftc -D QINGYI_TESTING -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$qingyi_work/cache" \
  "$qingyi_root/Tests/BuiltinTranslationTests.swift" "$qingyi_root/Tests/YoudaoDirectTests.swift" "$qingyi_root/Tests/YoudaoFastTests.swift" "$qingyi_root/Tests/GoogleNativeTests.swift" "$qingyi_root/Sources/BuiltinTranslation.swift" "$qingyi_root/Sources/GoogleWebTranslation.swift" "$qingyi_root/Sources/YoudaoWebTranslation.swift" "$qingyi_root/Sources/YoudaoTranslation.swift" "$qingyi_root/Sources/YoudaoWholeTranslation.swift" "$qingyi_root/Sources/ServiceResults.swift" \
  "$qingyi_root/Sources/YoudaoStreamingTranslation.swift" \
  "$qingyi_root/Sources/YoudaoNativeRequest.swift" "$qingyi_root/Sources/YoudaoTextPlan.swift" \
  "$qingyi_root/Sources/Core.swift" "$qingyi_root/Sources/Identity.swift" "$qingyi_root/Sources/ChatGPT.swift" \
  "$qingyi_work/AppDelegateUnderTest.swift" "$qingyi_root/Tests/HoverAppTests.swift" \
  "$qingyi_root/Sources/Hover.swift" "$qingyi_root/Sources/HoverReader.swift" "$qingyi_root/Tests/HoverTests.swift" \
  "$qingyi_root/Sources/Screenshot.swift" "$qingyi_root/Tests/ScreenshotTests.swift" \
  "$qingyi_root/Sources/Selection.swift" "$qingyi_root/Sources/Interface.swift" "$qingyi_root/Tests/Tests.swift" \
  "$qingyi_root/Sources/CustomAPI.swift" "$qingyi_root/Sources/CustomAPIViews.swift" "$qingyi_root/Tests/CustomAPITests.swift" \
  "$qingyi_root/Tests/TranslationThinkingTests.swift" "$qingyi_root/Tests/FastTranslationFallbackTests.swift" \
  "$qingyi_root/Sources/TemporaryModels.swift" "$qingyi_root/Tests/TemporaryModelTests.swift" \
  "$qingyi_root/Tests/NativeModelMenuFixture.swift" \
  "$qingyi_root/Sources/TranslationWindow.swift" \
  "$qingyi_root/Sources/Settings.swift" \
  "$qingyi_root/Sources/SettingsReturn.swift" \
  "$qingyi_root/Tests/SettingsTests.swift" \
  "$qingyi_root/Tests/ReleaseTests.swift" \
  "$qingyi_root/Tests/NativeSettingsFixture.swift" \
  -o "$qingyi_work/QingyiTests" -framework AppKit -framework SwiftUI -framework Carbon -framework Security \
  -framework WebKit -framework CryptoKit -framework Network -framework NaturalLanguage -framework ApplicationServices -framework ServiceManagement -framework Vision
"$qingyi_work/QingyiTests" --rsa-fixture "$qingyi_work/test-key.pem" "$@"
