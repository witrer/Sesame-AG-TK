#!/usr/bin/env bash
set -Eeuo pipefail

SSH_USER="${SSH_USER:-remoteai}"
SSH_PORT="${SSH_PORT:-22222}"
TS_HOSTNAME="${TS_HOSTNAME:-modelscope-ssh}"

pick_dir() {
  local d
  for d in "${REMOTE_SSH_DIR:-}" "/mnt/workspace/.remote-ssh" "${PWD}/.remote-ssh" "${HOME:-}/.remote-ssh" "/tmp/remote-ssh-$(id -u)"; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null || continue
    if touch "$d/.w" 2>/dev/null; then rm -f "$d/.w"; printf '%s' "$d"; return; fi
  done
  return 1
}

APP_DIR="$(pick_dir)" || { echo "ERROR: 找不到可写目录"; exit 1; }
PASS_FILE="$APP_DIR/password"
SSHD_CONFIG="$APP_DIR/sshd_config"
SSHD_LOG="$APP_DIR/sshd.log"
SSHD_PID="$APP_DIR/sshd.pid"
TS_STATE_DIR="$APP_DIR/tailscale-state"
TS_SOCKET="$APP_DIR/tailscaled.sock"
TS_LOG="$APP_DIR/tailscaled.log"
TS_PID="$APP_DIR/tailscaled.pid"
LOCK_DIR="$APP_DIR/persistent.lock"
STATUS_FILE="$APP_DIR/current.txt"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: 需要 root"; exit 1; }

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  old=""
  [ -f "$LOCK_DIR/pid" ] && old="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  [ -n "$old" ] && kill "$old" 2>/dev/null || true
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

install_base() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client curl ca-certificates python3 openssl >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server openssh-clients curl ca-certificates python3 openssl >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server openssh-clients curl ca-certificates python3 openssl >/dev/null 2>&1
  else
    echo "ERROR: 不支持当前包管理器"; exit 1
  fi
}

command -v sshd >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || install_base

if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
  echo "[1/6] 安装 Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Stop only services managed by this script.
if [ -s "$TS_PID" ]; then kill "$(cat "$TS_PID" 2>/dev/null || true)" 2>/dev/null || true; fi
if [ -s "$SSHD_PID" ]; then kill "$(cat "$SSHD_PID" 2>/dev/null || true)" 2>/dev/null || true; fi
pkill -f "[s]shd -f $SSHD_CONFIG" >/dev/null 2>&1 || true
rm -f "$TS_SOCKET" "$SSHD_PID"
sleep 1

port_free() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket,sys
s=socket.socket()
try: s.bind(("127.0.0.1",int(sys.argv[1])))
except OSError: sys.exit(1)
finally: s.close()
PY
}
if ! port_free "$SSH_PORT"; then
  for p in $(seq 22223 22399); do
    if port_free "$p"; then SSH_PORT="$p"; break; fi
  done
fi

echo "[2/6] 配置 SSH..."
if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SSH_USER"
fi
if [ ! -s "$PASS_FILE" ]; then
  openssl rand -base64 30 | tr -d '/+=' | cut -c1-24 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
PASS="$(cat "$PASS_FILE")"
echo "$SSH_USER:$PASS" | chpasswd

mkdir -p "$APP_DIR/keys" /run/sshd
[ -f "$APP_DIR/keys/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$APP_DIR/keys/ssh_host_ed25519_key"
[ -f "$APP_DIR/keys/ssh_host_rsa_key" ] || ssh-keygen -q -t rsa -b 3072 -N "" -f "$APP_DIR/keys/ssh_host_rsa_key"

cat > "$SSHD_CONFIG" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $APP_DIR/keys/ssh_host_ed25519_key
HostKey $APP_DIR/keys/ssh_host_rsa_key
PasswordAuthentication yes
PermitEmptyPasswords no
PermitRootLogin no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
MaxAuthTries 3
PidFile $SSHD_PID
AllowUsers $SSH_USER
Subsystem sftp internal-sftp
EOF

: > "$SSHD_LOG"
/usr/sbin/sshd -f "$SSHD_CONFIG" -E "$SSHD_LOG"
timeout 8 ssh-keyscan -T 5 -p "$SSH_PORT" 127.0.0.1 >/dev/null 2>>"$SSHD_LOG" || {
  echo "ERROR: 本机 SSH 握手失败"; tail -n 80 "$SSHD_LOG"; exit 1;
}
echo "[3/6] 本机 SSH 正常: 127.0.0.1:$SSH_PORT"

echo "[4/6] 启动持久 Tailscale 节点..."
mkdir -p "$TS_STATE_DIR"
: > "$TS_LOG"
nohup tailscaled   --tun=userspace-networking   --socket="$TS_SOCKET"   --statedir="$TS_STATE_DIR"   --port=0 >>"$TS_LOG" 2>&1 &
echo $! > "$TS_PID"

for _ in $(seq 1 30); do
  if tailscale --socket="$TS_SOCKET" status >/dev/null 2>&1; then break; fi
  sleep 1
done

STATE="$(tailscale --socket="$TS_SOCKET" status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)"
if [ "$STATE" != "Running" ]; then
  echo "[5/6] 首次需要把这个固定节点加入你的 Tailscale。"
  if [ -n "${TS_AUTHKEY:-}" ]; then
    tailscale --socket="$TS_SOCKET" up --auth-key="$TS_AUTHKEY" --hostname="$TS_HOSTNAME" --accept-dns=false
  else
    echo "下面会给你一个 Tailscale 登录网址；只需要授权这一次。"
    tailscale --socket="$TS_SOCKET" up --hostname="$TS_HOSTNAME" --accept-dns=false
  fi
fi

echo "[6/6] 开启固定公网 SSH Funnel..."
FUNNEL_OUT="$(tailscale --socket="$TS_SOCKET" funnel --bg --tcp=443 "tcp://127.0.0.1:$SSH_PORT" 2>&1)" || {
  echo "$FUNNEL_OUT"
  echo
  echo "如果上面给出 Enable Funnel/授权网址：打开一次完成授权，然后重新运行同一条脚本。"
  exit 2
}
echo "$FUNNEL_OUT"

DNS_NAME="$(tailscale --socket="$TS_SOCKET" status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Self",{}).get("DNSName") or "").rstrip("."))')"
[ -n "$DNS_NAME" ] || { echo "ERROR: 没取得 Tailscale DNS 名"; exit 1; }

{
  echo "Mode     : Tailscale Funnel"
  echo "WorkDir  : $APP_DIR"
  echo "Host     : $DNS_NAME"
  echo "Port     : 443"
  echo "User     : $SSH_USER"
  echo "Password : $PASS"
  echo "Connect  : ssh -p 443 $SSH_USER@$DNS_NAME"
} > "$STATUS_FILE"

echo
echo "========================================"
echo "       PERSISTENT REMOTE SSH READY"
echo "========================================"
cat "$STATUS_FILE"
echo "========================================"
echo "固定状态目录: $TS_STATE_DIR"
echo "只要 /mnt/workspace 还在，同一节点身份和地址会继续保留。"
