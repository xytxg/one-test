#!/bin/sh
set -eu

PORT="${PORT:-21959}"
METHOD="${METHOD:-chacha20-ietf-poly1305}"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE="shadowsocks-ss"
SERVICE_FILE="/etc/init.d/${SERVICE}"
CLIENT_FILE="${CONFIG_DIR}/client.txt"
DNS1="2606:4700:4700::1111"
DNS2="2001:4860:4860::8888"

say() { printf '%s\n' "$*"; }
fail() { say "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "请使用 root 用户运行"
[ -f /etc/alpine-release ] || fail "此脚本仅适用于 Alpine Linux"
case "$PORT" in ''|*[!0-9]*) fail "PORT 必须是数字" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "PORT 必须是 1-65535"

say "[1/6] 检查 IPv6 与 DNS..."
ip -6 route 2>/dev/null | grep -q '^default' || fail "没有 IPv6 默认路由"
if ! nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; then
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF
fi
nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || fail "DNS 无法解析 Alpine 软件源"

say "[2/6] 安装 Shadowsocks-rust..."
apk update
if ! apk add --no-cache shadowsocks-rust-ssserver ca-certificates iproute2; then
  apk add --no-cache shadowsocks-rust ca-certificates iproute2
fi
command -v ssserver >/dev/null 2>&1 || fail "ssserver 安装失败"

say "[3/6] 写入配置..."
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_FILE" ]; then
  PASSWORD="$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
else
  PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
fi
[ -n "$PASSWORD" ] || fail "密码生成失败"
cat > "$CONFIG_FILE" <<EOF
{
  "server": "::",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "method": "${METHOD}",
  "mode": "tcp_and_udp"
}
EOF
chmod 600 "$CONFIG_FILE"

say "[4/6] 配置 OpenRC..."
cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Shadowsocks Rust Server"
command="$(command -v ssserver)"
command_args="-c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/${SERVICE}.pid"
output_log="/var/log/${SERVICE}.log"
error_log="/var/log/${SERVICE}.log"
depend() { need net; }
EOF
chmod +x "$SERVICE_FILE"
rc-update add "$SERVICE" default >/dev/null 2>&1 || true
rc-service "$SERVICE" restart
sleep 1
rc-service "$SERVICE" status >/dev/null 2>&1 || fail "服务启动失败，请查看 /var/log/${SERVICE}.log"
ss -lntup 2>/dev/null | grep -q ":${PORT}" || fail "没有检测到 ${PORT} 监听"

say "[5/6] 获取公网 IPv6..."
IPV6="${SERVER_IPV6:-}"
if [ -z "$IPV6" ] && command -v wget >/dev/null 2>&1; then
  IPV6="$(wget -6 -qO- --timeout=8 https://api6.ipify.org 2>/dev/null || true)"
fi

say "[6/6] 完成"
say ""
say "========================================"
say "      KP-SS / Alpine IPv6"
say "========================================"
say "服务器 IPv6 : ${IPV6:-请填写 LazyCatCloud 面板公网 IPv6}"
say "端口        : ${PORT}"
say "加密        : ${METHOD}"
say "密码        : ${PASSWORD}"
say "TCP/UDP     : 开启"
say "========================================"
say "LazyCatCloud 必须映射："
say "TCP IPv6  ${PORT} -> ${PORT}"
say "UDP IPv6  ${PORT} -> ${PORT}"
say "========================================"

if [ -n "$IPV6" ]; then
  USERINFO="$(printf '%s' "${METHOD}:${PASSWORD}" | base64 | tr -d '\n')"
  URI="ss://${USERINFO}@[${IPV6}]:${PORT}#KP-SS"
  cat > "$CLIENT_FILE" <<EOF
===== BEGIN Shadowsocks =====
=============== 明文参数 ===============
节点类型  : Shadowsocks
服务器IP  : ${IPV6}
监听端口  : ${PORT}
加密方法  : ${METHOD}
密码      : ${PASSWORD}
TCP/UDP   : 开启

=============== 通用分享链接 ===============
${URI}

=============== Sub-Store ===============
KP-SS = Shadowsocks,${IPV6},${PORT},${METHOD},"${PASSWORD}",udp=true,fast-open=false

=============== Surge ===============
KP-SS = ss, ${IPV6}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true

=============== Clash Meta / Mihomo ===============
  - name: KP-SS
    type: ss
    server: ${IPV6}
    port: ${PORT}
    cipher: ${METHOD}
    password: "${PASSWORD}"
    udp: true

=============== Sing-box Outbound ===============
{
  "type": "shadowsocks",
  "tag": "KP-SS",
  "server": "${IPV6}",
  "server_port": ${PORT},
  "method": "${METHOD}",
  "password": "${PASSWORD}"
}
================================================================
===== END Shadowsocks =====
EOF
  cat "$CLIENT_FILE"
  say ""
  say "配置永久保存：${CLIENT_FILE}"
else
  say "未自动获取公网 IPv6。重新运行时可指定："
  say "SERVER_IPV6='你的LazyCat公网IPv6' wget -qO- https://raw.githubusercontent.com/xytxg/one-test/main/ss.sh | sh"
fi
