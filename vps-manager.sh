#!/usr/bin/env bash
# vps-manager: an interactive Ubuntu VPS initialization manager.

set -uo pipefail
umask 077

VERSION="1.2.4"
PROGRAM="vps-manager"
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
MANAGER_REPO="${VPS_MANAGER_REPO:-BBMCoin04/mb-linux}"
MANAGER_REF="${VPS_MANAGER_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
LOG_ROOT="${LOG_ROOT:-/var/log/vps-manager}"
LOG_FILE="${LOG_ROOT}/vps-manager.log"
BACKUP_ROOT="${VPS_MANAGER_BACKUP_ROOT:-/var/backups/vps-manager}"
LOCK_FILE="/run/lock/vps-manager.lock"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Shanghai}"
DEFAULT_PORTS="${DEFAULT_PORTS:-22/tcp,80/tcp,443/tcp,443/udp,8443/tcp,8443/udp,2087/tcp}"
SWAP_FILE="${VPS_MANAGER_SWAP_FILE:-/swapfile}"
SWAP_SYSCTL_FILE="/etc/sysctl.d/99-vps-manager-swap.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/vps-manager-sshd.local"
SSHD_MANAGED_FILE="/etc/ssh/sshd_config.d/00-vps-manager.conf"
APT_CONFIG_DIR="${VPS_MANAGER_APT_CONFIG_DIR:-/etc/apt/apt.conf.d}"
AUTO_UPGRADES_FILE="${VPS_MANAGER_AUTO_UPGRADES_FILE:-${APT_CONFIG_DIR}/20auto-upgrades}"
AUTO_UPGRADES_OPTIONS_FILE="${VPS_MANAGER_AUTO_UPGRADES_OPTIONS_FILE:-${APT_CONFIG_DIR}/52vps-manager-unattended-upgrades}"
DOCKER_KEY_FILE="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCE_FILE="/etc/apt/sources.list.d/docker.sources"
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

atomic_install_file() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return 1
  if ! install -m "$mode" "$source" "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

