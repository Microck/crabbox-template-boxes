#!/usr/bin/env bash
set -euo pipefail

GUEST_HOST="${1:?guest host required}"
GUEST_PORT="${2:?guest port required}"
YOGA_HOST="${CRABBOX_HYPERV_YOGA_HOST:-100.85.142.35}"
YOGA_USER="${CRABBOX_HYPERV_YOGA_USER:-microck}"

if [ -z "${CRABBOX_HYPERV_YOGA_PASS:-}" ]; then
  echo "CRABBOX_HYPERV_YOGA_PASS is required" >&2
  exit 2
fi

SSHPASS="$CRABBOX_HYPERV_YOGA_PASS" exec sshpass -e ssh \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 \
  -W "${GUEST_HOST}:${GUEST_PORT}" \
  "${YOGA_USER}@${YOGA_HOST}"

