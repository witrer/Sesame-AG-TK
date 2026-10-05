#!/usr/bin/env bash
set -Eeuo pipefail

SSH_PORT="${SSH_PORT:-22222}"
SSH_USER="${SSH_USER:-remoteai}"

port_in_use() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${1}$"
}

pick_ssh_port() {
  local p
  if ! port_in_use "$SSH_PORT"; then
    printf '%s' "$SSH_PORT"
    return
  fi
  for p in $(seq 22223 22350); do
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return
    fi
  done
  echo "ERROR: 22222-22350 没有可用端口" >&2
  return 1
}

pick_app_dir() {
  local c
  if [ -n "${REMOTE_SSH_DIR:-}" ]; then
    c="$REMOTE_SSH_DIR"
    mkdir -p "$c" 2>/dev/null && touch "$c/.write-test" 2>/dev/null && rm -f "$c/.write-test" && { printf '%s' "$c"; return; }
  fi
  for c in "/mnt/workspace/.remote-ssh" "${PWD}/.remote-ssh" "${HOME:-}/.remote-ssh" "/tmp/remote-ssh-$(id -u)"; do
    [ -n "$c" ] || continue
    mkdir -p "$c" 2>/dev/null || continue
    if touch "$c/.write-test" 2>/dev/null; then
      rm -f "$c/.write-test"
      printf '%s' "$c"
      return
    fi
  done
  return 1
}

APP_DIR="$(pick_app_dir)" || {
  echo "ERROR: 找不到可写工作目录"
  exit 1
}

SSH_PORT="$(pick_ssh_port)" || exit 1
SSH_USER="${SSH_USER:-remoteai}"
PASS_FILE="${APP_DIR}/password"
SSHD_CONFIG="${APP_DIR}/sshd_config"
SSHD_LOG="${APP_DIR}/sshd.log"
TUNNEL_LOG="${APP_DIR}/tunnel.log"
TUNNEL_PID="${APP_DIR}/tunnel.pid"
SSHD_PID="${APP_DIR}/sshd.pid"
PINGGY_KEY="${APP_DIR}/pinggy_ed25519"

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"
echo "[remote-ssh] 工作目录: $APP_DIR"
echo "[remote-ssh] SSH端口: $SSH_PORT"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 请用 root 运行：sudo bash"
  exit 1
fi

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client openssl >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server openssh-clients openssl >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server openssh-clients openssl >/dev/null 2>&1
  else
    echo "ERROR: 当前系统缺少受支持的包管理器"
    exit 1
  fi
}

if ! command -v sshd >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1; then
  install_pkg
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
  if [ -d /home ] && [ -w /home ]; then
    useradd -m -s /bin/bash "$SSH_USER"
  else
    USER_HOME="$APP_DIR/home-$SSH_USER"
    mkdir -p "$USER_HOME"
    useradd -M -d "$USER_HOME" -s /bin/bash "$SSH_USER"
    chown -R "$SSH_USER:$SSH_USER" "$USER_HOME"
  fi
fi

if [ ! -s "$PASS_FILE" ]; then
  PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  printf '%s' "$PASS" > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
else
  PASS="$(cat "$PASS_FILE")"
fi
echo "${SSH_USER}:${PASS}" | chpasswd

mkdir -p "$APP_DIR/keys" /run/sshd

if [ ! -f "$APP_DIR/keys/ssh_host_ed25519_key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$APP_DIR/keys/ssh_host_ed25519_key"
fi
if [ ! -f "$APP_DIR/keys/ssh_host_rsa_key" ]; then
  ssh-keygen -q -t rsa -b 3072 -N "" -f "$APP_DIR/keys/ssh_host_rsa_key"
fi
if [ ! -f "$PINGGY_KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$PINGGY_KEY"
fi

cat > "$SSHD_CONFIG" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
Protocol 2
HostKey $APP_DIR/keys/ssh_host_ed25519_key
HostKey $APP_DIR/keys/ssh_host_rsa_key
PasswordAuthentication yes
PermitEmptyPasswords no
PermitRootLogin no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
AllowTcpForwarding yes
GatewayPorts no
ClientAliveInterval 60
ClientAliveCountMax 3
PidFile $SSHD_PID
AllowUsers $SSH_USER
Subsystem sftp internal-sftp
EOF

if [ -s "$SSHD_PID" ] && kill -0 "$(cat "$SSHD_PID")" 2>/dev/null; then
  kill "$(cat "$SSHD_PID")" 2>/dev/null || true
  sleep 1
fi

/usr/sbin/sshd -f "$SSHD_CONFIG" -E "$SSHD_LOG"

if ! ss -ltn 2>/dev/null | grep -q "127.0.0.1:$SSH_PORT"; then
  echo "ERROR: sshd 未能监听 127.0.0.1:$SSH_PORT"
  tail -n 50 "$SSHD_LOG" 2>/dev/null || true
  exit 1
fi

if [ -s "$TUNNEL_PID" ] && kill -0 "$(cat "$TUNNEL_PID")" 2>/dev/null; then
  kill "$(cat "$TUNNEL_PID")" 2>/dev/null || true
  sleep 1
fi

pkill -f 'tcp@free\.pinggy\.io' >/dev/null 2>&1 || true
: > "$TUNNEL_LOG"

nohup bash -c '
while true; do
  yes "" | ssh -tt -p 443     -i "'"$PINGGY_KEY"'"     -o IdentitiesOnly=yes     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o PreferredAuthentications=publickey,password,keyboard-interactive     -o ServerAliveInterval=30     -o ServerAliveCountMax=3     -o ConnectTimeout=15     -R "0:127.0.0.1:'"$SSH_PORT"'"     tcp@free.pinggy.io >> "'"$TUNNEL_LOG"'" 2>&1 || true
  sleep 5
done
' >/dev/null 2>&1 &
echo $! > "$TUNNEL_PID"

ENDPOINT=""
for _ in $(seq 1 45); do
  ENDPOINT="$(grep -Eo 'tcp://[^[:space:]]+:[0-9]+' "$TUNNEL_LOG" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
  if [ -n "$ENDPOINT" ]; then
    break
  fi
  sleep 1
done

echo
echo "========================================"
echo "            REMOTE SSH READY"
echo "========================================"
echo "WorkDir  : $APP_DIR"
echo "User     : $SSH_USER"
echo "Password : $PASS"

if [ -n "$ENDPOINT" ]; then
  HOSTPORT="${ENDPOINT#tcp://}"
  HOST="${HOSTPORT%:*}"
  PORT="${HOSTPORT##*:}"
  echo "Endpoint : $ENDPOINT"
  echo "Host     : $HOST"
  echo "Port     : $PORT"
  echo "Address  : $HOST:$PORT"
  echo "Connect  : ssh -p $PORT $SSH_USER@$HOST"
  echo "========================================"
else
  echo "Tunnel   : FAILED"
  echo "Log      : $TUNNEL_LOG"
  echo "========================================"
  echo
  echo "--- Pinggy raw output ---"
  sed -n '1,120p' "$TUNNEL_LOG" 2>/dev/null || true
  echo "--- end ---"
  exit 2
fi
