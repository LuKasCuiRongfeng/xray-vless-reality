#!/usr/bin/env bash
# ============================================================
#  xray-vless-reality 回归测试 (无需 root)
#  用法:  bash test/smoke.sh
#  覆盖回归点:
#   - 密钥解析: 新格式(PrivateKey:/Password (PublicKey):) 与 旧格式(Private key:/Public key:)
#   - 默认值 / 环境变量覆盖 (PORT SNI DEST NAME)
#   - 非法端口校验 / 异常密钥输出(应报错且带原始输出)
#   - 保留已有配置重装路径 (PORT 未绑定回归)
#   - 防火墙: ufw / firewalld / iptables-DROP / 无限制, 放行与卸载回滚
#   - BBR: 已启用 / 支持并启用 / 不支持自动跳过
#   - 汇总输出 / 分享链接 / 卸载流程
# ============================================================
set -u

INSTALL_SH="$(cd "$(dirname "$0")/.." && pwd)/install.sh"
[ -f "$INSTALL_SH" ] || { echo "[x] 找不到 install.sh ($INSTALL_SH)"; exit 1; }

SIM="$(mktemp -d)"
trap 'rm -rf "$SIM"' EXIT
mkdir -p "$SIM/etc" "$SIM/bin" "$SIM/backup" "$SIM/log"

PASS=0
FAIL=0

# ---------- 断言工具 ----------
assert_contains() { # file pattern name
  if grep -qF -- "$2" "$1" 2>/dev/null; then return 0; fi
  echo "断言失败 [$3]: $1 中未找到 [$2]" >&2
  return 1
}
assert_same() { # expected actual name
  if [ "$1" = "$2" ]; then return 0; fi
  echo "断言失败 [$3]: 期望 [$1] 实际 [$2]" >&2
  return 1
}
assert_contains_str() { # string pattern name
  printf '%s\n' "$1" | grep -qF -- "$2" || { echo "断言失败 [$3]: 未包含 [$2]" >&2; return 1; }
  return 0
}
assert_fails() { # fn name
  if "$1" >/dev/null 2>&1; then
    echo "断言失败 [$2]: 期望失败但成功" >&2
    return 1
  fi
  return 0
}

# ---------- 生成被测库 ----------
# 路径全部重定向到沙箱; 摘掉 main 调用与 set -e(便于断言控制); 禁用端口探测(MSYS 下挂起)
LIB="$SIM/lib.sh"
sed -e "s|/usr/local/etc/xray|$SIM/etc|g" \
    -e "s|/usr/local/bin/xray|$SIM/bin/xray|g" \
    -e "s|/etc/systemd/system/xray.service|$SIM/svc|g" \
    -e "s|/etc/sysctl.d/99-xray-bbr.conf|$SIM/bbr.conf|g" \
    -e "s|/root/xray-config-backup|$SIM/backup|g" \
    -e '$d' \
    -e '/^set -euo pipefail$/d' \
    -e 's|exec 3<>/dev/tcp/127.0.0.1/"$PORT"|false|' \
    "$INSTALL_SH" > "$LIB"
. "$LIB"

