#!/usr/bin/env bash
# vps-manager: an interactive Ubuntu VPS initialization manager.

set -uo pipefail
umask 077

VERSION="1.0.0"
PROGRAM="vps-manager"
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
MANAGER_REPO="${VPS_MANAGER_REPO:-BBMCoin04/mb-linux}"
MANAGER_REF="${VPS_MANAGER_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
LOG_ROOT="${LOG_ROOT:-/var/log/vps-manager}"
LOG_FILE="${LOG_ROOT}/vps-manager.log"
LOCK_FILE="/run/lock/vps-manager.lock"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Shanghai}"
DEFAULT_PORTS="${DEFAULT_PORTS:-22/tcp,80/tcp,443/tcp}"
COMMON_PACKAGES=(
  ca-certificates
  curl
  dnsutils
  git
  jq
  lsof
  nano
  net-tools
  sudo
  unzip
  vim
  wget
)
SELF_PATH="${BASH_SOURCE[0]}"
if [[ -f "$SELF_PATH" ]]; then
  SELF_PATH="$(readlink -f "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")"
else
  SELF_PATH=""
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_BOLD=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按 Enter 键继续..." _
}

confirm() {
  local prompt="$1" answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

require_root() {
  if (( EUID != 0 )); then
    error "此操作需要 root 权限，请使用 sudo 运行。"
    exit 1
  fi
}

ensure_directories() {
  install -d -m 0700 "$LOG_ROOT"
  install -d -m 0755 "$(dirname "$LOCK_FILE")"
}

acquire_lock() {
  ensure_directories
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "另一个 vps-manager 任务正在运行，本次操作退出。"
    return 1
  fi
}

log_line() {
  ensure_directories
  printf '[%s] %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE"
}

log_command() {
  local mode="$1"
  shift
  ensure_directories
  printf '\n[%s] %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE"

  if [[ "$mode" == "quiet" || ! -t 1 ]]; then
    "$@" >> "$LOG_FILE" 2>&1
    return $?
  fi

  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

is_ubuntu() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]]
}

require_ubuntu() {
  if ! is_ubuntu; then
    error "首版仅支持 Ubuntu。当前系统不是 Ubuntu，已停止修改。"
    return 1
  fi
}

apt_install() {
  require_root
  require_ubuntu || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_command() {
  local command_name="$1" package_name="${2:-$1}"
  command -v "$command_name" >/dev/null 2>&1 && return 0
  warn "缺少命令：${command_name}，准备安装 ${package_name}。"
  apt-get update && apt_install "$package_name"
}

backup_file() {
  local file="$1" backup
  [[ -e "$file" ]] || return 0
  backup="${file}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp -a "$file" "$backup"
  ok "已备份 ${file} -> ${backup}"
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  ${PROGRAM}              打开交互菜单
  lm                       快捷打开交互菜单
  ${PROGRAM} init         进入基础初始化向导
  ${PROGRAM} status       查看系统、SSH、防火墙、BBR、DNS、IP 状态
  ${PROGRAM} ports        进入防火墙与端口管理
  ${PROGRAM} check-ai     执行内置 AI 连通性检测
  ${PROGRAM} check-media  选择并运行第三方流媒体检测
  ${PROGRAM} update       从 GitHub 更新 vps-manager
  ${PROGRAM} install      安装或修复固定副本
  ${PROGRAM} version

日志文件：${LOG_FILE}
EOF
}

banner() {
  [[ -t 1 ]] && clear || true
  printf '%s%s' "$C_BOLD" "$C_CYAN"
  cat <<'EOF'
 __  __  ____       __     ______  ____
|  \/  || __ )      \ \   / /  _ \/ ___|
| |\/| ||  _ \ _____ \ \ / /| |_) \___ \
| |  | || |_) |_____| \ V / |  __/ ___) |
|_|  |_||____/        \_/  |_|   |____/
EOF
  printf '%s' "$C_RESET"
  printf '%s%s %s%s\n' "$C_BOLD" "$PROGRAM" "$VERSION" "$C_RESET"
  printf "Ubuntu VPS 初始化、网络、SSH、防火墙与解锁检测工具\n\n"
}

