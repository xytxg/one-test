#!/bin/sh
set -eu

UPSTREAM_URL="https://raw.githubusercontent.com/cuteys/ProxyResource/main/Sing-Box/singbox.sh"
TMP_SCRIPT="/tmp/cuteys-singbox.sh"
DNS1="2606:4700:4700::1111"
DNS2="2001:4860:4860::8888"

say() { printf '%s\n' "$*"; }
fail() { say "[ERROR] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "请使用 root 用户运行"
[ -f /etc/alpine-release ] || fail "此入口专门用于 Alpine Linux"

say "[bootstrap] 检查 IPv6 网络..."
ip -6 route 2>/dev/null | grep -q '^default' || fail "没有 IPv6 默认路由"

say "[bootstrap] 修复 IPv6-only DNS..."
if ! nslookup raw.githubusercontent.com >/dev/null 2>&1; then
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF
fi
nslookup raw.githubusercontent.com >/dev/null 2>&1 || fail "DNS 仍无法解析 raw.githubusercontent.com"

say "[bootstrap] 安装原脚本所需 bash/curl..."
apk update
apk add --no-cache bash curl ca-certificates iproute2 openssl >/dev/null
update-ca-certificates >/dev/null 2>&1 || true
command -v bash >/dev/null 2>&1 || fail "bash 安装失败"
command -v curl >/dev/null 2>&1 || fail "curl 安装失败"

say "[bootstrap] 下载 cuteys 原版 Sing-Box 脚本..."
rm -f "$TMP_SCRIPT"
curl -6 -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 "$UPSTREAM_URL" -o "$TMP_SCRIPT"
[ -s "$TMP_SCRIPT" ] || fail "原版 singbox.sh 下载失败"

# 只做 IPv6-only 必需兼容修改，菜单、协议、Sub-Store、分享链接等全部保留原版逻辑。
# 1) 原版渲染 sing-box DNS 使用 IPv4 DNS，在这台 IPv6-only LXC 上改成 IPv6 DNS。
sed -i \
  -e 's/"server": "1\.1\.1\.1"/"server": "2606:4700:4700::1111"/g' \
  -e 's/"server": "8\.8\.8\.8"/"server": "2001:4860:4860::8888"/g' \
  "$TMP_SCRIPT"

# 2) 原版公网 IP 最后兜底走 IPv4 checkip；IPv6-only 环境改为 IPv6 公网查询。
sed -i \
  's#host_ip=$(curl -4 -s --max-time 5 http://checkip.amazonaws.com 2>/dev/null | tr -d '\''\\r\\n'\'')#host_ip=$(curl -6 -s --max-time 8 https://api6.ipify.org 2>/dev/null | tr -d '\''\\r\\n'\'')#' \
  "$TMP_SCRIPT" || true

chmod 700 "$TMP_SCRIPT"

say ""
say "============================================================"
say "以下进入 cuteys/ProxyResource 原版 Sing-Box 菜单"
say "仅增加 Alpine + IPv6-only 启动兼容；其余功能保持原版"
say "============================================================"
say ""

exec bash "$TMP_SCRIPT"
