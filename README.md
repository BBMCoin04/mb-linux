# mb-linux / vps-manager

`vps-manager 1.2.4` 是一个面向 Ubuntu VPS 的中文管理脚本，用菜单完成系统初始化、SSH、防火墙、BBR、Swap、Docker、DNS 和日常维护。

> 仅支持 Ubuntu。修改 SSH、防火墙或网络前，请保留当前 SSH 会话，并确保可以使用云厂商控制台救援。

## 安装

推荐先下载，再执行：

```bash
curl -fsSLo /tmp/vps-manager-install.sh "https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh?ts=$(date +%s)"
sudo bash /tmp/vps-manager-install.sh
```

从 ZIP 或 Git 仓库安装：

```bash
sudo bash install.sh
```

安装完成后，随时打开菜单：

```bash
sudo lm
```

也可以使用完整命令：

```bash
sudo vps-manager
```

## 主菜单

```text
  1. 基础初始化向导
  2. 系统升级、主机名、时区与重启
  3. SSH/root 登录设置
  4. Fail2ban 与自动安全更新
  5. 防火墙模式
  6. BBR 与网络优化
  7. Swap 管理
  8. Docker 管理
  9. DNS 配置
 10. AI/流媒体访问检测
 11. 系统状态与最近操作
 12. 保守系统清理
 13. 更新 vps-manager
  0. 退出
```

## 新 VPS 怎么用

第一次使用直接选择菜单 `1`，脚本会逐项询问：

1. 设置主机名和时区。
2. 升级 Ubuntu 并安装常用工具。
3. 创建 Swap、启用 BBR。
4. 配置 Fail2ban 和自动安全更新。
5. 安装 Docker。
6. 选择防火墙模式并配置 DNS。

每一步都可以跳过。脚本不会静默重启 VPS。

## 重要提醒

- 修改 SSH 端口前，先在云厂商安全组中放行新端口。
- 修改 SSH 时保持当前连接，并用新窗口测试成功后再关闭旧连接。
- 没有配置并测试 SSH 公钥前，不要关闭密码登录。
- UFW 不能代替云厂商安全组；两边都要正确放行端口。
- 加入 `docker` 用户组等同于获得 root 级权限，不要随意添加用户。
- AI/流媒体检测只代表网络可达性，不代表账号、订阅或具体内容一定可用。

## 防火墙模式

菜单 `5` 只保留两种模式：

- **宽松模式**：关闭 UFW，主机不再过滤入站端口；云安全组仍可能限制访问。
- **收紧模式**：备份并重建 UFW，只允许当前 SSH 端口及 `80/443/8443/2087` 服务端口，拒绝其他入站和转发。

收紧模式会最先放行当前 SSH 端口，应用前还会显示完整端口清单并要求确认。Docker 映射到公网的端口可能绕过 UFW，不需要的容器端口不要发布。

## AI 与流媒体检测

选择菜单 `10` 后直接检测 OpenAI、Gemini、Claude、Netflix、Disney+ 和 YouTube，只显示“可以访问 / 不可访问 / 检测失败”。

## 保守系统清理

选择菜单 `12`，或运行：

```bash
sudo lm cleanup-system
```

确认后只会清理：

- APT 下载缓存。
- 系统策略认定的过期临时文件。
- 14 天以前的 systemd journal 归档。
- 超过 5 MiB 的 vps-manager 日志旧记录。

不会执行 `autoremove`、Docker prune，不会删除证书、密钥、用户文件或防火墙规则。

## 更新与修复

选择菜单 `13`，或运行：

```bash
sudo lm update
```

更新会检查脚本标识、Bash 语法和版本，拒绝降级；失败时尝试恢复原版本。更新成功后会自动打开新版菜单。

从 `1.2.0` 升级时，请重新执行一次安装命令；`1.2.0` 的菜单更新存在系统版本误判。升级后即可继续使用菜单 `13`。菜单更新会先保留结果，按 Enter 后再重新载入新版。需要修复 `lm` 命令时也可重新运行安装器。

## 常用命令

```bash
sudo lm                 # 打开菜单
sudo lm init            # 基础初始化向导
sudo lm status          # 查看系统状态
sudo lm ports           # 选择防火墙模式
sudo lm swap            # Swap 管理
sudo lm security        # Fail2ban 与自动安全更新
sudo lm docker          # Docker 管理
sudo lm cleanup-system  # 保守系统清理
sudo lm update          # 更新管理器
lm version              # 查看版本
lm help                 # 查看帮助
```

安装位置：

```text
/usr/local/sbin/vps-manager
/usr/local/sbin/lm -> /usr/local/sbin/vps-manager
```

日志和备份位置：

```text
/var/log/vps-manager/vps-manager.log
/var/backups/vps-manager/
```

配置备份统一放在专用目录，不会留在 APT、SSH 或 DNS 配置目录中。
