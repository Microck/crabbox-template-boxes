#!/usr/bin/env bash
#
# Crabbox external provider for Windows 10 ARM64 through QEMU on a Windows host.
# The Windows guest is not a Docker box; this wraps it in Crabbox's lease protocol
# so the session goal remains "make Crabbox boxes" rather than a loose VM.
set -euo pipefail

WINDOWS_HOST="${CRABBOX_WINDOWS_HOST:-100.85.142.35}"
WINDOWS_USER="${CRABBOX_WINDOWS_USER:-microck}"
WINDOWS_PASS="${CRABBOX_WINDOWS_PASS:?CRABBOX_WINDOWS_PASS is required}"
MANAGER_PATH="${CRABBOX_QEMU_MANAGER_PATH:-C:\\crabbox\\win10-qemu-manager.ps1}"
GUEST_SSH_KEY="${CRABBOX_QEMU_GUEST_SSH_KEY:-/home/ubuntu/.ssh/id_rsa}"
PROTOCOL_VERSION=1
TUNNEL_DIR="/home/ubuntu/.crabbox/qemu-tunnels"

REQUEST=$(cat)
OP=$(echo "$REQUEST" | jq -r '.operation // ""')

get_lease_id() { echo "$REQUEST" | jq -r '.desired.leaseId // .lease.leaseId // ""'; }
get_slug() { echo "$REQUEST" | jq -r '.desired.slug // .lease.slug // ""'; }

get_template() {
  local template
  template=$(echo "$REQUEST" | jq -r '.config.template // empty')
  if [ -z "$template" ]; then
    template="win10-arm64-clean-qemu-ready"
  fi
  echo "$template"
}

get_net_device() {
  local net_device
  net_device=$(echo "$REQUEST" | jq -r '.config.netDevice // empty')
  if [ -z "$net_device" ]; then
    net_device="virtio-net-pci"
  fi
  echo "$net_device"
}

get_cpu_count() {
  local cpu_count
  cpu_count=$(echo "$REQUEST" | jq -r '.config.cpuCount // .config.cpus // empty')
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || [ "$cpu_count" -lt 1 ]; then
    cpu_count=1
  fi
  echo "$cpu_count"
}

get_memory_mb() {
  local memory_mb
  memory_mb=$(echo "$REQUEST" | jq -r '.config.memoryMb // .config.memoryMB // .config.memory // empty')
  if ! [[ "$memory_mb" =~ ^[0-9]+$ ]] || [ "$memory_mb" -lt 1024 ]; then
    memory_mb=3072
  fi
  echo "$memory_mb"
}

vm_name() {
  local slug
  slug=$(get_slug)
  if [ -z "$slug" ]; then
    slug="$(get_lease_id | tail -c 9)"
  fi
  printf 'qemu-%s' "$slug" | tr -cd '[:alnum:]-' | cut -c1-32
}

ssh_windows_ps() {
  sshpass -p "$WINDOWS_PASS" ssh \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    "${WINDOWS_USER}@${WINDOWS_HOST}" \
    "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$1\""
}

start_tunnel() {
  local lease_id="$1" host_port="$2"
  local port pid

  mkdir -p "$TUNNEL_DIR"
  port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

  SSHPASS="$WINDOWS_PASS" setsid sshpass -e ssh \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -N -L "${port}:127.0.0.1:${host_port}" \
    "${WINDOWS_USER}@${WINDOWS_HOST}" \
    < /dev/null \
    > "$TUNNEL_DIR/${lease_id}.log" 2>&1 &
  pid=$!

  echo "$pid" > "$TUNNEL_DIR/${lease_id}.pid"
  echo "$port" > "$TUNNEL_DIR/${lease_id}.port"
  echo "$host_port" > "$TUNNEL_DIR/${lease_id}.host-port"

  for _ in $(seq 1 30); do
    if ss -tlnH 2>/dev/null | grep -q ":${port}\\b"; then
      echo "$port"
      return 0
    fi
    sleep 1
  done

  kill "$pid" 2>/dev/null || true
  rm -f "$TUNNEL_DIR/${lease_id}.pid" "$TUNNEL_DIR/${lease_id}.port" "$TUNNEL_DIR/${lease_id}.host-port"
  return 1
}