validate_manager_paths() {
  [[ "$INSTALL_PATH" == /* && "$INSTALL_PATH" != *[[:space:]]* ]] || {
    error "管理器安装路径必须是不含空白的绝对路径。"
    return 1
  }
  if [[ -n "$ALIAS_PATH" ]]; then
    [[ "$ALIAS_PATH" == /* && "$ALIAS_PATH" != *[[:space:]]* && "$ALIAS_PATH" != "$INSTALL_PATH" ]] || {
      error "快捷命令路径必须是不含空白且不同于安装路径的绝对路径。"
      return 1
    }
  fi
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

is_ubuntu() (
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]]
)

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
  local file="$1" backup backup_name
  [[ -e "$file" || -L "$file" ]] || return 0
  install -d -m 0700 "$BACKUP_ROOT" || return 1
  backup_name="${file#/}"
  backup_name="${backup_name//\//_}"
  backup="${BACKUP_ROOT}/${backup_name}.bak.$(date '+%Y%m%d-%H%M%S').$$"
  if ! cp -a -- "$file" "$backup"; then
    error "无法备份 ${file}。"
    return 1
  fi
  ok "已备份 ${file} -> ${backup}"
}

relocate_legacy_apt_backups() {
  local file destination moved=0
  local -a files=()
  shopt -s nullglob
  files=(
    "$APT_CONFIG_DIR"/20auto-upgrades.bak.*
    "$APT_CONFIG_DIR"/52vps-manager-unattended-upgrades.bak.*
  )
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 0
  install -d -m 0700 "$BACKUP_ROOT" || return 1
  for file in "${files[@]}"; do
    destination="${BACKUP_ROOT}/legacy-$(basename "$file")"
    [[ ! -e "$destination" && ! -L "$destination" ]] || destination="${destination}.$(date '+%Y%m%d-%H%M%S').$$"
    mv -- "$file" "$destination" || return 1
    moved=$((moved + 1))
  done
  ok "已将 ${moved} 个旧版 APT 配置备份移到 ${BACKUP_ROOT}。"
}

reboot_required() {
  [[ -f /var/run/reboot-required ]]
}

show_reboot_status() {
  if reboot_required; then
    warn "系统标记为需要重启：$(tr '\n' ' ' < /var/run/reboot-required 2>/dev/null || printf 'reboot required')"
    [[ -s /var/run/reboot-required.pkgs ]] && sed 's/^/  - /' /var/run/reboot-required.pkgs
  else
    printf '重启要求：当前未检测到系统要求重启\n'
  fi
}

offer_reboot() {
  local reason="$1"
  warn "$reason"
  warn "立即重启会中断当前 SSH 会话和正在运行的任务。"
  confirm "是否立即重启 VPS？" || { info "已跳过重启，可稍后手动执行 sudo reboot。"; return 0; }
  log_line "reboot requested: ${reason}"
  sync
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reboot
  else
    reboot
  fi
}

show_help() {
  cat <<EOF
${PROGRAM} ${VERSION}

用法：
  ${PROGRAM}              打开交互菜单
  lm                       快捷打开交互菜单
  ${PROGRAM} init         进入基础初始化向导
  ${PROGRAM} status       查看系统、SSH、防火墙、BBR、DNS、IP 状态
  ${PROGRAM} ports        选择宽松或收紧防火墙模式
  ${PROGRAM} swap         进入 Swap 管理
  ${PROGRAM} security     进入 Fail2ban 与自动安全更新
  ${PROGRAM} docker       进入 Docker 管理
  ${PROGRAM} hostname     设置主机名
  ${PROGRAM} check-ai     检测 AI 与流媒体访问
  ${PROGRAM} check-media  同 check-ai（兼容旧命令）
  ${PROGRAM} cleanup-system  执行带确认的保守系统清理
  ${PROGRAM} update       从 GitHub 更新 vps-manager
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
  printf "Ubuntu VPS 初始化、网络、SSH、防火墙与访问检测工具\n\n"
}

print_os_summary() {
  local pretty="unknown"
  if [[ -r /etc/os-release ]]; then
    pretty="$(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"
    )"
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
  info "准备更新软件源并执行完整系统升级；该操作可能安装新内核。"
  log_command interactive apt-get update || return 1
  if ! log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y; then
    return 1
  fi
  if reboot_required; then
    offer_reboot "系统升级完成，并检测到新内核或关键组件要求重启。"
  else
    ok "系统升级完成，当前未检测到必须重启。"
  fi
}

install_common_dependencies() {
  require_root
  require_ubuntu || return 1
  acquire_lock || return 1
  info "准备安装常用依赖：${COMMON_PACKAGES[*]}"
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y "${COMMON_PACKAGES[@]}"
}

show_hostname() {
  printf '当前主机名：%s\n' "$(hostnamectl --static 2>/dev/null || hostname)"
  hostnamectl status 2>/dev/null | sed -n '1,8p' || true
}

set_hostname() {
  local new_hostname="${1:-}" hosts_file="/etc/hosts" old_hostname
  require_root
  require_ubuntu || return 1
  old_hostname="$(hostnamectl --static 2>/dev/null || hostname)"
  show_hostname
  if [[ -z "$new_hostname" ]]; then
    read -r -p "新的主机名（字母、数字和连字符，最长 63 位）：" new_hostname
  fi
  new_hostname="$(trim "${new_hostname,,}")"
  if [[ ! "$new_hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && ! "$new_hostname" =~ ^[a-z0-9]$ ]]; then
    error "主机名格式不正确。"
    return 1
  fi
  [[ "$new_hostname" != "$old_hostname" ]] || { info "主机名已经是 ${new_hostname}。"; return 0; }
  printf '准备修改：%s -> %s\n' "$old_hostname" "$new_hostname"
  confirm "确认修改主机名？" || return 0
  backup_file "$hosts_file" || return 1
  hostnamectl set-hostname "$new_hostname" || return 1
  if grep -qE '^127\.0\.1\.1[[:space:]]+' "$hosts_file"; then
    if ! sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1 ${new_hostname}/" "$hosts_file"; then
      hostnamectl set-hostname "$old_hostname" || true
      error "更新 ${hosts_file} 失败，已尝试恢复原主机名。"
      return 1
    fi
  elif ! printf '\n127.0.1.1 %s\n' "$new_hostname" >> "$hosts_file"; then
    hostnamectl set-hostname "$old_hostname" || true
    error "更新 ${hosts_file} 失败，已尝试恢复原主机名。"
    return 1
  fi
  ok "主机名已设置为 ${new_hostname}；新 SSH 会话会显示新名称。"
  log_line "hostname changed from ${old_hostname} to ${new_hostname}"
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
  done < <(printf '%s\n' "$input" | tr ',' '\n')
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

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}

build_tight_firewall_rules() {
  local ssh_rule rule
  local -a defaults=()
  local -A seen=()
  ssh_rule="$(current_ssh_port)/tcp"
  collect_port_rules "$DEFAULT_PORTS" || return 1
  defaults=("${PORT_RULES[@]}")
  PORT_RULES=()
  PORT_RULES+=("$ssh_rule")
  seen["$ssh_rule"]=1
  for rule in "${defaults[@]}"; do
    [[ "$rule" == "22/tcp" && "$ssh_rule" != "22/tcp" ]] && continue
    [[ -n "${seen[$rule]:-}" ]] && continue
    PORT_RULES+=("$rule")
    seen["$rule"]=1
  done
}

show_firewall_status() {
  local status allowed defaults
  if ! command -v ufw >/dev/null 2>&1; then
    printf 'UFW：未安装（宽松）\n'
    return 0
  fi
  if ! ufw_is_active; then
    printf 'UFW：已关闭（宽松）\n'
    return 0
  fi
  status="$(ufw status verbose 2>/dev/null || true)"
  allowed="$(printf '%s\n' "$status" | awk '$2=="ALLOW" && $1 !~ /^\(/ {print $1}' | sort -u | paste -sd, -)"
  defaults="$(printf '%s\n' "$status" | awk -F': ' '/^Default:/{print $2; exit}')"
  if [[ "$defaults" == *"deny (incoming)"* && "$defaults" == *"allow (outgoing)"* && "$defaults" == *"deny (routed)"* ]]; then
    defaults="拒绝入站，允许出站，拒绝转发"
  fi
  printf 'UFW：已启用\n'
  printf '默认策略：%s\n' "${defaults:-未读取到}"
  printf '允许端口：%s\n' "${allowed:-未读取到}"
}

restore_ufw_backup() {
  local backup_dir="$1" was_active="$2"
  [[ -d "$backup_dir/ufw" ]] && cp -a -- "$backup_dir/ufw/." /etc/ufw/ 2>/dev/null || true
  [[ -f "$backup_dir/default-ufw" ]] && install -m 0644 "$backup_dir/default-ufw" /etc/default/ufw 2>/dev/null || true
  if (( was_active )); then
    ufw --force enable >/dev/null 2>&1 || true
  else
    ufw disable >/dev/null 2>&1 || true
  fi
}

set_firewall_relaxed() {
  require_root
  require_ubuntu || return 1
  if ! command -v ufw >/dev/null 2>&1 || ! ufw_is_active; then
    ok "当前已经是宽松模式：UFW 未启用。"
    return 0
  fi
  warn "宽松模式会关闭 UFW，主机不再过滤入站端口；云厂商安全组仍可能限制访问。"
  confirm "确认切换到宽松模式？" || return 0
  if log_command quiet ufw disable; then
    ok "已切换到宽松模式：UFW 已关闭，现有规则保留。"
    log_line "firewall mode changed to relaxed"
  else
    error "关闭 UFW 失败，请查看日志。"
    return 1
  fi
}

set_firewall_tight() {
  local ssh_port backup_dir rule was_active=0 failed=0
  require_root
  require_ubuntu || return 1
  ensure_ufw || return 1
  build_tight_firewall_rules || return 1
  ssh_port="$(current_ssh_port)"
  printf '\n%s收紧模式%s\n' "$C_BOLD" "$C_RESET"
  printf '  当前 SSH：%s/tcp（最先放行）\n' "$ssh_port"
  printf '  允许端口：%s\n' "${PORT_RULES[*]}"
  printf '  默认策略：拒绝其他入站和转发，允许出站\n'
  warn "将清空现有 UFW 规则并按以上清单重建；云厂商安全组仍需单独配置。"
  confirm "确认切换到收紧模式？" || return 0
  acquire_lock || return 1

  ufw_is_active && was_active=1
  backup_dir="${BACKUP_ROOT}/ufw-$(date '+%Y%m%d-%H%M%S').$$"
  install -d -m 0700 "$backup_dir" || return 1
  cp -a -- /etc/ufw "$backup_dir/ufw" || { error "无法备份 UFW 配置。"; return 1; }
  [[ ! -f /etc/default/ufw ]] || cp -a -- /etc/default/ufw "$backup_dir/default-ufw" || return 1

  log_command quiet ufw --force reset || failed=1
  (( failed )) || log_command quiet ufw default deny incoming || failed=1
  (( failed )) || log_command quiet ufw default allow outgoing || failed=1
  (( failed )) || log_command quiet ufw default deny routed || failed=1
  (( failed )) || log_command quiet ufw logging low || failed=1
  if (( failed == 0 )); then
    for rule in "${PORT_RULES[@]}"; do
      if ! log_command quiet ufw allow "$rule" comment "vps-manager tight mode"; then
        failed=1
        break
      fi
    done
  fi
  (( failed )) || log_command quiet ufw --force enable || failed=1

  if (( failed )); then
    restore_ufw_backup "$backup_dir" "$was_active"
    error "收紧模式应用失败，已尝试恢复原配置。备份：${backup_dir}"
    return 1
  fi
  ok "已切换到收紧模式，当前 SSH ${ssh_port}/tcp 保持放行。"
  info "UFW 备份：${backup_dir}"
  log_line "firewall mode changed to tight: ${PORT_RULES[*]}"
  show_firewall_status
}

firewall_menu() {
  local choice
  require_root
  while true; do
    printf '\n防火墙模式：\n'
    show_firewall_status
    printf '\n  1. 宽松模式（关闭 UFW）\n'
    printf '  2. 收紧模式（只允许 SSH 和服务端口）\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) set_firewall_relaxed; pause ;;
      2) set_firewall_tight; pause ;;
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
  local available temporary backup=""
  modprobe tcp_bbr 2>/dev/null || true
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ "$available" != *bbr* ]]; then
    error "当前内核未提供 BBR，无法启用。"
    return 1
  fi
  temporary="$(mktemp /tmp/vps-manager-bbr.XXXXXX)" || return 1
  if [[ -f /etc/sysctl.d/99-vps-manager-bbr.conf ]]; then
    backup="$(mktemp /tmp/vps-manager-bbr-original.XXXXXX)" || { rm -f -- "$temporary"; return 1; }
    cp -a -- /etc/sysctl.d/99-vps-manager-bbr.conf "$backup" || { rm -f -- "$temporary" "$backup"; return 1; }
  fi
  {
    printf 'net.core.default_qdisc=fq\n'
    printf 'net.ipv4.tcp_congestion_control=bbr\n'
  } > "$temporary"
  if ! atomic_install_file "$temporary" /etc/sysctl.d/99-vps-manager-bbr.conf 0644; then
    rm -f -- "$temporary" "$backup"
    error "无法写入 BBR 配置。"
    return 1
  fi
  rm -f -- "$temporary"
  if log_command interactive sysctl --system; then
    rm -f -- "$backup"
    ok "BBR 配置已写入 /etc/sysctl.d/99-vps-manager-bbr.conf"
    bbr_status
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
      info "BBR 已即时生效，通常不需要重启。"
      offer_reboot "如需验证开机后 BBR 配置，可选择现在重启；通常可以跳过。"
    elif reboot_required; then
      offer_reboot "BBR 配置已写入，但系统同时标记为需要重启。"
    fi
  else
    if [[ -n "$backup" ]]; then
      atomic_install_file "$backup" /etc/sysctl.d/99-vps-manager-bbr.conf 0644 || true
    else
      rm -f -- /etc/sysctl.d/99-vps-manager-bbr.conf
    fi
    rm -f -- "$backup"
    log_command quiet sysctl --system || true
    error "应用 sysctl 配置失败，已恢复原配置。"
    return 1
  fi
}

disable_bbr() {
  local backup
  require_root
  [[ -f /etc/sysctl.d/99-vps-manager-bbr.conf ]] || { info "vps-manager 没有创建 BBR 配置。"; return 0; }
  warn "只会删除 vps-manager 创建的 BBR sysctl 文件。"
  confirm "确认移除 BBR 配置？" || return 0
  backup="$(mktemp /tmp/vps-manager-bbr-original.XXXXXX)" || return 1
  cp -a -- /etc/sysctl.d/99-vps-manager-bbr.conf "$backup" || { rm -f -- "$backup"; return 1; }
  rm -f -- /etc/sysctl.d/99-vps-manager-bbr.conf
  if ! log_command quiet sysctl --system; then
    atomic_install_file "$backup" /etc/sysctl.d/99-vps-manager-bbr.conf 0644 || true
    rm -f -- "$backup"
    log_command quiet sysctl --system || true
    error "重新加载 sysctl 失败，已恢复 BBR 配置。"
    return 1
  fi
  rm -f -- "$backup"
  ok "已移除 vps-manager 的 BBR 配置，系统已重新加载现有 sysctl。"
}

bbr_menu() {
  local choice
  while true; do
    printf '\nBBR 与网络优化：\n'
    printf '  1. 查看 BBR 状态\n'
    printf '  2. 启用 BBR\n'
    printf '  3. 移除 vps-manager 的 BBR 配置\n'
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
      3) disable_bbr; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_swap_status() {
  printf '内存与 Swap：\n'
  free -h 2>/dev/null || true
  printf '\n活动 Swap：\n'
  if command -v swapon >/dev/null 2>&1; then
    swapon --show --output=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || true
  fi
  printf '\n持久化配置：\n'
  grep -E '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null || printf '  未发现 fstab Swap 条目\n'
  [[ -e "$SWAP_FILE" ]] && ls -lh "$SWAP_FILE"
}

create_swap() {
  local size_gb available_kb required_kb target_dir temp_fstab temp_sysctl
  require_root
  require_ubuntu || return 1
  ensure_command mkswap util-linux || return 1
  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
    info "${SWAP_FILE} 已作为 Swap 启用。"
    show_swap_status
    return 0
  fi
  if [[ -e "$SWAP_FILE" ]]; then
    error "${SWAP_FILE} 已存在但未作为 Swap 启用，脚本不会覆盖。"
    return 1
  fi
  read -r -p "Swap 大小 GiB [2]：" size_gb
  size_gb="${size_gb:-2}"
  if [[ ! "$size_gb" =~ ^[0-9]+$ ]] || (( size_gb < 1 || size_gb > 64 )); then
    error "Swap 大小必须是 1 到 64 GiB 的整数。"
    return 1
  fi
  target_dir="$(dirname "$SWAP_FILE")"
  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  required_kb=$((size_gb * 1024 * 1024 + 512 * 1024))
  if [[ ! "$available_kb" =~ ^[0-9]+$ ]] || (( available_kb < required_kb )); then
    error "磁盘可用空间不足；创建 ${size_gb} GiB Swap 后至少需要保留 512 MiB。"
    return 1
  fi
  printf '准备创建 %s GiB Swap：%s\n' "$size_gb" "$SWAP_FILE"
  confirm "确认创建并设置开机启用？" || return 0
  if ! fallocate -l "${size_gb}G" "$SWAP_FILE" 2>/dev/null; then
    warn "fallocate 不可用，改用 dd 创建，可能需要一些时间。"
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$((size_gb * 1024))" status=progress || { rm -f "$SWAP_FILE"; return 1; }
  fi
  chmod 0600 "$SWAP_FILE"
  if ! mkswap "$SWAP_FILE" || ! swapon "$SWAP_FILE"; then
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f "$SWAP_FILE"
    error "Swap 初始化失败，已清理候选文件。"
    return 1
  fi
  if ! awk -v file="$SWAP_FILE" '$1==file && $3=="swap" {found=1} END {exit !found}' /etc/fstab; then
    temp_fstab="$(mktemp /tmp/vps-manager-fstab.XXXXXX)" || {
      swapoff "$SWAP_FILE" 2>/dev/null || true
      rm -f -- "$SWAP_FILE"
      return 1
    }
    if ! cp -a -- /etc/fstab "$temp_fstab" ||
       ! printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> "$temp_fstab" ||
       ! atomic_install_file "$temp_fstab" /etc/fstab 0644; then
      rm -f -- "$temp_fstab"
      swapoff "$SWAP_FILE" 2>/dev/null || true
      rm -f -- "$SWAP_FILE"
      error "写入 /etc/fstab 失败，已撤销新 Swap。"
      return 1
    fi
    rm -f -- "$temp_fstab"
  fi
  temp_sysctl="$(mktemp /tmp/vps-manager-swap-sysctl.XXXXXX)" || return 1
  printf 'vm.swappiness=10\n' > "$temp_sysctl"
  if ! atomic_install_file "$temp_sysctl" "$SWAP_SYSCTL_FILE" 0644; then
    rm -f -- "$temp_sysctl"
    warn "Swap 已启用，但无法写入 swappiness 持久配置。"
    return 1
  fi
  rm -f -- "$temp_sysctl"
  sysctl -p "$SWAP_SYSCTL_FILE" >/dev/null 2>&1 || warn "Swap 已启用，但 vm.swappiness 未能立即应用。"
  ok "Swap 已创建并启用。"
  log_line "swap created: ${SWAP_FILE} ${size_gb}GiB"
  show_swap_status
}

delete_swap() {
  local temp_fstab original_fstab was_active=0
  require_root
  [[ -e "$SWAP_FILE" ]] || { info "未发现 vps-manager 默认 Swap 文件：${SWAP_FILE}"; return 0; }
  warn "将停用并删除 ${SWAP_FILE}，释放其占用的磁盘空间。"
  show_swap_status
  confirm "确认删除该 Swap？" || return 0
  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
    was_active=1
    swapoff "$SWAP_FILE" || { error "无法停用 Swap，已停止删除。"; return 1; }
  fi
  temp_fstab="$(mktemp /tmp/vps-manager-fstab.XXXXXX)" || {
    (( was_active == 0 )) || swapon "$SWAP_FILE" 2>/dev/null || true
    return 1
  }
  original_fstab="$(mktemp /tmp/vps-manager-fstab-original.XXXXXX)" || {
    rm -f -- "$temp_fstab"
    (( was_active == 0 )) || swapon "$SWAP_FILE" 2>/dev/null || true
    return 1
  }
  if ! cp -a -- /etc/fstab "$original_fstab" ||
     ! awk -v file="$SWAP_FILE" '$1 != file' /etc/fstab > "$temp_fstab" ||
     ! atomic_install_file "$temp_fstab" /etc/fstab 0644; then
    rm -f -- "$temp_fstab" "$original_fstab"
    (( was_active == 0 )) || swapon "$SWAP_FILE" 2>/dev/null || true
    error "更新 /etc/fstab 失败，未删除 Swap 文件。"
    return 1
  fi
  rm -f -- "$temp_fstab"
  if ! rm -f -- "$SWAP_FILE"; then
    atomic_install_file "$original_fstab" /etc/fstab 0644 || true
    (( was_active == 0 )) || swapon "$SWAP_FILE" 2>/dev/null || true
    rm -f -- "$original_fstab"
    error "无法删除 ${SWAP_FILE}，已尝试恢复 /etc/fstab 和 Swap 状态。"
    return 1
  fi
  rm -f -- "$original_fstab"
  rm -f -- "$SWAP_SYSCTL_FILE"
  ok "${SWAP_FILE} 已删除。"
  log_line "swap deleted: ${SWAP_FILE}"
  show_swap_status
}

swap_menu() {
  local choice
  require_root
  while true; do
    printf '\nSwap 管理：\n'
    printf '  1. 查看内存与 Swap\n'
    printf '  2. 创建并启用 Swap\n'
    printf '  3. 删除 vps-manager 管理的 Swap\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_swap_status; pause ;;
      2) create_swap; pause ;;
      3) delete_swap; pause ;;
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
  local label="$1" dns="$2" fallback="$3" resolved_file="/etc/systemd/resolved.conf" rollback
  require_root
  require_ubuntu || return 1
  printf 'DNS 方案：%s\n' "$label"
  printf 'DNS=%s\nFallbackDNS=%s\n' "$dns" "$fallback"
  confirm "确认修改 DNS 配置？" || return 0

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$resolved_file" ]]; then
    rollback="$(mktemp /tmp/vps-manager-resolved.XXXXXX)" || return 1
    cp -a -- "$resolved_file" "$rollback" || { rm -f -- "$rollback"; return 1; }
    backup_file "$resolved_file" || { rm -f -- "$rollback"; return 1; }
    if set_resolved_key "$resolved_file" DNS "$dns" &&
       set_resolved_key "$resolved_file" FallbackDNS "$fallback" &&
       systemctl restart systemd-resolved; then
      rm -f -- "$rollback"
      ok "systemd-resolved DNS 已更新。"
      show_dns_status
      return 0
    fi
    cp -a -- "$rollback" "$resolved_file" || true
    rm -f -- "$rollback"
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    error "DNS 配置应用失败，已恢复原配置。"
    return 1
  fi

  rollback="$(mktemp /tmp/vps-manager-resolv.XXXXXX)" || return 1
  if ! cp -L -- /etc/resolv.conf "$rollback"; then
    rm -f -- "$rollback"
    return 1
  fi
  backup_file /etc/resolv.conf || { rm -f -- "$rollback"; return 1; }
  if ! {
    printf '# Managed by vps-manager on %s\n' "$(date '+%F %T %z')"
    for server in $dns $fallback; do
      printf 'nameserver %s\n' "$server"
    done
  } > /etc/resolv.conf; then
    cat "$rollback" > /etc/resolv.conf || true
    rm -f -- "$rollback"
    error "写入 /etc/resolv.conf 失败，已尝试恢复原内容。"
    return 1
  fi
  rm -f -- "$rollback"
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

current_ssh_port() {
  local sshd
  sshd="$(sshd_bin)"
  if [[ -x "$sshd" ]]; then
    "$sshd" -T 2>/dev/null | awk '$1=="port" {print $2; found=1; exit} END {if(!found) print 22}'
  else
    printf '22\n'
  fi
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
  printf '\nvps-manager 管理文件：%s\n' "$SSHD_MANAGED_FILE"
  sed -n '1,80p' "$SSHD_MANAGED_FILE" 2>/dev/null || printf '  尚未创建\n'
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
  local option="$1" value="$2" config backup="" sshd effective key had_file=0
  require_root
  require_ubuntu || return 1
  config="$(sshd_config_file)"
  sshd="$(sshd_bin)"
  [[ -f "$config" ]] || { error "未找到 ${config}。"; return 1; }
  [[ -x "$sshd" ]] || { error "未找到 sshd。"; return 1; }

  show_ssh_status
  printf '\n准备设置：%s %s\n' "$option" "$value"
  confirm "确认修改 SSH 配置？" || return 0
  install -d -m 0755 "$(dirname "$SSHD_MANAGED_FILE")"
  if [[ -f "$SSHD_MANAGED_FILE" ]]; then
    had_file=1
    install -d -m 0700 "$BACKUP_ROOT" || return 1
    backup="${BACKUP_ROOT}/etc_ssh_sshd_config.d_00-vps-manager.conf.bak.$(date '+%Y%m%d-%H%M%S').$$"
    cp -a -- "$SSHD_MANAGED_FILE" "$backup" || { error "无法备份 SSH 管理配置。"; return 1; }
  elif ! : > "$SSHD_MANAGED_FILE"; then
    error "无法创建 SSH 管理配置。"
    return 1
  fi
  if ! set_sshd_option_in_file "$SSHD_MANAGED_FILE" "$option" "$value" || ! chmod 0644 "$SSHD_MANAGED_FILE"; then
    if (( had_file )); then cp -a -- "$backup" "$SSHD_MANAGED_FILE"; else rm -f -- "$SSHD_MANAGED_FILE"; fi
    error "写入 SSH 管理配置失败，已恢复。"
    return 1
  fi

  if "$sshd" -t -f "$config"; then
    key="${option,,}"
    effective="$("$sshd" -T -f "$config" 2>/dev/null | awk -v key="$key" '$1==key {print $2; exit}')"
    if [[ "${effective,,}" == "${value,,}" ]]; then
      if reload_ssh_service; then
        ok "SSH 配置已更新并重载：${SSHD_MANAGED_FILE}"
        [[ -n "$backup" ]] && info "备份：${backup}"
        return 0
      fi
      warn "配置校验通过，但 SSH 服务重载失败，正在恢复。"
    else
      error "最终生效值为 ${effective:-未知}，不是目标值 ${value}，正在恢复。"
    fi
  else
    error "SSH 配置语法校验失败，正在恢复。"
  fi

  if (( had_file )); then
    cp -a -- "$backup" "$SSHD_MANAGED_FILE"
  else
    rm -f -- "$SSHD_MANAGED_FILE"
  fi
  reload_ssh_service || true
  return 1
}

change_ssh_port() {
  local port old_port
  old_port="$(current_ssh_port)"
  read -r -p "新的 SSH 端口（1-65535）：" port
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
    error "端口不正确。"
    return 1
  fi
  [[ "$port" != "$old_port" ]] || { info "SSH 当前已经使用端口 ${port}。"; return 0; }
  warn "请先在 VPS 控制台安全组中放行 ${port}/tcp，并保留当前 SSH 会话用于回退。"
  confirm "确认安全组已放行并继续？" || return 0
  if ufw_is_active; then
    info "检测到 UFW 已启用，先放行新的 SSH TCP ${port}。"
    log_command interactive ufw allow "${port}/tcp" comment "SSH added by vps-manager" || return 1
  fi
  if apply_sshd_option Port "$port"; then
    sync_fail2ban_ssh_port "$port" || true
    ok "SSH 已改为 ${port}/tcp；旧端口 ${old_port}/tcp 未自动删除，请用新会话验证后再清理。"
  fi
}

authorized_keys_present() {
  local file
  for file in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$file" ]] && return 0
  done
  return 1
}

disable_password_login() {
  if ! authorized_keys_present; then
    error "未发现任何非空 authorized_keys，拒绝关闭密码登录，以免锁定 SSH。"
    return 1
  fi
  warn "关闭密码登录前，请保持当前会话，并另开窗口验证公钥登录。"
  apply_sshd_option PasswordAuthentication no
}

disable_root_login() {
  warn "关闭 root 登录前，请确认至少有一个可用的 sudo 用户和已验证的新 SSH 会话。"
  apply_sshd_option PermitRootLogin no
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
      3) disable_root_login; pause ;;
      4) warn "开启密码登录会增加暴力破解风险。"; apply_sshd_option PasswordAuthentication yes; pause ;;
      5) disable_password_login; pause ;;
      6) change_ssh_port; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_fail2ban_status() {
  local status service_state enabled_state port="未知" current_failed=0 total_failed=0 current_banned=0 total_banned=0 banned_list=""
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    printf 'Fail2ban：未安装\n'
    return 0
  fi
  service_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
  enabled_state="$(systemctl is-enabled fail2ban 2>/dev/null || true)"
  [[ "$service_state" == "active" ]] || {
    printf 'Fail2ban：未运行\n'
    printf '开机启动：%s\n' "${enabled_state:-未知}"
    return 0
  }
  if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    port="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$FAIL2BAN_JAIL_FILE")"
  fi
  status="$(fail2ban-client status sshd 2>/dev/null || true)"
  [[ -n "$status" ]] || {
    printf 'Fail2ban：运行中\nSSH 保护：未启用\n'
    return 0
  }
  current_failed="$(printf '%s\n' "$status" | awk -F: '/Currently failed/{gsub(/[[:space:]]/, "", $2); print $2}')"
  total_failed="$(printf '%s\n' "$status" | awk -F: '/Total failed/{gsub(/[[:space:]]/, "", $2); print $2}')"
  current_banned="$(printf '%s\n' "$status" | awk -F: '/Currently banned/{gsub(/[[:space:]]/, "", $2); print $2}')"
  total_banned="$(printf '%s\n' "$status" | awk -F: '/Total banned/{gsub(/[[:space:]]/, "", $2); print $2}')"
  banned_list="$(printf '%s\n' "$status" | awk -F: '/Banned IP list/{sub(/^[[:space:]]+/, "", $2); print $2}')"
  printf 'Fail2ban：运行中\n'
  printf 'SSH 保护：已启用（端口 %s）\n' "${port:-未知}"
  printf '失败登录：当前 %s，累计 %s\n' "${current_failed:-0}" "${total_failed:-0}"
  printf '封禁地址：当前 %s，累计 %s\n' "${current_banned:-0}" "${total_banned:-0}"
  [[ -z "$banned_list" ]] || printf '当前名单：%s\n' "$banned_list"
  printf '规则：10 分钟失败 5 次，封禁 1 小时\n'
}

sync_fail2ban_ssh_port() {
  local port="$1" backup
  [[ -f "$FAIL2BAN_JAIL_FILE" ]] || return 0
  backup="$(mktemp /tmp/vps-manager-fail2ban.XXXXXX)" || return 1
  cp -a -- "$FAIL2BAN_JAIL_FILE" "$backup" || { rm -f -- "$backup"; return 1; }
  if sed -i -E "s/^port[[:space:]]*=.*/port = ${port}/" "$FAIL2BAN_JAIL_FILE" &&
     command -v fail2ban-client >/dev/null 2>&1 &&
     fail2ban-client -t >/dev/null 2>&1 &&
     systemctl restart fail2ban >/dev/null 2>&1; then
    rm -f -- "$backup"
    ok "Fail2ban SSH jail 已同步到端口 ${port}。"
    return 0
  fi
  cp -a -- "$backup" "$FAIL2BAN_JAIL_FILE" || true
  rm -f -- "$backup"
  systemctl restart fail2ban >/dev/null 2>&1 || true
  warn "Fail2ban 端口同步失败，已恢复原配置。"
  return 1
}

enable_fail2ban() {
  local port backup=""
  require_root
  require_ubuntu || return 1
  port="$(current_ssh_port)"
  info "将安装 Fail2ban，并保护当前 SSH TCP ${port}。"
  confirm "确认安装并启用 SSH 防暴力破解？" || return 0
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || return 1
  install -d -m 0755 "$(dirname "$FAIL2BAN_JAIL_FILE")"
  if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    install -d -m 0700 "$BACKUP_ROOT" || return 1
    backup="${BACKUP_ROOT}/etc_fail2ban_jail.d_vps-manager-sshd.local.bak.$(date '+%Y%m%d-%H%M%S').$$"
    cp -a -- "$FAIL2BAN_JAIL_FILE" "$backup" || { error "无法备份现有 Fail2ban 配置。"; return 1; }
  fi
  {
    printf '[sshd]\n'
    printf 'enabled = true\n'
    printf 'port = %s\n' "$port"
    printf 'backend = systemd\n'
    printf 'maxretry = 5\n'
    printf 'findtime = 10m\n'
    printf 'bantime = 1h\n'
  } > "$FAIL2BAN_JAIL_FILE"
  chmod 0644 "$FAIL2BAN_JAIL_FILE"
  if ! fail2ban-client -t; then
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$FAIL2BAN_JAIL_FILE"; else rm -f -- "$FAIL2BAN_JAIL_FILE"; fi
    error "Fail2ban 配置测试失败，已恢复。"
    return 1
  fi
  systemctl enable fail2ban >/dev/null 2>&1 || warn "Fail2ban 开机启动设置失败，请稍后检查。"
  if ! systemctl restart fail2ban; then
    if [[ -n "$backup" ]]; then cp -a -- "$backup" "$FAIL2BAN_JAIL_FILE"; else rm -f -- "$FAIL2BAN_JAIL_FILE"; fi
    systemctl restart fail2ban >/dev/null 2>&1 || true
    error "Fail2ban 启动失败，已恢复原配置。"
    return 1
  fi
  ok "Fail2ban SSH 防护已启用：5 次失败/10 分钟，封禁 1 小时。"
  log_line "fail2ban sshd enabled on port ${port}"
  show_fail2ban_status
}

disable_fail2ban() {
  local backup
  require_root
  [[ -f "$FAIL2BAN_JAIL_FILE" ]] || { info "未发现 vps-manager 管理的 Fail2ban SSH jail。"; return 0; }
  warn "只会移除 vps-manager 的 SSH jail，不卸载 Fail2ban，也不删除其他 jail。"
  confirm "确认关闭该 SSH jail？" || return 0
  backup="$(mktemp /tmp/vps-manager-fail2ban.XXXXXX)" || return 1
  cp -a -- "$FAIL2BAN_JAIL_FILE" "$backup" || { rm -f -- "$backup"; return 1; }
  rm -f -- "$FAIL2BAN_JAIL_FILE"
  if command -v fail2ban-client >/dev/null 2>&1 && ! systemctl restart fail2ban; then
    cp -a -- "$backup" "$FAIL2BAN_JAIL_FILE" || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
    rm -f -- "$backup"
    error "Fail2ban 重启失败，已恢复 SSH jail。"
    return 1
  fi
  rm -f -- "$backup"
  ok "vps-manager 的 Fail2ban SSH jail 已移除。"
}

show_auto_updates_status() {
  local list_state="未启用" upgrade_state="未启用" reboot_state="未明确关闭" timer_state="异常"
  if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    printf '自动安全更新：未安装\n'
    return 0
  fi
  grep -q 'APT::Periodic::Update-Package-Lists "1";' "$AUTO_UPGRADES_FILE" 2>/dev/null && list_state="每天"
  grep -q 'APT::Periodic::Unattended-Upgrade "1";' "$AUTO_UPGRADES_FILE" 2>/dev/null && upgrade_state="每天"
  grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' "$AUTO_UPGRADES_OPTIONS_FILE" 2>/dev/null && reboot_state="关闭"
  if systemctl is-active --quiet apt-daily.timer 2>/dev/null && systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
    timer_state="正常"
  fi
  printf '自动安全更新：已安装\n'
  printf '软件包列表更新：%s\n' "$list_state"
  printf '安全更新安装：%s\n' "$upgrade_state"
  printf '自动重启：%s\n' "$reboot_state"
  printf 'APT 定时器：%s\n' "$timer_state"
}

enable_auto_updates() {
  require_root
  require_ubuntu || return 1
  info "只启用 Ubuntu unattended-upgrades 的安全更新；不会自动重启。"
  confirm "确认安装并启用自动安全更新？" || return 0
  relocate_legacy_apt_backups || { error "迁移旧版 APT 备份失败，已停止配置。"; return 1; }
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1
  backup_file "$AUTO_UPGRADES_FILE" || return 1
  backup_file "$AUTO_UPGRADES_OPTIONS_FILE" || return 1
  {
    printf 'APT::Periodic::Update-Package-Lists "1";\n'
    printf 'APT::Periodic::Unattended-Upgrade "1";\n'
  } > "$AUTO_UPGRADES_FILE"
  {
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n'
    printf 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";\n'
  } > "$AUTO_UPGRADES_OPTIONS_FILE"
  chmod 0644 "$AUTO_UPGRADES_FILE" "$AUTO_UPGRADES_OPTIONS_FILE"
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  ok "自动安全更新已启用，自动重启保持关闭。"
  log_line "unattended-upgrades enabled without automatic reboot"
  show_auto_updates_status
}

disable_auto_updates() {
  require_root
  warn "不会卸载 unattended-upgrades，只会关闭周期执行并删除脚本管理的附加选项。"
  confirm "确认关闭自动安全更新？" || return 0
  {
    printf 'APT::Periodic::Update-Package-Lists "0";\n'
    printf 'APT::Periodic::Unattended-Upgrade "0";\n'
  } > "$AUTO_UPGRADES_FILE"
  rm -f "$AUTO_UPGRADES_OPTIONS_FILE"
  ok "自动安全更新周期已关闭。"
}

security_menu() {
  local choice
  require_root
  while true; do
    printf '\n安全防护：\n'
    printf '  1. 查看 Fail2ban 状态\n'
    printf '  2. 安装/更新并启用 Fail2ban SSH jail\n'
    printf '  3. 关闭 vps-manager 的 Fail2ban SSH jail\n'
    printf '  4. 查看自动安全更新状态\n'
    printf '  5. 安装并启用自动安全更新\n'
    printf '  6. 关闭自动安全更新\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_fail2ban_status; pause ;;
      2) enable_fail2ban; pause ;;
      3) disable_fail2ban; pause ;;
      4) show_auto_updates_status; pause ;;
      5) enable_auto_updates; pause ;;
      6) disable_auto_updates; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

