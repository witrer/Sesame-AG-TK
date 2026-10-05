#!/usr/bin/env bash
set -Eeuo pipefail

SSH_USER="${SSH_USER:-remoteai}"
SSH_PORT="${SSH_PORT:-22222}"
BORE_SERVER="${BORE_SERVER:-bore.pub}"
BORE_VERSION="${BORE_VERSION:-0.6.0}"

pick_app_dir() {
  local d
  for d in "${REMOTE_SSH_DIR:-}" "/mnt/workspace/.remote-ssh" "${PWD}/.remote-ssh" "${HOME:-}/.remote-ssh" "/tmp/remote-ssh-$(id -u)"; do
    [ -n "$d" ] || continue
    mkdir -p "$d" 2>/dev/null || continue
    if touch "$d/.write-test" 2>/dev/null; then
      rm -f "$d/.write-test"
      printf '%s' "$d"
      return
    fi
  done
  return 1
}

APP_DIR="$(pick_app_dir)" || { echo "ERROR: 找不到可写目录"; exit 1; }
PASS_FILE="$APP_DIR/password"
SSHD_CONFIG="$APP_DIR/sshd_config"
SSHD_LOG="$APP_DIR/sshd.log"
SSHD_PID="$APP_DIR/sshd.pid"
TUNNEL_LOG="$APP_DIR/bore.log"
TUNNEL_PID="$APP_DIR/bore.pid"
SUPERVISOR_PID="$APP_DIR/supervisor.pid"
STATUS_FILE="$APP_DIR/current.txt"
BORE_BIN="$APP_DIR/bore"
BORE_PORT_FILE="$APP_DIR/bore_remote_port"
LOCK_DIR="$APP_DIR/instance.lock"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: 当前版本需要 root"; exit 1; }

mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"

# Stop previous launcher-managed processes only.
for pf in "$SUPERVISOR_PID" "$TUNNEL_PID" "$SSHD_PID"; do
  if [ -s "$pf" ]; then
    p="$(cat "$pf" 2>/dev/null || true)"
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    rm -f "$pf"
  fi
done
pkill -f "[s]shd -f $SSHD_CONFIG" >/dev/null 2>&1 || true
sleep 1

rm -rf "$LOCK_DIR"
mkdir "$LOCK_DIR"
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

install_base() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client curl ca-certificates python3 openssl tar >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server openssh-clients curl ca-certificates python3 openssl tar >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openssh-server openssh-clients curl ca-certificates python3 openssl tar >/dev/null 2>&1
  else
    echo "ERROR: 不支持当前包管理器"
    exit 1
  fi
}

command -v sshd >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || install_base

port_free() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
p=int(sys.argv[1])
s=socket.socket()
try:
    s.bind(("127.0.0.1",p))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

if ! port_free "$SSH_PORT"; then
  for p in $(seq 22223 22399); do
    if port_free "$p"; then SSH_PORT="$p"; break; fi
  done
fi

echo "[1/5] 配置 SSH: 127.0.0.1:$SSH_PORT"

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
PrintMotd no
PrintLastLog no
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

if ! timeout 8 ssh-keyscan -T 5 -p "$SSH_PORT" 127.0.0.1 >/dev/null 2>>"$SSHD_LOG"; then
  echo "ERROR: 本机 SSH 握手失败"
  tail -n 80 "$SSHD_LOG" || true
  exit 1
fi
echo "[2/5] 本机 SSH 握手正常"

install_bore() {
  if command -v bore >/dev/null 2>&1; then
    BORE_BIN="$(command -v bore)"
    return 0
  fi
  if [ -x "$BORE_BIN" ]; then return 0; fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) target="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) target="aarch64-unknown-linux-musl" ;;
    *) echo "ERROR: Bore 暂不支持此架构: $arch"; return 1 ;;
  esac

  url="https://github.com/ekzhang/bore/releases/download/v$BORE_VERSION/bore-v$BORE_VERSION-$target.tar.gz"
  tmp="$APP_DIR/bore.tar.gz"
  echo "[3/5] 下载 Bore v$BORE_VERSION ($target)..."
  if curl -fL --connect-timeout 12 --retry 2 "$url" -o "$tmp"; then
    tar -xzf "$tmp" -C "$APP_DIR"
    rm -f "$tmp"
    chmod +x "$BORE_BIN"
    return 0
  fi

  echo "[remote-ssh] GitHub Release 直连失败，尝试 Cargo 编译兜底..."
  if ! command -v cargo >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y cargo rustc >/dev/null 2>&1 || return 1
    else
      return 1
    fi
  fi
  cargo install --locked --root "$APP_DIR/bore-cargo" bore-cli >/dev/null 2>&1 || return 1
  BORE_BIN="$APP_DIR/bore-cargo/bin/bore"
}

install_bore || {
  echo "ERROR: Bore 客户端安装失败"
  echo "备用 Pinggy 脚本:"
  echo "curl -fsSL https://cdn.jsdelivr.net/gh/witrer/Sesame-AG-TK@main/start_pinggy.sh | bash"
  exit 2
}