print_os_summary() {
  local pretty="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-${ID:-unknown}}"
  fi
  printf '系统：%s\n' "$pretty"
  printf '内核：%s\n' "$(uname -r)"
  if command -v uptime >/dev/null 2>&1; then
    printf '运行：%s\n' "$(uptime -p 2>/dev/null || true)"
  fi
}

system_upgrade() {
  require_root
  require_ubuntu || return 1
  acquire_lock || return 1
  info "准备更新软件源并升级系统软件包。"
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_common_dependencies() {
  require_root
  require_ubuntu || return 1
  acquire_lock || return 1
  info "准备安装常用依赖：${COMMON_PACKAGES[*]}"
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y "${COMMON_PACKAGES[@]}"
}

set_timezone() {
  local timezone="${1:-$DEFAULT_TIMEZONE}"
  require_root
  require_ubuntu || return 1
  ensure_command timedatectl systemd || return 1
  info "当前时区：$(timedatectl show -p Timezone --value 2>/dev/null || printf '未知')"
  if timedatectl set-timezone "$timezone"; then
    ok "时区已设置为 ${timezone}"
    log_line "timezone set to ${timezone}"
  else
    error "时区设置失败。"
    return 1
  fi
}

normalize_port_rule() {
  local raw="$1" port proto
  raw="$(trim "${raw,,}")"
  [[ -n "$raw" ]] || return 1
  if [[ "$raw" =~ ^([0-9]{1,5})(/(tcp|udp))?$ ]]; then
    port="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[3]:-tcp}"
    (( port >= 1 && port <= 65535 )) || return 1
    printf '%s/%s\n' "$port" "$proto"
    return 0
  fi
  return 1
}

collect_port_rules() {
  local input="${1:-}" item rule
  PORT_RULES=()
  while IFS= read -r item; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    if ! rule="$(normalize_port_rule "$item")"; then
      error "端口格式不正确：${item}。示例：443、443/tcp、53/udp"
      return 1
    fi
    PORT_RULES+=("$rule")
  done < <(printf '%s' "$input" | tr ',' '\n')
}

declare -a PORT_RULES=()

ensure_ufw() {
  require_root
  require_ubuntu || return 1
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  warn "当前未安装 ufw。"
  if confirm "是否安装 ufw？"; then
    apt-get update && apt_install ufw
    return $?
  fi
  return 1
}

show_firewall_status() {
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  else
    printf 'ufw：未安装\n'
  fi
}

open_port_rules() {
  local input="${1:-}" rule
  ensure_ufw || return 1
  if [[ -z "$input" ]]; then
    read -r -p "需要开放的端口（逗号分隔，默认 ${DEFAULT_PORTS}）：" input
    input="${input:-$DEFAULT_PORTS}"
  fi
  collect_port_rules "$input" || return 1
  (( ${#PORT_RULES[@]} > 0 )) || { error "没有有效端口。"; return 1; }
  printf '准备开放：%s\n' "${PORT_RULES[*]}"
  confirm "确认继续？" || return 0
  for rule in "${PORT_RULES[@]}"; do
    log_command interactive ufw allow "$rule" || return 1
  done
  ok "端口规则已添加。"
}

delete_port_rules() {
  local input rule
  ensure_ufw || return 1
  read -r -p "需要删除的 allow 端口（逗号分隔，例如 8080/tcp,53/udp）：" input
  collect_port_rules "$input" || return 1
  (( ${#PORT_RULES[@]} > 0 )) || { error "没有有效端口。"; return 1; }
  printf '准备删除 allow 规则：%s\n' "${PORT_RULES[*]}"
  confirm "确认继续？" || return 0
  for rule in "${PORT_RULES[@]}"; do
    log_command interactive ufw delete allow "$rule" || true
  done
  ok "端口删除命令已执行。"
}

enable_ufw() {
  ensure_ufw || return 1
  warn "启用防火墙前，请确认当前 SSH 端口已经放行。"
  confirm "确认启用 ufw？" || return 0
  log_command interactive ufw --force enable
}

disable_ufw() {
  ensure_ufw || return 1
  warn "关闭防火墙会扩大暴露面，除排障外不建议长期关闭。"
  confirm "确认关闭 ufw？" || return 0
  log_command interactive ufw disable
}

firewall_menu() {
  local choice
  require_root
  while true; do
    printf '\n防火墙与端口：\n'
    printf '  1. 查看 ufw 状态\n'
    printf '  2. 开放端口\n'
    printf '  3. 删除开放端口\n'
    printf '  4. 启用 ufw\n'
    printf '  5. 关闭 ufw\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_firewall_status; pause ;;
      2) open_port_rules; pause ;;
      3) delete_port_rules; pause ;;
      4) enable_ufw; pause ;;
      5) disable_ufw; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

bbr_status() {
  local current available qdisc
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || printf 'unknown')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
  printf '当前拥塞控制：%s\n' "$current"
  printf '可用拥塞控制：%s\n' "$available"
  printf '默认队列算法：%s\n' "$qdisc"
  if [[ "$current" == "bbr" ]]; then
    ok "BBR 当前已启用。"
  elif [[ "$available" == *bbr* ]]; then
    warn "内核支持 BBR，但当前未启用。"
  else
    warn "当前内核未显示 BBR 支持；可尝试加载 tcp_bbr 模块。"
  fi
}

enable_bbr() {
  require_root
  require_ubuntu || return 1
  local available
  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ "$available" != *bbr* ]]; then
    error "当前内核未提供 BBR，无法启用。"
    return 1
  fi
  cat > /etc/sysctl.d/99-vps-manager-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  if log_command interactive sysctl --system; then
    ok "BBR 配置已写入 /etc/sysctl.d/99-vps-manager-bbr.conf"
    bbr_status
  else
    error "应用 sysctl 配置失败。"
    return 1
  fi
}

bbr_menu() {
  local choice
  while true; do
    printf '\nBBR 与网络优化：\n'
    printf '  1. 查看 BBR 状态\n'
    printf '  2. 启用 BBR\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) bbr_status; pause ;;
      2)
        warn "启用 BBR 会修改 sysctl 配置。"
        if confirm "确认启用 BBR？"; then
          enable_bbr
        fi
        pause
        ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_dns_status() {
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns 2>/dev/null || true
    resolvectl domain 2>/dev/null || true
  fi
  printf '\n/etc/resolv.conf：\n'
  sed -n '1,20p' /etc/resolv.conf 2>/dev/null || true
}

set_resolved_key() {
  local file="$1" key="$2" value="$3"
  touch "$file"
  if ! grep -q '^\[Resolve\]' "$file"; then
    printf '\n[Resolve]\n' >> "$file"
  fi
  if grep -qiE "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|I" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

apply_dns_servers() {
  local label="$1" dns="$2" fallback="$3" resolved_file="/etc/systemd/resolved.conf"
  require_root
  require_ubuntu || return 1
  printf 'DNS 方案：%s\n' "$label"
  printf 'DNS=%s\nFallbackDNS=%s\n' "$dns" "$fallback"
  confirm "确认修改 DNS 配置？" || return 0

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$resolved_file" ]]; then
    backup_file "$resolved_file"
    set_resolved_key "$resolved_file" DNS "$dns"
    set_resolved_key "$resolved_file" FallbackDNS "$fallback"
    if systemctl restart systemd-resolved; then
      ok "systemd-resolved DNS 已更新。"
      show_dns_status
      return 0
    fi
    error "重启 systemd-resolved 失败。"
    return 1
  fi

  backup_file /etc/resolv.conf
  {
    printf '# Managed by vps-manager on %s\n' "$(date '+%F %T %z')"
    for server in $dns $fallback; do
      printf 'nameserver %s\n' "$server"
    done
  } > /etc/resolv.conf
  ok "/etc/resolv.conf 已更新。"
  show_dns_status
}

custom_dns() {
  local dns fallback
  read -r -p "主 DNS（空格分隔，例如 1.1.1.1 8.8.8.8）：" dns
  dns="$(trim "$dns")"
  [[ -n "$dns" ]] || { error "主 DNS 不能为空。"; return 1; }
  read -r -p "备用 DNS（空格分隔，可留空）：" fallback
  fallback="$(trim "$fallback")"
  apply_dns_servers "自定义" "$dns" "$fallback"
}

dns_menu() {
  local choice
  while true; do
    printf '\nDNS 配置：\n'
    printf '  1. 查看当前 DNS\n'
    printf '  2. Cloudflare + Google（推荐）\n'
    printf '  3. Cloudflare\n'
    printf '  4. Google\n'
    printf '  5. Quad9\n'
    printf '  6. 自定义\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_dns_status; pause ;;
      2) apply_dns_servers "Cloudflare + Google" "1.1.1.1 1.0.0.1" "8.8.8.8 8.8.4.4"; pause ;;
      3) apply_dns_servers "Cloudflare" "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001"; pause ;;
      4) apply_dns_servers "Google" "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844"; pause ;;
      5) apply_dns_servers "Quad9" "9.9.9.9 149.112.112.112" "2620:fe::fe 2620:fe::9"; pause ;;
      6) custom_dns; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

