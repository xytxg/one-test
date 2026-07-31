#!/bin/sh
# Alpine Linux IPv6-only bootstrap for cuteys/ProxyResource Sing-Box installer.
# Target: Alpine 3.23+, IPv6-only VPS/container, OpenRC, very small memory/disk.
# This file intentionally uses POSIX /bin/sh so it can run before bash/curl are installed.

set -eu

UPSTREAM_URL="https://raw.githubusercontent.com/cuteys/ProxyResource/main/Sing-Box/singbox.sh"
DNS1="2606:4700:4700::1111"
DNS2="2001:4860:4860::8888"
TMP_SCRIPT="/tmp/singbox-upstream.sh"

say() { printf '%s\n' "$*"; }
fail() { say "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "请使用 root 用户运行"

if [ ! -f /etc/alpine-release ]; then
  fail "此启动脚本仅用于 Alpine Linux"
fi

say "[1/5] 检查 IPv6 网络..."
if ! ip -6 route 2>/dev/null | grep -q '^default'; then
  fail "未发现 IPv6 默认路由。请先检查 VPS/容器的 IPv6 网络配置。"
fi

say "[2/5] 配置 IPv6 DNS..."
# IPv6-only 主机不能依赖 IPv4 DNS（如 1.1.1.1 / 8.8.8.8）。
cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF

# BusyBox nslookup is normally present on Alpine. If not, apk below will still be attempted.
if command -v nslookup >/dev/null 2>&1; then
  nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || fail "DNS 仍无法解析 dl-cdn.alpinelinux.org"
fi

say "[3/5] 安装运行依赖..."
# The upstream installer is Bash-specific. curl is required by upstream functions.
# ca-certificates fixes HTTPS certificate validation; iproute2 provides `ss`.
apk update
apk add --no-cache bash curl ca-certificates iproute2 openssl
update-ca-certificates >/dev/null 2>&1 || true

command -v bash >/dev/null 2>&1 || fail "bash 安装失败"
command -v curl >/dev/null 2>&1 || fail "curl 安装失败"

say "[4/5] 通过 IPv6 下载上游 Sing-Box 脚本..."
rm -f "$TMP_SCRIPT"
curl -6 -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
  "$UPSTREAM_URL" -o "$TMP_SCRIPT"
[ -s "$TMP_SCRIPT" ] || fail "上游脚本下载失败"
chmod 700 "$TMP_SCRIPT"

say "[5/5] 启动 Sing-Box 安装菜单..."
say "已针对 Alpine + IPv6-only 完成 DNS、依赖和下载兼容处理。"
exec bash "$TMP_SCRIPT"
