# MB-Linux / vps-manager 1.5.2

中文 Ubuntu VPS 管理工具，快捷命令 **`lm`**。提供系统升级、SSH、防火墙、Fail2ban、自动安全更新、BBR、Swap、Docker、DNS、访问检测和保守清理。

面向使用 systemd 的 Ubuntu 22.04 / 24.04 / 26.04。修改系统需要 root 权限；其他 Ubuntu 版本会提示后按通用流程处理。

## 一键安装 / 升级

在 Ubuntu VPS 终端复制执行，支持 root 和具有 sudo 权限的普通用户：

```bash
( set -e; mb_installer="$(mktemp)"; trap 'rm -f -- "$mb_installer"' EXIT; curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 -fsSL https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh -o "$mb_installer"; if [ "$(id -u)" -eq 0 ]; then bash "$mb_installer" --online; else sudo bash "$mb_installer" --online; fi )
```

需要服务器能访问 GitHub，并已安装 `curl`。下载失败会停止；退出安装和菜单后清理临时安装文件。

安装后打开菜单：

```bash
sudo lm
```

root 用户直接运行 `lm`。安装器仅安装管理工具，系统升级、SSH、防火墙等操作均在菜单中按需选择。

## 本地源码安装 / 升级

将本目录完整上传到 Ubuntu VPS，进入目录执行：

```bash
sudo bash install.sh
```

root 用户运行 `bash install.sh`。本地安装使用同目录的源码，不依赖 GitHub；缺文件或目录权限不符合要求时直接停止，不会自动改装远程版本。

**三份脚本必须一起保留并更新：**

| 文件 | 用途 |
| --- | --- |
| `install.sh` | 安装、升级和安装失败回退 |
| `vps-manager.sh` | 主程序及中文菜单 |
| `network-rollback.sh` | SSH / UFW 配置恢复 |
| `README.md` | 安装、使用和恢复说明 |
| `SHA256SUMS` | 发布文件的校验值，可用 `sha256sum -c SHA256SUMS` 核对 |
| `.gitattributes` | 保持脚本为 Linux 换行格式 |

源码目录和脚本的所有者应为 root 或运行 sudo 的用户，不能允许其他用户或组写入。确认文件来源后，可修正权限：

```bash
chmod go-w . install.sh vps-manager.sh network-rollback.sh
```

安装后核对版本：

```bash
lm version
```

预期输出 `vps-manager 1.5.2`。程序位于 `/usr/local/sbin/vps-manager`，快捷命令为 `/usr/local/sbin/lm`，恢复程序为 `/usr/local/sbin/vps-manager.rollback`。安装器不覆盖其他程序占用的 `lm`，也不允许用旧版本覆盖新版。

## 常用入口

| 命令 | 功能 |
| --- | --- |
| `sudo lm` | 完整中文菜单 |
| `sudo lm init` | 逐项确认的初始化向导 |
| `sudo lm status` | 系统、网络和服务状态 |
| `sudo lm system` | 系统升级、主机名、时区和重启 |
| `sudo lm security` | Fail2ban 与自动安全更新 |
| `sudo lm ports` | UFW 模式和业务端口 |
| `sudo lm swap` | Swap 管理 |
| `sudo lm docker` | Docker 安装、状态和用户组 |
| `lm check-ai` | AI / 流媒体 HTTP 访问检测 |
| `sudo lm cleanup-system` | 带确认的保守清理 |
| `sudo lm update` | 从 GitHub 更新管理器 |
| `lm help` | 命令说明 |

SSH、BBR 和 DNS 通过主菜单管理。系统升级会先展示计划；Docker 更新可能短暂中断容器，会另行提示。

## SSH 与防火墙

修改 SSH 或切换 UFW 收紧模式前，程序保存配置快照，并安排独立恢复任务。默认 **180 秒确认窗口从快照阶段开始计算，包含应用和检查时间**。修改任务有执行时限；超时恢复会先停止该修改任务，再恢复配置，避免卡住的修改进程持续占用恢复锁。

1. 保持当前 SSH 窗口。新增端口前，先在云厂商安全组放行。
2. 按菜单执行修改。新增 SSH 端口时保留原端口。
3. 另开窗口，通过目标端口和目标账号登录，并检查必要业务。
4. 验证成功后，在原窗口输入 `y`；也可在新窗口执行：

   ```bash
   sudo lm confirm-network
   ```

输入 `n`、确认输入中断或超时会尝试恢复。修改尚未通过全部本机检查时，不能提前确认。恢复需要服务重新载入时间，180 秒不是恢复完成时间。