sshd_bin() {
  command -v sshd 2>/dev/null || printf '/usr/sbin/sshd'
}

sshd_config_file() {
  printf '/etc/ssh/sshd_config'
}

show_ssh_status() {
  local sshd config
  sshd="$(sshd_bin)"
  config="$(sshd_config_file)"
  if [[ -x "$sshd" ]]; then
    printf 'sshd 有效配置：\n'
    "$sshd" -T 2>/dev/null | awk '/^(port|permitrootlogin|passwordauthentication) / {print "  " $0}' || true
  else
    warn "未找到 sshd。"
  fi
  printf '\n%s 中的相关配置：\n' "$config"
  grep -Ein '^[#[:space:]]*(Port|PermitRootLogin|PasswordAuthentication)[[:space:]]+' "$config" 2>/dev/null || true
}

set_sshd_option_in_file() {
  local file="$1" option="$2" value="$3"
  if grep -qiE "^[#[:space:]]*${option}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${option}[[:space:]].*|${option} ${value}|I" "$file"
  else
    printf '\n%s %s\n' "$option" "$value" >> "$file"
  fi
}

reload_ssh_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null && return 0
    systemctl reload sshd 2>/dev/null && return 0
  fi
  service ssh reload 2>/dev/null && return 0
  service sshd reload 2>/dev/null && return 0
}

