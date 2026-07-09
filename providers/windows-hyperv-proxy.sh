#!/usr/bin/env bash
set -euo pipefail

GUEST_HOST="${1:?guest host required}"
GUEST_PORT="${2:?guest port required}"
WINDOWS_HOST="${CRABBOX_WINDOWS_HOST:?CRABBOX_WINDOWS_HOST is required}"
WINDOWS_USER="${CRABBOX_WINDOWS_USER:-Administrator}"

if [ -z "${CRABBOX_WINDOWS_PASS:-}" ]; then
  echo "CRABBOX_WINDOWS_PASS is required" >&2
  exit 2
fi

SSHPASS="$CRABBOX_WINDOWS_PASS" exec sshpass -e ssh \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 \
  -W "${GUEST_HOST}:${GUEST_PORT}" \
  "${WINDOWS_USER}@${WINDOWS_HOST}"
