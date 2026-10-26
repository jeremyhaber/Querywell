#!/usr/bin/env bash
# Sets MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml.
#   scripts/bump-version.sh 1.1.0         # version 1.1.0, build = current build + 1
#   scripts/bump-version.sh 1.1.0 7       # explicit build number
#   scripts/bump-version.sh --show        # print current version (build)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YML="$ROOT/project.yml"

usage() {
  cat <<'EOF'
usage: scripts/bump-version.sh <version> [build]
       scripts/bump-version.sh --show

  <version>  semantic version, e.g. 1.2.0 (MARKETING_VERSION)
  [build]    integer build number (CURRENT_PROJECT_VERSION); default: current + 1
EOF
}

current_version() { sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$YML" | head -1; }
current_build() { sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$YML" | head -1; }

case "${1:-}" in
  -h|--help|"") usage; [ -n "${1:-}" ] && exit 0 || exit 2 ;;
  --show) echo "$(current_version) ($(current_build))"; exit 0 ;;
esac

VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3 (got '$VERSION')" >&2; exit 2
fi
OLD_BUILD="$(current_build)"
BUILD="${2:-$((OLD_BUILD + 1))}"
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "error: build must be an integer (got '$BUILD')" >&2; exit 2
fi

TMP="$(mktemp)"
sed -e "s/^\( *MARKETING_VERSION:\).*$/\1 $VERSION/" \
    -e "s/^\( *CURRENT_PROJECT_VERSION:\).*$/\1 $BUILD/" "$YML" > "$TMP"
cat "$TMP" > "$YML"
rm -f "$TMP"
echo "project.yml: version $VERSION (build $BUILD)"
