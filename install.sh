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
# ============================================================
set -euo pipefail

XRAY_DIR="/usr/local/etc/xray"
CONFIG_FILE="$XRAY_DIR/config.json"
META_FILE="$XRAY_DIR/meta.conf"
BIN_FILE="/usr/local/bin/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"
FW_FILE="$XRAY_DIR/firewall.conf"
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
  echo ""
  echo "============= VLESS + Reality 分享链接 ============="
  echo "$(build_link "$ip")"
  echo "==================================================="
  echo ""
  echo "  IP: $ip    端口: $PORT    SNI: $SNI"
  echo "  UUID: $UUID"
  echo "  公钥: $PUB    shortId: $SID"
}

show_summary() {
  [ -f "$META_FILE" ] || die "未找到安装信息, 请先运行: sudo bash install.sh install"
  . "$META_FILE"
  local ip ver svc cc bbr
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
  echo "===================== 安装信息汇总 ====================="
  echo "  服务状态:   $svc"
  echo "  Xray 版本:  ${ver:-未知}"
  echo "  BBR 加速:   $bbr"
  echo "  公网 IP:    $ip"
  echo "  监听端口:   $PORT"
  echo "  SNI 伪装:   $SNI"
  echo "  UUID:       $UUID"
  echo "  公钥 Pbk:   $PUB"
  echo "  shortId:    $SID"
  echo "  配置文件:   $CONFIG_FILE"
  echo "  服务单元:   $SERVICE_FILE"
  echo "  系统用户:   $SERVICE_USER"
  if [ -f "$FW_FILE" ]; then
    . "$FW_FILE"
    echo "  防火墙放行: 已自动放行 TCP $PORT ($FIREWALL)"
  else
    echo "  防火墙放行: 系统防火墙无限制 (公网不通需检查云安全组)"
  fi
  echo "======================================================"
  echo ""
  echo "  分享链接 (复制到 v2rayN / Shadowrocket 等客户端):"
  echo "$(build_link "$ip")"
  echo ""
  echo "  管理命令:  bash install.sh link | restart | status | info | bbr | update | uninstall"
  echo "  提示: 若客户端无法连接, 请检查防火墙 / 云安全组放行 TCP $PORT"
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
  show_summary
}

cmd_service() {
  systemctl "$1" "$SERVICE_NAME"
  ok "已执行: systemctl $1 $SERVICE_NAME"
}

cmd_status() {
  systemctl is-active "$SERVICE_NAME" 2>/dev/null || true
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
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
  if have ufw && ufw status 2>/dev/null | grep -qi "active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
    fw="ufw"
  elif have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    fw="firewalld"
  elif have iptables; then
    if iptables -S INPUT 2>/dev/null | grep -qE "(^-P INPUT (DROP|REJECT))"; then
      if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
      fi
      fw="iptables"
    fi
  fi
  if [ -n "$fw" ]; then
    printf 'FIREWALL=%s\nPORT=%s\n' "$fw" "$PORT" > "$FW_FILE"
    if [ "$fw" = "iptables" ]; then
      have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true
      mkdir -p /etc/iptables 2>/dev/null || true
      { iptables-save > /etc/iptables/rules.v4; } 2>/dev/null || true
    fi
    ok "已自动放行 TCP $PORT (防火墙: $fw)"
  else
    rm -f "$FW_FILE"
    warn "未检测到需要放行的系统防火墙 (ufw/firewalld/iptables 均未启用限制)"
    warn "若公网仍无法连接: 多为云厂商安全组拦截, 请到云控制台放行 TCP $PORT (脚本无法操作云平台)"
  fi
}

close_firewall() {
  if [ ! -f "$FW_FILE" ]; then
    return
  fi
  . "$FW_FILE"
  case "$FIREWALL" in
    ufw)        ufw delete allow "$PORT/tcp" >/dev/null 2>&1 || true ;;
    firewalld)  firewall-cmd --permanent --remove-port="$PORT/tcp" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true ;;
    iptables)   iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1 || true
                have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1 || true ;;
  esac
  warn "已回滚本脚本添加的防火墙规则 ($FIREWALL, TCP $PORT)"
  rm -f "$FW_FILE"
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
  rm -f "$BIN_FILE"
  rm -rf "$XRAY_DIR"
  userdel "$SERVICE_USER" 2>/dev/null || true
  ok "卸载完成: 已删除二进制 / 配置 / systemd 单元 / 用户 $SERVICE_USER"
}

usage() {
  cat <<'EOF'
用法:  sudo bash install.sh [子命令]

子命令:
  install              安装 (默认总是重新生成配置/密钥, 旧配置自动备份为 config.json.bak)
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