http_access_status() {
  local url="$1" code
  code="$(curl -4 -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36' \
    -sS -L --connect-timeout 4 -m 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  case "$code" in
    2??|3??|400|401|404|405|409|422|429) printf '可以访问' ;;
    403|451) printf '不可访问' ;;
    *) printf '检测失败' ;;
  esac
}

show_access_origin() {
  local trace ip country
  trace="$(curl -4 -fsS --connect-timeout 4 -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  ip="$(printf '%s\n' "$trace" | awk -F= '$1=="ip" {print $2; exit}')"
  country="$(printf '%s\n' "$trace" | awk -F= '$1=="loc" {print $2; exit}')"
  printf '公网 IPv4：%s\n' "${ip:-不可用}"
  printf '出口地区：%s\n' "${country:-未知}"
}

check_service_access() {
  local temporary i status
  local -a labels=(OpenAI Gemini Claude Netflix Disney+ YouTube)
  local -a urls=(
    "https://api.openai.com/v1/models"
    "https://gemini.google.com/"
    "https://claude.ai/"
    "https://www.netflix.com/"
    "https://www.disneyplus.com/"
    "https://www.youtube.com/premium"
  )
  command -v curl >/dev/null 2>&1 || { error "缺少 curl，无法执行访问检测。"; return 1; }
  temporary="$(mktemp -d /tmp/vps-manager-access.XXXXXX)" || return 1
  printf '\n%sAI 与流媒体访问检测%s\n' "$C_BOLD" "$C_RESET"
  show_access_origin
  printf '\n'
  for i in "${!labels[@]}"; do
    http_access_status "${urls[$i]}" > "$temporary/$i" &
  done
  wait
  for i in "${!labels[@]}"; do
    status="$(<"$temporary/$i")"
    printf '  %-10s %s\n' "${labels[$i]}" "${status:-检测失败}"
  done
  rm -f -- "$temporary"/{0..5}
  rmdir -- "$temporary" 2>/dev/null || true
  printf '\n结果只代表当前 VPS 的网络可达性，不代表账号、订阅或具体内容一定可用。\n'
}

