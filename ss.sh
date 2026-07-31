#!/bin/sh
set -eu

PORT="${PORT:-21959}"
INTERNAL_PORT="${INTERNAL_PORT:-21960}"
METHOD="${METHOD:-2022-blake3-aes-128-gcm}"
SNI="${SNI:-www.bing.com}"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_FILE="${CONFIG_DIR}/clients/shadowtls.txt"
SERVICE_FILE="/etc/init.d/sing-box"
DNS1="2606:4700:4700::1111"
DNS2="2001:4860:4860::8888"

say() { printf '%s\n' "$*"; }
fail() { say "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "请使用 root 用户运行"
[ -f /etc/alpine-release ] || fail "此脚本仅适用于 Alpine Linux"
case "$PORT" in ''|*[!0-9]*) fail "PORT 必须是数字" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "PORT 必须是 1-65535"

say "[1/7] 检查 IPv6 与 DNS..."
ip -6 route 2>/dev/null | grep -q '^default' || fail "没有 IPv6 默认路由"
if ! nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; then
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF
fi
nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || fail "DNS 无法解析 Alpine 软件源"

say "[2/7] 安装 sing-box..."
apk update
apk add --no-cache sing-box ca-certificates iproute2 >/dev/null
command -v sing-box >/dev/null 2>&1 || fail "sing-box 安装失败"

say "[3/7] 生成 ShadowTLS + Shadowsocks 参数..."
mkdir -p "$CONFIG_DIR/clients"
SS_PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -d '\n')"
ST_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
[ -n "$SS_PASSWORD" ] || fail "Shadowsocks 密码生成失败"
[ -n "$ST_PASSWORD" ] || fail "ShadowTLS 密码生成失败"

say "[4/7] 写入 sing-box 配置..."
cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },
  "inbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls-in",
      "listen": "::",
      "listen_port": ${PORT},
      "version": 3,
      "users": [
        {
          "name": "kp",
          "password": "${ST_PASSWORD}"
        }
      ],
      "handshake": {
        "server": "${SNI}",
        "server_port": 443,
        "domain_strategy": "ipv6_only"
      },
      "strict_mode": true,
      "detour": "ss-tcp-in"
    },
    {
      "type": "shadowsocks",
      "tag": "ss-tcp-in",
      "listen": "127.0.0.1",
      "listen_port": ${INTERNAL_PORT},
      "network": "tcp",
      "method": "${METHOD}",
      "password": "${SS_PASSWORD}"
    },
    {
      "type": "shadowsocks",
      "tag": "ss-udp-in",
      "listen": "::",
      "listen_port": ${PORT},
      "network": "udp",
      "method": "${METHOD}",
      "password": "${SS_PASSWORD}"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
chmod 600 "$CONFIG_FILE"

say "[5/7] 检查配置并配置 OpenRC..."
sing-box check -c "$CONFIG_FILE" || fail "sing-box 配置检查失败"
if [ -f /etc/init.d/shadowsocks-ss ]; then
  rc-service shadowsocks-ss stop >/dev/null 2>&1 || true
  rc-update del shadowsocks-ss default >/dev/null 2>&1 || true
fi
cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="ShadowTLS + Shadowsocks"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; }
EOF
chmod +x "$SERVICE_FILE"
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart
sleep 1
rc-service sing-box status >/dev/null 2>&1 || fail "sing-box 启动失败，请查看 /var/log/sing-box.log"
ss -lnt 2>/dev/null | grep -q ":${PORT}" || fail "未检测到 TCP ${PORT} 监听"
ss -lnu 2>/dev/null | grep -q ":${PORT}" || fail "未检测到 UDP ${PORT} 监听"

say "[6/7] 获取公网 IPv6..."
IPV6="${SERVER_IPV6:-}"
if [ -z "$IPV6" ] && command -v wget >/dev/null 2>&1; then
  IPV6="$(wget -6 -qO- --timeout=8 https://api6.ipify.org 2>/dev/null || true)"