stop_tunnel() {
  local lease_id="$1"
  local pid_file="$TUNNEL_DIR/${lease_id}.pid"

  if [ -f "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi

  rm -f "$TUNNEL_DIR/${lease_id}.pid" "$TUNNEL_DIR/${lease_id}.port" "$TUNNEL_DIR/${lease_id}.host-port" "$TUNNEL_DIR/${lease_id}.log"
}

get_tunnel_port() {
  local lease_id="$1"
  cat "$TUNNEL_DIR/${lease_id}.port" 2>/dev/null || true
}

emit_lease() {
  local name="$1" port="$2" host_port="$3"
  local template net_device cpu_count memory_mb
  template=$(get_template)
  net_device=$(get_net_device)
  cpu_count=$(get_cpu_count)
  memory_mb=$(get_memory_mb)

  jq -n \
    --arg leaseId "$(get_lease_id)" \
    --arg slug "$(get_slug)" \
    --arg name "$name" \
    --arg cloudId "windows-qemu/$name" \
    --arg host "127.0.0.1" \
    --arg port "$port" \
    --arg windowsHost "$WINDOWS_HOST" \
    --arg hostPort "$host_port" \
    --arg template "$template" \
    --arg netDevice "$net_device" \
    --arg cpuCount "$cpu_count" \
    --arg memoryMb "$memory_mb" \
    --arg guestSSHKey "$GUEST_SSH_KEY" \
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
          port: $port,
          user: "crabbox",
          key: $guestSSHKey,
          noControlMaster: true,
          readyCheck: "cmd.exe /c echo connected"
        },
        metadata: {
          provider: "windows-qemu-win10",
          target: "windows",
          template: $template,
          netDevice: $netDevice,
          cpuCount: ($cpuCount | tonumber),
          memoryMb: ($memoryMb | tonumber),
          windowsHost: $windowsHost,
          hostPort: ($hostPort | tonumber)
        }
      }
    }'
}

case "$OP" in
  doctor)
    ssh_windows_ps "& '$MANAGER_PATH' -Action doctor -Template '$(get_template)'" >/dev/null
    jq -n '{protocolVersion: 1, message: "QEMU Win10 provider ready"}'
    ;;

  acquire)
    NAME=$(vm_name)
    LEASE_ID=$(get_lease_id)
    stop_tunnel "$LEASE_ID"
    RESULT=$(ssh_windows_ps "& '$MANAGER_PATH' -Action create -Name '$NAME' -Template '$(get_template)' -NetDevice '$(get_net_device)' -CpuCount $(get_cpu_count) -MemoryMb $(get_memory_mb)")
    HOST_PORT=$(echo "$RESULT" | jq -r '.sshPort // empty')
    if [ -z "$HOST_PORT" ]; then
      echo "QEMU manager did not return sshPort: $RESULT" >&2
      exit 1
    fi
    PORT=$(start_tunnel "$LEASE_ID" "$HOST_PORT") || {
      ssh_windows_ps "& '$MANAGER_PATH' -Action destroy -Name '$NAME'" >/dev/null || true
      echo "Failed to start local SSH tunnel for QEMU box $NAME" >&2
      exit 1
    }
    emit_lease "$NAME" "$PORT" "$HOST_PORT"
    ;;

  resolve)
    NAME=$(vm_name)
    LEASE_ID=$(get_lease_id)
    RESULT=$(ssh_windows_ps "& '$MANAGER_PATH' -Action status -Name '$NAME'")
    RUNNING=$(echo "$RESULT" | jq -r '.running // false')
    HOST_PORT=$(echo "$RESULT" | jq -r '.sshPort // empty')
    if [ "$RUNNING" != "true" ] || [ -z "$HOST_PORT" ]; then
      echo "QEMU box $NAME is not running" >&2
      exit 1
    fi
    PORT=$(get_tunnel_port "$LEASE_ID")
    if [ -z "$PORT" ]; then
      PORT=$(start_tunnel "$LEASE_ID" "$HOST_PORT") || exit 1
    fi
    emit_lease "$NAME" "$PORT" "$HOST_PORT"
    ;;

  list)
    RAW=$(ssh_windows_ps "& '$MANAGER_PATH' -Action list" 2>/dev/null || echo "[]")
    echo "$RAW" | jq 'if type == "array" then . else [.] end | {
      protocolVersion: 1,
      leases: map({
        name: .name,
        cloudId: ("windows-qemu/" + .name),
        status: (if .running then "active" else "stopped" end)
      })
    }'
    ;;

  release)
    NAME=$(vm_name)
    LEASE_ID=$(get_lease_id)
    stop_tunnel "$LEASE_ID"
    ssh_windows_ps "& '$MANAGER_PATH' -Action destroy -Name '$NAME'" >/dev/null || true
    echo '{"protocolVersion":1,"message":"released"}'
    ;;

  touch)
    echo '{"protocolVersion":1,"message":"ok"}'
    ;;

  cleanup)
    echo '{"protocolVersion":1,"message":"cleanup delegated to release"}'
    ;;

  *)
    echo "Unknown operation: $OP" >&2
    exit 1
    ;;
esac
