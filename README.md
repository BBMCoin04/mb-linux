# mb-linux / vps-manager

`vps-manager 1.4.1` 是面向个人 Ubuntu VPS 的中文交互式基础环境管理脚本，提供系统升级、SSH、UFW、Fail2ban、自动安全更新、BBR、Swap、Docker、DNS、状态检查和保守清理。

## 支持范围

目标支持：

- Ubuntu 22.04 LTS（jammy）
- Ubuntu 24.04 LTS（noble）
- Ubuntu 26.04 LTS（resolute）

同时识别 Ubuntu 25.10（questing）。其他 Ubuntu 版本按通用流程运行并显示未专项验证提示；不支持 Debian 或其他发行版。

> 修改 SSH、防火墙或 DNS 前，请保持当前 SSH 会话，并确保可以使用云厂商控制台救援。

## 安装

推荐先下载并查看安装器，再执行：

```bash
curl -fsSLo /tmp/vps-manager-install.sh \
  "https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh?ts=$(date +%s)"
sudo bash /tmp/vps-manager-install.sh
```

从 ZIP 或 Git 仓库安装时，安装器会优先使用同目录的 `vps-manager.sh`：

```bash
sudo bash install.sh
```

安装位置：

```text
/usr/local/sbin/vps-manager
/usr/local/sbin/lm -> /usr/local/sbin/vps-manager
```

## 常用命令

```bash
sudo lm                 # 打开菜单
sudo lm init            # 基础初始化向导
sudo lm status          # 系统与服务状态
sudo lm ports           # UFW 模式与端口
sudo lm swap            # Swap 管理
sudo lm security        # Fail2ban 与自动安全更新
sudo lm docker          # Docker 管理
sudo lm cleanup-system  # 保守系统清理
sudo lm update          # 更新管理器
lm version              # 查看版本
```

初始化向导中的每一步都可跳过，脚本不会静默重启 VPS。

## 关键行为

### SSH

- 新增 SSH 端口时会显式保留当前全部 SSH 端口。
- UFW 已启用时先放行新端口，再修改 SSH。
- 配置需通过 `sshd -t`、有效值检查、服务重载和实际监听检查。
- Ubuntu 24.04/26.04 的 `ssh.socket` 会执行 `daemon-reload` 并重启 socket。
- 脚本不会自动删除旧 SSH 端口。请先用新窗口验证，再手动清理不再需要的端口和云安全组规则。
- 关闭 root 登录前，必须检测到具有 `sudo` 权限和 `authorized_keys` 的普通用户。

### UFW

- 宽松模式关闭 UFW 并保留现有规则。
- 收紧模式备份并重建 UFW，优先放行检测到的全部 SSH 端口；无法可靠识别 SSH 端口时拒绝执行。
- 云厂商安全组需要单独配置。
- Docker 发布到公网的容器端口可能绕过 UFW；脚本只提示，不接管 `DOCKER-USER` 链。

服务端口清单：

```text
/etc/vps-manager/ports.conf
```

### Swap

- 默认创建 `/swapfile`，并记录管理状态。
- 只有带有匹配管理状态的 Swap 才允许从菜单删除。
- 升级前已经存在的 Swap 不会被自动接管；可在创建 Swap 菜单中明确确认接管。

### DNS

- systemd-resolved 正在实际管理 DNS 时修改 `resolved.conf`；否则安全替换 `/etc/resolv.conf`，不会写穿原符号链接。
- 修改后必须通过真实域名解析测试，否则恢复原配置。
- 脚本不修改 cloud-init 或 netplan。它们仍可能在重启后覆盖下层 DNS，脚本会提示复查。

### Docker

- 使用 Docker 官方 Ubuntu 仓库，支持 `jammy`、`noble`、`questing` 和 `resolute`。
- 如果系统已有唯一且有效的 `docker.list` 或 `docker.sources`，会原样复用，不创建重复源；检测到多个官方源时拒绝继续并提示检查。
- 没有现有官方源时，先创建并验证新源；随后预下载 Docker CE 安装包，再请求移除冲突包。
- 不会自动删除 `/var/lib/docker`。
- `docker` 组权限等同 root，添加用户前会再次确认。

### 自动安全更新

- 使用 Ubuntu `unattended-upgrades`，自动重启保持关闭。
- 写入后验证 APT 生效值和 systemd timer；验证失败恢复原配置并报告失败。

## 更新行为

`sudo lm update` 只替换管理器程序并执行版本自检，不会自动运行初始化向导，也不会迁移或重写现有 SSH、UFW、DNS、Swap、Docker 或 Fail2ban 配置。修复后的行为在下次主动选择对应菜单操作时生效。

更新通过 HTTPS 从配置的 GitHub 仓库和引用下载，并以 root 安装。脚本标识、Bash 语法和版本检查用于防止错误文件及降级，不等同于发布者签名验证。

## 清理与备份

保守清理只执行：

- 清理 APT 下载缓存。
- 按 systemd-tmpfiles 策略清理过期临时文件。
- 清理 14 天以前的 systemd journal 归档。
- 日志超过 5 MiB 时保留最近 2000 行。

不会执行 `autoremove`、Docker prune，也不会删除证书、密钥、用户文件或防火墙规则。

```text
日志：/var/log/vps-manager/vps-manager.log
备份：/var/backups/vps-manager/
配置：/etc/vps-manager/
```

## 功能边界

脚本不提供 Debian 兼容、非交互批处理、SSH 定时回滚、旧 SSH 端口自动清理、cloud-init/netplan 接管、Docker 防火墙链集成、应用服务降权，以及 Reality、ACME、Sing-box 等上层代理或证书功能。
