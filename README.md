# MB-Linux / vps-manager 1.5.0

中文 Ubuntu VPS 管理工具。保留原项目的系统升级、SSH、UFW、BBR、Swap、Docker、DNS、访问检测和清理功能，并完善网络修改恢复、Fail2ban 管理和安装更新流程。

新用户先读 [先看这里.md](先看这里.md)。详细变更见 [CHANGELOG.md](CHANGELOG.md)，测试边界见 [测试报告](docs/TEST-REPORT.md)。

## 本地源码安装

将完整源码目录传到 Ubuntu VPS，进入目录执行：

```bash
sudo bash install.sh
```

以后打开菜单：

```bash
sudo lm
```

安装器使用同目录中可信且版本一致的三份脚本，不需要从 GitHub 下载程序。菜单中安装依赖、安装 Docker 或更新软件包时仍需要网络。

三个脚本的版本必须一致：

| 文件 | 用途 |
| --- | --- |
| `install.sh` | 安装 / 升级入口，失败时尝试成套回退 |
| `vps-manager.sh` | 主程序与中文菜单 |
| `network-rollback.sh` | 独立执行网络配置恢复 |

默认安装位置：

- 主程序：`/usr/local/sbin/vps-manager`
- 快捷命令：`/usr/local/sbin/lm`
- 恢复程序：`/usr/local/sbin/vps-manager.rollback`

本地源码目录及脚本不能被其他用户或用户组写入；所有者须为 root 或运行 sudo 的用户。公共临时目录中的同名脚本不会被自动信任。需要时，在确认这些文件确实属于你后运行：

```bash
chmod go-w . install.sh vps-manager.sh network-rollback.sh
sudo bash install.sh
```

安装器不会覆盖被其他程序占用的 `lm` 命令，也不会用旧版本覆盖新版。

## 已有 1.4.x 用户

把完整的 1.5.0 源码目录上传到服务器，运行 `sudo bash install.sh` 即可。旧版的服务端口清单和系统配置会保留。

1.5.0 增加了配套恢复程序；不能仅覆盖 `vps-manager.sh`。如果缺少配套程序或版本不一致，SSH 修改和防火墙收紧会停止。

安装后可核对：

```bash
sudo lm version
```

预期输出：`vps-manager 1.5.0`。

## 功能入口

| 命令 | 功能 |
| --- | --- |
| `sudo lm` | 完整中文菜单 |
| `sudo lm status` | 系统状态 |
| `sudo lm system` | 系统升级、主机名、时区、重启 |
| `sudo lm security` | Fail2ban 与自动安全更新 |
| `sudo lm ports` | UFW 模式与服务端口 |
| `sudo lm swap` | Swap 管理 |
| `sudo lm docker` | Docker 管理 |
| `sudo lm confirm-network` | 从新 SSH 连接确认保留待确认的网络修改 |
| `sudo lm update` | 更新管理器自身 |
| `lm help` | 命令说明 |

SSH、BBR、DNS 和访问检测入口在主菜单中。

## SSH 与网络恢复

SSH 端口识别同时参考：OpenSSH 有效配置、实际监听进程、`ssh.socket` 配置和当前 SSH 连接端口。其他服务恰好占用同一个端口，不会被视为 SSH 已监听。

新增 SSH 端口时保留旧端口。程序会验证有效配置、实际监听，并同步已经运行的 SSH Fail2ban 防护；任何一步不通过，就尝试恢复。

SSH 设置修改与 UFW 收紧在写入前建立恢复快照，并用 systemd 安排独立的超时任务。默认窗口为 180 秒；未确认时开始恢复，恢复完成还需要服务重新载入的时间。

验证成功后，在原窗口输入 `y`，或在新连接运行：

```bash
sudo lm confirm-network
```

`ssh.socket` 模式需要重启 SSH 主进程以接收新监听套接字。程序会检查 `ssh.service` 的 `KillMode=process`；如为其他模式，停止自动修改，避免重启时一起终止现有会话。

定时任务是 systemd 临时任务，不跨服务器重启。云安全组、外部网络故障、断电或磁盘故障不在其恢复范围内。恢复失败会明确报告并保留快照，后续网络修改会阻止继续叠加。详见 [恢复说明](docs/RECOVERY.md)。

## UFW 端口策略

新安装的业务端口清单默认为空；收紧模式仅优先保留已识别的 SSH 端口。

网站、代理或其他服务所需端口，先在菜单中逐个添加，例如 `80/tcp`、`443/tcp`。已有 `/etc/vps-manager/ports.conf` 的服务器继续使用原清单。

