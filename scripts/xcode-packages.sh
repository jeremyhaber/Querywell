#!/usr/bin/env bash
# Sourced by ci.sh / snapshots.sh. Xcode resolves the *whole* project graph (local package Core + SwiftTerm)
# and writes that superset into Packages/Core/Package.resolved, while `swift build` in Packages/Core prunes it
# back to Core's own pins - two writers, endless churn in git. So: resolve once (letting Xcode fetch what it
# needs), put the tracked file back, and build with -disableAutomaticPackageResolution so the build itself
# never rewrites it. SwiftTerm is an exact pin in project.yml, so it needs no lock-file entry.
# Sets XCODE_PACKAGE_FLAGS (to be added to xcodebuild invocations).
xcode_resolve_packages() {
  local derived="$1"
  local resolved="Packages/Core/Package.resolved" backup
  backup="$(mktemp)"
  cp "$resolved" "$backup"
  xcodebuild -project Querywell.xcodeproj -scheme Querywell -derivedDataPath "$derived" -resolvePackageDependencies >/dev/null 2>&1 || true
  cp "$backup" "$resolved"
  rm -f "$backup"
  XCODE_PACKAGE_FLAGS=(-disableAutomaticPackageResolution)
}