# ---------- 场景工具 ----------
reset() {
  rm -f "$SIM/etc/config.json" "$SIM/etc/meta.conf" "$SIM/etc/firewall.conf" "$SIM/bbr.conf" "$SIM/etc/config.json.bak"
  unset -f ufw firewall-cmd systemctl iptables sysctl userdel netfilter-persistent iptables-save openssl chown 2>/dev/null || true
  chown() { return 0; }
  XRAY_DIR="$SIM/etc"
  META_FILE="$SIM/etc/meta.conf"
  CONFIG_FILE="$SIM/etc/config.json"
  FW_FILE="$SIM/etc/firewall.conf"
  BIN_FILE="$SIM/bin/xray"
  PORT=""; NAME=""; SNI=""; DEST=""; UUID=""; IP=""
  : > "$SIM/log/calls"
}
stub_xray_new() {
  printf '#!/usr/bin/env bash\ncase "$1" in\n  x25519) printf "PrivateKey: NEWPRIVKEY01\\nPassword (PublicKey): NEWPUBKEY02\\nHash32: AAAABBBB\\n" ;;\n  uuid) echo "12345678-1234-1234-1234-123456789abc" ;;\n  *) echo "Xray vTEST (smoke)" ;;\nesac\n' > "$SIM/bin/xray"
  chmod +x "$SIM/bin/xray"
}
stub_xray_old() {
  printf '#!/usr/bin/env bash\ncase "$1" in\n  x25519) printf "Private key: OLDPRIVKEY01\\nPublic key: OLDPUBKEY02\\n" ;;\n  uuid) echo "12345678-1234-1234-1234-123456789abc" ;;\n  *) echo "Xray vTEST (smoke)" ;;\nesac\n' > "$SIM/bin/xray"
  chmod +x "$SIM/bin/xray"
}
stub_xray_v262() {
  printf '#!/usr/bin/env bash\ncase "$1" in\n  x25519) printf "PrivateKey: V26PRIVKEY01\\nPassword: V26PUBKEY02\\nHash32: BBBB\\n" ;;\n  uuid) echo "12345678-1234-1234-1234-123456789abc" ;;\n  *) echo "Xray v26.2.6 (smoke)" ;;\nesac\n\' > "$SIM/bin/xray"
  chmod +x "$SIM/bin/xray"
}
stub_xray_bad() {
  printf '#!/usr/bin/env bash\ncase "$1" in\n  x25519) printf "Something unexpected: XYZ\\n" ;;\n  *) echo "Xray vTEST (smoke)" ;;\nesac\n' > "$SIM/bin/xray"
  chmod +x "$SIM/bin/xray"
}
stub_ufw_active() {
  ufw() { echo "ufw $*" >> "$SIM/log/calls"; if [ "$1" = "status" ]; then echo "Status: active"; fi; }
}
stub_ip() {
  get_public_ip() { echo "203.0.113.9"; }
}

