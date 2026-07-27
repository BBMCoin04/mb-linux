# mb-linux / vps-manager

`vps-manager 1.1.0` 是面向 Ubuntu VPS 的交互式初始化与日常维护工具，适合新机器开通后统一处理：

- 完整系统升级与重启提示
- 主机名、时区和常用依赖
- SSH/root 登录设置
- UFW 与端口
- BBR
- Swap
- Fail2ban
- unattended-upgrades 自动安全更新
- Docker 官方 Ubuntu 仓库安装
- DNS
- AI/流媒体网络检测

所有关键修改都显示影响并请求确认。脚本不会自动关闭 SSH、防火墙或删除 Docker 数据。

## 安装

推荐先下载再执行：

```bash
curl -fsSLo /tmp/vps-manager-install.sh https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh
sudo bash /tmp/vps-manager-install.sh
```

快速方式：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh | sudo bash
```

从完整 ZIP 或仓库运行 `sudo bash install.sh` 时，安装器优先使用同目录中的 `vps-manager.sh`；只有单独下载 `install.sh` 时才从 HTTPS 获取主程序。

安装路径：

```text
/usr/local/sbin/vps-manager
/usr/local/sbin/lm -> /usr/local/sbin/vps-manager
```

重新打开菜单：

```bash
sudo lm
# 或
sudo vps-manager
```

## 主菜单

```text
1.  基础初始化向导
2.  系统升级、主机名、时区与重启
3.  SSH/root 登录设置
4.  Fail2ban 与自动安全更新
5.  防火墙与端口
6.  BBR 与网络优化
7.  Swap 管理
8.  Docker 管理
9.  DNS 配置
10. AI/流媒体解锁检测
11. 系统状态与最近日志
12. 高级维护
0.  退出
```

## 新 VPS 推荐顺序

运行：

```bash
sudo vps-manager init
```

向导逐项询问以下操作，任何一项都可以跳过：

1. 设置主机名。
2. `apt-get full-upgrade` 完整系统升级。
3. 设置 `Asia/Shanghai` 时区。
4. 安装常用依赖。
5. 创建 Swap。
6. 启用 BBR。
7. 安装 Fail2ban SSH jail。
8. 启用自动安全更新。
9. 安装 Docker 官方版本。
10. 配置 UFW 和端口。
11. 配置 DNS。

系统升级后仅在 `/var/run/reboot-required` 存在时提示重启。BBR 通常即时生效，脚本会说明无需重启，但仍提供可选重启确认。

## 主机名与系统升级

主机名只接受最长 63 位的小写字母、数字和连字符。修改使用 `hostnamectl`，并同步 `/etc/hosts` 的 `127.0.1.1` 条目；修改前备份 hosts 文件。

系统升级使用：

```bash
apt-get update
apt-get full-upgrade -y
```

完整升级可能安装新内核。脚本不会静默重启；立即重启始终需要确认。

## SSH 安全

SSH 设置写入独立文件：

```text
/etc/ssh/sshd_config.d/00-vps-manager.conf
```

支持：

- 查看最终生效配置。
- 开启/关闭 root 登录。
- 开启/关闭密码登录。
- 修改 SSH 端口。

每次修改都会：

1. 备份旧的脚本管理文件。
2. 执行 `sshd -t` 语法测试。
3. 读取 `sshd -T` 确认最终生效值。
4. 成功后 reload SSH。
5. 失败时恢复旧配置。

关闭密码登录前必须检测到至少一个非空 `authorized_keys`。修改 SSH 端口时，如果 UFW 已启用，会先放行新端口；旧端口不会自动删除，便于新会话验证后回退。云厂商安全组仍需手动放行。

## UFW 与默认端口

新 VPS 默认端口列表：

```text
22/tcp
80/tcp
443/tcp
443/udp
8443/tcp
8443/udp
2087/tcp
```

`2096/TCP` 是 Cloudflare Argo 边缘端口，不需要在 VPS 入站开放。

启用 UFW 前，脚本会从 `sshd -T` 读取当前 SSH 端口并先放行。UFW 不能替代云厂商安全组；Docker 发布端口也不会由本脚本自动开放。

## BBR

启用 BBR 写入：

```text
/etc/sysctl.d/99-vps-manager-bbr.conf
```

仅在当前内核提供 BBR 时写入，并立即执行 `sysctl --system`。菜单可删除脚本自己的 BBR 文件，不修改其他 sysctl 配置。

## Swap

默认管理：

```text
/swapfile
/etc/sysctl.d/99-vps-manager-swap.conf
```

创建时：

- 支持 1-64 GiB整数。
- 检查磁盘空间并至少保留 512 MiB。
- 优先使用 `fallocate`，失败时回退 `dd`。
- 设置权限 `0600`。
- 写入 `/etc/fstab`。
- 默认设置 `vm.swappiness=10`。

删除时只处理脚本配置的 Swap 文件和对应 fstab 条目，不删除其他 Swap。若内存不足导致 `swapoff` 失败，会停止删除。

## Fail2ban

管理文件：

```text
/etc/fail2ban/jail.d/vps-manager-sshd.local
```

默认 SSH 策略：

```text
5 次失败 / 10 分钟
封禁 1 小时
backend = systemd
```

Fail2ban 自动读取当前 SSH 端口；通过脚本修改 SSH 端口后 jail 会同步更新。关闭功能只删除此 jail，不卸载 Fail2ban，也不删除其他 jail。

Fail2ban 只能降低在线暴力破解风险，不能替代强密码、公钥登录、云安全组和及时更新。

## 自动安全更新

安装 Ubuntu 官方 `unattended-upgrades`，使用包自带的安全更新来源。管理文件：

```text
/etc/apt/apt.conf.d/20auto-upgrades
/etc/apt/apt.conf.d/52vps-manager-unattended-upgrades
```

默认行为：

- 每日更新软件包列表。
- 每日执行 unattended-upgrades。
- 清理无用内核和新依赖。
- **不自动重启**。

关闭时不卸载软件包，只关闭周期配置并删除脚本附加选项。

## Docker

Docker 安装严格使用官方 Ubuntu apt 流程：

```text
/etc/apt/keyrings/docker.asc
/etc/apt/sources.list.d/docker.sources
```

安装包：

```text
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

