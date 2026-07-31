#!/bin/sh
set -eu

UPSTREAM_URL="https://raw.githubusercontent.com/cuteys/ProxyResource/main/Sing-Box/singbox.sh"
TMP_SCRIPT="/tmp/cuteys-singbox.sh"
DNS1="2606:4700:4700::1111"
DNS2="2001:4860:4860::8888"
SERVICE_FILE="/etc/init.d/sing-box"

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

say "[bootstrap] 安装原脚本依赖与 sing-box..."
apk update
apk add --no-cache bash curl ca-certificates iproute2 openssl sing-box >/dev/null

if ! command -v sing-box >/dev/null 2>&1; then
  say "[bootstrap] 检测到 sing-box 包存在但二进制缺失，正在修复..."
  apk fix sing-box >/dev/null 2>&1 || true
fi

if ! command -v sing-box >/dev/null 2>&1; then
  apk del sing-box >/dev/null 2>&1 || true
  apk add --no-cache sing-box >/dev/null
fi

update-ca-certificates >/dev/null 2>&1 || true
command -v bash >/dev/null 2>&1 || fail "bash 安装失败"
command -v curl >/dev/null 2>&1 || fail "curl 安装失败"
command -v sing-box >/dev/null 2>&1 || fail "sing-box 二进制仍不存在"

say "[bootstrap] sing-box: $(command -v sing-box)"
sing-box version 2>/dev/null | head -n1 || true

# Alpine 的 sing-box 包在部分镜像中只有二进制，不提供 /etc/init.d/sing-box。
# cuteys 原脚本会直接 rc-update/rc-service，因此这里提前补齐 OpenRC 服务。
if [ ! -f "$SERVICE_FILE" ]; then
  say "[bootstrap] 创建缺失的 OpenRC sing-box 服务..."
  cat > "$SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
  need net
}
EOF
  chmod +x "$SERVICE_FILE"
fi

rc-update add sing-box default >/dev/null 2>&1 || true

say "[bootstrap] 下载 cuteys 原版 Sing-Box 脚本..."
rm -f "$TMP_SCRIPT"
curl -6 -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 "$UPSTREAM_URL" -o "$TMP_SCRIPT"
[ -s "$TMP_SCRIPT" ] || fail "原版 singbox.sh 下载失败"

# 仅修正 Alpine + IPv6-only 兼容问题，菜单与输出格式继续沿用原版。
sed -i \
  -e 's/"server": "1\.1\.1\.1"/"server": "2606:4700:4700::1111"/g' \
  -e 's/"server": "8\.8\.8\.8"/"server": "2001:4860:4860::8888"/g' \
  "$TMP_SCRIPT"

sed -i \
  's#host_ip=$(curl -4 -s --max-time 5 http://checkip.amazonaws.com 2>/dev/null | tr -d '\''\\r\\n'\'')#host_ip=$(curl -6 -s --max-time 8 https://api6.ipify.org 2>/dev/null | tr -d '\''\\r\\n'\'')#' \
  "$TMP_SCRIPT" || true

# 修复 Alpine 当前 sing-box 版本下 `sing-box generate rand 16 --base64`
# 可能返回空值，导致 ShadowTLS 的 Shadowsocks 2022 密码为空。
sed -i \
  's#ss_password=$(sing-box generate rand 16 --base64)#ss_password=$(openssl rand -base64 16 | tr -d '\''\\r\\n'\'')#g' \
  "$TMP_SCRIPT"

chmod 700 "$TMP_SCRIPT"

say ""
say "============================================================"
say "以下进入 cuteys/ProxyResource 原版 Sing-Box 菜单"
say "已适配 Alpine + IPv6-only，并补齐 OpenRC 服务与 ShadowTLS 密码修复"
say "============================================================"
say ""

exec bash "$TMP_SCRIPT"
