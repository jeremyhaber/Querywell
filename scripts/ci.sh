#!/usr/bin/env bash
# Full build + test with warnings as errors. The phase gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_XCODE=0
SKIP_PACKAGE=0
SKIP_INTEGRATION=0
for arg in "$@"; do
  case "$arg" in
    --skip-xcode) SKIP_XCODE=1 ;;
    --skip-package) SKIP_PACKAGE=1 ;;
    --skip-integration) SKIP_INTEGRATION=1 ;;
    -h|--help) echo "usage: scripts/ci.sh [--skip-xcode] [--skip-package] [--skip-integration]"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

STEPS=()
FAILED=0
record() { STEPS+=("$1: $2"); [ "$2" = "PASS" ] || FAILED=1; }

summary() {
  echo
  echo "================ CI SUMMARY ================"
  for s in "${STEPS[@]}"; do echo "  $s"; done
  if [ "$FAILED" -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
  echo "============================================"
  exit "$FAILED"
}

mkdir -p build

# a) generate project
if [ "$SKIP_XCODE" -eq 0 ]; then
  echo "==> xcodegen generate"
  if xcodegen generate --quiet; then record "xcodegen generate" PASS; else record "xcodegen generate" FAIL; summary; fi
fi

# b) package
if [ "$SKIP_PACKAGE" -eq 0 ]; then
  echo "==> swift build (Packages/Core)"
  if (cd Packages/Core && swift build -Xswiftc -warnings-as-errors); then record "package build" PASS; else record "package build" FAIL; summary; fi
  echo "==> swift test (Packages/Core)"
  if (cd Packages/Core && swift test -Xswiftc -warnings-as-errors); then record "package test" PASS; else record "package test" FAIL; summary; fi
fi

# b2) integration tests (docker); skipped when Docker is unavailable
if [ "$SKIP_INTEGRATION" -eq 1 ]; then
  STEPS+=("integration tests: SKIPPED")
else
  echo "==> scripts/integration.sh"
  INT_LOG="$(mktemp)"
  if scripts/integration.sh 2>&1 | tee "$INT_LOG"; then
    if grep -q "Docker not available" "$INT_LOG"; then STEPS+=("integration tests: SKIPPED"); else record "integration tests" PASS; fi
  else
    record "integration tests" FAIL; rm -f "$INT_LOG"; summary
  fi
  rm -f "$INT_LOG"
fi

# c) app
if [ "$SKIP_XCODE" -eq 0 ]; then
  echo "==> xcodebuild build test"
  LOG="build/xcodebuild.log"
  set +e
  xcodebuild -project Querywell.xcodeproj -scheme Querywell \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    LM_SKIP_METADATA_EXTRACTION=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= \
    build test > "$LOG" 2>&1
  RC=$?
  set -e
  if [ "$RC" -ne 0 ]; then
    echo "xcodebuild failed (exit $RC); last 80 lines of $LOG:"
    if command -v xcbeautify >/dev/null 2>&1; then xcbeautify < "$LOG" | tail -80; else tail -80 "$LOG"; fi
    record "xcodebuild build+test" FAIL
  else
    record "xcodebuild build+test" PASS
  fi
  WARNINGS="$(grep -E "warning:" "$LOG" | sort -u || true)"
  if [ -n "$WARNINGS" ]; then
    echo "Warnings found in $LOG:"
    echo "$WARNINGS"
    record "xcodebuild warnings" FAIL
  else
    record "xcodebuild warnings" PASS
  fi
fi

summary
