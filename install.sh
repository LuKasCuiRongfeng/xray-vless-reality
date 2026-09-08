#!/usr/bin/env bash
# ============================================================
#  Xray + VLESS + Reality 一键安装 / 管理 / 卸载
#  使用官方 Xray (XTLS/Xray-core) 二进制
#
#  用法:  sudo bash install.sh [子命令]
#  子命令: install | link | restart | start | stop | status |
#          update | info | uninstall | help
#
#  环境变量(可选):
#    PORT          监听端口, 默认 443
#    SNI           伪装域名, 默认 www.cloudflare.com (Reality 标准伪装目标)
#    DEST          Reality 目标, 默认 www.cloudflare.com:443
#    UUID          自定义用户 ID, 默认自动生成
#    NAME          链接备注, 默认 xray-vless
#    IP            手动指定公网 IP, 默认自动探测
#    XRAY_VERSION  指定 Xray 版本, 默认自动获取最新
#    GEO_DATA      是否安装 geoip/geosite 路由数据(需路由规则时), 默认 0(不装)
#    ENABLE_BBR    是否自动启用 BBR 加速(内核支持时), 默认 1; 0 = 跳过
#
#  Hysteria2 速度线 (可选, 与 xray+reality 双轨安装):
#    HY2_PORT      Hysteria2 端口 (UDP), 默认 8443
#    HY2_SNI       Hysteria2 伪装域名, 默认 www.bing.com
#    HY2_PASS      Hysteria2 密码, 默认自动生成 (随机十六进制)
#    HY2_UP / HY2_DOWN 同时设置则启用 Brutal 锁带宽 (Mbps), 默认 BBR 自适应
#    HY2_VERSION   指定 Hysteria 版本, 默认自动获取最新 (如 app/v2.12.2)
# ============================================================
set -euo pipefail

XRAY_DIR="/usr/local/etc/xray"
CONFIG_FILE="$XRAY_DIR/config.json"
META_FILE="$XRAY_DIR/meta.conf"
BIN_FILE="/usr/local/bin/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"
FW_FILE="$XRAY_DIR/firewall.conf"
HY2_DIR="/usr/local/etc/hysteria"
HY2_CONFIG_FILE="$HY2_DIR/config.yaml"
HY2_META_FILE="$HY2_DIR/meta.conf"
HY2_CERT_FILE="$HY2_DIR/tls.crt"
HY2_KEY_FILE="$HY2_DIR/tls.key"
HY2_BIN_FILE="/usr/local/bin/hysteria"
HY2_SERVICE_FILE="/etc/systemd/system/hysteria.service"
HY2_SERVICE_NAME="hysteria"
SERVICE_NAME="xray"
SERVICE_USER="xray"

log()  { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "需要 root 权限运行: sudo bash install.sh <子命令>"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

infoline() {
  printf '\033[44;37;1m%s\033[0m\n' "$1"
}

sanitize() { echo "$1" | tr -cd '[:alnum:]_.-'; }

check_deps() {
  local miss=""
  for c in curl unzip awk od; do
    if ! have "$c"; then
      miss="$miss $c"
    fi
  done
  if ! have systemctl; then
    miss="$miss systemd(systemctl)"
  fi
  if [ -n "$miss" ]; then
    die "缺少依赖:$miss 请先安装 (Debian/Ubuntu: apt install curl unzip; CentOS: yum install curl unzip)"
  fi
}

detect_arch() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)      echo "64" ;;
    aarch64|arm64)     echo "arm64-v8a" ;;
    armv7l|armv6l|arm) echo "arm32-v7a" ;;
    *) die "不支持的架构: $m (仅支持 x86_64 / arm64 / armv7)" ;;
  esac
}

resolve_version() {
  if [ -n "${XRAY_VERSION:-}" ]; then
    echo "$XRAY_VERSION"
    return
  fi
  local ver
  ver=$(curl -fsSL --retry 3 -m 30 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4) || true
  if [ -z "$ver" ]; then
    die "自动获取最新版本失败, 请设置 XRAY_VERSION=v2.x.x 后重试"
  fi
  echo "$ver"
}

