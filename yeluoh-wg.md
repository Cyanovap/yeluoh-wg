# yeluoh-wg

脚本运行在 Ubuntu/Debian VPS 上，不在 Windows 上运行。它启动后显示 WireGuard 服务、接口、监听端口、出口网卡、IPv4 转发、已登记客户端以及 `wg show` 的实时握手和流量；未安装或未配置时会询问是否安装/初始化。

## 使用

将 `yeluoh-wg.sh` 上传到 VPS，然后执行：

```bash
chmod 700 yeluoh-wg.sh
sudo bash yeluoh-wg.sh
```

## 从 GitHub 部署到 VPS

仓库公开后，可直接在 Ubuntu/Debian VPS 上克隆并运行：

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/Cyanovap/yeluoh-wg.git ~/yeluoh-wg
sudo bash ~/yeluoh-wg/yeluoh-wg.sh
```

再次运行管理菜单：

```bash
sudo bash ~/yeluoh-wg/yeluoh-wg.sh
```

以后拉取脚本更新并重新运行：

```bash
git -C ~/yeluoh-wg pull --ff-only
sudo bash ~/yeluoh-wg/yeluoh-wg.sh
```

菜单提供刷新状态、安装/初始化、添加客户端、删除客户端、查看日志、更换 UDP 端口和退出。状态页会显示运行中的监听端口。安装/初始化适用于 Ubuntu/Debian，默认配置为指南中的 `wg0`、UDP `51820`、`10.8.0.0/24`；会启用 IPv4 转发和 NAT，并启用 `wg-quick@wg0`。已有 `/etc/wireguard/wg0.conf` 时不会覆盖。

## 更换 WireGuard UDP 端口

在菜单中选择“更换 WireGuard UDP 端口”，输入新端口。脚本使用官方 `wg set <接口> listen-port <端口>` 方式即时修改运行中的接口，并备份、更新 `/etc/wireguard/wg0.conf` 以便重启后保留；新建客户端模板也会使用新端口。更换后需在 AWS 安全组/云防火墙中允许新的 UDP 端口，并手动更新已经导入 Windows WireGuard 的隧道配置中的 `Endpoint = <公网IP>:<新端口>`，否则客户端无法连接。此操作不会自动修改云安全组。

## 添加 Windows 客户端

1. 在 Windows WireGuard 应用中选择 **Add Tunnel → Add empty tunnel**。
2. 复制应用生成的 **Public key**，在 VPS 菜单选择“添加 Windows 客户端”并粘贴。
3. VPS 将客户端 Peer 加入运行配置，并在 `/etc/wireguard/clients/<名称>.conf` 生成客户端配置模板。
4. 通过 SSH/SFTP 安全复制配置模板到 Windows；在本机把 `PrivateKey` 占位符替换为 WireGuard 应用生成的私钥，然后将配置导入应用。不要把客户端私钥发回 VPS。
5. AWS EC2 用户需在关联安全组添加当前服务器使用的 UDP 入站端口（默认 `51820`），来源最好限制为客户端固定公网 IP `/32`。云厂商防火墙也要允许该端口。

模板包含 `AllowedIPs = 0.0.0.0/0`，与指南一致，会将 Windows IPv4 默认流量经 VPS 转发；IPv6 不在此隧道范围内。

## 删除客户端

在菜单选择“删除客户端”，按名称和地址确认。脚本会备份服务器配置、从运行中的 WireGuard 删除 Peer，并删除 VPS 上该客户端的配置模板。还需在 Windows WireGuard 应用中删除对应隧道。

## 安全与适用范围

- 需要以 root/sudo 执行；仅支持 Ubuntu/Debian 与 `wg0`。
- 安装配置不会覆盖现有 `wg0.conf`，也不会改写 AWS 安全组或清空防火墙规则。
- 客户端私钥在 Windows WireGuard 应用生成，脚本只登记客户端公钥。服务器私钥保存在 `/etc/wireguard/server_private.key`，配置和密钥目录权限受限。
- 客户端配置模板含服务端公钥与地址信息，不含客户端私钥；通过 SSH/SFTP 传输仍建议只给自己的设备。

## 官方参考

- [WireGuard Quick Start](https://www.wireguard.com/quickstart/)：密钥生成、`wg show` 与接口配置。
- [Ubuntu Server WireGuard VPN](https://ubuntu.com/server/docs/how-to/wireguard-vpn/)：安装、Peer 配置及转发/NAT。
- [AWS EC2 安全组规则](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/creating-security-group.html)：入站规则配置。
