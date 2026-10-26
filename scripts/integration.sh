#!/usr/bin/env bash
# Brings up the docker test servers and runs the package tests with QUERYWELL_INTEGRATION=1.
# usage: scripts/integration.sh [--down]   (--down stops the containers afterwards)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOWN=0
for arg in "$@"; do
  case "$arg" in
    --down) DOWN=1 ;;
    -h|--help) echo "usage: scripts/integration.sh [--down]"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker not available — skipping integration tests"
  exit 0
fi

KEYS="$ROOT/build/test-ssh"
mkdir -p "$KEYS"
chmod 700 "$KEYS"
KEYS_CREATED=0

if [ ! -f "$KEYS/id_ed25519" ]; then
  rm -f "$KEYS/id_ed25519" "$KEYS/id_ed25519.pub"
  ssh-keygen -q -t ed25519 -N "" -C querywell-test -f "$KEYS/id_ed25519"
  KEYS_CREATED=1
fi
if [ ! -f "$KEYS/passphrase" ]; then
  # 24 hex chars; not a secret of any value, only guards the throwaway test key.
  openssl rand -hex 12 | tr -d '\n' > "$KEYS/passphrase"
  chmod 600 "$KEYS/passphrase"
  rm -f "$KEYS/id_ed25519_enc" "$KEYS/id_ed25519_enc.pub"
fi
if [ ! -f "$KEYS/id_ed25519_enc" ]; then
  ssh-keygen -q -t ed25519 -N "$(cat "$KEYS/passphrase")" -C querywell-test -f "$KEYS/id_ed25519_enc"
  KEYS_CREATED=1
fi
chmod 600 "$KEYS/id_ed25519" "$KEYS/id_ed25519_enc"

EXPECTED="$(cat "$KEYS/id_ed25519.pub" "$KEYS/id_ed25519_enc.pub")"
if [ ! -f "$KEYS/authorized_keys" ] || [ "$(cat "$KEYS/authorized_keys")" != "$EXPECTED" ]; then
  printf '%s\n' "$EXPECTED" > "$KEYS/authorized_keys"
  KEYS_CREATED=1
fi
chmod 644 "$KEYS/authorized_keys"

echo "==> docker compose up"
docker compose up -d --build --wait

if [ "$KEYS_CREATED" -eq 1 ]; then
  # The entrypoint copies authorized_keys once at start; restart so new keys are picked up.
  echo "==> restarting sshd to load new authorized_keys"
  docker compose restart sshd
  docker compose up -d --wait sshd
fi

echo "==> swift test (integration)"
RC=0
(cd Packages/Core && QUERYWELL_INTEGRATION=1 QUERYWELL_TEST_SSH_DIR="$KEYS" swift test -Xswiftc -warnings-as-errors) || RC=$?

if [ "$DOWN" -eq 1 ]; then
  echo "==> docker compose down"
  docker compose down
fi
exit "$RC"