fetch_xray() {
  local ver arch url tmp
  ver=$(resolve_version)
  arch=$(detect_arch)
  url="https://github.com/XTLS/Xray-core/releases/download/$ver/Xray-linux-$arch.zip"
  log "下载官方 Xray $ver ($arch) ..."
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT
  curl -fL --retry 3 --connect-timeout 15 -m 300 -o "$tmp/xray.zip" "$url" || die "下载失败: $url"
  mkdir -p "$tmp/x"
  unzip -o -q "$tmp/xray.zip" -d "$tmp/x" || die "解压失败: $url"
  if [ ! -f "$tmp/x/xray" ]; then
    die "压缩包中未找到 xray 二进制文件, 请检查 $url"
  fi
  install -m 0755 "$tmp/x/xray" "$BIN_FILE"
  if [ "${GEO_DATA:-0}" = "1" ]; then
    if [ -f "$tmp/x/geoip.dat" ]; then
      install -m 0644 "$tmp/x/geoip.dat" "$XRAY_DIR/geoip.dat"
    fi
    if [ -f "$tmp/x/geosite.dat" ]; then
      install -m 0644 "$tmp/x/geosite.dat" "$XRAY_DIR/geosite.dat"
    fi
    ok "已安装 geoip/geosite 路由数据 (~29MB)"
  else
    log "跳过 geoip/geosite 数据文件 (~29MB), 如需路由规则: sudo GEO_DATA=1 bash install.sh install --force"
  fi
  rm -rf "$tmp"
  trap - EXIT
  ok "已安装官方 Xray $ver 到 $BIN_FILE"
}

create_user() {
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    local sh_path
    sh_path=$(command -v nologin || true)
    [ -n "$sh_path" ] || sh_path="/usr/sbin/nologin"
    useradd -r -M -d "$XRAY_DIR" -s "$sh_path" "$SERVICE_USER" 2>/dev/null || true
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
      die "创建用户 $SERVICE_USER 失败"
    fi
  fi
}

gen_config() {
  local keys priv pub sid
  log "生成 Reality 密钥对 / UUID / shortId ..."
  keys=$("$BIN_FILE" x25519)
  # 兼容旧版 (Private key:/Public key:) 与新 (PrivateKey:/Password (PublicKey):) 两种输出
  priv=$(printf '%s\n' "$keys" | sed -n 's/^Private *[Kk]ey: *//p')
  pub=$(printf '%s\n' "$keys" | sed -n 's/^Password *\([^:]*\): *//p; s/^Public *[Kk]ey: *//p')
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    die "生成 Reality 密钥失败, xray x25519 原始输出: ${keys}"
  fi
  UUID=$(sanitize "${UUID:-$("$BIN_FILE" uuid)}")
  [ -n "$UUID" ] || UUID=$("$BIN_FILE" uuid)
  sid=$(openssl rand -hex 8 2>/dev/null || od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [ -n "$sid" ] || sid="0000000000000000"
  PORT=$(echo "${PORT:-443}" | tr -cd '[:digit:]')
  if [ -z "$PORT" ] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "端口无效: ${PORT:-未设置} (PORT 应为 1-65535)"
  fi
  SNI=$(sanitize "${SNI:-www.cloudflare.com}")
  [ -n "$SNI" ] || SNI="www.cloudflare.com"
  DEST=$(echo "${DEST:-www.cloudflare.com:443}" | tr -cd '[:alnum:]_.:-')
  [ -n "$DEST" ] || DEST="www.cloudflare.com:443"
  NAME=$(sanitize "${NAME:-xray-vless}")
  [ -n "$NAME" ] || NAME="xray-vless"
  if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
    warn "端口 $PORT 已被占用, 如需更换请: sudo PORT=其他端口 bash install.sh install --force"
  fi
  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "decryption": "none",
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$DEST",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$priv",
        "shortIds": ["$sid"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct"
  }]
}
EOF
  cat > "$META_FILE" <<EOF
