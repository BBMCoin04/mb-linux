# mb-linux / vps-manager

面向 Ubuntu VPS 的交互式初始化管理工具。用于新开机器后的标准化处理：系统更新、时区、常用依赖、SSH/root 登录、防火墙端口、BBR、DNS，以及 AI/流媒体解锁检测入口。

脚本风格与 `acme-manager` 保持一致：中文菜单、明确提示、成功/失败状态、关键修改前确认、安装器校验后落到固定路径。

## 一行安装

推荐方式（先下载、再执行，便于检查和排错）：

```bash
curl -fsSLo /tmp/vps-manager-install.sh https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh && sudo bash /tmp/vps-manager-install.sh
```

快速方式：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh | sudo bash
```

使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh | sudo bash
```

`install.sh` 会执行以下步骤：

1. 只允许从 HTTPS 地址下载。
2. 将主程序下载到临时文件。
3. 检查文件非空、程序标识和 Bash 语法。
4. 安装为 `/usr/local/sbin/vps-manager`。
5. 输出安装文件的 SHA-256（系统支持时）。
6. 重新连接当前终端并打开交互菜单。

重新打开菜单：

```bash
sudo vps-manager
```

## 主菜单

```text
1. 基础初始化
2. SSH/root 登录设置
3. 防火墙与端口
4. BBR 与网络优化
5. DNS 配置
6. AI/流媒体解锁检测
7. 系统状态与最近日志
8. 高级维护
0. 退出
```

## 基础初始化

新 VPS 推荐先运行：

```bash
sudo vps-manager init
```

基础初始化会逐项确认，不会静默修改系统关键配置：

- 更新软件源并升级系统。
- 设置时区为 `Asia/Shanghai`。
- 安装常用依赖：`curl wget sudo vim nano git unzip ca-certificates jq lsof net-tools dnsutils`。
- 检查并启用 BBR。
- 开放默认端口：`22/tcp,80/tcp,443/tcp`。
- 进入 DNS 配置向导。

## SSH/root 登录

SSH 菜单支持：

- 查看当前 SSH 生效配置。
- 开启或关闭 root 登录。
- 开启或关闭密码登录。
- 修改 SSH 端口。

涉及 `/etc/ssh/sshd_config` 的修改都会：

1. 显示当前配置。
2. 显示准备写入的目标值。
3. 请求确认。
4. 自动备份原文件。
5. 执行 `sshd -t` 校验。
6. 校验通过后重载 SSH；失败则恢复备份。

开启 root 登录和密码登录会增加暴力破解风险，脚本允许按个人习惯开启，但不会静默执行。

## 防火墙与端口

默认使用 `ufw`。菜单支持：

- 查看状态。
- 开放端口。
- 删除开放端口。
- 启用防火墙。
- 关闭防火墙。

端口格式示例：

```text
443
443/tcp
53/udp
22/tcp,80/tcp,443/tcp
```

关闭防火墙属于高风险操作，脚本会二次确认。

## BBR 与 DNS

BBR 菜单会显示：

- 当前拥塞控制算法。
- 内核可用拥塞控制算法。
- 当前默认队列算法。

启用 BBR 会写入：

```text
/etc/sysctl.d/99-vps-manager-bbr.conf
```

DNS 菜单优先使用 `systemd-resolved`，否则回退到 `/etc/resolv.conf`。修改前会备份原配置。

内置 DNS 方案：

- Cloudflare + Google：`1.1.1.1 1.0.0.1`，备用 `8.8.8.8 8.8.4.4`
- Cloudflare
- Google
- Quad9
- 自定义

## AI/流媒体检测

内置 AI 基础连通性检测会检查：

- IPv4/IPv6 公网 IP。
- `openai.com`、`api.openai.com`、`chatgpt.com`、`chat.openai.com` 的 DNS 解析。
- OpenAI API 与 ChatGPT 相关地址的 HTTP 状态。

这只代表网络可达性，不代表账号、套餐、风控或地区一定可用。

完整流媒体检测通过菜单手动运行第三方脚本：

- `RegionRestrictionCheck`：`https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh`
- `MediaUnlockTest`：`https://unlock.icmp.ing/scripts/test.sh`

外部脚本不会默认执行。运行前会显示来源 URL 并请求确认。

## CLI

```bash
sudo vps-manager
sudo vps-manager init
sudo vps-manager status
sudo vps-manager ports
sudo vps-manager check-ai
sudo vps-manager check-media
sudo vps-manager update
sudo vps-manager install
vps-manager version
vps-manager help
```

日志文件：

```text
/var/log/vps-manager/vps-manager.log
```

## 更新

进入菜单：

```text
8. 高级维护 -> 2. 更新 vps-manager
```

也可以使用 CLI：

```bash
sudo vps-manager update
```

默认仓库可以通过环境变量覆盖：

```bash
curl -fsSL https://raw.githubusercontent.com/BBMCoin04/mb-linux/main/install.sh | sudo env VPS_MANAGER_REPO=OWNER/REPO VPS_MANAGER_REF=main bash
```

## 支持范围

首版只支持 Ubuntu。非 Ubuntu 系统可以查看部分状态，但修改类操作会被拒绝。

建议在新 VPS 的控制台保留一个备用登录窗口，再修改 SSH 端口、root 登录或防火墙规则。
