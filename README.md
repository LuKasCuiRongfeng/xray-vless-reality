# Xray VLESS + Reality 一键安装脚本

基于官方 [XTLS/Xray-core](https://github.com/XTLS/Xray) 二进制, 自动生成 VLESS + Reality + Vision 配置,
支持安装、打印分享链接、服务管理、升级、卸载。适用于 Linux (x86_64 / arm64 / armv7, 需要 systemd)。

## 一键安装

在 Linux 服务器 (Debian/Ubuntu/CentOS 等) 上执行, 把地址中的 USERNAME/REPO 换成你的 GitHub 仓库:

    curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/xray-vless-reality/master/install.sh -o install.sh
    sudo bash install.sh install

或一行管道方式 (建议先下载查看内容再执行):

    curl -fsSL https://raw.githubusercontent.com/LuKasCuiRongfeng/xray-vless-reality/master/install.sh | sudo bash install.sh install

安装完成后脚本会直接打印 vless:// 分享链接, 复制到 v2rayN / Shadowrocket / Clash Verge 等客户端导入即可。

> 注意: 需在防火墙 / 云安全组放行 TCP 端口 (默认 443)。客户端与服务端时间请保持同步 (建议开启 NTP),
> 否则 Reality 握手会失败。

## 常用命令

    sudo bash install.sh install             安装或修复 (已安装时保留现有配置)
    sudo bash install.sh install --force     强制重新生成配置 (新密钥 / 新UUID)
    sudo bash install.sh link                重新打印分享链接 (无需 root)
    sudo bash install.sh restart             重启服务
    sudo bash install.sh status              查看服务状态 (无需 root)
    sudo bash install.sh update              升级到最新官方 Xray
    sudo bash install.sh info                查看安装信息 (无需 root)
    sudo bash install.sh uninstall           卸载 (配置自动备份到 /root/xray-config-backup/)

## 自定义参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| PORT | 443 | 监听端口 (1-65535) |
| SNI | www.microsoft.com | 伪装域名 (证书 SNI) |
| DEST | www.microsoft.com:443 | Reality 目标地址 |
| UUID | 自动生成 | 用户 ID |
| NAME | xray-vless | 分享链接备注 |
| IP | 自动探测 | 手动指定公网 IP |
| XRAY_VERSION | 自动最新 | 固定 Xray 版本, 如 v2.26.0 |

示例: 换端口 + 换伪装域名

    sudo PORT=8443 SNI=www.apple.com DEST=www.apple.com:443 NAME=my-node bash install.sh install

## 安装内容

| 路径 | 说明 |
|------|------|
| /usr/local/bin/xray | 官方 Xray 二进制 |
| /usr/local/etc/xray/config.json | 服务配置 (含私钥, 仅本机可读) |
| /usr/local/etc/xray/meta.conf | UUID/公钥/SNI 等元数据, 用于打印链接 |
| /etc/systemd/system/xray.service | systemd 单元 (专用用户运行, 已加固) |
| 系统用户 xray | 无登录 shell 的专用用户 |

## 设计说明

- 版本通过 GitHub 官方 API 获取 XTLS/Xray-core 最新 release, 或用 XRAY_VERSION 固定版本。
- x25519 密钥对由 Xray 自带命令 xray x25519 生成, 私钥只保存在服务器本地。
- 脚本幂等: 重复执行 install 不会覆盖现有配置; 需要更换时用 --force。
- 分享链接只包含公钥 / UUID / SNI / shortId, 不包含私钥。

## 安全提示

- 建议更换默认 SNI / DEST 为自己常用的 HTTPS 站点, 伪装效果更好。
- 公网端口建议配合云安全组 / 防火墙限制来源 (可选)。
- 仅用于个人合法用途, 请遵守当地法律法规。

## 卸载

    sudo bash install.sh uninstall

会停止并禁用服务, 删除二进制 / 配置 / systemd 单元 / 系统用户, 配置自动备份到 /root/xray-config-backup/。