UUID=$UUID
PUB=$pub
SNI=$SNI
SID=$sid
PORT=$PORT
NAME=$NAME
EOF
  chmod 600 "$CONFIG_FILE"
  chmod 644 "$META_FILE"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$XRAY_DIR"
  ok "配置已生成: $CONFIG_FILE"
}

write_service_unit() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service (VLESS + Reality)
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_FILE run -config $CONFIG_FILE
Restart=on-failure
RestartSec=2
RestartPreventExitStatus=23
LimitNOFILE=1048576
LimitNPROC=1024
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$XRAY_DIR

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
}

get_public_ip() {
  if [ -n "${IP:-}" ]; then
    echo "$IP"
    return
  fi
  local ip u
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me" "https://4.ipw.cn"; do
    ip=$(curl -4fsS -m 8 --retry 1 "$u" 2>/dev/null | tr -d ' \n\r') || true
    if [ -n "$ip" ] && [ "$ip" != "null" ]; then
      echo "$ip"
      return
    fi
  done
  echo ""
}

build_link() {
  local ip="${1:-}"
  [ -f "$META_FILE" ] || die "未找到安装信息 ($META_FILE)"
  . "$META_FILE"
  echo "vless://$UUID@$ip:$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&spx=%2F&type=tcp&headerType=none&flow=xtls-rprx-vision#$NAME"
}

print_link() {
  local ip
  [ -f "$META_FILE" ] || die "未找到安装信息 ($META_FILE), 请先运行: sudo bash install.sh install"
  ip=$(get_public_ip)
  if [ -z "$ip" ]; then
    warn "未能自动获取公网 IP, 可手动指定: IP=你的公网IP bash install.sh link"
    ip="<你的公网IP>"
  fi
  . "$META_FILE"
  [ -f "$HY2_META_FILE" ] && . "$HY2_META_FILE"
  echo ""
  echo "================ 双线链接 (稳定 / 速度) ================"
  infoline "[稳定] VLESS + Reality:"
  infoline "$(build_link "$ip")"
  if [ -f "$HY2_META_FILE" ]; then
    infoline "[速度] Hysteria2:"
    infoline "$(build_hy2_link "$ip")"
    infoline "提醒: Hysteria2 节点请在 v2rayN 中切换 hysteria2 / sing-box 核心"
  fi
  echo "========================================================"
  echo ""
  echo "  IP: $ip    稳定线: $PORT/TCP    SNI: $SNI"
  if [ -f "$HY2_META_FILE" ]; then
    echo "  速度线: $HY2_PORT/UDP    SNI: $HY2_SNI"
    echo "  pinSHA256: $HY2_PIN (自签证书指纹, 新版 v2rayN 必需)"
  fi
  echo "  UUID: $UUID"
  echo "  公钥: $PUB    shortId: $SID"
}