脚本检测官方支持架构和已知 Ubuntu 代号。若检测到 `docker.io`、`containerd`、`runc` 等冲突包，会显示列表并单独请求确认后才移除；不会删除 `/var/lib/docker`。

菜单还支持：

- 查看 Engine、Compose、Buildx 和 systemd 状态。
- 将现有用户加入 `docker` 组。
- 运行 `hello-world` 测试。

`docker` 组权限实际等同 root，因此不会自动添加用户。

## DNS 与检测

DNS 优先通过 `systemd-resolved` 配置，无法使用时才回退 `/etc/resolv.conf`。内置 Cloudflare、Google、Quad9 和自定义方案，修改前创建备份。

AI 基础检测只检查 DNS、IPv4/IPv6 公网地址和 HTTP 可达性，不代表账号或地区一定可用。

第三方流媒体脚本仅在用户确认后下载到临时文件执行：

- RegionRestrictionCheck
- MediaUnlockTest

## CLI

```bash
sudo vps-manager
sudo lm
sudo vps-manager init
sudo vps-manager system
sudo vps-manager status
sudo vps-manager ports
sudo vps-manager swap
sudo vps-manager security
sudo vps-manager docker
sudo vps-manager hostname my-vps-01
sudo vps-manager check-ai
sudo vps-manager check-media
sudo vps-manager update
sudo vps-manager install
vps-manager version
vps-manager help
```

日志：

```text
/var/log/vps-manager/vps-manager.log
```

## 更新与回归

管理器更新会下载并检查安装器和主程序标识、Bash 语法及版本。远程版本低于当前版本时自动恢复，拒绝意外降级。

开发行为测试：

```bash
./tests/behavior.sh
```

测试覆盖端口解析、默认端口数量、子菜单返回、帮助和版本。实际系统修改应继续在新 Ubuntu VPS 上验证，因为沙箱不能模拟 systemd、UFW、sshd、Swap 和 Docker daemon 的完整行为。

## 支持范围

修改类操作仅支持 Ubuntu。Docker 官方流程按当前文档支持 Ubuntu 22.04、24.04、25.10、26.04 及官方列出的架构。

修改 SSH、防火墙或网络前，建议始终保留云厂商控制台和一个现有 SSH 会话用于回退。
