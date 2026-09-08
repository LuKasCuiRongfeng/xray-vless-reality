# Xray VLESS + Reality 一键安装脚本

基于官方 [XTLS/Xray-core](https://github.com/XTLS/Xray) 二进制, 自动生成 VLESS + Reality + Vision 配置,
支持安装、打印分享链接、服务管理、升级、卸载。适用于 Linux (x86_64 / arm64 / armv7, 需要 systemd)。

## 一键安装

在 Linux 服务器 (Debian/Ubuntu/CentOS 等) 上执行, 把地址中的 USERNAME/REPO 换成你的 GitHub 仓库:

    curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/xray-vless-reality/master/install.sh -o install.sh
    sudo bash install.sh install

一条命令 (推荐, 下载后执行, 脚本会留在服务器上便于后续管理):

    curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/xray-vless-reality/master/install.sh -o install.sh && sudo bash install.sh install

管道方式 (不落盘, 仅供一次性安装; 执行完后服务器上没有 install.sh, 后续 link/restart 需重新下载):

    curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/xray-vless-reality/master/install.sh | sudo bash -s install

安装完成后脚本会打印完整信息汇总与**两条分享链接**: [稳定] vless:// (VLESS+Reality, 日常使用) + [速度] hysteria2:// (Hysteria2, 大流量/测速使用), 复制到 v2rayN / Shadowrocket 等客户端导入即可。Hysteria2 节点在 v2rayN 中请切换为 hysteria2 / sing-box 核心。

> 注意: 需在防火墙 / 云安全组放行 TCP 端口 (默认 443)。客户端与服务端时间请保持同步 (建议开启 NTP),
> 否则 Reality 握手会失败。

## 常用命令

    sudo bash install.sh install             双线安装: VLESS+Reality(稳定) + Hysteria2(速度), 两条链接自由选择
    sudo bash install.sh install --keep      保留现有配置, 仅修复 / 重装服务
    sudo bash install.sh link                重新打印分享链接 (无需 root)
    sudo bash install.sh restart             重启服务
    sudo bash install.sh status              查看服务状态 (无需 root)
    sudo bash install.sh update              升级到最新官方 Xray
    sudo bash install.sh info                查看安装信息 (无需 root)
    sudo bash install.sh uninstall           卸载 (配置自动备份到 /root/xray-config-backup/)
    sudo bash install.sh bbr [on|off]       查看 BBR 状态 / 启用 / 关闭 (安装时默认自动启用)

## 自定义参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| PORT | 443 | 监听端口 (1-65535) |
| SNI | www.cloudflare.com | 伪装域名 (证书 SNI, Reality 标准目标, 默认不用 microsoft——实测握手会被拒) |
| DEST | www.cloudflare.com:443 | Reality 目标地址 |
| UUID | 自动生成 | 用户 ID |
| NAME | xray-vless | 分享链接备注 |
| IP | 自动探测 | 手动指定公网 IP |
| XRAY_VERSION | 自动最新 | 固定 Xray 版本, 如 v2.26.0 |
| GEO_DATA | 0 | 是否安装 geoip/geosite 路由数据 (1 为安装, 约 29MB, 本脚本默认不需要) |
| ENABLE_BBR | 1 | 安装时是否自动启用 BBR 加速 (内核不支持时自动跳过, 不换内核) |
| HY2_PORT | 8443 | Hysteria2 速度线端口 (**UDP**) |
| HY2_SNI | www.bing.com | Hysteria2 伪装域名 (自签证书 SAN 自动写入) |
| HY2_PASS | 自动生成 | Hysteria2 密码 |
| HY2_UP / HY2_DOWN | 留空 | 同时设置启用 Brutal 锁带宽 (Mbps); 默认 BBR 自适应 |
| HY2_VERSION | 自动最新 | 固定 Hysteria 版本 (如 app/v2.12.2) |

示例: 换端口 + 换伪装域名

    sudo PORT=8443 SNI=www.apple.com DEST=www.apple.com:443 NAME=my-node bash install.sh install

## 安装内容

| 路径 | 说明 |
|------|------|
| /usr/local/bin/xray | 官方 Xray 二进制 |
| /usr/local/etc/xray/config.json | 服务配置 (含私钥, 仅本机可读) |
| /usr/local/etc/xray/meta.conf | UUID/公钥/SNI 等元数据, 用于打印链接 |
| /etc/systemd/system/xray.service | systemd 单元 (专用用户运行, 已加固) |
| /usr/local/etc/xray/firewall.conf | 记录脚本自动放行的防火墙规则 (用于卸载时精确回滚) |
| /usr/local/etc/hysteria/ | Hysteria2 速度线配置 (config.yaml / 自签证书 / meta.conf) |
| /usr/local/bin/hysteria | 官方 Hysteria2 二进制 |
| /etc/systemd/system/hysteria.service | Hysteria2 systemd 单元 (UDP) |
| geoip.dat / geosite.dat | 仅 GEO_DATA=1 时安装 (约 29MB, 默认不装) |
| 系统用户 xray | 无登录 shell 的专用用户 |

## 设计说明

- 版本通过 GitHub 官方 API 获取 XTLS/Xray-core 最新 release, 或用 XRAY_VERSION 固定版本。
- x25519 密钥对由 Xray 自带命令 xray x25519 生成, 私钥只保存在服务器本地。
- 脚本幂等: 重复执行 install 不会覆盖现有配置; 需要更换时用 --force。
- 分享链接只包含公钥 / UUID / SNI / shortId, 不包含私钥。
- 默认最小安装: 只装官方 xray 二进制 (~35MB), 不装 geoip/geosite 路由数据 (本配置用不到)。
- 脚本不安装任何系统软件包 (curl / unzip 仅检查是否存在), 不换内核、不改防火墙、不开面板端口。
- BBR: 内核支持时自动启用 2 个 sysctl 参数 (使用系统自带模块, 零软件/零磁盘, 即时生效无需重启); 内核低于 4.9 时自动跳过, 绝不自动升级内核。
- 系统防火墙: 自动检测 ufw / firewalld / iptables, 只**精准放行**自己的 TCP 端口 (不清空用户已有规则), 卸载时仅回滚自己添加的规则。云厂商安全组 (如 Vultr Firewall) 在 VPS 之外, 脚本无法操作, 需在云控制台手动放行。
- 双线架构: 同时安装 **VLESS+Reality(稳定线, TCP 443)** 与 **Hysteria2(速度线, UDP 8443)**, 两条链接由用户自由选择。Hysteria2 使用自签证书 + **pinSHA256 证书指纹** (应对新版 v2rayN 下线 allowInsecure 的证书强校验), 无域名即可用。

## 回归测试

    bash test/smoke.sh

无需 root, 可在 Linux / Git Bash 运行。覆盖: 密钥解析(新旧格式)、默认值与环境变量覆盖、非法端口、保留配置重装、防火墙三体系放行与卸载回滚、BBR 三态、链接与汇总输出、卸载全流程。

## 安全提示

- 建议更换默认 SNI / DEST 为自己常用的 HTTPS 站点, 伪装效果更好。
- 公网端口建议配合云安全组 / 防火墙限制来源 (可选)。
- 仅用于个人合法用途, 请遵守当地法律法规。

## 卸载

    sudo bash install.sh uninstall

会停止并禁用 xray 与 hysteria 两个服务, 删除两者的二进制 / 配置 / systemd 单元 / 系统用户, 配置自动备份到 /root/xray-config-backup/。
BBR 为系统级优化, 卸载时保留; 如需移除请执行 sudo bash install.sh bbr off。
脚本自动添加的防火墙规则会随卸载精确回滚 (只删除自己加的, 不动其他规则); 云厂商安全组放行需在云控制台手动移除。