show_summary() {
  [ -f "$META_FILE" ] || die "未找到安装信息, 请先运行: sudo bash install.sh install"
  . "$META_FILE"
  local ip ver svc cc bbr hy2svc fw_hint
  ip=$(get_public_ip)
  [ -n "$ip" ] || ip="<你的公网IP>"
  ver=$("$BIN_FILE" version 2>/dev/null | head -n 1 || true)
  svc=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  if [ "$cc" = "bbr" ]; then
    bbr="已启用 (bbr)"
  elif [ -f /etc/sysctl.d/99-xray-bbr.conf ]; then
    bbr="配置文件存在但未生效 (当前: $cc)"
  else
    bbr="未启用 (当前: $cc)"
  fi
  echo ""
  infoline "===================== 安装信息汇总 ====================="
  infoline "  服务状态:   $svc"
  infoline "  Xray 版本:  ${ver:-未知}"
  infoline "  BBR 加速:   $bbr"
  infoline "  公网 IP:    $ip"
  infoline "  监听端口:   $PORT"
  infoline "  SNI 伪装:   $SNI"
  infoline "  UUID:       $UUID"
  infoline "  公钥 Pbk:   $PUB"
  infoline "  shortId:    $SID"
  infoline "  配置文件:   $CONFIG_FILE"
  infoline "  服务单元:   $SERVICE_FILE"
  infoline "  系统用户:   $SERVICE_USER"
  if [ -f "$FW_FILE" ]; then
    . "$FW_FILE"
    infoline "  防火墙放行: 已自动放行 TCP $PORT ($FIREWALL)"
  else
    infoline "  防火墙放行: 系统防火墙无限制 (公网不通需检查云安全组)"
  fi
  if [ -f "$HY2_META_FILE" ]; then
    . "$HY2_META_FILE"
    hy2svc=$(systemctl is-active "$HY2_SERVICE_NAME" 2>/dev/null || echo unknown)
    infoline "  速度线 HY2:   $hy2svc (UDP $HY2_PORT / $HY2_SNI / pinSHA256 已内置)"
  else
    infoline "  速度线 HY2:   未安装"
  fi
  infoline "======================================================"
  echo ""
  infoline "  分享链接 (复制到 v2rayN / Shadowrocket 等客户端):"
  infoline "  [稳定] VLESS + Reality:"
  infoline "$(build_link "$ip")"
  if [ -f "$HY2_META_FILE" ]; then
    infoline "  [速度] Hysteria2:"
    infoline "$(build_hy2_link "$ip")"
    infoline "  提示: Hysteria2 节点请在 v2rayN 中切换 hysteria2 / sing-box 核心"
  fi
  echo ""
  infoline "  管理命令:  bash install.sh link | restart | status | info | bbr | update | uninstall"
  fw_hint="TCP $PORT"
  [ -n "${HY2_PORT:-}" ] && fw_hint="TCP $PORT 与 UDP $HY2_PORT"
  infoline "  提示: 若客户端无法连接, 请检查防火墙 / 云安全组放行 $fw_hint"
  echo ""
}

cmd_install() {
  local mode="${1:-}"
  require_root
  check_deps
  mkdir -p "$XRAY_DIR"
  create_user
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fetch_xray
  if [ "$mode" = "--keep" ] && [ -f "$CONFIG_FILE" ]; then
    warn "已保留现有配置 (--keep)"
  else
    if [ -f "$CONFIG_FILE" ]; then
      cp -a "$CONFIG_FILE" "$CONFIG_FILE.bak"
      warn "原配置已备份: $CONFIG_FILE.bak (默认会重新生成配置; 保留旧配置用: install --keep)"
    fi
    gen_config
  fi
  write_service_unit
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Xray 服务已启动"
  else
    die "服务启动失败, 请检查: journalctl -u xray -n 50"
  fi
  enable_bbr
  install_hy2 "$mode"
  open_firewall
  show_summary
}

cmd_update() {
  require_root
  check_deps
  mkdir -p "$XRAY_DIR"
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  if ! ( fetch_xray ); then
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    die "升级失败, 已尝试恢复原服务"
  fi
  systemctl start "$SERVICE_NAME" 2>/dev/null || true
  ok "Xray 已更新并重启"
  if [ -f "$HY2_BIN_FILE" ]; then
    if ( fetch_hy2 ); then
      systemctl restart "$HY2_SERVICE_NAME" 2>/dev/null || true
      ok "Hysteria2 已更新并重启"
    fi
  fi
  show_summary
}

cmd_service() {
  systemctl "$1" "$SERVICE_NAME"
  if [ -f "$HY2_SERVICE_FILE" ]; then
    systemctl "$1" "$HY2_SERVICE_NAME"
    ok "已执行: systemctl $1 $SERVICE_NAME 与 $HY2_SERVICE_NAME"
  else
    ok "已执行: systemctl $1 $SERVICE_NAME"
  fi
}