# ---------- 场景 ----------
sc_fresh_defaults() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || { echo "gen_config 不应失败" >&2; return 1; }
  assert_contains "$CONFIG_FILE" '"port": 443' "默认端口443" || return 1
  assert_contains "$CONFIG_FILE" '"privateKey": "NEWPRIVKEY01"' "新格式私钥" || return 1
  assert_contains "$CONFIG_FILE" '"id": "12345678-1234-1234-1234-123456789abc"' "UUID" || return 1
  assert_contains "$META_FILE" 'PUB=NEWPUBKEY02' "新格式公钥" || return 1
  assert_contains "$META_FILE" 'NAME=xray-vless' "默认NAME" || return 1
  assert_contains "$META_FILE" 'SNI=www.cloudflare.com' "默认SNI(cloudflare)" || return 1
  assert_contains "$META_FILE" 'SID=' "shortId 存在" || return 1
  return 0
}
sc_env_overrides() {
  reset; stub_xray_new
  PORT=8443; SNI=www.apple.com; DEST=www.apple.com:443; NAME=my-node
  gen_config >/dev/null 2>&1 || { echo "gen_config 不应失败" >&2; return 1; }
  assert_contains "$CONFIG_FILE" '"port": 8443' "覆盖端口" || return 1
  assert_contains "$CONFIG_FILE" '"serverNames": ["www.apple.com"]' "覆盖SNI" || return 1
  assert_contains "$META_FILE" 'NAME=my-node' "覆盖NAME" || return 1
  local link
  link=$(build_link "1.2.3.4")
  assert_contains_str "$link" "vless://" "链接前缀" || return 1
  assert_contains_str "$link" "@1.2.3.4:8443" "链接端口" || return 1
  assert_contains_str "$link" "pbk=NEWPUBKEY02" "链接公钥" || return 1
  assert_contains_str "$link" "flow=xtls-rprx-vision" "Vision流控" || return 1
  return 0
}
sc_keyparse_v262() {
  reset; stub_xray_v262
  gen_config >/dev/null 2>&1 || { echo "gen_config 不应失败" >&2; return 1; }
  assert_contains "$CONFIG_FILE" '"privateKey": "V26PRIVKEY01"' "v26.2.6格式私钥" || return 1
  assert_contains "$META_FILE" 'PUB=V26PUBKEY02' "v26.2.6格式公钥" || return 1
  return 0
}
sc_install_default_regen() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || return 1
  require_root() { return 0; }
  fetch_xray() { :; }
  create_user() { return 0; }
  systemctl() { [ "$1" = "is-active" ] && { echo "active"; return 0; }; return 0; }
  sysctl() { if [ "$1" = "-n" ]; then echo "bbr"; fi; return 0; }
  stub_ip
  cmd_install "" > "$SIM/log/inst2" 2>&1
  [ -f "$CONFIG_FILE.bak" ] || { echo "默认重生成应有配置备份" >&2; return 1; }
  grep -q '^UUID=' "$META_FILE" || { echo "meta 应有 UUID" >&2; return 1; }
  grep -q '"port": 443' "$CONFIG_FILE" || { echo "config 应有效" >&2; return 1; }
  return 0
}
sc_install_keep() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || return 1
  local old_uuid
  old_uuid=$(grep '^UUID=' "$META_FILE" | cut -d= -f2)
  require_root() { return 0; }
  fetch_xray() { :; }
  create_user() { return 0; }
  systemctl() { [ "$1" = "is-active" ] && { echo "active"; return 0; }; return 0; }
  sysctl() { if [ "$1" = "-n" ]; then echo "bbr"; fi; return 0; }
  stub_ip
  cmd_install "--keep" > "$SIM/log/inst3" 2>&1
  local new_uuid
  new_uuid=$(grep '^UUID=' "$META_FILE" | cut -d= -f2)
  [ "$old_uuid" = "$new_uuid" ] || { echo "--keep 应保留原 UUID" >&2; return 1; }
  [ -f "$CONFIG_FILE.bak" ] && { echo "--keep 不应生成备份" >&2; return 1; }
  return 0
}
sc_keyparse_old() {
  reset; stub_xray_old
  gen_config >/dev/null 2>&1 || { echo "gen_config 不应失败" >&2; return 1; }
  assert_contains "$CONFIG_FILE" '"privateKey": "OLDPRIVKEY01"' "旧格式私钥" || return 1
  assert_contains "$META_FILE" 'PUB=OLDPUBKEY02' "旧格式公钥" || return 1
  return 0
}
sc_keyparse_bad() {
  reset; stub_xray_bad
  ( gen_config ) > "$SIM/log/bad" 2>&1 || true
  assert_contains "$SIM/log/bad" "Something unexpected: XYZ" "失败信息带原始输出" || return 1
  [ -f "$CONFIG_FILE" ] && { echo "坏输出不应生成配置" >&2; return 1; }
  return 0
}
sc_port_invalid() {
  reset; stub_xray_new
  PORT=abc
  ( gen_config ) > "$SIM/log/badport" 2>&1 || true
  assert_contains "$SIM/log/badport" "端口无效" "非法端口应报错" || return 1
  return 0
}
sc_preserved_reinstall() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || { echo "gen_config 不应失败" >&2; return 1; }
  unset PORT
  stub_ufw_active
  open_firewall >/dev/null 2>&1 || { echo "open_firewall 不应失败 (PORT unbound 回归)" >&2; return 1; }
  assert_contains "$FW_FILE" "FIREWALL=ufw" "保留配置路径防火墙" || return 1
  assert_contains "$FW_FILE" "PORT=443" "从 meta 恢复端口" || return 1
  return 0
}
sc_fw_ufw_rollback() {
  reset; stub_xray_new; stub_ufw_active
  gen_config >/dev/null 2>&1 || return 1
  open_firewall >/dev/null 2>&1 || return 1
  assert_contains "$FW_FILE" "FIREWALL=ufw" "ufw 记录" || return 1
  assert_contains "$SIM/log/calls" "ufw allow 443/tcp" "ufw 放行" || return 1
  close_firewall >/dev/null 2>&1 || { echo "close_firewall 不应失败" >&2; return 1; }
  [ -f "$FW_FILE" ] && { echo "回滚后 FW_FILE 应删除" >&2; return 1; }
  assert_contains "$SIM/log/calls" "ufw delete allow 443/tcp" "ufw 回滚" || return 1
  return 0
}
sc_fw_firewalld() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || return 1
  firewall-cmd() { echo "fwcmd $*" >> "$SIM/log/calls"; }
  systemctl() { echo "systemctl $*" >> "$SIM/log/calls"; return 0; }
  open_firewall >/dev/null 2>&1 || return 1
  assert_contains "$FW_FILE" "FIREWALL=firewalld" "firewalld 记录" || return 1
  assert_contains "$SIM/log/calls" "add-port=443/tcp" "firewalld 放行" || return 1
  return 0
}
sc_fw_iptables_rollback() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || return 1
  iptables() { echo "iptables $*" >> "$SIM/log/calls"; case "$1" in -S) echo "-P INPUT DROP";; -C) return 1;; esac; return 0; }
  netfilter-persistent() { :; }
  iptables-save() { :; }
  open_firewall >/dev/null 2>&1 || return 1
  assert_contains "$FW_FILE" "FIREWALL=iptables" "iptables 记录" || return 1
  assert_contains "$SIM/log/calls" "-I INPUT -p tcp --dport 443 -j ACCEPT" "iptables 放行" || return 1
  close_firewall >/dev/null 2>&1 || return 1
  assert_contains "$SIM/log/calls" "-D INPUT -p tcp --dport 443 -j ACCEPT" "iptables 回滚" || return 1
  [ -f "$FW_FILE" ] && { echo "回滚后 FW_FILE 应删除" >&2; return 1; }
  return 0
}
sc_fw_none() {
  reset; stub_xray_new
  gen_config >/dev/null 2>&1 || return 1
  iptables() { case "$1" in -S) echo "-P INPUT ACCEPT";; esac; return 0; }
  open_firewall >/dev/null 2>&1 || return 1
  [ -f "$FW_FILE" ] && { echo "无限制时不应生成 FW_FILE" >&2; return 1; }
  return 0
}
sc_bbr_already() {
  reset
  sysctl() { if [ "$1" = "-n" ]; then case "$2" in net.ipv4.tcp_congestion_control) echo "bbr";; *) echo "?";; esac; fi; return 0; }
  enable_bbr > "$SIM/log/bbr" 2>&1
  assert_contains "$SIM/log/bbr" "BBR 已开启" "BBR 已启用识别" || return 1
  [ -f "$SIM/bbr.conf" ] && { echo "已启用时不应写配置文件" >&2; return 1; }
  return 0
}
sc_bbr_enable() {
  reset
  sysctl() { if [ "$1" = "-n" ]; then case "$2" in net.ipv4.tcp_congestion_control) if [ -f "$SIM/bbr.conf" ]; then echo "bbr"; else echo "cubic"; fi;; net.ipv4.tcp_available_congestion_control) echo "cubic reno bbr";; esac; fi; return 0; }
  modprobe() { return 0; }
  enable_bbr > "$SIM/log/bbr" 2>&1
  assert_contains "$SIM/log/bbr" "BBR 已启用" "BBR 启用" || return 1
  [ -f "$SIM/bbr.conf" ] || { echo "应写入 bbr 配置" >&2; return 1; }
  return 0
}
sc_bbr_unsupported() {
  reset
  sysctl() { if [ "$1" = "-n" ]; then case "$2" in net.ipv4.tcp_congestion_control) echo "cubic";; net.ipv4.tcp_available_congestion_control) echo "cubic reno";; esac; fi; return 0; }
  enable_bbr > "$SIM/log/bbr" 2>&1
  assert_contains "$SIM/log/bbr" "不支持" "内核不支持提示" || return 1
  [ -f "$SIM/bbr.conf" ] && { echo "不支持时不应写配置" >&2; return 1; }
  return 0
}
sc_summary() {
  reset; stub_xray_new; stub_ip
  gen_config >/dev/null 2>&1 || return 1
  systemctl() { echo "systemctl $*" >> "$SIM/log/calls"; if [ "$1" = "is-active" ]; then echo "active"; fi; return 0; }
  sysctl() { if [ "$1" = "-n" ]; then echo "bbr"; fi; return 0; }
  show_summary > "$SIM/log/summary" 2>&1
  assert_contains "$SIM/log/summary" "安装信息汇总" "汇总标题" || return 1
  assert_contains "$SIM/log/summary" "服务状态:   active" "服务状态" || return 1
  assert_contains "$SIM/log/summary" "Xray vTEST (smoke)" "版本行" || return 1
  assert_contains "$SIM/log/summary" "203.0.113.9" "公网IP" || return 1
  assert_contains "$SIM/log/summary" "vless://" "分享链接" || return 1
  assert_contains "$SIM/log/summary" "防火墙放行" "防火墙行" || return 1
  return 0
}
sc_link() {
  reset; stub_xray_new; stub_ip
  gen_config >/dev/null 2>&1 || return 1
  print_link > "$SIM/log/link" 2>&1
  assert_contains "$SIM/log/link" "vless://" "分享链接" || return 1
  assert_contains "$SIM/log/link" "@203.0.113.9:443" "链接公网IP端口" || return 1
  assert_contains "$SIM/log/link" "flow=xtls-rprx-vision" "Vision 流控" || return 1
  return 0
}
sc_uninstall() {
  reset; stub_xray_new; stub_ufw_active
  gen_config >/dev/null 2>&1 || return 1
  open_firewall >/dev/null 2>&1 || return 1
  require_root() { return 0; }
  systemctl() { echo "systemctl $*" >> "$SIM/log/calls"; return 0; }
  userdel() { echo "userdel $*" >> "$SIM/log/calls"; return 0; }
  cmd_uninstall > "$SIM/log/uninstall" 2>&1
  [ -d "$SIM/etc" ] && { echo "卸载后配置目录应被删除" >&2; return 1; }
  ls "$SIM/backup" | grep -q config.json || { echo "应备份配置到 backup" >&2; return 1; }
  assert_contains "$SIM/log/calls" "ufw delete allow 443/tcp" "卸载回滚防火墙" || return 1
  assert_contains "$SIM/log/calls" "userdel xray" "删除用户" || return 1
  return 0
}

