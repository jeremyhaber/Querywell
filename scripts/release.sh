#!/usr/bin/env bash
# Developer ID signed + notarized release build of Querywell.
# Output: build/release/ (Querywell-<version>.dmg, Querywell-<version>.zip, SHA256SUMS.txt, logs/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage: scripts/release.sh [--dry-run] [--no-notarize] [--skip-tests] [-h|--help]

Builds, signs (Developer ID, hardened runtime, secure timestamp), notarizes and staples Querywell,
then packages Querywell-<version>.dmg and .zip with SHA-256 checksums in build/release/.

Options
  --dry-run        Print every command without executing it. Needs only QUERYWELL_TEAM_ID;
                   no keychain identity or notary profile is required.
  --no-notarize    Local signed build: skip notarization/stapling and the Gatekeeper checks.
                   (QUERYWELL_NOTARY_PROFILE not needed.)
  --skip-tests     Skip scripts/ci.sh --skip-integration before archiving.
  --verify-only APP
                   Only run the signature verification on an existing .app (needs QUERYWELL_TEAM_ID).

Environment
  QUERYWELL_TEAM_ID          (required) 10-character Apple Developer Team ID, e.g. ABCDE12345.
  QUERYWELL_SIGN_IDENTITY    Certificate name prefix. Default: "Developer ID Application".
                             The keychain must hold a matching identity for the team, i.e.
                             "Developer ID Application: Your Name (TEAMID)".
  QUERYWELL_NOTARY_PROFILE   Keychain profile name for `xcrun notarytool` (required unless
                             --no-notarize / --dry-run). Create it once with:
                               xcrun notarytool store-credentials "<profile>" \
                                 --apple-id "<apple id>" --team-id "$QUERYWELL_TEAM_ID" \
                                 --password "<app-specific password from appleid.apple.com>"
  QUERYWELL_VERSION          Override MARKETING_VERSION (default: project.yml; see scripts/bump-version.sh).
  QUERYWELL_BUILD            Override CURRENT_PROJECT_VERSION (default: project.yml).
EOF
}

