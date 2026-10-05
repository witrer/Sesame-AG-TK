#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${HOME}/.remote-ssh"
SSH_PORT="${SSH_PORT:-22222}"
SSH_USER="${SSH_USER:-remoteai}"
PASS_FILE="${APP_DIR}/password"
SSHD_CONFIG="${APP_DIR}/sshd_config"
SSHD_LOG="${APP_DIR}/sshd.log"
TUNNEL_LOG="${APP_DIR}/tunnel.log"
TUNNEL_PID="${APP_DIR}/tunnel.pid"
SSHD_PID="${APP_DIR}/sshd.pid"

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: 请用 root 运行，例如: sudo bash start.sh"
  exit 1
fi

if ! command -v sshd >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server openssh-clients openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server openssh-clients openssl
  else
    echo "ERROR: 不支持当前包管理器，请先安装 openssh-server openssh-client openssl"
    exit 1
  fi
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SSH_USER"
fi

if [ ! -s "$PASS_FILE" ]; then
  PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
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

if [ ! -s "$SSHD_PID" ] || ! kill -0 "$(cat "$SSHD_PID" 2>/dev/null || true)" 2>/dev/null; then
  /usr/sbin/sshd -f "$SSHD_CONFIG" -E "$SSHD_LOG"
fi

if [ -s "$TUNNEL_PID" ] && kill -0 "$(cat "$TUNNEL_PID")" 2>/dev/null; then
  kill "$(cat "$TUNNEL_PID")" 2>/dev/null || true
fi

: > "$TUNNEL_LOG"
nohup bash -c '
while true; do
  ssh -p 443     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o ServerAliveInterval=30     -o ServerAliveCountMax=3     -o ExitOnForwardFailure=yes     -R "0:127.0.0.1:'"$SSH_PORT"'"     tcp@free.pinggy.io >> "'"$TUNNEL_LOG"'" 2>&1 || true
  sleep 5
done
' >/dev/null 2>&1 &
echo $! > "$TUNNEL_PID"

for _ in $(seq 1 20); do
  HOSTPORT="$(grep -Eo '([A-Za-z0-9._-]+\.pinggy\.(link|io)):[0-9]+' "$TUNNEL_LOG" | tail -n1 || true)"
  [ -n "$HOSTPORT" ] && break
  sleep 1
done

echo
echo "========== REMOTE SSH =========="
echo "User     : $SSH_USER"
echo "Password : $PASS"
if [ -n "${HOSTPORT:-}" ]; then
  HOST="${HOSTPORT%:*}"
  PORT="${HOSTPORT##*:}"
  echo "Connect  : ssh -p $PORT $SSH_USER@$HOST"
else
  echo "Tunnel   : 正在建立，运行下面命令查看日志"
  echo "           tail -f $TUNNEL_LOG"
fi
echo "================================"