cmd_status() {
  systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
  if [ -f "$HY2_SERVICE_FILE" ]; then
    echo "--- Hysteria2 ---"
    systemctl is-active "$HY2_SERVICE_NAME" 2>/dev/null || true
    systemctl status "$HY2_SERVICE_NAME" --no-pager 2>/dev/null || true
  fi
}

cmd_info() {
  show_summary
}

open_firewall() {
  local fw=""
  if [ -z "${PORT:-}" ]; then
    [ -f "$META_FILE" ] || die "无法确定端口: PORT 未设置且未找到 $META_FILE"
    . "$META_FILE"
  fi
  if [ -f "$HY2_META_FILE" ]; then
    . "$HY2_META_FILE"
  fi
  if have ufw && ufw status 2>/dev/null | grep -qi "active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
    [ -n "${HY2_PORT:-}" ] && ufw allow "$HY2_PORT/udp" >/dev/null 2>&1 || true
    fw="ufw"
  elif have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
    [ -n "${HY2_PORT:-}" ] && firewall-cmd --permanent --add-port="$HY2_PORT/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    fw="firewalld"
  elif have iptables; then
    if iptables -S INPUT 2>/dev/null | grep -qE "(^-P INPUT (DROP|REJECT))"; then
      if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
      fi
      if [ -n "${HY2_PORT:-}" ] && ! iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p udp --dport "$HY2_PORT" -j ACCEPT >/dev/null 2>&1 || true
      fi
      fw="iptables"
    fi
  fi
  if [ -n "$fw" ]; then
    printf 'FIREWALL=%s\nPORT=%s\nHY2_PORT=%s\n' "$fw" "$PORT" "${HY2_PORT:-}" > "$FW_FILE"
    if [ "$fw" = "iptables" ]; then
      have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
      mkdir -p /etc/iptables 2>/dev/null || true
      { iptables-save > /etc/iptables/rules.v4; } 2>/dev/null || true
    fi
    if [ -n "${HY2_PORT:-}" ]; then
      ok "已自动放行 TCP $PORT 与 UDP $HY2_PORT (防火墙: $fw)"
    else
      ok "已自动放行 TCP $PORT (防火墙: $fw)"
    fi
  else
    rm -f "$FW_FILE"
    warn "未检测到需要放行的系统防火墙 (ufw/firewalld/iptables 均未启用限制)"
    if [ -n "${HY2_PORT:-}" ]; then
      warn "若公网仍无法连接: 请到云控制台放行 TCP $PORT 与 UDP $HY2_PORT (脚本无法操作云平台)"
    else
      warn "若公网仍无法连接: 多为云厂商安全组拦截, 请到云控制台放行 TCP $PORT (脚本无法操作云平台)"
    fi
  fi
}

close_firewall() {
  if [ ! -f "$FW_FILE" ]; then
    return
  fi
  . "$FW_FILE"
  HY2_PORT="${HY2_PORT:-}"
  case "$FIREWALL" in
    ufw)        ufw delete allow "$PORT/tcp" >/dev/null 2>&1 || true
                [ -n "$HY2_PORT" ] && ufw delete allow "$HY2_PORT/udp" >/dev/null 2>&1 || true ;;
    firewalld)  firewall-cmd --permanent --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
                [ -n "$HY2_PORT" ] && firewall-cmd --permanent --remove-port="$HY2_PORT/udp" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true ;;
    iptables)   iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
                [ -n "$HY2_PORT" ] && iptables -D INPUT -p udp --dport "$HY2_PORT" -j ACCEPT >/dev/null 2>&1 || true
                have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true ;;
  esac
  warn "已回滚本脚本添加的防火墙规则 ($FIREWALL: TCP $PORT, UDP ${HY2_PORT:-无})"
  rm -f "$FW_FILE"
}

detect_hy2_arch() {
  case "$(uname -m)" in
    x86_64|amd64)      echo "amd64" ;;
    aarch64|arm64)     echo "arm64" ;;
    armv7l|armv6l|arm) echo "arm" ;;
    *) die "不支持的架构: $(uname -m) (Hysteria2 仅支持 x86_64 / arm64 / armv7)" ;;
  esac
}