fi

say "[7/7] 生成客户端配置..."
say ""
say "============================================================"
say "           KP-ShadowTLS + Shadowsocks / Alpine IPv6"
say "============================================================"
say "服务器 IPv6      : ${IPV6:-请填写 LazyCatCloud 面板公网 IPv6}"
say "公网端口         : ${PORT}"
say "Shadowsocks 方法 : ${METHOD}"
say "Shadowsocks 密码 : ${SS_PASSWORD}"
say "ShadowTLS 密码   : ${ST_PASSWORD}"
say "ShadowTLS 版本   : 3"
say "SNI              : ${SNI}"
say "TCP              : ShadowTLS -> Shadowsocks"
say "UDP              : Shadowsocks 直连同端口"
say "============================================================"
say "LazyCatCloud 必须映射："
say "TCP IPv6  ${PORT} -> ${PORT}"
say "UDP IPv6  ${PORT} -> ${PORT}"
say "============================================================"

if [ -n "$IPV6" ]; then
  SS_USERINFO="$(printf '%s' "${METHOD}:${SS_PASSWORD}" | base64 | tr -d '\n')"
  URI="ss://${SS_USERINFO}@[${IPV6}]:${PORT}/?plugin=shadow-tls%3Bhost%3D${SNI}%3Bpasswd%3D${ST_PASSWORD}%3Bv3#KP-ShadowTLS"
  cat > "$CLIENT_FILE" <<EOF
===== BEGIN ShadowTLS + Shadowsocks =====
=============== 明文参数 ===============
节点类型        : ShadowTLS + Shadowsocks
服务器IP        : ${IPV6}
ShadowTLS 端口  : ${PORT}
Shadowsocks UDP : ${PORT}
加密方法        : ${METHOD}
Shadowsocks 密码: ${SS_PASSWORD}
ShadowTLS 密码  : ${ST_PASSWORD}
伪装域名        : ${SNI}
ShadowTLS 版本  : 3
指纹(fp)        : chrome

=============== 通用分享链接 ===============
${URI}

=============== Sub-Store ===============
KP-ShadowTLS = Shadowsocks,${IPV6},${PORT},${METHOD},"${SS_PASSWORD}",shadow-tls-password=${ST_PASSWORD},shadow-tls-sni=${SNI},shadow-tls-version=3,udp-port=${PORT},fast-open=false,udp=true

=============== Clash Meta / Mihomo ===============
  - name: KP-ShadowTLS
    type: ss
    server: ${IPV6}
    port: ${PORT}
    cipher: ${METHOD}
    password: ${SS_PASSWORD}
    udp: true
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      mode: tls
      host: ${SNI}
      password: ${ST_PASSWORD}
      version: 3

=============== Sing-box Outbound ===============
[
  {
    "type": "shadowsocks",
    "tag": "KP-ShadowTLS-SS",
    "server": "${IPV6}",
    "server_port": ${PORT},
    "method": "${METHOD}",
    "password": "${SS_PASSWORD}",
    "detour": "KP-ShadowTLS"
  },
  {
    "type": "shadowtls",
    "tag": "KP-ShadowTLS",
    "server": "${IPV6}",
    "server_port": ${PORT},
    "version": 3,
    "password": "${ST_PASSWORD}",
    "tls": {
      "enabled": true,
      "server_name": "${SNI}",
      "utls": {
        "enabled": true,
        "fingerprint": "chrome"
      }
    }
  }
]
================================================================
===== END ShadowTLS + Shadowsocks =====
EOF
  cat "$CLIENT_FILE"
  say ""
  say "配置永久保存：${CLIENT_FILE}"
else
  say "未自动获取公网 IPv6。重新运行时可指定："
  say "SERVER_IPV6='你的LazyCat公网IPv6' wget -qO- https://raw.githubusercontent.com/xytxg/one-test/main/ss.sh | sh"
fi