# ---------- 运行器 ----------
run_sc() { # name fn
  local name="$1"
  local fn="$2"
  if ( "$fn" ) > "$SIM/out" 2>&1; then
    PASS=$((PASS+1))
    echo "  [PASS] $name"
  else
    FAIL=$((FAIL+1))
    echo "  [FAIL] $name"
    sed 's/^/         | /' "$SIM/out" | tail -n 8
  fi
}

echo "== xray-vless-reality 回归测试 =="
run_sc "全新安装默认值(新格式密钥)" sc_fresh_defaults
run_sc "环境变量覆盖(PORT/SNI/NAME/链接)" sc_env_overrides
run_sc "v26.2.6格式密钥解析(Password:无括号)" sc_keyparse_v262
run_sc "旧格式密钥解析回归" sc_keyparse_old
run_sc "异常密钥输出应报错并附原始输出" sc_keyparse_bad
run_sc "非法端口应有明确报错" sc_port_invalid
run_sc "install 默认重新生成配置(含备份)" sc_install_default_regen
run_sc "install --keep 保留原配置" sc_install_keep
run_sc "保留配置重装(端口从meta恢复)" sc_preserved_reinstall
run_sc "ufw 放行+卸载回滚" sc_fw_ufw_rollback
run_sc "firewalld 放行" sc_fw_firewalld
run_sc "iptables DROP 放行+回滚" sc_fw_iptables_rollback
run_sc "无防火墙限制不写记录" sc_fw_none
run_sc "BBR 已启用识别" sc_bbr_already
run_sc "BBR 支持并启用" sc_bbr_enable
run_sc "BBR 不支持自动跳过" sc_bbr_unsupported
run_sc "安装信息汇总完整性" sc_summary
run_sc "分享链接格式" sc_link
run_sc "卸载: 清理+防火墙回滚+备份" sc_uninstall
echo ""
echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "存在失败场景"; exit 1; }
echo "全部通过"