apply_sshd_option() {
  local option="$1" value="$2" config backup sshd
  require_root
  require_ubuntu || return 1
  config="$(sshd_config_file)"
  sshd="$(sshd_bin)"
  [[ -f "$config" ]] || { error "未找到 ${config}。"; return 1; }
  [[ -x "$sshd" ]] || { error "未找到 sshd。"; return 1; }

  show_ssh_status
  printf '\n准备设置：%s %s\n' "$option" "$value"
  confirm "确认修改 SSH 配置？" || return 0
  backup="${config}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp -a "$config" "$backup"
  set_sshd_option_in_file "$config" "$option" "$value"

  if "$sshd" -t -f "$config"; then
    if reload_ssh_service; then
      ok "SSH 配置已更新并重载。备份：${backup}"
      return 0
    fi
    warn "配置校验通过，但 SSH 服务重载失败。请手动检查服务名。备份：${backup}"
    return 1
  fi

  cp -a "$backup" "$config"
  error "SSH 配置校验失败，已恢复备份：${backup}"
  return 1
}

change_ssh_port() {
  local port
  read -r -p "新的 SSH 端口（1-65535）：" port
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
    error "端口不正确。"
    return 1
  fi
  warn "修改 SSH 端口前，建议先在防火墙和 VPS 控制台安全组中放行 ${port}/tcp。"
  apply_sshd_option Port "$port"
}

