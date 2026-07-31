# vps-manager 1.4.4 修复清单

## 更新影响

执行 `sudo lm update` 只替换管理器程序并执行版本自检，不会自动修改现有 SSH、UFW、DNS、Swap、Docker、Fail2ban 或 APT 配置，也不会自动运行初始化向导。

旧配置不会在更新时迁移。以下修复只在用户以后主动选择对应菜单操作时生效。

## 已修复

### 安装与更新

- 版本更新为 `1.4.4`。
- 安装过程增加未提交/已提交状态；覆盖期间收到 HUP、INT、TERM 或异常退出时恢复原管理器。
- curl 保持 HTTPS/TLS 限制，wget 增加 `--https-only`。
- 保留语法、程序标识、版本、防降级和安装后版本自检。
- 安装和更新不会自动迁移系统配置。

### Ubuntu 26.04

- 明确识别 `jammy`、`noble`、`questing`、`resolute`。
- 状态页显示 Ubuntu 版本、代号和适配状态。
- Docker 官方源允许 Ubuntu 26.04 `resolute`。
- 保留 Ubuntu 24.04/26.04 `ssh.socket` 的 generator 重载流程。

### SSH

- “修改端口”改为“新增端口并保留当前全部端口”。
- 将所有当前端口和新端口显式写入管理文件，避免隐式默认 22 被新 `Port` 替代。
- 修改前检查端口格式、云安全组确认和 UFW 放行。
- 修改后依次执行 `sshd -t`、有效端口检查、服务/socket 重载和实际监听检查。
- 取消第二次确认返回独立状态，不再误报成功或错误同步 Fail2ban。
- 取消时删除本次新增的 UFW 规则；应用失败时为避免误封暂时保留并明确提示。
- 关闭密码或 root 登录前检查有效配置已启用默认公钥路径，并要求存在对应候选账户；真实登录仍由用户在新窗口验证。
- SSH 普通选项应用失败后验证原配置恢复与服务重载结果，失败时明确提示控制台救援。
- 带前导零的端口按十进制规范化，例如 `080` 变为 `80`。

### UFW

- `1.4.4` 首次安装 UFW 前执行 APT 预演；检测到会移除 `iptables-persistent`、`netfilter-persistent` 或其他软件包时显示清单并二次确认。
- 无法可靠识别 SSH 端口时拒绝重建 UFW，不再猜测端口 22。
- 关闭 TCP 端口时若 SSH 端口识别失败，同样拒绝操作。
- UFW 解析统一使用 `LC_ALL=C`，避免本地化输出导致误判。
- 回退过程检查文件恢复、启用/禁用和最终状态，并在回退不完整时给出控制台救援提示。
- Docker 运行时在确认前提示容器发布端口可能绕过 UFW；不接管 Docker 防火墙链。

### Fail2ban

- `1.4.2` 根据真实 Ubuntu 24.04 测试补充重启后的 jail 就绪等待，避免刚重启就查询而误报未启用。
- 成功前读取并验证 `maxretry=5`、`findtime=600`、`bantime=3600`；未生效时恢复原配置。
- 状态页改为显示 jail 的真实生效规则；非脚本管理的 jail 不再固定显示 1 小时封禁。
- SSH jail 改为保护全部当前 SSH 端口，例如 `22,2222`。
- SSH 新增端口成功后同步全部端口，并确认管理文件中的端口值确实匹配。
- 配置使用候选文件和原子替换，并继续执行 `fail2ban-client -t`。
- 区分当前运行成功和开机启用失败，不再无条件报告完整成功。

### Swap

- `1.4.2` 修正 Ubuntu 24.04 `swapon` 活动列表参数，状态页不再因无效的 `--output` 参数显示空白。
- 新增 `/etc/vps-manager/swap.conf` 管理标记。
- 只有路径和管理标记匹配时才允许删除 Swap，避免误删云镜像或用户创建的 `/swapfile`。
- 升级前已经存在的 Swap 不会自动接管；需要用户明确确认。
- 创建和删除前备份 `/etc/fstab`。
- 检查 Swap 文件 `0600` 权限设置结果。
- 新建 Swap 的管理标记写入失败时，立即撤销本次 Swap 和新增的 fstab 条目；swappiness 写入失败不影响后续安全管理。
- 删除后移除管理状态并重新加载现有 sysctl 配置。