SSH 检查包括语法、全局配置、真实监听及运行中的 Fail2ban 端口；取得当前连接信息时，还核对 root 和调用用户在该来源地址下的条件配置。其他用户、来源以及基于主机名的 `Match Host` 规则仍需使用对应连接验证；没有连接信息时会明确提示检查范围。

**验证期间不要重启服务器。** 恢复定时器不跨重启；云安全组、外部网络、断电和磁盘故障不在其恢复范围内。`ssh.socket` 模式仅在服务停止策略允许保留现有会话时自动重启 SSH 主进程。

UFW 收紧模式会展示清单并经确认后重建规则。新安装默认只保留识别到的 SSH 端口，网站或代理所需的 `80/tcp`、`443/tcp` 等业务端口要先在菜单中添加。Docker 发布端口可能绕过 UFW，云安全组也需单独配置。SSH 修改失败时，新增的 UFW 放行规则可能保留，核对后可通过端口菜单移除。

## 其他功能说明

- **Fail2ban**：可选的 SSH 防护，默认 10 分钟内失败 5 次封禁 1 小时。支持规则调整、可信 IP / 网段和解封；保留其他 jail，白名单管理仅移除本工具添加的地址。
- **自动安全更新**：沿用系统允许的软件来源，启用时关闭自动重启。
- **DNS**：逐个检查主 DNS，备用服务器不能替代主 DNS 检查。systemd-resolved 使用独立配置文件并核对全局生效地址，接口 DHCP / netplan DNS 仍可能参与解析；`FallbackDNS` 只在没有其他 DNS 配置信息时使用，不是主 DNS 超时切换机制。
- **BBR**：只应用本工具的两项参数，失败时尝试恢复原配置和运行值。移除持久配置不会立即切换当前拥塞算法。
- **Swap**：创建前核对空间；删除只针对明确由本工具管理的 Swap。
- **访问检测**：显示 HTTP 可达、需要认证、访问受限、限流等结果，不等于账号、订阅或地区内容一定可用。
- **保守清理**：仅处理 APT 缓存、系统策略允许的过期临时文件、较旧 journal 归档和过大的管理器日志，不执行 Docker prune 或自动卸载软件。

## 网络恢复未完成时

通过云厂商网页控制台查看最近一次恢复目录及日志：

```bash
sudo cat /var/lib/vps-manager/network-guard/current
```

把以下 `change.XXXXXXXX` 替换为上一步显示的实际目录名：

```bash
sudo cat /var/lib/vps-manager/network-guard/change.XXXXXXXX/state
sudo cat /var/lib/vps-manager/network-guard/change.XXXXXXXX/rollback.log
```

`pending` 为待确认，`confirmed` 为已保留，`rolling-back` 为恢复中，`rolled-back` 为恢复命令完成，`rollback-failed` 为恢复失败。无法停止修改任务或取得恢复锁时也会记录原因，并保留快照。

阅读日志、确认要还原该次修改后，可在控制台重试：

```bash
sudo bash /var/lib/vps-manager/network-guard/change.XXXXXXXX/rollback.sh /var/lib/vps-manager/network-guard/change.XXXXXXXX
```

此命令使用快照覆盖对应管理配置并重新载入服务。已确认保留的事务不会被撤销；待确认或恢复未完成时，其他修改会被阻止。

普通备份在 `/var/backups/vps-manager/`，操作日志在 `/var/log/vps-manager/vps-manager.log`。

## 本地维护与上传 GitHub

1.5.2 修正恢复日志：已正常结束并被 systemd 回收的修改任务不再显示 `Unit ... not loaded`；已确认或已恢复的事务直接结束重复请求。真正的停止失败仍会记录原因并阻止并发恢复。功能和菜单与 1.5.1 一致。

先在本地保存完整源码，再将本目录中的文件一起提交到 `BBMCoin04/mb-linux` 的 `main` 分支。仓库根目录应直接看到 `install.sh`，不要再套一层文件夹。在线安装和菜单更新取 GitHub 内容，尚未上传时可直接使用本地安装。

若在旧源码目录中替换文件，保留自己的 `.git`；旧 `tests/`、`scripts/check.sh`、`.github/workflows/check.yml`、测试报告、旧入门说明与旧变更记录不属于本定稿包，可一并从发布内容移除。下载包不附带 Git 历史或开发测试文件。

使用其他仓库或固定引用时，显式指定来源：

```bash
sudo VPS_MANAGER_REPO="你的用户名/仓库名" VPS_MANAGER_REF="分支、标签或提交" bash install.sh --online
sudo VPS_MANAGER_REPO="你的用户名/仓库名" VPS_MANAGER_REF="分支、标签或提交" lm update
```