ssh_menu() {
  local choice
  require_root
  while true; do
    printf '\nSSH/root 登录设置：\n'
    printf '  1. 查看 SSH 配置\n'
    printf '  2. 开启 root 登录\n'
    printf '  3. 关闭 root 登录\n'
    printf '  4. 开启密码登录\n'
    printf '  5. 关闭密码登录\n'
    printf '  6. 修改 SSH 端口\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_ssh_status; pause ;;
      2) warn "开启 root 登录会增加暴力破解风险。"; apply_sshd_option PermitRootLogin yes; pause ;;
      3) apply_sshd_option PermitRootLogin no; pause ;;
      4) warn "开启密码登录会增加暴力破解风险。"; apply_sshd_option PasswordAuthentication yes; pause ;;
      5) apply_sshd_option PasswordAuthentication no; pause ;;
      6) change_ssh_port; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

curl_probe() {
  local label="$1" url="$2" family="$3" family_arg=()
  command -v curl >/dev/null 2>&1 || { warn "缺少 curl，跳过 ${label}。"; return 0; }
  [[ "$family" == "4" ]] && family_arg=(-4)
  [[ "$family" == "6" ]] && family_arg=(-6)
  printf '%s IPv%s: ' "$label" "$family"
  curl "${family_arg[@]}" -sS -L -o /dev/null -m 12 \
    -w 'HTTP %{http_code}, remote=%{remote_ip}, time=%{time_total}s\n' "$url" 2>&1 || printf '访问失败\n'
}

show_public_ip() {
  command -v curl >/dev/null 2>&1 || { warn "缺少 curl，无法获取公网 IP。"; return 0; }
  printf 'IPv4：%s\n' "$(curl -4 -fsS -m 8 https://api64.ipify.org 2>/dev/null || printf '不可用')"
  printf 'IPv6：%s\n' "$(curl -6 -fsS -m 8 https://api64.ipify.org 2>/dev/null || printf '不可用')"
}

resolve_host() {
  local host="$1"
  printf '%s：' "$host"
  getent ahosts "$host" 2>/dev/null | awk 'NR <= 4 {printf "%s%s", sep, $1; sep=", "} END {printf "\n"}' || printf '解析失败\n'
}

check_ai_connectivity() {
  info "基础连通性检测只判断网络可达性，不代表账号、套餐或地区一定可用。"
  printf '\n公网 IP：\n'
  show_public_ip
  printf '\nDNS 解析：\n'
  resolve_host openai.com
  resolve_host api.openai.com
  resolve_host chatgpt.com
  resolve_host chat.openai.com
  printf '\nHTTP 探测：\n'
  curl_probe "OpenAI API" "https://api.openai.com/v1/models" 4
  curl_probe "OpenAI API" "https://api.openai.com/v1/models" 6
  curl_probe "ChatGPT" "https://chatgpt.com/cdn-cgi/trace" 4
  curl_probe "ChatGPT" "https://chatgpt.com/cdn-cgi/trace" 6
  curl_probe "chat.openai.com" "https://chat.openai.com/cdn-cgi/trace" 4
  curl_probe "chat.openai.com" "https://chat.openai.com/cdn-cgi/trace" 6
}

