#!/usr/bin/env bash
# Renders app screens to build/snapshots/*.png (light + dark) and runs the app-level
# end-to-end connection test. Needs the Docker test servers (scripts/integration.sh starts them).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build/snapshots
xcodegen generate --quiet
TEST_RUNNER_QUERYWELL_SNAPSHOTS=1 TEST_RUNNER_QUERYWELL_SNAPSHOT_DIR="$ROOT/build/snapshots" \
xcodebuild -project Querywell.xcodeproj -scheme Querywell -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:QuerywellTests/SnapshotTests -only-testing:QuerywellTests/Phase7SnapshotTests \
  LM_SKIP_METADATA_EXTRACTION=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  test > build/snapshots.log 2>&1 || { tail -60 build/snapshots.log; exit 1; }
grep -E "Test run with|✘" build/snapshots.log || true
ls -1 build/snapshots/*.png