show_public_ip() {
  command -v curl >/dev/null 2>&1 || { warn "缺少 curl，无法获取公网 IP。"; return 0; }
  printf 'IPv4：%s\n' "$(curl -4 -fsS -m 8 https://api64.ipify.org 2>/dev/null || printf '不可用')"
  printf 'IPv6：%s\n' "$(curl -6 -fsS -m 8 https://api64.ipify.org 2>/dev/null || printf '不可用')"
}

show_docker_status() {
  local active="未运行" enabled="未启用"
  if command -v docker >/dev/null 2>&1; then
    docker --version 2>/dev/null || true
    docker compose version 2>/dev/null || true
    docker buildx version 2>/dev/null || true
  else
    printf 'Docker：未安装\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    active="$(systemctl is-active docker 2>/dev/null || true)"
    enabled="$(systemctl is-enabled docker 2>/dev/null || true)"
    printf 'Docker 服务：%s\n' "${active:-未运行}"
    printf '开机启动：%s\n' "${enabled:-未启用}"
  fi
  [[ -f "$DOCKER_SOURCE_FILE" ]] && { printf '\nDocker 官方源：\n'; sed -n '1,80p' "$DOCKER_SOURCE_FILE"; }
}

install_docker_official() {
  local codename architecture package
  local -a conflicts=() conflict_packages=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
  require_root
  require_ubuntu || return 1
  codename="$(
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  )"
  architecture="$(dpkg --print-architecture)"
  [[ -n "$codename" && -n "$architecture" ]] || { error "无法识别 Ubuntu 代号或架构。"; return 1; }
  case "$architecture" in
    amd64|armhf|arm64|s390x|ppc64el) ;;
    *) error "Docker 官方 Ubuntu 仓库不支持当前架构：${architecture}"; return 1 ;;
  esac
  case "$codename" in
    jammy|noble|questing|resolute) ;;
    *)
      warn "当前 Ubuntu 代号 ${codename} 不在脚本已知的 Docker 官方支持列表。"
      confirm "仍要尝试使用 Docker 官方仓库？" || return 0
      ;;
  esac
  for package in "${conflict_packages[@]}"; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      conflicts+=("$package")
    fi
  done
  info "准备配置 Docker 官方 Ubuntu 仓库：${codename}/${architecture}。"
  if (( ${#conflicts[@]} > 0 )); then
    warn "检测到与 Docker CE 官方包冲突的软件包：${conflicts[*]}"
    warn "继续安装前必须移除这些包；不会自动删除 /var/lib/docker，但现有容器服务可能中断。"
  fi
  confirm "确认开始安装或更新 Docker Engine？" || return 0
  acquire_lock || return 1
  if (( ${#conflicts[@]} > 0 )); then
    confirm "再次确认移除冲突包并继续安装 Docker？" || return 0
    log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicts[@]}" || return 1
  fi
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl || return 1
  install -d -m 0755 /etc/apt/keyrings
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEY_FILE"; then
    error "Docker 官方 GPG key 下载失败。"
    return 1
  fi
  chmod a+r "$DOCKER_KEY_FILE"
  {
    printf 'Types: deb\n'
    printf 'URIs: https://download.docker.com/linux/ubuntu\n'
    printf 'Suites: %s\n' "$codename"
    printf 'Components: stable\n'
    printf 'Architectures: %s\n' "$architecture"
    printf 'Signed-By: %s\n' "$DOCKER_KEY_FILE"
  } > "$DOCKER_SOURCE_FILE"
  chmod 0644 "$DOCKER_SOURCE_FILE"
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  systemctl enable --now docker || { error "Docker 服务启动失败。"; return 1; }
  ok "Docker Engine、Buildx 和 Compose 插件已安装。"
  log_line "docker official engine installed for ${codename}/${architecture}"
  show_docker_status
}

add_user_to_docker_group() {
  local username="${1:-}"
  require_root
  command -v docker >/dev/null 2>&1 || { error "请先安装 Docker。"; return 1; }
  if [[ -z "$username" ]]; then
    read -r -p "要加入 docker 组的现有用户名：" username
  fi
  id "$username" >/dev/null 2>&1 || { error "用户不存在：${username}"; return 1; }
  warn "docker 组成员可以控制 Docker daemon，权限实际等同 root。"
  confirm "确认将 ${username} 加入 docker 组？" || return 0
  groupadd -f docker
  usermod -aG docker "$username"
  ok "${username} 已加入 docker 组；需要重新登录后生效。"
}

test_docker() {
  require_root
  command -v docker >/dev/null 2>&1 || { error "Docker 尚未安装。"; return 1; }
  warn "测试会从 Docker Hub 拉取 hello-world 镜像并运行一次。"
  confirm "确认运行 Docker 测试？" || return 0
  log_command interactive docker run --rm hello-world
}

docker_menu() {
  local choice
  require_root
  while true; do
    printf '\nDocker 管理：\n'
    printf '  1. 查看 Docker 状态\n'
    printf '  2. 按官方 Ubuntu 流程安装/更新 Docker\n'
    printf '  3. 将现有用户加入 docker 组\n'
    printf '  4. 运行 hello-world 测试\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) show_docker_status; pause ;;
      2) install_docker_official; pause ;;
      3) add_user_to_docker_group; pause ;;
      4) test_docker; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

show_status() {
  print_os_summary
  printf '\n主机名：\n'
  show_hostname
  printf '\n内存与 Swap：\n'
  free -h 2>/dev/null || true
  swapon --show 2>/dev/null || true
  printf '\n根分区：\n'
  df -h / 2>/dev/null || true
  printf '\n重启状态：\n'
  show_reboot_status
  printf '\n公网 IP：\n'
  show_public_ip
  printf '\nSSH：\n'
  show_ssh_status
  printf '\n防火墙：\n'
  show_firewall_status
  printf '\nBBR：\n'
  bbr_status
  printf '\nFail2ban：\n'
  show_fail2ban_status
  printf '\n自动安全更新：\n'
  show_auto_updates_status
  printf '\nDocker：\n'
  show_docker_status
  printf '\nDNS：\n'
  show_dns_status
}

show_log() {
  local events
  if [[ ! -f "$LOG_FILE" ]]; then
    info "暂无操作记录。"
    return 0
  fi
  events="$(grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} ' "$LOG_FILE" 2>/dev/null | tail -n 20 || true)"
  if [[ -n "$events" ]]; then
    printf '%s\n' "$events"
  else
    info "暂无操作记录。"
  fi
}

trim_manager_log_if_large() {
  local size temporary
  [[ -f "$LOG_FILE" ]] || return 0
  size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  (( size > 5 * 1024 * 1024 )) || return 0
  temporary="$(mktemp "${LOG_ROOT}/.vps-manager-log.XXXXXX")" || return 1
  if ! tail -n 2000 "$LOG_FILE" > "$temporary" || ! atomic_install_file "$temporary" "$LOG_FILE" 0600; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
  ok "管理器日志超过 5 MiB，已保留最近 2000 行。"
}

safe_system_cleanup() {
  local before_kb after_kb freed_kb actions=0 failures=0
  require_root
  require_ubuntu || return 1
  printf '\n%s保守系统清理范围%s\n' "$C_BOLD" "$C_RESET"
  printf '  - 清理 APT 下载缓存（不卸载软件）\n'
  printf '  - 按 systemd-tmpfiles 系统策略清理过期临时文件\n'
  printf '  - 清理 14 天以前的 systemd journal 归档\n'
  printf '  - vps-manager.log 超过 5 MiB 时保留最近 2000 行\n'
  printf '明确不会执行：autoremove、Docker prune、证书/密钥删除、用户目录扫描、防火墙清空。\n'
  confirm "确认执行以上保守清理？" || return 0
  acquire_lock || return 1
  relocate_legacy_apt_backups || { error "迁移旧版 APT 备份失败，已停止清理。"; return 1; }

  before_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}' || printf '0')"
  if command -v apt-get >/dev/null 2>&1; then
    actions=$((actions + 1))
    apt-get clean || failures=$((failures + 1))
  else
    info "未找到 apt-get，跳过软件包缓存。"
  fi
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    actions=$((actions + 1))
    systemd-tmpfiles --clean || failures=$((failures + 1))
  fi
  if command -v journalctl >/dev/null 2>&1; then
    actions=$((actions + 1))
    journalctl --vacuum-time=14d || failures=$((failures + 1))
  fi
  actions=$((actions + 1))
  trim_manager_log_if_large || failures=$((failures + 1))

  after_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}' || printf '0')"
  if [[ "$before_kb" =~ ^[0-9]+$ && "$after_kb" =~ ^[0-9]+$ && "$before_kb" -ge "$after_kb" ]]; then
    freed_kb=$((before_kb - after_kb))
  else
    freed_kb=0
  fi
  if (( failures == 0 )); then
    ok "保守系统清理完成，共执行 ${actions} 项，约释放 $((freed_kb / 1024)) MiB。"
    log_line "safe system cleanup completed: actions=${actions} freed_mib=$((freed_kb / 1024))"
  else
    warn "保守系统清理完成，但 ${failures}/${actions} 项失败；未执行激进删除。"
    log_line "safe system cleanup completed with failures: ${failures}/${actions}"
    return 1
  fi
}