run_remote_script() {
  local name="$1" url="$2"
  shift 2
  local temp_file rc
  ensure_command curl curl || return 1
  [[ "$url" == https://* ]] || { error "仅允许从 HTTPS 地址下载检测脚本。"; return 1; }
  printf '即将运行第三方脚本：%s\n来源：%s\n' "$name" "$url"
  warn "第三方检测脚本会从远程下载并执行，请确认你信任该来源。"
  confirm "确认继续？" || return 0

  temp_file="$(mktemp /tmp/vps-manager-remote.XXXXXX.sh)" || return 1
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$url" -o "$temp_file"; then
    rm -f "$temp_file"
    error "下载第三方脚本失败。"
    return 1
  fi
  if [[ ! -s "$temp_file" ]]; then
    rm -f "$temp_file"
    error "下载结果为空，拒绝执行。"
    return 1
  fi
  log_command interactive bash "$temp_file" "$@"
  rc=$?
  rm -f "$temp_file"
  return "$rc"
}

check_media_menu() {
  local choice
  while true; do
    printf '\nAI/流媒体解锁检测：\n'
    printf '  1. 内置 AI 基础连通性检测\n'
    printf '  2. RegionRestrictionCheck 全量检测\n'
    printf '  3. RegionRestrictionCheck 仅 IPv4\n'
    printf '  4. RegionRestrictionCheck 仅 IPv6\n'
    printf '  5. MediaUnlockTest 备用检测\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) check_ai_connectivity; pause ;;
      2) run_remote_script "RegionRestrictionCheck" "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh"; pause ;;
      3) run_remote_script "RegionRestrictionCheck IPv4" "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh" -M 4; pause ;;
      4) run_remote_script "RegionRestrictionCheck IPv6" "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh" -M 6; pause ;;
      5) run_remote_script "MediaUnlockTest" "https://unlock.icmp.ing/scripts/test.sh"; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_status() {
  print_os_summary
  printf '\n公网 IP：\n'
  show_public_ip
  printf '\nSSH：\n'
  show_ssh_status
  printf '\n防火墙：\n'
  show_firewall_status
  printf '\nBBR：\n'
  bbr_status
  printf '\nDNS：\n'
  show_dns_status
}

show_log() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 120 "$LOG_FILE"
  else
    info "暂无日志。"
  fi
}

init_wizard() {
  require_root
  require_ubuntu || return 1
  banner
  info "基础初始化会逐项确认，不会静默修改系统关键配置。"
  if confirm "是否更新软件源并升级系统？"; then
    system_upgrade || warn "系统升级步骤失败。"
  fi
  if confirm "是否设置时区为 ${DEFAULT_TIMEZONE}？"; then
    set_timezone "$DEFAULT_TIMEZONE" || warn "时区设置步骤失败。"
  fi
  if confirm "是否安装常用依赖？"; then
    install_common_dependencies || warn "依赖安装步骤失败。"
  fi
  if confirm "是否检查并启用 BBR？"; then
    enable_bbr || warn "BBR 步骤未完成。"
  fi
  if confirm "是否进入防火墙与端口向导？"; then
    open_port_rules "$DEFAULT_PORTS" || warn "默认端口放行未完成。"
    firewall_menu
  fi
  if confirm "是否进入 DNS 配置向导？"; then
    dns_menu
  fi
  ok "基础初始化向导已结束。"
}

install_alias() {
  [[ -n "$ALIAS_PATH" ]] || return 0
  [[ "$ALIAS_PATH" == "$INSTALL_PATH" ]] && return 0
  install -d -m 0755 "$(dirname "$ALIAS_PATH")"
  if [[ -e "$ALIAS_PATH" && ! -L "$ALIAS_PATH" ]]; then
    warn "${ALIAS_PATH} 已存在且不是软链接，跳过快捷命令配置。"
    return 0
  fi
  if ln -sfn "$INSTALL_PATH" "$ALIAS_PATH"; then
    ok "快捷命令已配置：sudo $(basename "$ALIAS_PATH")"
  else
    warn "快捷命令配置失败：${ALIAS_PATH}"
  fi
}