echo "[4/5] 检查 $BORE_SERVER:7835..."
if ! python3 - "$BORE_SERVER" 7835 <<'PY' >/dev/null 2>&1
import socket,sys
try:
    s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=8)
    s.close()
except Exception:
    sys.exit(1)
PY
then
  echo "ERROR: 当前实例无法连接 $BORE_SERVER:7835"
  echo "说明这个地区/网络不适合 Bore。备用 Pinggy:"
  echo "curl -fsSL https://cdn.jsdelivr.net/gh/witrer/Sesame-AG-TK@main/start_pinggy.sh | bash"
  exit 3
fi

if [ ! -s "$BORE_PORT_FILE" ]; then
  python3 - <<'PY' > "$BORE_PORT_FILE"
import random
print(random.randint(20000,60000))
PY
fi
REMOTE_PORT="$(cat "$BORE_PORT_FILE")"

: > "$TUNNEL_LOG"

# Supervisor: reuse the same requested public port so a short reconnect normally keeps the address stable.
nohup bash -c '
while true; do
  echo "===== BORE START $(date -Is) port='"$REMOTE_PORT"' =====" >> "'"$TUNNEL_LOG"'"
  "'"$BORE_BIN"'" local '"$SSH_PORT"' --to "'"$BORE_SERVER"'" --port '"$REMOTE_PORT"' >> "'"$TUNNEL_LOG"'" 2>&1
  rc=$?
  echo "===== BORE END rc=$rc $(date -Is) =====" >> "'"$TUNNEL_LOG"'"
  sleep 5
done
' >/dev/null 2>&1 &
echo $! > "$SUPERVISOR_PID"

ENDPOINT=""
for _ in $(seq 1 30); do
  if grep -Eq "$BORE_SERVER:[0-9]+" "$TUNNEL_LOG"; then
    ENDPOINT="$(grep -Eo "$BORE_SERVER:[0-9]+" "$TUNNEL_LOG" | tail -n1)"
    break
  fi
  if grep -qiE "already in use|failed|error" "$TUNNEL_LOG"; then
    break
  fi
  sleep 1
done

# If requested port was occupied, retry once with a fresh one.
if [ -z "$ENDPOINT" ]; then
  kill "$(cat "$SUPERVISOR_PID")" 2>/dev/null || true
  REMOTE_PORT="$(python3 - <<'PY'
import random
print(random.randint(20000,60000))
PY
)"
  echo "$REMOTE_PORT" > "$BORE_PORT_FILE"
  : > "$TUNNEL_LOG"
  nohup bash -c '
while true; do
  "'"$BORE_BIN"'" local '"$SSH_PORT"' --to "'"$BORE_SERVER"'" --port '"$REMOTE_PORT"' >> "'"$TUNNEL_LOG"'" 2>&1
  sleep 5
done
' >/dev/null 2>&1 &
  echo $! > "$SUPERVISOR_PID"
  for _ in $(seq 1 30); do
    ENDPOINT="$(grep -Eo "$BORE_SERVER:[0-9]+" "$TUNNEL_LOG" 2>/dev/null | tail -n1 || true)"
    [ -n "$ENDPOINT" ] && break
    sleep 1
  done
fi

if [ -z "$ENDPOINT" ]; then
  echo "ERROR: Bore 未成功建立隧道"
  tail -n 80 "$TUNNEL_LOG" || true
  echo
  echo "备用 Pinggy:"
  echo "curl -fsSL https://cdn.jsdelivr.net/gh/witrer/Sesame-AG-TK@main/start_pinggy.sh | bash"
  exit 4
fi

HOST="${ENDPOINT%:*}"
PORT="${ENDPOINT##*:}"

echo "[5/5] 公网 SSH Banner 自检..."
BANNER="$(python3 - "$HOST" "$PORT" <<'PY' 2>/dev/null || true
import socket,sys
try:
    s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=10)
    s.settimeout(10)
    print(s.recv(256).decode("ascii","replace").strip())
    s.close()
except Exception:
    pass
PY
)"

if [[ "$BANNER" != SSH-2.0-* ]]; then
  echo "ERROR: Bore TCP 已建立，但公网 SSH 握手失败"
  echo "Endpoint : $ENDPOINT"
  echo "Banner   : ${BANNER:-<empty>}"
  echo "--- Bore log ---"
  tail -n 80 "$TUNNEL_LOG" || true
  echo "--- sshd log ---"
  tail -n 80 "$SSHD_LOG" || true
  exit 5
fi

{
  echo "Mode     : Bore"
  echo "Updated  : $(date -Is)"
  echo "WorkDir  : $APP_DIR"
  echo "Host     : $HOST"
  echo "Port     : $PORT"
  echo "User     : $SSH_USER"
  echo "Password : $PASS"
  echo "Connect  : ssh -p $PORT $SSH_USER@$HOST"
} > "$STATUS_FILE"

echo
echo "========================================"
echo "            REMOTE SSH READY"
echo "========================================"
cat "$STATUS_FILE"
echo "Banner   : $BANNER"
echo "========================================"
echo "Bore 会后台自动重连，并优先继续申请同一个公网端口。"
