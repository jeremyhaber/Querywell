#!/usr/bin/env bash
# Runs only the Docker-free accessibility audit (App/Tests/AccessibilityTests.swift).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodegen generate --quiet
# shellcheck source=scripts/xcode-packages.sh
source scripts/xcode-packages.sh
xcode_resolve_packages build/DerivedData
xcodebuild -project Querywell.xcodeproj -scheme Querywell -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData "${XCODE_PACKAGE_FLAGS[@]}" -only-testing:QuerywellTests/${1:-AccessibilityTests} \
  LM_SKIP_METADATA_EXTRACTION=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  test > build/a11y.log 2>&1 || true
grep -E "error:|a11y|unlabeled|walk found|Test run|✘" build/a11y.log | cut -c1-300 | sort -u | head -${2:-60}