DRY_RUN=0
NOTARIZE=1
RUN_TESTS=1
VERIFY_ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    --skip-tests) RUN_TESTS=0 ;;
    --verify-only) shift; VERIFY_ONLY="${1:-}"; [ -n "$VERIFY_ONLY" ] || { echo "error: --verify-only needs an .app path" >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# print the command (shell-quoted); execute unless --dry-run
run() {
  printf '+'; printf ' %q' "$@"; echo
  [ "$DRY_RUN" -eq 1 ] || "$@"
}

# like run, but send output to a log file and show its tail on failure
run_logged() {
  local log="$1"; shift
  printf '+'; printf ' %q' "$@"; printf ' > %q 2>&1\n' "$log"
  [ "$DRY_RUN" -eq 1 ] && return 0
  if ! "$@" > "$log" 2>&1; then
    echo "command failed; last 60 lines of $log:" >&2
    tail -60 "$log" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------- configuration
TEAM="${QUERYWELL_TEAM_ID:-}"
[ -n "$TEAM" ] || die "QUERYWELL_TEAM_ID is required (your 10-character Apple Developer Team ID). See --help."
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "QUERYWELL_TEAM_ID '$TEAM' is not a 10-character Team ID (A-Z, 0-9)."
IDENTITY_PREFIX="${QUERYWELL_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${QUERYWELL_NOTARY_PROFILE:-}"

VERSION="${QUERYWELL_VERSION:-$(scripts/bump-version.sh --show | sed 's/ (.*//')}"
BUILD="${QUERYWELL_BUILD:-$(scripts/bump-version.sh --show | sed 's/.*(\(.*\))/\1/')}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' must look like 1.2.3"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "build '$BUILD' must be an integer"

OUT="$ROOT/build/release"
ARCHIVE="$OUT/Querywell.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Querywell.app"
OPTIONS_PLIST="$OUT/ExportOptions.plist"
DMG="$OUT/Querywell-$VERSION.dmg"
ZIP="$OUT/Querywell-$VERSION.zip"
LOGS="$OUT/logs"
IDENTITY="$IDENTITY_PREFIX"   # resolved to the exact keychain identity during preflight

# ---------------------------------------------------------------- verification
# Every Mach-O in the bundle must carry our team ID, hardened runtime and a secure timestamp.
verify_signing() {
  local app="$1"
  step "Verify signatures"
  run codesign --verify --deep --strict --verbose=2 "$app"
  run codesign -d --entitlements - --xml "$app"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (would check: no App Sandbox entitlement; no entitlements other than com.apple.security.app-sandbox=false;"
    echo "   every Mach-O under the bundle incl. Frameworks/ has TeamIdentifier=$TEAM, flags with 'runtime', and a secure timestamp)"
    return 0
  fi

  local ents
  ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
  # key=value lines for the signed entitlements (booleans normalised to true/false)
  local keys=""
  if [ -n "$ents" ]; then
    keys="$(printf '%s' "$ents" | plutil -p - 2>/dev/null | sed -n 's/^ *"\(.*\)" => \(.*\)$/\1=\2/p' | sed -e 's/=1$/=true/' -e 's/=0$/=false/' || true)"
  fi
  if printf '%s\n' "$keys" | grep -q '^com.apple.security.app-sandbox=true$'; then
    die "app is sandboxed; Querywell must not be (it launches ssh/mysqldump/pg_dump)."
  fi
  local unexpected
  unexpected="$(printf '%s\n' "$keys" | grep -v '^$' | grep -v '^com.apple.security.app-sandbox=false$' || true)"
  [ -z "$unexpected" ] || die "unexpected entitlements in signed app:
$unexpected
(allowed: only com.apple.security.app-sandbox=false; add others deliberately in App/Resources/Querywell.entitlements and update this script)"
  echo "  entitlements: ok (no sandbox, nothing else)"

  local failures=0 count=0 f info
  while IFS= read -r f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    count=$((count + 1))
    info="$(codesign -dv --verbose=4 "$f" 2>&1 || true)"
    local rel="${f#"$app"/}"
    if ! printf '%s\n' "$info" | grep -q "^TeamIdentifier=$TEAM$"; then
      echo "  FAIL $rel: TeamIdentifier is not $TEAM" >&2; failures=$((failures + 1))
    fi
    if ! printf '%s\n' "$info" | grep -E '^CodeDirectory .*flags=' | grep -q 'runtime'; then
      echo "  FAIL $rel: hardened runtime flag missing" >&2; failures=$((failures + 1))
    fi
    if ! printf '%s\n' "$info" | grep -q '^Timestamp='; then
      echo "  FAIL $rel: no secure timestamp" >&2; failures=$((failures + 1))
    fi
  done < <(find "$app" -type f)
  [ "$count" -gt 0 ] || die "found no Mach-O files in $app"
  [ "$failures" -eq 0 ] || die "$failures signing problem(s) in $count Mach-O file(s); see above."
  echo "  $count Mach-O file(s): team $TEAM, hardened runtime, secure timestamp: ok"
}

if [ -n "$VERIFY_ONLY" ]; then
  [ -d "$VERIFY_ONLY" ] || die "no such app: $VERIFY_ONLY"
  verify_signing "$VERIFY_ONLY"
  exit 0
fi

# ---------------------------------------------------------------- preflight
step "Preflight"
echo "  team $TEAM, identity prefix \"$IDENTITY_PREFIX\", version $VERSION ($BUILD)"
echo "  dry-run: $DRY_RUN, notarize: $NOTARIZE, tests: $RUN_TESTS"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  (dry run: skipping Xcode / xcodegen / keychain identity / notary profile checks)"
  IDENTITY="$IDENTITY_PREFIX: <name> ($TEAM)"
else
  xcodebuild -version >/dev/null 2>&1 || die "Xcode command line tools not found. Install Xcode 26 and run: sudo xcode-select -s /Applications/Xcode.app"
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found. Install with: brew install xcodegen"
  command -v xcrun >/dev/null 2>&1 || die "xcrun not found."
  if [ "$NOTARIZE" -eq 1 ]; then
    [ -n "$NOTARY_PROFILE" ] || die "QUERYWELL_NOTARY_PROFILE is required (or pass --no-notarize). Create it once with:
  xcrun notarytool store-credentials \"<profile>\" --apple-id \"<apple id>\" --team-id \"$TEAM\" --password \"<app-specific password>\""
  fi

  IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  CANDIDATES="$(printf '%s\n' "$IDS" | grep -F "\"$IDENTITY_PREFIX" || true)"
  [ -n "$CANDIDATES" ] || die "no valid code signing identity starting with \"$IDENTITY_PREFIX\" in your keychains.
Install your Developer ID Application certificate (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com),
then check: security find-identity -v -p codesigning"
  MATCH="$(printf '%s\n' "$CANDIDATES" | grep -F "($TEAM)" || true)"
  [ -n "$MATCH" ] || die "found \"$IDENTITY_PREFIX\" identities, but none for team $TEAM:
$CANDIDATES"
  if [ "$(printf '%s\n' "$MATCH" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "  note: multiple matching identities; using the first:" >&2
    printf '%s\n' "$MATCH" >&2
  fi
  IDENTITY="$(printf '%s\n' "$MATCH" | head -1 | sed -n 's/^[^"]*"\(.*\)".*$/\1/p')"
  echo "  signing identity: $IDENTITY"

  if [ "$NOTARIZE" -eq 1 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || die "notarytool cannot use keychain profile \"$NOTARY_PROFILE\" (missing or invalid credentials). Create it with:
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id \"<apple id>\" --team-id \"$TEAM\" --password \"<app-specific password>\""
    echo "  notary profile \"$NOTARY_PROFILE\": ok"
  fi
fi

# ---------------------------------------------------------------- generate project
step "Clean output + generate project"
run rm -rf "$OUT" Querywell.xcodeproj
run mkdir -p "$LOGS"
run xcodegen generate --quiet

# ---------------------------------------------------------------- tests
if [ "$RUN_TESTS" -eq 1 ]; then
  step "Tests (scripts/ci.sh --skip-integration)"
  run scripts/ci.sh --skip-integration
else
  step "Tests skipped (--skip-tests)"
fi

# ---------------------------------------------------------------- archive + export
step "Archive (Release, Developer ID, hardened runtime)"
VERSION_SETTINGS=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD")
run_logged "$LOGS/archive.log" xcodebuild archive \
  -project Querywell.xcodeproj -scheme Querywell -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGN_STYLE=Manual "DEVELOPMENT_TEAM=$TEAM" "CODE_SIGN_IDENTITY=$IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  LM_SKIP_METADATA_EXTRACTION=YES "${VERSION_SETTINGS[@]}"

step "Export (developer-id)"
echo "+ write $OPTIONS_PLIST"
OPTIONS_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingCertificate</key><string>$IDENTITY_PREFIX</string>
	<key>destination</key><string>export</string>
	<key>stripSwiftSymbols</key><true/>
</dict>
</plist>"
if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n' "$OPTIONS_XML" | sed 's/^/    | /'; else printf '%s\n' "$OPTIONS_XML" > "$OPTIONS_PLIST"; fi
run_logged "$LOGS/export.log" xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS_PLIST" -exportPath "$EXPORT"

verify_signing "$APP"

# ---------------------------------------------------------------- notarize app, staple
notarize() {
  local file="$1" name="$2" out id status
  out="$LOGS/notarytool-$name.txt"
  step "Notarize $name"
  printf '+'; printf ' %q' xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait; printf ' | tee %q\n' "$out"
  [ "$DRY_RUN" -eq 1 ] && { echo "+ (on failure: xcrun notarytool log <submission id> --keychain-profile \"\$QUERYWELL_NOTARY_PROFILE\")"; return 0; }
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$out" || true
  id="$(awk '/^ *id:/ {print $2; exit}' "$out")"
  status="$(awk '/^ *status:/ {s=$2} END {print s}' "$out")"
  if [ "$status" != "Accepted" ]; then
    echo "notarization of $name finished with status '${status:-unknown}'" >&2
    if [ -n "$id" ]; then
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tee "$LOGS/notarytool-$name-log.json" >&2 || true
    fi
    exit 1
  fi
}

if [ "$NOTARIZE" -eq 1 ]; then
  # Notarize + staple the app first so the app inside the DMG carries its own ticket.
  step "Zip app for notarization"
  run ditto -c -k --keepParent "$APP" "$OUT/Querywell-notarize.zip"
  notarize "$OUT/Querywell-notarize.zip" app
  step "Staple app"
  run xcrun stapler staple "$APP"
  run xcrun stapler validate "$APP"
  run rm -f "$OUT/Querywell-notarize.zip"
fi

# ---------------------------------------------------------------- dmg + zip
step "Create DMG and zip"
STAGE="$OUT/dmg-stage"
run mkdir -p "$STAGE"
run ditto "$APP" "$STAGE/Querywell.app"
run ln -s /Applications "$STAGE/Applications"
run hdiutil create -volname "Querywell $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
run rm -rf "$STAGE"
run codesign --sign "$IDENTITY" --timestamp "$DMG"
run codesign --verify --verbose=2 "$DMG"
run ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" -eq 1 ]; then
  notarize "$DMG" dmg
  step "Staple DMG"
  run xcrun stapler staple "$DMG"
  run xcrun stapler validate "$DMG"

  step "Gatekeeper assessment"
  run spctl -a -vvv -t install "$DMG"
  run spctl -a -vv "$APP"
else
  step "Gatekeeper assessment skipped (--no-notarize: local signed build, Gatekeeper will not accept it)"
fi

# ---------------------------------------------------------------- checksums
step "Checksums"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ (cd $OUT && shasum -a 256 $(basename "$DMG") $(basename "$ZIP") > SHA256SUMS.txt)"
else
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt && cat SHA256SUMS.txt)
fi

step "Done"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run only; nothing was executed. Outputs would be in $OUT"
else
  echo "Release $VERSION ($BUILD) artifacts in $OUT"
  [ "$NOTARIZE" -eq 1 ] || echo "NOTE: not notarized (--no-notarize)."
fi