resolve_hy2_version() {
  if [ -n "${HY2_VERSION:-}" ]; then
    echo "$HY2_VERSION"
    return
  fi
  local ver
  ver=$(curl -fsSL --retry 3 -m 30 "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4) || true
  if [ -z "$ver" ]; then
    die "自动获取 Hysteria2 最新版本失败, 请设置 HY2_VERSION=app/v2.x.x 重试"
  fi
  echo "$ver"
}

fetch_hy2() {
  local ver arch url tmp
  ver=$(resolve_hy2_version)
  arch=$(detect_hy2_arch)
  url="https://github.com/apernet/hysteria/releases/download/$ver/hysteria-linux-$arch"
  log "下载官方 Hysteria2 $ver ($arch) ..."
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT
  curl -fL --retry 3 --connect-timeout 15 -m 300 -o "$tmp/hysteria" "$url" || die "下载失败: $url"
  chmod 0755 "$tmp/hysteria"
  "$tmp/hysteria" version >/dev/null 2>&1 || die "下载内容不是合法的 Hysteria2 二进制: $url"
  install -m 0755 "$tmp/hysteria" "$HY2_BIN_FILE"
  rm -rf "$tmp"
  trap - EXIT
  ok "已安装官方 Hysteria2 $ver 到 $HY2_BIN_FILE"
}

generate_hy2_config() {
  local ip bw san_ip
  ip=$(get_public_ip)
  if [ -z "${HY2_PASS:-}" ]; then
    HY2_PASS=$(openssl rand -hex 16 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  fi
  HY2_PASS=$(echo "$HY2_PASS" | tr -cd '[:alnum:]_-')
  [ -n "$HY2_PASS" ] || HY2_PASS=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  HY2_PORT=$(echo "${HY2_PORT:-8443}" | tr -cd '[:digit:]')
  if [ -z "$HY2_PORT" ] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then
    die "HY2 端口无效: ${HY2_PORT:-未设置} (HY2_PORT 应为 1-65535)"
  fi
  HY2_SNI=$(sanitize "${HY2_SNI:-www.bing.com}")
  [ -n "$HY2_SNI" ] || HY2_SNI="www.bing.com"
  HY2_UP=$(echo "${HY2_UP:-}" | tr -cd '[:digit:]')
  HY2_DOWN=$(echo "${HY2_DOWN:-}" | tr -cd '[:digit:]')
  if [ -n "$HY2_UP" ] || [ -n "$HY2_DOWN" ]; then
    if [ -z "$HY2_UP" ] || [ -z "$HY2_DOWN" ]; then
      die "Brutal 模式需同时设置 HY2_UP 与 HY2_DOWN (Mbps)"
    fi
  fi
  log "生成 Hysteria2 自签证书与配置 ..."
  openssl ecparam -genkey -name prime256v1 -out "$HY2_KEY_FILE" 2>/dev/null || die "生成 Hysteria2 私钥失败"
  [ -n "$ip" ] && san_ip="IP.1 = $ip"
  cat > "$HY2_DIR/openssl.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $HY2_SNI
[ext]
subjectAltName = @san
extendedKeyUsage = serverAuth
[san]
DNS.1 = $HY2_SNI
${san_ip:-}
EOF
  openssl req -new -x509 -days 3650 -key "$HY2_KEY_FILE" -out "$HY2_CERT_FILE" -config "$HY2_DIR/openssl.cnf" 2>/dev/null || die "生成 Hysteria2 证书失败"
  HY2_PIN=$(openssl x509 -in "$HY2_CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | awk -F= '{print $2}' | tr -d ':' | tr 'A-F' 'a-f')
  if [ -z "$HY2_PIN" ]; then
    die "计算 Hysteria2 证书 pinSHA256 失败"
  fi
  if [ -n "$HY2_UP" ] && [ -n "$HY2_DOWN" ]; then
    bw="bandwidth:
  up: $HY2_UP mbps
  down: $HY2_DOWN mbps
"
  fi
  cat > "$HY2_CONFIG_FILE" <<EOF
listen: :$HY2_PORT
tls:
  cert: $HY2_CERT_FILE
  key: $HY2_KEY_FILE
auth:
  type: password
  password: $HY2_PASS
${bw:-}
masquerade:
  type: proxy
  proxy:
    url: https://$HY2_SNI/
    rewriteHost: true
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 10s
EOF
  cat > "$HY2_META_FILE" <<EOF
HY2_PORT=$HY2_PORT
HY2_SNI=$HY2_SNI
HY2_PASS=$HY2_PASS
HY2_PIN=$HY2_PIN
HY2_UP=$HY2_UP
HY2_DOWN=$HY2_DOWN
EOF
  chmod 600 "$HY2_KEY_FILE"
  chmod 644 "$HY2_CERT_FILE" "$HY2_META_FILE" "$HY2_CONFIG_FILE"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$HY2_DIR"
  ok "Hysteria2 配置已生成: $HY2_CONFIG_FILE"
}

write_hy2_unit() {
  cat > "$HY2_SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria2 Service (Speed Line)
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$HY2_BIN_FILE server -c $HY2_CONFIG_FILE
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576
LimitNPROC=1024
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$HY2_DIR

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$HY2_SERVICE_FILE"
}

enable_udp_buffers() {
  cat > /etc/sysctl.d/90-xray-udp.conf <<'EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
EOF
  sysctl -p /etc/sysctl.d/90-xray-udp.conf >/dev/null 2>&1 || true
}

build_hy2_link() {
  local ip="${1:-}"
  local query="sni=$HY2_SNI&alpn=h3&pinSHA256=$HY2_PIN"
  if [ -n "$HY2_UP" ] && [ -n "$HY2_DOWN" ]; then
    query="${query}&upmbps=$HY2_UP&downmbps=$HY2_DOWN"
  fi
  echo "hysteria2://$HY2_PASS@$ip:$HY2_PORT/?$query#$NAME-hy2"
}

install_hy2() {
  local keep="${1:-}"
  mkdir -p "$HY2_DIR"
  fetch_hy2
  if [ "$keep" = "--keep" ] && [ -f "$HY2_CONFIG_FILE" ]; then
    log "保留现有 Hysteria2 配置 (--keep)"
    [ -f "$HY2_META_FILE" ] && . "$HY2_META_FILE"
  else
    if [ -f "$HY2_CONFIG_FILE" ]; then
      cp -a "$HY2_CONFIG_FILE" "$HY2_CONFIG_FILE.bak"
      warn "Hysteria2 原配置已备份: $HY2_CONFIG_FILE.bak"
    fi
    generate_hy2_config
  fi
  enable_udp_buffers
  write_hy2_unit
  systemctl daemon-reload
  systemctl enable "$HY2_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$HY2_SERVICE_NAME"
  sleep 1
  if systemctl is-active --quiet "$HY2_SERVICE_NAME"; then
    ok "Hysteria2 服务已启动 (UDP $HY2_PORT)"
  else
    warn "Hysteria2 服务启动失败 (不影响 xray 主线路); 检查: journalctl -u hysteria -n 20"
  fi
}

enable_bbr() {
  local cc avail
  if [ "${ENABLE_BBR:-1}" = "0" ]; then
    log "已跳过 BBR (ENABLE_BBR=0)"
    return
  fi
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  if [ "$cc" = "bbr" ]; then
    ok "BBR 已开启 (当前拥塞控制: bbr)"
    return
  fi
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if ! echo "$avail" | grep -qw bbr; then
    modprobe tcp_bbr 2>/dev/null || true
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  fi
  if ! echo "$avail" | grep -qw bbr; then
    warn "当前内核不支持 BBR (需 Linux 4.9+), 已跳过; 本脚本不会自动升级内核"
    return
  fi
  cat > /etc/sysctl.d/99-xray-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/99-xray-bbr.conf >/dev/null 2>&1 \
    || sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
    || true
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  if [ "$cc" = "bbr" ]; then
    ok "BBR 已启用 (写入 /etc/sysctl.d/99-xray-bbr.conf, 即时生效无需重启)"
  else
    warn "sysctl 写入失败 (可能运行在受限容器中), BBR 未生效"
  fi
}

bbr_status() {
  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  echo "TCP 拥塞控制: $cc"
  if [ -f /etc/sysctl.d/99-xray-bbr.conf ]; then
    echo "配置文件: /etc/sysctl.d/99-xray-bbr.conf (存在)"
  else
    echo "配置文件: 无 (BBR 未由本脚本启用)"
  fi
}

bbr_on() {
  require_root
  enable_bbr
}

bbr_off() {
  require_root
  rm -f /etc/sysctl.d/99-xray-bbr.conf
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  warn "已关闭 BBR, 拥塞控制恢复为 cubic (如需其它算法请手动调整)"
}

cmd_bbr() {
  local action="${1:-}"
  case "$action" in
    on)  bbr_on ;;
    off) bbr_off ;;
    *)   bbr_status ;;
  esac
}