### DNS

- 只有 systemd-resolved 正在运行且实际管理 `/etc/resolv.conf` 时才走 resolved 配置路径。
- resolved 配置使用候选文件、原子替换和失败恢复。
- 普通 `resolv.conf` 路径继续先备份符号链接或文件，再安全替换。
- 修改后执行带超时的真实域名解析测试；失败恢复原配置。
- DNS 列表改用数组解析，避免通配符展开。
- 不修改 cloud-init 或 netplan，只提示其可能在重启后覆盖下层 DNS。

### Docker

- `1.4.2` 根据真实 Docker 29.6.2 -> 29.7.0 升级测试增加二次确认：预下载后显示全部待升级 Docker 组件和版本，并明确提示 daemon 重启可能短暂中断容器。
- 用户拒绝二次确认时不安装升级；新建的仓库配置会恢复，预下载包可保留在 APT 缓存。
- `1.4.1` 根据真实 Ubuntu 24.04 环境补充旧式 `docker.list` / `docker.gpg` 兼容：其他路径存在唯一有效 Docker 官方源时原样复用；默认 `docker.sources` 路径由脚本备份并规范化写入。
- 检测到多个 Docker 官方源时拒绝继续，显示全部路径，不自动删除或迁移。
- 没有现有官方源时，GPG key 和 `docker.sources` 先写入临时文件，再原子替换。
- 检查下载结果是否为 PGP 公钥文本。
- 保存旧仓库状态；仓库验证失败或用户取消时恢复。
- `apt-get update` 成功并预下载 Docker CE 包后，才请求移除冲突包。
- 最终安装失败时保留有效官方源和已下载包，便于修复 APT/dpkg 后重试。
- Ubuntu 26.04 `resolute` 纳入官方仓库流程。

### 自动安全更新

- 沿用系统现有 unattended-upgrades 允许来源，不接管 `Allowed-Origins` / `Origins-Pattern`。
- 配置通过候选文件原子写入。
- 保存原配置快照和长期备份。
- 使用 `apt-config dump` 验证最终生效值。
- 检查 `apt-daily.timer` 和 `apt-daily-upgrade.timer` 启用结果。
- 写入、验证或 timer 启用失败时恢复原配置文件；timer 可能部分启用时明确提示检查，不再无条件显示成功。
- 关闭操作同样执行验证和失败恢复。

### 其他可靠性

- SSH、DNS、Swap、BBR、UFW 端口、Fail2ban、自动更新和管理器更新等修改操作统一使用进程锁，避免并发写配置。
- `/etc/hosts` 和 cloud-init 主机名配置改为候选文件及原子替换。
- 非 Ubuntu 的 BBR 删除、Swap 删除、Fail2ban 关闭、自动更新关闭和 Docker 组操作补齐系统检查。
- AI/流媒体检测不再强制 IPv4，可在 IPv6-only 网络中使用。
- README 精简并与实际行为统一。

## 明确保留的功能边界

本版本没有加入以下功能：

- 自动清理旧 SSH 端口。
- 接管 cloud-init/netplan DNS。
- Docker `DOCKER-USER` 深度集成。
- Debian、非交互模式、端口范围和签名体系。
- SSH 定时回滚、应用服务降权和复杂权限加固。
- Reality、ACME、Sing-box 或其他上层代理功能。

## 验证结果

当前 `1.4.4` 已完成：

- `bash -n install.sh`
- `bash -n vps-manager.sh`
- `vps-manager version` 返回 `1.4.4`
- 端口、IPv4、IPv6、DNS 输入边界测试
- 修改锁重复获取和并发拒绝模拟
- SSH 默认公钥配置前置检查模拟
- Fail2ban `22,2222` 管理端口匹配测试
- UFW 安装 APT 卸载项识别与取消测试
- 安装器非 root 拒绝测试

当前沙箱没有真实 root/systemd/UFW/sshd 环境。SSH 双端口、Swap 失败撤销、DNS 恢复、Fail2ban 重启、UFW、Docker、自动更新 timer 和 bundled root 安装需要在有云控制台的 Ubuntu VPS 上回归后再发布。