install_manager_binary() {
  require_root
  install -d -m 0755 "$(dirname "$INSTALL_PATH")"
  if [[ "$SELF_PATH" == "$INSTALL_PATH" ]]; then
    chmod 0755 "$INSTALL_PATH"
  elif [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
    install -m 0755 "$SELF_PATH" "$INSTALL_PATH"
  else
    error "当前脚本来自临时数据流，无法安装固定副本。请使用 install.sh 引导安装器。"
    return 1
  fi
  install_alias
  ok "vps-manager 已安装到 ${INSTALL_PATH}"
}

update_manager() {
  local timestamp installer installer_url source_url rc
  require_root
  ensure_command curl curl || return 1

  timestamp="$(date +%s)"
  installer_url="${MANAGER_RAW_BASE}/install.sh?ts=${timestamp}"
  source_url="${MANAGER_RAW_BASE}/vps-manager.sh?ts=${timestamp}"
  installer="$(mktemp /tmp/vps-manager-bootstrap.XXXXXX.sh)" || return 1

  info "正在检查 ${MANAGER_REPO}@${MANAGER_REF} 的管理器版本..."
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$installer_url" -o "$installer"; then
    rm -f "$installer"
    error "无法下载 GitHub 引导安装器。"
    return 1
  fi
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for vps-manager\.$' "$installer"; then
    rm -f "$installer"
    error "下载内容未通过安装器校验，拒绝更新。"
    return 1
  fi

  VPS_MANAGER_REPO="$MANAGER_REPO" \
    VPS_MANAGER_REF="$MANAGER_REF" \
    VPS_MANAGER_SOURCE_URL="$source_url" \
    VPS_MANAGER_INSTALL_PATH="$INSTALL_PATH" \
    bash "$installer" version
  rc=$?
  rm -f "$installer"

  if (( rc != 0 )); then
    error "vps-manager 更新失败。"
    return "$rc"
  fi
  ok "vps-manager 更新完成。"
}

advanced_menu() {
  local choice
  require_root
  while true; do
    printf '\n高级维护：\n'
    printf '  1. 安装/修复 vps-manager 固定副本\n'
    printf '  2. 更新 vps-manager\n'
    printf '  3. 查看最近日志\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) install_manager_binary; pause ;;
      2)
        if update_manager; then
          info "正在重新载入最新版菜单..."
          exec "$INSTALL_PATH"
        fi
        pause
        ;;
      3) show_log; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

main_menu() {
  local choice
  require_root
  while true; do
    banner
    if is_ubuntu; then
      print_os_summary
    else
      warn "当前系统不是 Ubuntu，修改类操作会被拒绝。"
      print_os_summary
    fi
    printf '\n'
    printf '  1. 基础初始化\n'
    printf '  2. SSH/root 登录设置\n'
    printf '  3. 防火墙与端口\n'
    printf '  4. BBR 与网络优化\n'
    printf '  5. DNS 配置\n'
    printf '  6. AI/流媒体解锁检测\n'
    printf '  7. 系统状态与最近日志\n'
    printf '  8. 高级维护\n'
    printf '  0. 退出\n'
    read -r -p "请选择：" choice
    printf '\n'
    case "$choice" in
      1) init_wizard; pause ;;
      2) ssh_menu ;;
      3) firewall_menu ;;
      4) bbr_menu ;;
      5) dns_menu ;;
      6) check_media_menu ;;
      7) show_status; printf '\n最近日志：\n'; show_log; pause ;;
      8) advanced_menu ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

main() {
  local subcommand="${1:-menu}"
  case "$subcommand" in
    menu) main_menu ;;
    init) init_wizard ;;
    status) show_status ;;
    ports) firewall_menu ;;
    check-ai) check_ai_connectivity ;;
    check-media) check_media_menu ;;
    update|update-manager) update_manager ;;
    install) install_manager_binary ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${subcommand}"; show_help; return 2 ;;
  esac
}

main "$@"
