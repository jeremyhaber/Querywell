#!/usr/bin/env bash
# Runs only the Core-free contrast audit (App/Tests/ContrastTests.swift); no Docker needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodegen generate --quiet
# shellcheck source=scripts/xcode-packages.sh
source scripts/xcode-packages.sh
xcode_resolve_packages build/DerivedData
xcodebuild -project Querywell.xcodeproj -scheme Querywell -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData "${XCODE_PACKAGE_FLAGS[@]}" -only-testing:QuerywellTests/ContrastTests \
  LM_SKIP_METADATA_EXTRACTION=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  test > build/contrast.log 2>&1 || true
grep -E "error:|\] [a-zA-Z]+ on |Test run|✘|\.\.\. " build/contrast.log | sort -u | head -${1:-200}