cmd_uninstall() {
  require_root
  warn "开始卸载 Xray ..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  if [ -d "$XRAY_DIR" ] && [ -f "$CONFIG_FILE" ]; then
    local backup_dir="/root/xray-config-backup"
    mkdir -p "$backup_dir"
    cp -a "$CONFIG_FILE" "$backup_dir/config.json.$(date +%Y%m%d%H%M%S)"
    warn "配置已备份到: $backup_dir"
  fi
  close_firewall
  systemctl stop "$HY2_SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$HY2_SERVICE_NAME" 2>/dev/null || true
  rm -f "$HY2_SERVICE_FILE"
  rm -f "$HY2_BIN_FILE"
  rm -rf "$HY2_DIR"
  systemctl daemon-reload
  rm -f "$BIN_FILE"
  rm -rf "$XRAY_DIR"
  userdel "$SERVICE_USER" 2>/dev/null || true
  ok "卸载完成: 已删除 xray / hysteria2 二进制、配置、systemd 单元与用户 $SERVICE_USER"
}

usage() {
  cat <<'EOF'
用法:  sudo bash install.sh [子命令]

子命令:
  install              双线安装: VLESS+Reality(稳定) + Hysteria2(速度), 两条链接自由选择
                        (默认重新生成配置/密钥, 旧配置自动备份为 config.json.bak)
  install --keep       保留现有配置, 仅修复 / 重装服务
  link                打印 VLESS + Reality 分享链接 (无需 root)
  start | stop | restart   服务管理
  status              查看服务状态 (无需 root)
  update              升级到最新官方 Xray
  info                查看安装信息 (无需 root)
  uninstall           卸载 Xray (配置自动备份到 /root/xray-config-backup/)
  bbr [on|off]        查看 BBR 状态; on/off 启用或关闭 (安装时默认自动启用)
  help                显示帮助

环境变量(可选): PORT SNI DEST UUID NAME IP XRAY_VERSION
示例:  sudo PORT=8443 SNI=www.apple.com bash install.sh install
EOF
}

main() {
  local cmd="${1:-}"
  local arg="${2:-}"
  case "$cmd" in
    "")
      if [ -f "$META_FILE" ] && [ -x "$BIN_FILE" ]; then
        usage
      else
        cmd_install ""
      fi
      ;;
    install)   require_root; cmd_install "$arg" ;;
    link)      print_link ;;
    start|restart|stop) require_root; cmd_service "$cmd" ;;
    status)    cmd_status ;;
    update)    cmd_update ;;
    info)      cmd_info ;;
    uninstall) cmd_uninstall ;;
    bbr)      cmd_bbr "$arg" ;;
    help|-h|--help) usage ;;
    *) die "未知命令: $cmd (使用: bash install.sh help)" ;;
  esac
}

main "$@"
