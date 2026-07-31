#!/bin/sh
# Alpine IPv6-only Shadowsocks installer for tiny LazyCatCloud/LXC instances.
# Target: Alpine 3.23+, OpenRC, IPv6-only, 128 MB RAM / 512 MB disk.
# Default public/internal port: 21959 (TCP + UDP).

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

need_root() {
  [ "$(id -u)" = "0" ] || fail "请使用 root 用户运行"
}

check_alpine() {
  [ -f /etc/alpine-release ] || fail "此脚本仅适用于 Alpine Linux"
}

check_port() {
  case "$PORT" in
    ''|*[!0-9]*) fail "PORT 必须是 1-65535 的数字" ;;
  esac
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "PORT 必须是 1-65535"
}

fix_dns_if_needed() {
  say "[1/6] 检查 IPv6 与 DNS..."
  ip -6 route 2>/dev/null | grep -q '^default' || fail "没有 IPv6 默认路由"

  if command -v nslookup >/dev/null 2>&1 && nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1; then
    say "DNS 正常"
    return
  fi

  say "当前 DNS 不可用，切换为 IPv6 DNS"
  cat > /etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
options timeout:2 attempts:3
EOF

  if command -v nslookup >/dev/null 2>&1; then
    nslookup dl-cdn.alpinelinux.org >/dev/null 2>&1 || fail "IPv6 DNS 仍无法解析 Alpine 软件源"
  fi
}

install_pkg() {
  say "[2/6] 安装 Shadowsocks-rust 服务端..."
  apk update
  if ! apk add --no-cache shadowsocks-rust-ssserver ca-certificates; then
    say "独立 ssserver 包不可用，尝试完整 shadowsocks-rust 包..."
    apk add --no-cache shadowsocks-rust ca-certificates
  fi
  update-ca-certificates >/dev/null 2>&1 || true
  command -v ssserver >/dev/null 2>&1 || fail "ssserver 安装失败"
}

gen_password() {
  if [ -f "$CONFIG_FILE" ]; then
    sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1
    return
  fi
  head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24
}

get_public_ipv6() {
  # LazyCatCloud exposes a public IPv6 that may differ from the LXC's fd42:: address.
  # Prefer an explicitly supplied SERVER_IPV6; otherwise try public IPv6 discovery.
  if [ -n "${SERVER_IPV6:-}" ]; then
    printf '%s' "$SERVER_IPV6"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    ip6="$(wget -6 -qO- --timeout=8 https://api6.ipify.org 2>/dev/null || true)"
    if [ -n "$ip6" ]; then
      printf '%s' "$ip6"
      return
    fi
  fi

  # Do not publish fd00/fd42 internal addresses as client addresses.
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6 / {print $2}' \
    | cut -d/ -f1 \
    | grep -Ev '^(fd|fc)' \
    | head -n1 || true
}

write_config() {
  say "[3/6] 写入 SS 配置..."
  mkdir -p "$CONFIG_DIR"
  PASSWORD="$(gen_password)"
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
}

write_service() {
  say "[4/6] 配置 OpenRC 开机自启..."
  cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="Shadowsocks Rust Server"
description="Lightweight Shadowsocks server"
command="$(command -v ssserver)"
command_args="-c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/${SERVICE}.pid"
output_log="/var/log/${SERVICE}.log"
error_log="/var/log/${SERVICE}.log"

depend() {
    need net
}
EOF
  chmod +x "$SERVICE_FILE"
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
  rc-service "$SERVICE" restart
}

verify() {
  say "[5/6] 验证服务..."
  sleep 1
  rc-service "$SERVICE" status >/dev/null 2>&1 || {
    say "服务启动失败，日志："
    tail -n 50 "/var/log/${SERVICE}.log" 2>/dev/null || true
    exit 1
  }

  if command -v ss >/dev/null 2>&1; then
    ss -lntup 2>/dev/null | grep -q ":${PORT}" || fail "没有检测到 ${PORT} 端口监听"
  fi
}

show_client() {
  PASSWORD="$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
  IPV6="$(get_public_ipv6)"

  say "[6/6] 完成"
  say ""
  say "========================================"
  say "      Shadowsocks IPv6 节点"
  say "========================================"
  if [ -n "$IPV6" ]; then
    say "服务器 IPv6 : $IPV6"
  else
    say "服务器 IPv6 : 未自动获取"
    say "请按 LazyCatCloud 面板显示的公网 IPv6 填写客户端"
  fi
  say "端口        : $PORT"
  say "加密        : $METHOD"
  say "密码        : $PASSWORD"
  say "TCP/UDP     : 已开启"
  say "监听地址    : ::"
  say "========================================"
  say "LazyCatCloud 面板必须同时存在："
  say "TCP IPv6  ${PORT} -> ${PORT}"
  say "UDP IPv6  ${PORT} -> ${PORT}"
  say "========================================"

  if [ -n "$IPV6" ]; then
    USERINFO="$(printf '%s' "${METHOD}:${PASSWORD}" | base64 | tr -d '\n')"
    URI="ss://${USERINFO}@[${IPV6}]:${PORT}#KP-SS"
    cat > "$CLIENT_FILE" <<EOF
服务器: ${IPV6}
端口: ${PORT}
加密: ${METHOD}
密码: ${PASSWORD}
UDP: true

${URI}

Surge:
KP-SS = ss, ${IPV6}, ${PORT}, encrypt-method=${METHOD}, password=${PASSWORD}, udp-relay=true

Clash/Mihomo:
- name: KP-SS
  type: ss
  server: ${IPV6}
  port: ${PORT}
  cipher: ${METHOD}
  password: "${PASSWORD}"
  udp: true
EOF
    say ""
    say "分享链接："
    say "$URI"
    say ""
    say "客户端配置已保存：$CLIENT_FILE"
  fi
}

uninstall_ss() {
  rc-service "$SERVICE" stop >/dev/null 2>&1 || true
  rc-update del "$SERVICE" default >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  apk del shadowsocks-rust-ssserver >/dev/null 2>&1 || apk del shadowsocks-rust >/dev/null 2>&1 || true
  say "Shadowsocks 已卸载"
}

main() {
  need_root
  check_alpine
  check_port

  case "${1:-install}" in
    install)
      fix_dns_if_needed
      install_pkg
      write_config
      write_service
      verify
      show_client
      ;;
    show)
      [ -f "$CONFIG_FILE" ] || fail "尚未安装"
      show_client
      ;;
    restart)
      rc-service "$SERVICE" restart
      ;;
    status)
      rc-service "$SERVICE" status
      ;;
    uninstall)
      uninstall_ss
      ;;
    *)
      say "用法: $0 [install|show|restart|status|uninstall]"
      say "自定义端口: PORT=21959 $0 install"
      say "指定公网 IPv6: SERVER_IPV6=2001:db8::1 $0 install"
      exit 1
      ;;
  esac
}

main "$@"
