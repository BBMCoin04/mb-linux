# 网络恢复与故障处理

## 正常操作

SSH 配置修改、SSH 端口修改和 UFW 收紧都会先保存恢复快照，再安排独立的 systemd 临时定时任务。默认等待窗口为 180 秒。

- 本机配置或运行检查失败：立即尝试恢复。
- 检查通过且新窗口验证正常：输入 `y`，或执行 `sudo lm confirm-network` 后确认保留。
- 输入 `n`、输入流断开或超过等待窗口：尝试恢复。
- SSH 会话断开：定时任务仍由 systemd 管理，不依赖原来的 SSH 窗口。

恢复本身也需要执行服务命令，所以 180 秒是开始恢复的时间窗口，不是所有网络状态都恢复完成的承诺。

## 无法用新端口登录

1. 不要确认保留。
2. 等待恢复开始和服务重新加载，然后用原端口重连。
3. 检查云厂商安全组是否放行了新端口。
4. 如果原端口仍不能连接，打开云厂商网页控制台。

修改 SSH 端口时会保留原端口。新增的 UFW 放行规则可能继续保留，以避免恢复时误删已有授权；确认不再使用时，可通过端口菜单清理。旧 SSH 端口是否继续监听，以有效配置和实际监听为准。

## 在网页控制台查看状态

```bash
sudo cat /var/lib/vps-manager/network-guard/current
```

该文件显示最近一次事务目录，例如：

```text
/var/lib/vps-manager/network-guard/change.XXXXXXXX
```

将下面的目录替换为实际输出：

```bash
sudo cat /var/lib/vps-manager/network-guard/change.XXXXXXXX/state
sudo cat /var/lib/vps-manager/network-guard/change.XXXXXXXX/rollback.log
```

状态含义：

| 状态 | 含义 |
| --- | --- |
| `pending` | 等待确认或恢复 |
| `confirmed` | 已确认保留，恢复程序不会再撤销 |
| `rolling-back` | 正在恢复 |
| `rolled-back` | 恢复命令及对应检查通过 |
| `rollback-failed` | 至少一个恢复步骤失败，需检查日志 |
| `not-armed` | 恢复任务未能创建，管理器未继续修改网络 |

SSH 恢复会还原管理器的 SSH / Fail2ban 配置文件，并重新载入服务。UFW 恢复会还原防火墙配置、业务端口清单和原启停状态。之前运行的 Fail2ban 会重新载入动作。

## 重试未完成的恢复

仅针对 `pending` 或 `rollback-failed` 的事务。先阅读日志，确认这些就是要还原的配置，然后在网页控制台执行：

```bash
sudo bash /var/lib/vps-manager/network-guard/change.XXXXXXXX/rollback.sh \
  /var/lib/vps-manager/network-guard/change.XXXXXXXX
```

这会用该事务保存的配置覆盖对应管理文件，并重新载入相关服务。已 `confirmed` 的事务不会被这个命令撤销。

成功后状态变为 `rolled-back`，才继续尝试新的网络修改。恢复失败时，管理器会阻止再次叠加新的 SSH / 防火墙事务。

## 常见提示

**缺少配套恢复程序 / 版本不匹配**：使用完整源码包重新运行 `sudo bash install.sh`。

**未能确认真正监听的 SSH 端口**：检查 `sudo ss -ltnp`、`sudo sshd -T` 以及 `sudo systemctl status ssh.socket`。不能确认时，程序停止收紧防火墙。

**SSH 服务 KillMode 不是 process**：当前服务停止策略可能终止已有会话。不要为了通过检查而盲目改这个值；先理解镜像或管理员的自定义服务配置，必要时通过网页控制台手动维护。

**Fail2ban 封禁动作无法核验**：默认系统动作通常可以识别。自定义动作、后加载的 `.local` 配置或手工指定的 action 端口，需要先检查；不会把“文件写好了”当作“运行状态已经正确”。

**远程版本较旧**：先把完整的本地新版上传到 GitHub，再更新。它不会自动用旧安装器覆盖本地新版。

## 恢复范围

此机制覆盖管理器发起的 SSH 设置修改及 UFW 收紧，不覆盖所有菜单操作。BBR、Docker、DNS、Swap 和系统软件升级不使用此 180 秒确认机制。

定时器是临时任务，服务器重启后不会自动重建。因此验证期间不要重启服务器。断电、系统不可启动、磁盘不可写、云安全组、外部路由以及其他管理员同时修改配置，都可能需要云平台控制台或服务器快照协助处理。

普通备份位于 `/var/backups/vps-manager/`，操作日志位于 `/var/log/vps-manager/vps-manager.log`。不要在网络修改尚未确认或恢复完成时删除这些文件。