system_menu() {
  local choice timezone
  require_root
  require_ubuntu || return 1
  while true; do
    printf '\n系统与主机设置：\n'
    printf '  1. 完整系统升级\n'
    printf '  2. 查看/设置主机名\n'
    printf '  3. 设置时区\n'
    printf '  4. 安装常用依赖\n'
    printf '  5. 查看是否需要重启\n'
    printf '  6. 立即重启\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice
    case "$choice" in
      1) system_upgrade; pause ;;
      2) set_hostname; pause ;;
      3)
        read -r -p "时区 [${DEFAULT_TIMEZONE}]：" timezone
        set_timezone "${timezone:-$DEFAULT_TIMEZONE}"
        pause
        ;;
      4) install_common_dependencies; pause ;;
      5) show_reboot_status; pause ;;
      6) offer_reboot "用户从系统菜单请求立即重启。" ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

init_wizard() {
  require_root
  require_ubuntu || return 1
  banner
  info "基础初始化会逐项确认，不会静默修改系统关键配置。"
  if confirm "是否设置统一主机名？"; then
    set_hostname || warn "主机名设置未完成。"
  fi
  if confirm "是否更新软件源并执行完整系统升级？"; then
    system_upgrade || warn "系统升级步骤失败。"
  fi
  if confirm "是否设置时区为 ${DEFAULT_TIMEZONE}？"; then
    set_timezone "$DEFAULT_TIMEZONE" || warn "时区设置步骤失败。"
  fi
  if confirm "是否安装常用依赖？"; then
    install_common_dependencies || warn "依赖安装步骤失败。"
  fi
  if confirm "是否配置小内存 VPS 的 Swap？"; then
    create_swap || warn "Swap 步骤未完成。"
  fi
  if confirm "是否检查并启用 BBR？"; then
    enable_bbr || warn "BBR 步骤未完成。"
  fi
  if confirm "是否安装并启用 Fail2ban SSH 防护？"; then
    enable_fail2ban || warn "Fail2ban 步骤未完成。"
  fi
  if confirm "是否启用自动安全更新（不自动重启）？"; then
    enable_auto_updates || warn "自动安全更新步骤未完成。"
  fi
  if confirm "是否安装 Docker 官方版本？"; then
    install_docker_official || warn "Docker 步骤未完成。"
  fi
  if confirm "是否配置防火墙模式？"; then
    firewall_menu
  fi
  if confirm "是否进入 DNS 配置向导？"; then
    dns_menu
  fi
  ok "基础初始化向导已结束。"
}

