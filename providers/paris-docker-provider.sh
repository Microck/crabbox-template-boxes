#!/usr/bin/env bash
set -euo pipefail

PARIS_HOST="${CRABBOX_PARIS_HOST:-100.96.124.15}"
PARIS_SSH_ALIAS="${CRABBOX_PARIS_SSH_ALIAS:-oracle-paris}"
DEFAULT_IMAGE="${CRABBOX_PARIS_IMAGE:-crabbox:full}"
NAME_PREFIX="cbx-"

REQUEST=$(cat)
OP=$(echo "$REQUEST" | jq -r '.operation // ""')
IMAGE=$(echo "$REQUEST" | jq -r '.config.image // empty')
if [ -z "$IMAGE" ]; then
  IMAGE="$DEFAULT_IMAGE"
fi

get_lease_id() { echo "$REQUEST" | jq -r '.desired.leaseId // .lease.leaseId // ""'; }
get_slug() { echo "$REQUEST" | jq -r '.desired.slug // .lease.slug // ""'; }

find_free_port() {
  ssh "$PARIS_SSH_ALIAS" bash -s <<'PORTSCRIPT'
for port in $(shuf -i 22000-22999); do
  if ! ss -tlnH | awk '{print $4}' | grep -q ":${port}$"; then
    echo "$port"
    exit 0
  fi
done
exit 1
PORTSCRIPT
}

case "$OP" in
  doctor)
    ssh -o ConnectTimeout=10 "$PARIS_SSH_ALIAS" 'docker info >/dev/null'
    echo '{"protocolVersion":1,"message":"Paris Docker ready"}'
    ;;
  acquire)
    slug=$(get_slug)
    lease_id=$(get_lease_id)
    resource_name="${NAME_PREFIX}${slug}"
    port=$(find_free_port)
    key_dir="${CRABBOX_KEY_DIR:-/home/ubuntu/.crabbox/keys}"
    mkdir -p "$key_dir"
    chmod 700 "$key_dir"
    key_path="${key_dir}/${lease_id}"
    rm -f "$key_path" "${key_path}.pub"
    ssh-keygen -t ed25519 -N "" -f "$key_path" -q
    chmod 600 "$key_path"
    pubkey=$(cat "${key_path}.pub")
    env_file="/tmp/cbx-env-${resource_name}"
    ssh "$PARIS_SSH_ALIAS" "printf 'CRABBOX_PUBKEY=%s\n' '$pubkey' > '$env_file'"
    ssh "$PARIS_SSH_ALIAS" docker run -d --name "$resource_name" \
      --label crabbox=true \
      --label "crabbox-lease=${lease_id}" \
      -p "${port}:22" \
      --env-file "$env_file" \
      "$IMAGE" >/dev/null
    ssh "$PARIS_SSH_ALIAS" "rm -f '$env_file'" 2>/dev/null || true
    jq -n \
      --arg leaseId "$lease_id" \
      --arg slug "$slug" \
      --arg name "$resource_name" \
      --arg host "$PARIS_HOST" \
      --arg port "$port" \
      --arg key "$key_path" \
      '{
        protocolVersion: 1,
        lease: {
          leaseId: $leaseId,
          slug: $slug,
          name: $name,
          cloudId: ("docker-paris/" + $name),
          status: "active",
          ssh: {
            host: $host,
            port: $port,
            user: "ubuntu",
            key: $key,
            readyCheck: "command -v git && command -v rsync && command -v tar"
          }
        }
      }'
    ;;
  release)
    slug=$(get_slug)
    lease_id=$(get_lease_id)
    ssh "$PARIS_SSH_ALIAS" docker rm -f "${NAME_PREFIX}${slug}" >/dev/null 2>&1 || true
    rm -f "${CRABBOX_KEY_DIR:-/home/ubuntu/.crabbox/keys}/${lease_id}" "${CRABBOX_KEY_DIR:-/home/ubuntu/.crabbox/keys}/${lease_id}.pub"
    echo '{"protocolVersion":1,"message":"released"}'
    ;;
  touch)
    echo '{"protocolVersion":1,"message":"ok"}'
    ;;
  *)
    echo "Unsupported operation in minimal provider: $OP" >&2
    exit 1
    ;;
esac