收紧操作会明确展示放行清单，并确认后重建 UFW。其恢复快照包含 `/etc/ufw`、`/etc/default/ufw`、业务端口清单和之前的启停状态；之前已运行 Fail2ban 时会重新加载封禁动作。

Docker 发布端口可能绕过 UFW。此工具不接管 Docker 的网络链，云厂商安全组也需单独配置。

## Fail2ban

Fail2ban 为可选功能。默认保护 SSH：600 秒内失败 5 次，封禁 3600 秒。适合公网 SSH，尤其使用密码认证的服务器。

安全菜单提供：启用、明确停用 SSH jail、调整规则、可信 IP / 网段管理、单个 IP 解封和运行状态。

- 启用时核对配置合并结果、运行中的次数/时长和封禁动作 TCP 端口。
- 同步 SSH 端口时保留已经设置的失败次数与封禁时长。
- 停用时写入 `enabled = false`，同时核对合并配置和运行状态。后加载的 `.local` 若覆盖它，会报告失败并尝试恢复。
- 本工具仅直接修改 `/etc/fail2ban/jail.d/vps-manager-sshd.local`；首次启用或停用 jail 会重新载入 Fail2ban 配置，不删除其他 jail 文件。
- 白名单支持 IPv4、IPv6 和 CIDR，拒绝整个互联网的 `/0`。优先继承已有白名单，再添加本工具的地址；原先完全没有 `ignoreip` 设置时，使用独立列表。之后若人工新增全局白名单，再用菜单更新一次即可重新尝试继承。
- 移除白名单只移除本工具添加的地址，不删除其他配置提供的可信地址。
- 不支持自动核验的自定义封禁动作会使操作失败，而不会被报告为已验证成功。可以保留自定义配置并手工维护。

运行参数检查不等于从外部主机验证实际封禁报文；Fail2ban 也不能替代密钥认证、系统更新或抗 DDoS 服务。

## DNS、软件更新及其他功能

DNS 修改前会直接查询指定 DNS 服务器，避免旧系统缓存造成误判；修改后继续检查系统解析。DHCP / netplan 的接口 DNS 可能继续参与解析，菜单会展示状态。

系统完整升级先展示模拟结果，再确认实际升级。多个常见安装路径会等待 apt/dpkg 锁。Docker 用户组修改会核对结果；加入 Docker 组等同于获得很高的主机权限，菜单保留确认提示。

BBR、Swap、主机名、时区、访问检测和保守清理保留原有入口。访问检测反映探测时的网络 / HTTP 结果，不能保证某个账号登录后的完整业务可用性。

## 上传 GitHub 与在线安装

先将源码目录内的文件上传到仓库根目录，包括三个脚本。默认仓库为 `BBMCoin04/mb-linux`，分支为 `main`。

**以下在线命令仅在你上传新版之后使用。** 本地安装不必等 GitHub 更新。

```bash
mb_install_dir="$(mktemp -d)"
curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 10 --max-time 90 -fsSL \
  https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh \
  -o "$mb_install_dir/install.sh"
sudo bash "$mb_install_dir/install.sh"
```

安装器会下载同一仓库引用的主程序和恢复程序，并检查版本一致。菜单更新会在执行远程安装器之前拒绝旧版本。

自建分支或固定提交可以指定：

```bash
sudo VPS_MANAGER_REPO="你的用户名/仓库名" VPS_MANAGER_REF="提交哈希或分支名" bash install.sh
```

后续在线更新如需使用同一自定义来源，也需以相同环境变量运行 `lm update`。下载使用 HTTPS；语法、程序标识、版本检查和 `SHA256SUMS` 不等于发布者数字签名。

## 开发与检查

```bash
bash scripts/check.sh
```

检查脚本不会安装软件，不会运行真实系统服务或修改真实防火墙。运行隔离回归需要 Bash 和 Python 3；如果安装了 ShellCheck，会额外执行全部级别的静态检查。

真实 Fail2ban 配置解析测试是可选的：

```bash
FAIL2BAN_SOURCE=/path/to/fail2ban-1.1.0 python3 tests/test_fail2ban_config.py
```

该测试只调用客户端的配置测试 / 配置转储功能，不启动 Fail2ban 服务。`.github/workflows/check.yml` 已配置 Ubuntu 22.04 / 24.04 的隔离回归和 Fail2ban 1.1.0 解析测试；这些 GitHub 作业需在上传仓库后才会运行。

主要目标系统为使用 systemd 的 Ubuntu 22.04 / 24.04 / 26.04。版本识别保留 25.10，但不建议在已停止维护的发行版上新部署。此包尚未完成这些发行版的真实 VPS 安装、远程登录、内核防火墙和重启验收。