update_manager() {
  local timestamp installer installer_url source_url rc backup="" new_version=""
  require_root
  validate_manager_paths || return 1
  ensure_command curl curl || return 1

  timestamp="$(date +%s)"
  installer_url="${MANAGER_RAW_BASE}/install.sh?ts=${timestamp}"
  source_url="${MANAGER_RAW_BASE}/vps-manager.sh?ts=${timestamp}"
  installer="$(mktemp /tmp/vps-manager-bootstrap.XXXXXX.sh)" || return 1
  if [[ -f "$INSTALL_PATH" ]]; then
    backup="$(mktemp /tmp/vps-manager-current.XXXXXX.sh)" || { rm -f -- "$installer"; return 1; }
    cp -a -- "$INSTALL_PATH" "$backup" || { rm -f -- "$installer" "$backup"; return 1; }
  fi

  info "正在检查 ${MANAGER_REPO}@${MANAGER_REF} 的管理器版本..."
  if ! curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$installer_url" -o "$installer"; then
    rm -f "$installer" "$backup"
    error "无法下载 GitHub 引导安装器。"
    return 1
  fi
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for vps-manager\.$' "$installer"; then
    rm -f "$installer" "$backup"
    error "下载内容未通过安装器校验，拒绝更新。"
    return 1
  fi

  VPS_MANAGER_REPO="$MANAGER_REPO" \
    VPS_MANAGER_REF="$MANAGER_REF" \
    VPS_MANAGER_SOURCE_URL="$source_url" \
    VPS_MANAGER_INSTALL_PATH="$INSTALL_PATH" \
    VPS_MANAGER_ALIAS_PATH="$ALIAS_PATH" \
    bash "$installer" version
  rc=$?
  rm -f "$installer"

  if (( rc != 0 )); then
    if [[ -n "$backup" && -s "$backup" ]]; then
      install -m 0755 "$backup" "$INSTALL_PATH" || true
    fi
    rm -f -- "$backup"
    error "vps-manager 更新失败。"
    return "$rc"
  fi
  new_version="$("$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}')"
  if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
     [[ "$(printf '%s\n' "$VERSION" "$new_version" | sort -V | head -n 1)" != "$VERSION" ]]; then
    if [[ -n "$backup" && -s "$backup" ]]; then
      install -m 0755 "$backup" "$INSTALL_PATH" || true
    else
      rm -f -- "$INSTALL_PATH"
    fi
    rm -f -- "$backup"
    error "远程版本 ${new_version:-未知} 低于或无法验证当前版本 ${VERSION}，已拒绝降级并恢复。"
    return 1
  fi
  rm -f "$backup"
  ok "vps-manager 更新完成：${VERSION} -> ${new_version}"
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
    printf '  1. 基础初始化向导\n'
    printf '  2. 系统升级、主机名、时区与重启\n'
    printf '  3. SSH/root 登录设置\n'
    printf '  4. Fail2ban 与自动安全更新\n'
    printf '  5. 防火墙模式\n'
    printf '  6. BBR 与网络优化\n'
    printf '  7. Swap 管理\n'
    printf '  8. Docker 管理\n'
    printf '  9. DNS 配置\n'
    printf ' 10. AI/流媒体访问检测\n'
    printf ' 11. 系统状态与最近操作\n'
    printf ' 12. 保守系统清理\n'
    printf ' 13. 更新 vps-manager\n'
    printf '  0. 退出\n'
    read -r -p "请选择：" choice
    printf '\n'
    case "$choice" in
      1) init_wizard; pause ;;
      2) system_menu ;;
      3) ssh_menu ;;
      4) security_menu ;;
      5) firewall_menu ;;
      6) bbr_menu ;;
      7) swap_menu ;;
      8) docker_menu ;;
      9) dns_menu ;;
      10) check_service_access; pause ;;
      11) show_status; printf '\n最近操作：\n'; show_log; pause ;;
      12) safe_system_cleanup; pause ;;
      13)
        if update_manager; then
          info "更新结果已显示。按 Enter 重新载入最新版菜单。"
          pause
          exec "$INSTALL_PATH"
        fi
        pause
        ;;
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
    system) system_menu ;;
    ports) firewall_menu ;;
    swap) swap_menu ;;
    security) security_menu ;;
    docker) docker_menu ;;
    hostname) shift; set_hostname "${1:-}" ;;
    check-ai|check-media) check_service_access ;;
    cleanup-system) safe_system_cleanup ;;
    update|update-manager) update_manager ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${subcommand}"; show_help; return 2 ;;
  esac
}

if [[ "${VPS_MANAGER_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
