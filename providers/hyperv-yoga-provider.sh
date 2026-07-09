#!/usr/bin/env bash
set -euo pipefail

YOGA_HOST="${CRABBOX_HYPERV_YOGA_HOST:-100.85.142.35}"
YOGA_USER="${CRABBOX_HYPERV_YOGA_USER:-microck}"
YOGA_PASS="${CRABBOX_HYPERV_YOGA_PASS:?CRABBOX_HYPERV_YOGA_PASS is required}"
MANAGER_PATH="${CRABBOX_HYPERV_MANAGER_PATH:-C:\\crabbox\\hyperv-yoga-manager.ps1}"
GUEST_SSH_KEY="${CRABBOX_HYPERV_GUEST_SSH_KEY:-/home/ubuntu/.ssh/id_rsa}"
PROXY_COMMAND="${CRABBOX_HYPERV_PROXY_COMMAND:-/home/ubuntu/.config/crabbox/hyperv-yoga-proxy.sh %h %p}"

INPUT=$(cat)
OPERATION=$(echo "$INPUT" | jq -r '.operation // empty')
LEASE_ID=$(echo "$INPUT" | jq -r '.desired.leaseId // .lease.leaseId // empty')
SLUG=$(echo "$INPUT" | jq -r '.desired.slug // .lease.slug // empty')
NAME=$(echo "$INPUT" | jq -r '.desired.name // .lease.name // empty')

if [ -z "$NAME" ] && [ -n "$SLUG" ]; then
  NAME="cbx-${SLUG}"
fi
if [ -z "$NAME" ] && [ -n "$LEASE_ID" ]; then
  NAME="box-$(echo "$LEASE_ID" | tail -c 9)"
fi
VM_NAME=$(echo "$NAME" | sed 's/[^a-zA-Z0-9-]//g' | cut -c1-15 | tr '[:upper:]' '[:lower:]')

ssh_yoga_ps() {
  SSHPASS="$YOGA_PASS" sshpass -e ssh \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    "${YOGA_USER}@${YOGA_HOST}" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$1\""
}

emit_lease() {
  local ip="$1"
  jq -n \
    --arg leaseId "${LEASE_ID:-cbx-${VM_NAME}}" \
    --arg slug "${SLUG:-${VM_NAME}}" \
    --arg name "$VM_NAME" \
    --arg cloudId "hyperv-yoga/$VM_NAME" \
    --arg host "$ip" \
    --arg key "$GUEST_SSH_KEY" \
    --arg proxyCommand "$PROXY_COMMAND" \
    '{
      protocolVersion: 1,
      lease: {
        leaseId: $leaseId,
        slug: $slug,
        name: $name,
        cloudId: $cloudId,
        status: "active",
        ssh: {
          host: $host,
          port: "22",
          user: "Administrator",
          key: $key,
          readyCheck: "echo ready",
          sshConfigProxy: true,
          proxyCommand: $proxyCommand,
          noControlMaster: true
        }
      }
    }'
}

case "$OPERATION" in
  doctor)
    ssh_yoga_ps "& '$MANAGER_PATH' -Action doctor -Template win11-arm64" >/dev/null
    echo '{"protocolVersion":1,"message":"ok"}'
    ;;
  acquire)
    result=$(ssh_yoga_ps "& '$MANAGER_PATH' -Action create -Name '$VM_NAME' -Template win11-arm64" 2>&1)
    ip=$(echo "$result" | grep -oP 'IP:\s+\K[\d.]+' | head -1)
    if [ -z "$ip" ]; then
      echo "$result" >&2
      exit 1
    fi
    emit_lease "$ip"
    ;;
  resolve)
    status=$(ssh_yoga_ps "& '$MANAGER_PATH' -Action status -Name '$VM_NAME'")
    ip=$(echo "$status" | jq -r '.ip // empty')
    if [ -z "$ip" ]; then
      echo "VM $VM_NAME not found or has no IP" >&2
      exit 1
    fi
    emit_lease "$ip"
    ;;
  list)
    raw=$(ssh_yoga_ps "& '$MANAGER_PATH' -Action list" 2>/dev/null || echo "[]")
    echo "$raw" | jq 'if type == "array" then . else [.] end | {
      protocolVersion: 1,
      leases: map({
        name: .name,
        cloudId: ("hyperv-yoga/" + .name),
        status: (if .state == "Running" then "active" else "stopped" end)
      })
    }'
    ;;
  release)
    ssh_yoga_ps "& '$MANAGER_PATH' -Action destroy -Name '$VM_NAME'" >/dev/null 2>&1 || true
    echo '{"protocolVersion":1,"message":"released"}'
    ;;
  touch)
    echo '{"protocolVersion":1,"message":"ok"}'
    ;;
  cleanup)
    echo '{"protocolVersion":1,"message":"cleanup handled by manager destroy"}'
    ;;
  *)
    echo "Unknown operation: $OPERATION" >&2
    exit 1
    ;;
esac

