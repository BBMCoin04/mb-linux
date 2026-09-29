#!/usr/bin/env bash
# vps-manager: an interactive Ubuntu VPS initialization manager.

set -uo pipefail
umask 077

VERSION="1.5.0"
PROGRAM="vps-manager"
SUPPORTED_UBUNTU_CODENAMES=(jammy noble questing resolute)
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
MANAGER_REPO="${VPS_MANAGER_REPO:-BBMCoin04/mb-linux}"
MANAGER_REF="${VPS_MANAGER_REF:-main}"
MANAGER_RAW_BASE="https://raw.githubusercontent.com/${MANAGER_REPO}/${MANAGER_REF}"
LOG_ROOT="${LOG_ROOT:-/var/log/vps-manager}"
LOG_FILE="${LOG_ROOT}/vps-manager.log"
BACKUP_ROOT="${VPS_MANAGER_BACKUP_ROOT:-/var/backups/vps-manager}"
LOCK_FILE="/run/lock/vps-manager.lock"
LOCK_HELD=0
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Shanghai}"
DEFAULT_PORTS="${DEFAULT_PORTS:-}"
CONFIG_ROOT="${VPS_MANAGER_CONFIG_ROOT:-/etc/vps-manager}"
PORT_CONFIG_FILE="${VPS_MANAGER_PORT_CONFIG_FILE:-${CONFIG_ROOT}/ports.conf}"
SWAP_FILE="${VPS_MANAGER_SWAP_FILE:-/swapfile}"
SWAP_STATE_FILE="${VPS_MANAGER_SWAP_STATE_FILE:-${CONFIG_ROOT}/swap.conf}"
SWAP_SYSCTL_FILE="/etc/sysctl.d/99-vps-manager-swap.conf"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/vps-manager-sshd.local"
SSHD_MANAGED_FILE="${VPS_MANAGER_SSHD_MANAGED_FILE:-/etc/ssh/sshd_config.d/00-vps-manager.conf}"
CLOUD_HOSTNAME_FILE="${VPS_MANAGER_CLOUD_HOSTNAME_FILE:-/etc/cloud/cloud.cfg.d/99-vps-manager-hostname.cfg}"
RESOLVED_CONFIG_FILE="${VPS_MANAGER_RESOLVED_CONFIG_FILE:-/etc/systemd/resolved.conf}"
RESOLV_CONF_FILE="${VPS_MANAGER_RESOLV_CONF_FILE:-/etc/resolv.conf}"
APT_CONFIG_DIR="${VPS_MANAGER_APT_CONFIG_DIR:-/etc/apt/apt.conf.d}"
AUTO_UPGRADES_FILE="${VPS_MANAGER_AUTO_UPGRADES_FILE:-${APT_CONFIG_DIR}/20auto-upgrades}"
AUTO_UPGRADES_OPTIONS_FILE="${VPS_MANAGER_AUTO_UPGRADES_OPTIONS_FILE:-${APT_CONFIG_DIR}/52vps-manager-unattended-upgrades}"
APT_SOURCE_ROOT="${VPS_MANAGER_APT_SOURCE_ROOT:-/etc/apt}"
DOCKER_KEY_FILE="${VPS_MANAGER_DOCKER_KEY_FILE:-${APT_SOURCE_ROOT}/keyrings/docker.asc}"
DOCKER_SOURCE_FILE="${VPS_MANAGER_DOCKER_SOURCE_FILE:-${APT_SOURCE_ROOT}/sources.list.d/docker.sources}"
ROLLBACK_HELPER="${VPS_MANAGER_ROLLBACK_HELPER:-${INSTALL_PATH}.rollback}"
GUARD_ROOT="${VPS_MANAGER_GUARD_ROOT:-/var/lib/vps-manager/network-guard}"
GUARD_TIMEOUT="${VPS_MANAGER_GUARD_TIMEOUT:-180}"
ACTIVE_GUARD=""
FAIL2BAN_JAIL="sshd"
DOWNLOAD_CONNECT_TIMEOUT=10
DOWNLOAD_TOTAL_TIMEOUT=90
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
  read -r -p "${prompt} [y/N]: " answer || return 1
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
  install -d -m 0700 "$LOG_ROOT" || return 1
  install -d -m 0755 "$(dirname "$LOCK_FILE")" || return 1
}

atomic_install_file() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(mktemp "$(dirname "$target")/.$(basename "$target").XXXXXX")" || return 1
  if ! install -m "$mode" "$source" "$temporary" || ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

save_guard_snapshot() {
  local guard="$1" name="$2" target="$3"
  [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || {
    error "配置路径不是普通文件，停止修改：${target}"
    return 1
  }
  if [[ -f "$target" ]]; then
    cp -a -- "$target" "$guard/$name" && : > "$guard/${name}.exists"
  fi
}

start_network_guard() {
  local kind="$1" guard unit old="" previous_state="" service="ssh.service" executable ufw_status
  [[ "$GUARD_ROOT" == /* && "$GUARD_ROOT" != *[[:space:]]* && ! -L "$GUARD_ROOT" ]] || {
    error "恢复目录必须是普通的绝对目录路径。"; return 1;
  }
  if [[ ! "$GUARD_TIMEOUT" =~ ^[0-9]{2,3}$ ]] || (( 10#$GUARD_TIMEOUT < 60 || 10#$GUARD_TIMEOUT > 900 )); then
    error "恢复等待时间必须为 60–900 秒。"; return 1
  fi
  GUARD_TIMEOUT="$((10#$GUARD_TIMEOUT))"
  for executable in systemd-run systemctl timeout flock; do
    command -v "$executable" >/dev/null 2>&1 || { error "缺少 ${executable}，不能安全安排超时恢复。"; return 1; }
  done
  [[ -f "$ROLLBACK_HELPER" && ! -L "$ROLLBACK_HELPER" ]] || {
    error "缺少配套恢复程序，请先用 v1.5.0 安装器安装完整版本。"; return 1;
  }
  [[ "$(bash "$ROLLBACK_HELPER" version)" == "vps-manager-network-rollback ${VERSION}" ]] || {
    error "恢复程序版本不匹配，请重新运行安装器。"; return 1;
  }
  install -d -m 0700 "$GUARD_ROOT" || return 1
  if [[ -f "$GUARD_ROOT/current" ]]; then
    old="$(<"$GUARD_ROOT/current")"
    if [[ -f "$old/state" ]]; then
      previous_state="$(<"$old/state")"
      case "$previous_state" in
        pending|rolling-back|rollback-failed)
          error "已有待确认或未恢复完成的网络修改（${previous_state}）：${old}"
          info "待确认时可运行 sudo lm confirm-network；恢复失败时请用控制台检查 rollback.log。"
          return 1 ;;
      esac
    fi
  fi
  guard="$(mktemp -d "$GUARD_ROOT/change.XXXXXXXX")" || return 1
  unit="vps-manager-rollback-$(basename "$guard")"
  printf '%s\n' "$kind" > "$guard/kind" || return 1
  printf '%s\n' "$unit" > "$guard/unit" || return 1
  printf '%s\n' "$(( $(date +%s) + GUARD_TIMEOUT ))" > "$guard/deadline" || return 1
  printf '0\n' > "$guard/fail2ban-active" || return 1
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    printf '1\n' > "$guard/fail2ban-active" || return 1
  fi
  case "$kind" in
    ssh)
      save_guard_snapshot "$guard" ssh-config "$SSHD_MANAGED_FILE" || return 1
      save_guard_snapshot "$guard" fail2ban-config "$FAIL2BAN_JAIL_FILE" || return 1
      printf '%s\n' "$SSHD_MANAGED_FILE" > "$guard/ssh-target" || return 1
      printf '%s\n' "$FAIL2BAN_JAIL_FILE" > "$guard/fail2ban-target" || return 1
      printf '0\n' > "$guard/socket-active" || return 1
      if ssh_socket_activated; then printf '1\n' > "$guard/socket-active" || return 1; fi
      systemctl is-active --quiet sshd.service 2>/dev/null && service="sshd.service"
      printf '%s\n' "$service" > "$guard/ssh-service" || return 1
      printf '0\n' > "$guard/fail2ban-sshd-active" || return 1
      if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
        printf '1\n' > "$guard/fail2ban-sshd-active" || return 1
      fi
      ;;
    ufw)
      ufw_status="$(LC_ALL=C ufw status)" || { error "无法读取原 UFW 状态，停止修改。"; return 1; }
      case "$ufw_status" in 'Status: active'*|'Status: inactive'*) ;; *) error "无法识别原 UFW 状态，停止修改。"; return 1 ;; esac
      cp -a -- /etc/ufw "$guard/ufw" || return 1
      save_guard_snapshot "$guard" ufw-default /etc/default/ufw || return 1
      save_guard_snapshot "$guard" port-config "$PORT_CONFIG_FILE" || return 1
      printf '%s\n' "$PORT_CONFIG_FILE" > "$guard/port-target" || return 1
      printf '/etc/ufw\n' > "$guard/ufw-target" || return 1
      printf '/etc/default/ufw\n' > "$guard/ufw-default-target" || return 1
      printf '0\n' > "$guard/ufw-active" || return 1
      if [[ "$ufw_status" == 'Status: active'* ]]; then printf '1\n' > "$guard/ufw-active" || return 1; fi
      ;;
    *) return 1 ;;
  esac
  cp -- "$ROLLBACK_HELPER" "$guard/rollback.sh" && chmod 0700 "$guard/rollback.sh" || return 1
  bash -n "$guard/rollback.sh" || return 1
  exec 8>"$guard/lock" || return 1
  flock -x 8 || { exec 8>&-; return 1; }
  printf 'pending\n' > "$guard/state" || { exec 8>&-; return 1; }
  if ! systemd-run --quiet --collect --unit="$unit" --on-active="${GUARD_TIMEOUT}s" \
    --timer-property=AccuracySec=1s --property=Type=oneshot --property=TimeoutStartSec=300 \
    /bin/bash "$guard/rollback.sh" "$guard"; then
    printf 'not-armed\n' > "$guard/state"
    exec 8>&-
    error "自动恢复任务创建失败，尚未修改网络配置。"
    return 1
  fi
  ACTIVE_GUARD="$guard"
  local pointer
  pointer="$(mktemp "$GUARD_ROOT/.current.XXXXXX")" || { abort_network_guard; return 1; }
  if ! printf '%s\n' "$guard" > "$pointer" || ! mv -f -- "$pointer" "$GUARD_ROOT/current"; then
    rm -f -- "$pointer"
    abort_network_guard
    return 1
  fi
  info "已安排 ${GUARD_TIMEOUT} 秒超时恢复；当前 SSH 会话断开也会执行。"
}

abort_network_guard() {
  local guard="${ACTIVE_GUARD:-}" unit
  [[ -n "$guard" && -f "$guard/state" ]] || return 1
  exec 8>&-
  unit="$(<"$guard/unit")"
  systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
  if bash "$guard/rollback.sh" "$guard"; then
    warn "本次网络修改已撤销，原配置已恢复。"
    ACTIVE_GUARD=""
    return 0
  fi
  error "恢复未完整成功，请用云控制台检查：${guard}/rollback.log"
  ACTIVE_GUARD=""
  return 1
}

commit_network_guard() {
  local guard="$1" unit state
  exec 8>"$guard/lock" || return 1
  flock -x 8 || { exec 8>&-; return 1; }
  state="$(<"$guard/state")"
  if [[ "$state" != pending ]]; then
    exec 8>&-
    [[ "$state" == confirmed ]] && return 0
    error "本次修改已开始恢复或恢复失败，不能再确认保留。"
    return 1
  fi
  if (( $(date +%s) >= $(<"$guard/deadline") )); then
    exec 8>&-
    error "确认时间已过，将恢复原配置。"
    return 1
  fi
  printf 'confirmed\n' > "$guard/state" || { exec 8>&-; return 1; }
  unit="$(<"$guard/unit")"
  exec 8>&-
  systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
  ok "已确认保留网络修改，超时恢复已取消。"
}

finish_network_guard() {
  local guard="${ACTIVE_GUARD:-}" answer rc state
  [[ -n "$guard" ]] || return 1
  exec 8>&-
  warn "请保持本窗口，另开 SSH 窗口验证登录和需要的服务。"
  printf '验证成功后输入 y 保留；输入 n 撤销。未确认将自动恢复。\n'
  while true; do
    state="$(<"$guard/state")"
    if [[ "$state" == confirmed ]]; then ACTIVE_GUARD=""; return 0; fi
    if [[ "$state" != pending ]] || (( $(date +%s) >= $(<"$guard/deadline") )); then
      abort_network_guard
      return 1
    fi
    answer=""
    read -r -t 5 answer
    rc=$?
    if (( rc == 0 )); then
      case "$answer" in
        y|Y) if commit_network_guard "$guard"; then ACTIVE_GUARD=""; return 0; fi; abort_network_guard; return 1 ;;
        n|N) abort_network_guard; return 1 ;;
        *) printf '请先用新窗口验证，再输入 y 保留，或输入 n 撤销。\n' ;;
      esac
    elif (( rc <= 128 )); then
      abort_network_guard
      return 1
    fi
  done
}

confirm_pending_network() {
  local guard
  require_root
  [[ -f "$GUARD_ROOT/current" ]] || { info "没有待确认的网络修改。"; return 0; }
  guard="$(<"$GUARD_ROOT/current")"
  [[ "$guard" == "$GUARD_ROOT"/change.* && -f "$guard/state" && ! -L "$guard" ]] || return 1
  [[ "$(<"$guard/state")" == pending ]] || { info "没有待确认的网络修改。"; return 0; }
  confirm "已通过新的 SSH 连接验证登录和服务正常，确认保留？" || return 0
  commit_network_guard "$guard"
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
  (( LOCK_HELD == 0 )) || return 0
  ensure_directories || return 1
  if [[ "$(readlink /proc/self/fd/9 2>/dev/null || true)" != "$LOCK_FILE" ]]; then
    exec 9>"$LOCK_FILE" || return 1
  fi
  if ! flock -n 9; then
    exec 9>&-
    warn "另一个 vps-manager 修改任务正在运行，本次操作退出。"
    return 1
  fi
  LOCK_HELD=1
}

log_line() {
  ensure_directories || return 1
  printf '[%s] %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE"
}

log_command() {
  local mode="$1"
  shift
  ensure_directories || return 1
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

ubuntu_codename() (
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
)

ubuntu_version_id() (
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s' "${VERSION_ID:-unknown}"
)

is_supported_ubuntu_release() {
  local codename supported
  codename="$(ubuntu_codename)" || return 1
  for supported in "${SUPPORTED_UBUNTU_CODENAMES[@]}"; do
    [[ "$codename" != "$supported" ]] || return 0
  done
  return 1
}

require_ubuntu() {
  if ! is_ubuntu; then
    error "仅支持 Ubuntu。当前系统不是 Ubuntu，已停止修改。"
    return 1
  fi
  if ! is_supported_ubuntu_release; then
    warn "Ubuntu $(ubuntu_version_id) 不在已适配列表（22.04/24.04/25.10/26.04），将按通用 Ubuntu 流程继续。"
  fi
}

apt_install() {
  require_root
  require_ubuntu || return 1
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y "$@"
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
  ${PROGRAM} ports        管理防火墙模式和端口
  ${PROGRAM} swap         进入 Swap 管理
  ${PROGRAM} security     进入 Fail2ban 与自动安全更新
  ${PROGRAM} docker       进入 Docker 管理
  ${PROGRAM} hostname     设置主机名
  ${PROGRAM} check-ai     检测 AI 与流媒体访问
  ${PROGRAM} check-media  同 check-ai（兼容旧命令）
  ${PROGRAM} cleanup-system  执行带确认的保守系统清理
  ${PROGRAM} update       从 GitHub 更新 vps-manager
  ${PROGRAM} confirm-network  在新连接中确认保留本次网络修改
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
  if is_ubuntu; then
    if is_supported_ubuntu_release; then
      printf '适配：Ubuntu %s（%s）\n' "$(ubuntu_version_id)" "$(ubuntu_codename)"
    else
      printf '适配：通用 Ubuntu 模式（未专项验证）\n'
    fi
  fi
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
  local simulation
  simulation="$(LC_ALL=C apt-get -s full-upgrade 2>&1)" || { error "无法预演系统升级。"; return 1; }
  printf '%s\n' "$simulation" | awk '/^(Inst|Remv|[0-9]+ upgraded)/'
  warn "完整升级可能重启服务，并按以上计划安装、更新或移除软件包。"
  confirm "确认按以上计划升级系统？" || return 0
  if ! log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 full-upgrade -y; then
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
  local new_hostname="${1:-}" hosts_file="/etc/hosts" old_hostname hosts_candidate cloud_candidate
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
  acquire_lock || return 1
  backup_file "$hosts_file" || return 1
  hosts_candidate="$(mktemp /tmp/vps-manager-hosts.XXXXXX)" || return 1
  cp -a -- "$hosts_file" "$hosts_candidate" || { rm -f -- "$hosts_candidate"; return 1; }
  if grep -qE '^127\.0\.1\.1[[:space:]]+' "$hosts_candidate"; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]]+.*/127.0.1.1 ${new_hostname}/" "$hosts_candidate" || { rm -f -- "$hosts_candidate"; return 1; }
  else
    printf '\n127.0.1.1 %s\n' "$new_hostname" >> "$hosts_candidate" || { rm -f -- "$hosts_candidate"; return 1; }
  fi
  hostnamectl set-hostname "$new_hostname" || { rm -f -- "$hosts_candidate"; return 1; }
  if ! atomic_install_file "$hosts_candidate" "$hosts_file" 0644; then
    rm -f -- "$hosts_candidate"
    hostnamectl set-hostname "$old_hostname" || true
    error "更新 ${hosts_file} 失败，已恢复原主机名。"
    return 1
  fi
  rm -f -- "$hosts_candidate"

  if [[ -d "$(dirname "$CLOUD_HOSTNAME_FILE")" ]]; then
    cloud_candidate="$(mktemp /tmp/vps-manager-cloud-hostname.XXXXXX)" || cloud_candidate=""
    if [[ -n "$cloud_candidate" ]] && printf 'preserve_hostname: true\n' > "$cloud_candidate" &&
       backup_file "$CLOUD_HOSTNAME_FILE" &&
       atomic_install_file "$cloud_candidate" "$CLOUD_HOSTNAME_FILE" 0644; then
      :
    else
      warn "无法安全写入 ${CLOUD_HOSTNAME_FILE}；cloud-init 可能在重启后恢复旧主机名。"
    fi
    [[ -z "$cloud_candidate" ]] || rm -f -- "$cloud_candidate"
  fi
  ok "主机名已设置为 ${new_hostname}；新 SSH 会话会显示新名称。"
  log_line "hostname changed from ${old_hostname} to ${new_hostname}"
}

set_timezone() {
  local timezone="${1:-$DEFAULT_TIMEZONE}"
  require_root
  require_ubuntu || return 1
  acquire_lock || return 1
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
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    port="$((10#$port))"
    printf '%s/%s\n' "$port" "$proto"
    return 0
  fi
  return 1
}

declare -a PORT_RULES=()
declare -a MANAGED_PORTS=()

load_managed_service_ports() {
  local item rule source
  local -A seen=()
  MANAGED_PORTS=()
  if [[ -f "$PORT_CONFIG_FILE" ]]; then
    source="$(grep -Ev '^[[:space:]]*(#|$)' "$PORT_CONFIG_FILE" 2>/dev/null || true)"
  else
    source="$(printf '%s\n' "$DEFAULT_PORTS" | tr ',' '\n' | grep -vx '22/tcp' || true)"
  fi
  while IFS= read -r item; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue
    rule="$(normalize_port_rule "$item")" || { warn "忽略无效的端口配置：${item}"; continue; }
    [[ -n "${seen[$rule]:-}" ]] && continue
    MANAGED_PORTS+=("$rule")
    seen["$rule"]=1
  done <<< "$source"
}

save_managed_service_ports() {
  local temporary rule
  install -d -m 0755 "$(dirname "$PORT_CONFIG_FILE")" || return 1
  temporary="$(mktemp /tmp/vps-manager-ports.XXXXXX)" || return 1
  {
    printf '# Managed by vps-manager. One port/protocol per line.\n'
    for rule in "${MANAGED_PORTS[@]}"; do
      printf '%s\n' "$rule"
    done
  } > "$temporary"
  if [[ -f "$PORT_CONFIG_FILE" ]]; then
    backup_file "$PORT_CONFIG_FILE" || { rm -f -- "$temporary"; return 1; }
  fi
  if ! atomic_install_file "$temporary" "$PORT_CONFIG_FILE" 0644; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$temporary"
}

managed_port_exists() {
  local target="$1" rule
  for rule in "${MANAGED_PORTS[@]}"; do
    [[ "$rule" == "$target" ]] && return 0
  done
  return 1
}

remove_managed_port() {
  local target="$1" rule
  local -a remaining=()
  for rule in "${MANAGED_PORTS[@]}"; do
    [[ "$rule" == "$target" ]] || remaining+=("$rule")
  done
  MANAGED_PORTS=("${remaining[@]}")
}

ensure_ufw() {
  local simulation
  local -a removals=()
  require_root
  require_ubuntu || return 1
  if command -v ufw >/dev/null 2>&1; then
    return 0
  fi
  warn "当前未安装 ufw。"
  if confirm "是否安装 ufw？"; then
    acquire_lock || return 1
    apt-get update || return 1
    simulation="$(LC_ALL=C apt-get -s install ufw 2>&1)" || {
      error "无法预演 UFW 安装，已停止操作。"
      return 1
    }
    mapfile -t removals < <(awk '$1=="Remv" && !seen[$2]++ {print $2}' <<< "$simulation")
    if (( ${#removals[@]} > 0 )); then
      warn "APT 安装 UFW 将移除以下软件包：${removals[*]}"
      confirm "确认接受以上软件包变更并继续？" || { info "已取消 UFW 安装。"; return 1; }
    fi
    apt_install ufw
    return $?
  fi
  return 1
}

ufw_is_active() {
  command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

build_tight_firewall_rules() {
  local ssh_port ssh_rule rule ssh_count=0
  local -A seen=()
  load_managed_service_ports
  PORT_RULES=()
  while IFS= read -r ssh_port; do
    [[ "$ssh_port" =~ ^[0-9]+$ ]] || continue
    ssh_rule="${ssh_port}/tcp"
    [[ -n "${seen[$ssh_rule]:-}" ]] && continue
    PORT_RULES+=("$ssh_rule")
    seen["$ssh_rule"]=1
    ssh_count=$((ssh_count + 1))
  done < <(current_ssh_ports)
  if (( ssh_count == 0 )); then
    error "无法可靠识别当前 SSH 监听端口，拒绝重建 UFW。"
    return 1
  fi
  for rule in "${MANAGED_PORTS[@]}"; do
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
  status="$(LC_ALL=C ufw status verbose 2>/dev/null || true)"
  allowed="$(printf '%s\n' "$status" | awk '$2=="ALLOW" && $1 !~ /^\(/ && !seen[$1]++ {print $1}' | paste -sd, -)"
  defaults="$(printf '%s\n' "$status" | awk -F': ' '/^Default:/{print $2; exit}')"
  if [[ "$defaults" == *"deny (incoming)"* && "$defaults" == *"allow (outgoing)"* && "$defaults" == *"deny (routed)"* ]]; then
    defaults="拒绝入站，允许出站，拒绝转发"
  fi
  printf 'UFW：已启用\n'
  printf '默认策略：%s\n' "${defaults:-未读取到}"
  printf '允许端口：%s\n' "${allowed:-未读取到}"
}

ufw_rule_exists() {
  local target="$1"
  command -v ufw >/dev/null 2>&1 || return 1
  LC_ALL=C ufw show added 2>/dev/null | awk -v target="$target" '$1=="ufw" && $2=="allow" && $3==target {found=1} END {exit !found}'
}

port_listener_summary() {
  local rule="$1" port proto lines names
  port="${rule%/*}"
  proto="${rule#*/}"
  command -v ss >/dev/null 2>&1 || { printf '无法检测（缺少 ss）'; return 0; }
  lines="$(ss -H -lntup 2>/dev/null | awk -v proto="$proto" -v port="$port" '
    $1==proto {
      local_endpoint=$5
      sub(/^.*:/, "", local_endpoint)
      if (local_endpoint==port) print
    }
  ')"
  [[ -n "$lines" ]] || { printf '未检测到监听服务'; return 0; }
  names="$(printf '%s\n' "$lines" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | paste -sd, -)"
  if [[ -n "$names" ]]; then
    printf '%s' "$names"
  else
    printf '检测到监听（服务名未知）'
  fi
}

show_port_details() {
  local rule="$1" firewall_state listener
  listener="$(port_listener_summary "$rule")"
  if ufw_rule_exists "$rule"; then
    if ufw_is_active; then
      firewall_state="已开放"
    else
      firewall_state="规则已保存，UFW 当前关闭"
    fi
  elif ufw_is_active; then
    firewall_state="未开放"
  else
    firewall_state="UFW 已关闭，主机当前不拦截"
  fi
  printf '端口：%s\n' "$rule"
  printf '防火墙：%s\n' "$firewall_state"
  printf '监听服务：%s\n' "$listener"
}

prompt_port_rule() {
  local input rule
  read -r -p "请输入端口（例如 8080、8080/tcp、53/udp）：" input
  if ! rule="$(normalize_port_rule "$input")"; then
    error "端口格式不正确。"
    return 1
  fi
  printf '%s\n' "$rule"
}

open_managed_port() {
  local rule was_rule=0 is_ssh_rule=0
  local -a previous=()
  require_root
  require_ubuntu || return 1
  ensure_ufw || return 1
  rule="$(prompt_port_rule)" || return 1
  if [[ "${rule#*/}" == "tcp" ]] && current_ssh_ports | grep -Fxq "${rule%/*}"; then
    is_ssh_rule=1
  fi
  load_managed_service_ports
  previous=("${MANAGED_PORTS[@]}")
  ufw_rule_exists "$rule" && was_rule=1
  printf '\n'
  show_port_details "$rule"
  if (( was_rule )) && { (( is_ssh_rule )) || managed_port_exists "$rule"; }; then
    info "${rule} 已在允许清单中。"
    return 0
  fi
  confirm "确认开放 ${rule}？" || return 0
  acquire_lock || return 1
  if (( is_ssh_rule == 0 )) && ! managed_port_exists "$rule"; then
    MANAGED_PORTS+=("$rule")
  fi
  if ! save_managed_service_ports; then
    MANAGED_PORTS=("${previous[@]}")
    error "保存端口清单失败。"
    return 1
  fi
  if (( was_rule == 0 )) && ! log_command quiet ufw allow "$rule" comment "vps-manager managed port"; then
    MANAGED_PORTS=("${previous[@]}")
    save_managed_service_ports >/dev/null 2>&1 || true
    error "添加 UFW 规则失败，已恢复端口清单。"
    return 1
  fi
  ok "已开放 ${rule}。"
  ufw_is_active || info "当前是宽松模式；规则已保存，将在启用 UFW 后生效。"
  log_line "firewall port opened: ${rule}"
  show_port_details "$rule"
}

close_managed_port() {
  local rule ssh_ports was_rule=0 was_managed=0
  local -a previous=()
  require_root
  require_ubuntu || return 1
  ensure_ufw || return 1
  rule="$(prompt_port_rule)" || return 1
  if [[ "${rule#*/}" == "tcp" ]]; then
    ssh_ports="$(current_ssh_ports)" || {
      error "无法识别当前 SSH 端口，拒绝执行 TCP 端口关闭操作。"
      return 1
    }
    if grep -Fxq "${rule%/*}" <<< "$ssh_ports"; then
      error "拒绝关闭当前 SSH 端口 ${rule}。请先在 SSH 菜单中新增并验证其他端口。"
      return 1
    fi
  fi
  load_managed_service_ports
  previous=("${MANAGED_PORTS[@]}")
  managed_port_exists "$rule" && was_managed=1
  ufw_rule_exists "$rule" && was_rule=1
  printf '\n'
  show_port_details "$rule"
  if (( was_managed == 0 && was_rule == 0 )); then
    info "${rule} 当前不在允许清单中。"
    return 0
  fi
  warn "关闭端口只修改防火墙，不会停止正在监听的服务。"
  confirm "确认关闭 ${rule}？" || return 0
  acquire_lock || return 1
  remove_managed_port "$rule"
  if ! save_managed_service_ports; then
    MANAGED_PORTS=("${previous[@]}")
    error "保存端口清单失败。"
    return 1
  fi
  if (( was_rule )) && ! log_command quiet ufw --force delete allow "$rule"; then
    MANAGED_PORTS=("${previous[@]}")
    save_managed_service_ports >/dev/null 2>&1 || true
    error "删除 UFW 规则失败，已恢复端口清单。"
    return 1
  fi
  ok "已关闭 ${rule}。"
  log_line "firewall port closed: ${rule}"
  show_port_details "$rule"
}

restore_ufw_backup() {
  local backup_dir="$1" was_active="$2" failed=0
  [[ -d "$backup_dir/ufw" ]] || return 1
  cp -a -- "$backup_dir/ufw/." /etc/ufw/ 2>/dev/null || failed=1
  if [[ -f "$backup_dir/default-ufw" ]]; then
    install -m 0644 "$backup_dir/default-ufw" /etc/default/ufw 2>/dev/null || failed=1
  fi
  if (( was_active )); then
    ufw --force enable >/dev/null 2>&1 || failed=1
    ufw_is_active || failed=1
  else
    ufw disable >/dev/null 2>&1 || failed=1
    ufw_is_active && failed=1
  fi
  (( failed == 0 ))
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
  acquire_lock || return 1
  if log_command quiet ufw disable; then
    ok "已切换到宽松模式：UFW 已关闭，现有规则保留。"
    log_line "firewall mode changed to relaxed"
  else
    error "关闭 UFW 失败，请查看日志。"
    return 1
  fi
}

set_firewall_tight() {
  local ssh_ports backup_dir rule failed=0 docker_was_active=0
  require_root
  require_ubuntu || return 1
  ensure_ufw || return 1
  build_tight_firewall_rules || return 1
  ssh_ports="$(current_ssh_ports | paste -sd',' -)" || {
    error "无法读取 SSH 端口，拒绝重建 UFW。"
    return 1
  }
  systemctl is-active --quiet docker 2>/dev/null && docker_was_active=1
  printf '\n%s收紧模式%s\n' "$C_BOLD" "$C_RESET"
  printf '  当前 SSH：%s/tcp（全部优先放行）\n' "${ssh_ports//,//tcp,}"
  printf '  允许端口：%s\n' "${PORT_RULES[*]}"
  printf '  默认策略：拒绝其他入站和转发，允许出站\n'
  warn "将清空现有 UFW 规则并按以上清单重建；云厂商安全组仍需单独配置。"
  info "额外业务端口按你的端口清单放行；新安装默认只保留 SSH，不自动开放网站或代理端口。"
  info "如清单缺少业务端口，请先取消，并用端口菜单添加。"
  if (( docker_was_active )); then
    warn "Docker 发布到公网的容器端口可能绕过 UFW；本模式不接管 Docker 防火墙链。"
  fi
  confirm "确认切换到收紧模式？" || return 0
  acquire_lock || return 1
  backup_dir="${BACKUP_ROOT}/ufw-$(date '+%Y%m%d-%H%M%S').$$"
  install -d -m 0700 "$backup_dir" || return 1
  cp -a -- /etc/ufw "$backup_dir/ufw" || { error "无法备份 UFW 配置。"; return 1; }
  [[ ! -f /etc/default/ufw ]] || cp -a -- /etc/default/ufw "$backup_dir/default-ufw" || return 1

  start_network_guard ufw || return 1
  if [[ ! -f "$PORT_CONFIG_FILE" ]] && ! save_managed_service_ports; then
    error "无法保存收紧模式端口清单。"
    abort_network_guard
    return 1
  fi
  log_command quiet timeout 35s ufw --force reset || failed=1
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
  (( failed )) || log_command quiet timeout 35s ufw --force enable || failed=1
  (( failed )) || ufw_is_active || failed=1
  if (( failed == 0 )); then
    for rule in "${PORT_RULES[@]}"; do ufw_rule_exists "$rule" || failed=1; done
  fi
  if (( failed == 0 )) && systemctl is-active --quiet fail2ban 2>/dev/null; then
    timeout 35s fail2ban-client reload --restart || failed=1
  fi

  if (( failed )); then
    error "收紧模式应用或运行检查失败，正在恢复。"
    abort_network_guard
    show_firewall_status
    return 1
  fi
  finish_network_guard || return 1
  ok "已切换到收紧模式，当前 SSH 端口均保持放行。"
  info "UFW 备份：${backup_dir}"
  if (( docker_was_active )); then
    warn "检测到 Docker 正在运行；UFW 重建可能影响容器 NAT 或端口发布规则。"
    if confirm "是否现在重启 Docker 以重建网络规则？"; then
      systemctl restart docker || warn "Docker 重启失败，请立即检查容器网络。"
    fi
  fi
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
    printf '  3. 开启端口\n'
    printf '  4. 关闭端口\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice || return 0
    case "$choice" in
      1) set_firewall_relaxed; pause ;;
      2) set_firewall_tight; pause ;;
      3) open_managed_port; pause ;;
      4) close_managed_port; pause ;;
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
  acquire_lock || return 1
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
      ok "BBR 已即时生效，不需要重启。"
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
  require_ubuntu || return 1
  [[ -f /etc/sysctl.d/99-vps-manager-bbr.conf ]] || { info "vps-manager 没有创建 BBR 配置。"; return 0; }
  warn "只会删除 vps-manager 创建的 BBR sysctl 文件。"
  confirm "确认移除 BBR 配置？" || return 0
  acquire_lock || return 1
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
    read -r -p "请选择：" choice || return 0
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
    swapon --show=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null || true
  fi
  printf '\n持久化配置：\n'
  grep -E '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab 2>/dev/null || printf '  未发现 fstab Swap 条目\n'
  [[ -e "$SWAP_FILE" ]] && ls -lh "$SWAP_FILE"
  if swap_is_managed; then
    printf '管理状态：由 vps-manager 管理\n'
  elif [[ -e "$SWAP_FILE" ]]; then
    printf '管理状态：现有文件未由 vps-manager 接管\n'
  fi
}

validate_swap_path() {
  [[ "$SWAP_FILE" == /* && "$SWAP_FILE" != *[[:space:]]* && ! -L "$SWAP_FILE" ]] || {
    error "Swap 文件必须是不含空白的绝对路径：${SWAP_FILE}"
    return 1
  }
}

swap_is_managed() {
  [[ -f "$SWAP_STATE_FILE" ]] || return 1
  grep -Fxq 'managed_by=vps-manager' "$SWAP_STATE_FILE" 2>/dev/null &&
    grep -Fxq "path=${SWAP_FILE}" "$SWAP_STATE_FILE" 2>/dev/null
}

save_swap_state() {
  local temporary
  install -d -m 0755 "$(dirname "$SWAP_STATE_FILE")" || return 1
  temporary="$(mktemp "$(dirname "$SWAP_STATE_FILE")/.swap-state.XXXXXX")" || return 1
  {
    printf 'managed_by=vps-manager\n'
    printf 'path=%s\n' "$SWAP_FILE"
  } > "$temporary" || { rm -f -- "$temporary"; return 1; }
  atomic_install_file "$temporary" "$SWAP_STATE_FILE" 0644 || { rm -f -- "$temporary"; return 1; }
  rm -f -- "$temporary"
}

create_swap() {
  local size_gb available_kb required_kb target_dir temp_fstab temp_sysctl="" fstab_added=0
  require_root
  require_ubuntu || return 1
  validate_swap_path || return 1
  ensure_command mkswap util-linux || return 1
  if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
    info "${SWAP_FILE} 已作为 Swap 启用。"
    if ! swap_is_managed; then
      warn "该 Swap 没有 vps-manager 管理标记，脚本不会直接删除它。"
      if confirm "是否将现有 ${SWAP_FILE} 纳入 vps-manager 管理？"; then
        acquire_lock || return 1
        save_swap_state || { error "无法保存 Swap 管理状态。"; return 1; }
        ok "已记录 Swap 管理状态。"
      fi
    fi
    show_swap_status
    return 0
  fi
  if [[ -e "$SWAP_FILE" || -L "$SWAP_FILE" ]]; then
    error "${SWAP_FILE} 已存在但未作为 Swap 启用，脚本不会覆盖。"
    return 1
  fi
  read -r -p "Swap 大小 GiB [2]：" size_gb
  size_gb="${size_gb:-2}"
  if [[ ! "$size_gb" =~ ^[0-9]+$ ]] || (( 10#$size_gb < 1 || 10#$size_gb > 64 )); then
    error "Swap 大小必须是 1 到 64 GiB 的整数。"
    return 1
  fi
  size_gb="$((10#$size_gb))"
  target_dir="$(dirname "$SWAP_FILE")"
  available_kb="$(df -Pk "$target_dir" | awk 'NR==2 {print $4}')"
  required_kb=$((size_gb * 1024 * 1024 + 512 * 1024))
  if [[ ! "$available_kb" =~ ^[0-9]+$ ]] || (( available_kb < required_kb )); then
    error "磁盘可用空间不足；创建 ${size_gb} GiB Swap 后至少需要保留 512 MiB。"
    return 1
  fi
  printf '准备创建 %s GiB Swap：%s\n' "$size_gb" "$SWAP_FILE"
  confirm "确认创建并设置开机启用？" || return 0
  acquire_lock || return 1
  backup_file /etc/fstab || return 1
  if ! fallocate -l "${size_gb}G" "$SWAP_FILE" 2>/dev/null; then
    warn "fallocate 不可用，改用 dd 创建，可能需要一些时间。"
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$((size_gb * 1024))" status=progress || { rm -f "$SWAP_FILE"; return 1; }
  fi
  if ! chmod 0600 "$SWAP_FILE"; then
    rm -f -- "$SWAP_FILE"
    error "无法设置 Swap 文件权限，已清理候选文件。"
    return 1
  fi
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
    fstab_added=1
  fi
  if ! save_swap_state; then
    swapoff "$SWAP_FILE" 2>/dev/null || true
    rm -f -- "$SWAP_FILE" "$SWAP_STATE_FILE"
    if (( fstab_added )); then
      temp_fstab="$(mktemp /tmp/vps-manager-fstab.XXXXXX)" || temp_fstab=""
      if [[ -z "$temp_fstab" ]] ||
         ! awk -v file="$SWAP_FILE" '$1 != file' /etc/fstab > "$temp_fstab" ||
         ! atomic_install_file "$temp_fstab" /etc/fstab 0644; then
        error "Swap 管理状态写入失败，且 /etc/fstab 自动恢复不完整，请检查备份。"
      fi
      [[ -z "$temp_fstab" ]] || rm -f -- "$temp_fstab"
    fi
    error "Swap 管理状态写入失败，已尝试撤销本次 Swap 创建。"
    return 1
  fi
  temp_sysctl="$(mktemp /tmp/vps-manager-swap-sysctl.XXXXXX)" || temp_sysctl=""
  if [[ -n "$temp_sysctl" ]] &&
     printf 'vm.swappiness=10\n' > "$temp_sysctl" &&
     atomic_install_file "$temp_sysctl" "$SWAP_SYSCTL_FILE" 0644; then
    sysctl -p "$SWAP_SYSCTL_FILE" >/dev/null 2>&1 || warn "Swap 已启用，但 vm.swappiness 未能立即应用。"
  else
    warn "Swap 已启用并受管理，但无法写入 swappiness 持久配置。"
  fi
  [[ -z "$temp_sysctl" ]] || rm -f -- "$temp_sysctl"
  ok "Swap 已创建并启用。"
  log_line "swap created: ${SWAP_FILE} ${size_gb}GiB"
  show_swap_status
}

delete_swap() {
  local temp_fstab original_fstab was_active=0
  require_root
  require_ubuntu || return 1
  validate_swap_path || return 1
  [[ -e "$SWAP_FILE" ]] || { info "未发现 vps-manager 默认 Swap 文件：${SWAP_FILE}"; return 0; }
  if ! swap_is_managed; then
    error "${SWAP_FILE} 没有 vps-manager 管理标记，拒绝删除。可先在创建 Swap 菜单中明确纳入管理。"
    return 1
  fi
  warn "将停用并删除 ${SWAP_FILE}，释放其占用的磁盘空间。"
  show_swap_status
  confirm "确认删除该 Swap？" || return 0
  acquire_lock || return 1
  backup_file /etc/fstab || return 1
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
  rm -f -- "$SWAP_STATE_FILE" || warn "Swap 已删除，但管理状态文件清理失败：${SWAP_STATE_FILE}"
  if [[ -f "$SWAP_SYSCTL_FILE" ]]; then
    rm -f -- "$SWAP_SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1 || warn "Swap 已删除，但现有 sysctl 配置未能完整重新加载。"
  fi
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
    read -r -p "请选择：" choice || return 0
    case "$choice" in
      1) show_swap_status; pause ;;
      2) create_swap; pause ;;
      3) delete_swap; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

validate_ipv4() {
  local value="$1" octet
  local -a octets=()
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$value"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && (( 10#$octet <= 255 )) || return 1
  done
}

count_ipv6_groups() {
  local side="$1" group
  local -a groups=()
  [[ -n "$side" ]] || { printf '0'; return 0; }
  IFS=':' read -r -a groups <<< "$side"
  (( ${#groups[@]} > 0 )) || return 1
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9a-f]{1,4}$ ]] || return 1
  done
  printf '%d' "${#groups[@]}"
}

validate_ipv6() {
  local value="${1,,}" left right left_count right_count group_count ipv4_tail
  [[ "$value" == *:* && "$value" != *'%'* ]] || return 1
  if [[ "$value" == *.* ]]; then
    ipv4_tail="${value##*:}"
    validate_ipv4 "$ipv4_tail" || return 1
    value="${value%:*}:0:0"
  fi
  [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 1
  if [[ "$value" == *::* ]]; then
    [[ "${value#*::}" != *::* ]] || return 1
    [[ "$value" != *: || "$value" == *:: ]] || return 1
    left="${value%%::*}"
    right="${value#*::}"
    left_count="$(count_ipv6_groups "$left")" || return 1
    right_count="$(count_ipv6_groups "$right")" || return 1
    (( left_count + right_count < 8 ))
  else
    [[ "$value" != :* && "$value" != *: ]] || return 1
    group_count="$(count_ipv6_groups "$value")" || return 1
    (( group_count == 8 ))
  fi
}

validate_dns_server_list() {
  local values="$1" allow_empty="${2:-0}" server count=0
  local -a servers=()
  read -r -a servers <<< "$values"
  for server in "${servers[@]}"; do
    if ! validate_ipv4 "$server" && ! validate_ipv6 "$server"; then
      error "DNS 地址格式不正确：${server}"
      return 1
    fi
    count=$((count + 1))
  done
  (( count > 0 || allow_empty == 1 ))
}

show_dns_status() {
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl dns 2>/dev/null || true
    resolvectl domain 2>/dev/null || true
  fi
  printf '\n%s：\n' "$RESOLV_CONF_FILE"
  sed -n '1,20p' "$RESOLV_CONF_FILE" 2>/dev/null || true
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

systemd_resolved_manages_dns() {
  local target
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 1
  [[ -f "$RESOLVED_CONFIG_FILE" ]] || return 1
  target="$(readlink -f "$RESOLV_CONF_FILE" 2>/dev/null || true)"
  case "$target" in
    /run/systemd/resolve/resolv.conf|/run/systemd/resolve/stub-resolv.conf) return 0 ;;
  esac
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.(53|54)([[:space:]]|$)' "$RESOLV_CONF_FILE" 2>/dev/null
}

dns_resolution_works() {
  local host
  command -v getent >/dev/null 2>&1 || return 1
  for host in ubuntu.com cloudflare.com; do
    if command -v timeout >/dev/null 2>&1; then
      timeout 8 getent ahosts "$host" >/dev/null 2>&1 && return 0
    else
      getent ahosts "$host" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

configured_dns_works() {
  local dns_addresses="$1" server answer host
  for server in $dns_addresses; do
    for host in ubuntu.com cloudflare.com; do
      answer="$(timeout 7s dig +time=2 +tries=1 +short "@${server}" "$host" A 2>/dev/null)" || continue
      if grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' <<< "$answer"; then return 0; fi
    done
  done
  return 1
}

apply_dns_servers() {
  local label="$1" dns="$2" fallback="$3" resolved_file="$RESOLVED_CONFIG_FILE"
  local rollback rollback_dir temporary candidate server
  local -a dns_servers=() fallback_servers=() all_servers=()
  require_root
  require_ubuntu || return 1
  validate_dns_server_list "$dns" || return 1
  validate_dns_server_list "$fallback" 1 || return 1
  printf 'DNS 方案：%s\n' "$label"
  printf 'DNS=%s\nFallbackDNS=%s\n' "$dns" "$fallback"
  if command -v cloud-init >/dev/null 2>&1 || [[ -d /etc/netplan ]]; then
    warn "检测到 cloud-init 或 netplan；其网络配置可能在重启后覆盖系统 DNS，请重启后复查。"
  fi
  confirm "确认修改 DNS 配置？" || return 0
  acquire_lock || return 1
  ensure_command dig dnsutils || return 1
  info "先直接查询你指定的 DNS，避免旧缓存造成误判。"
  configured_dns_works "${dns} ${fallback}" || { error "指定 DNS 未通过直接解析测试，原配置未修改。"; return 1; }

  if systemd_resolved_manages_dns; then
    rollback="$(mktemp /tmp/vps-manager-resolved-old.XXXXXX)" || return 1
    candidate="$(mktemp /tmp/vps-manager-resolved-new.XXXXXX)" || { rm -f -- "$rollback"; return 1; }
    cp -a -- "$resolved_file" "$rollback" || { rm -f -- "$rollback" "$candidate"; return 1; }
    cp -a -- "$resolved_file" "$candidate" || { rm -f -- "$rollback" "$candidate"; return 1; }
    backup_file "$resolved_file" || { rm -f -- "$rollback" "$candidate"; return 1; }
    if set_resolved_key "$candidate" DNS "$dns" &&
       set_resolved_key "$candidate" FallbackDNS "$fallback" &&
       atomic_install_file "$candidate" "$resolved_file" 0644 &&
       systemctl restart systemd-resolved && dns_resolution_works; then
      rm -f -- "$rollback" "$candidate"
      ok "systemd-resolved 配置已更新，指定 DNS 与系统解析测试通过。"
      info "接口级 DHCP / netplan DNS 仍可能参与解析，请结合下方状态确认。"
      show_dns_status
      return 0
    fi
    if ! atomic_install_file "$rollback" "$resolved_file" 0644; then
      error "DNS 配置失败且原配置恢复失败，请立即通过控制台检查 ${resolved_file}。"
    fi
    rm -f -- "$rollback" "$candidate"
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
    error "DNS 配置未通过应用或解析测试，已尝试恢复原配置。"
    return 1
  fi

  rollback_dir="$(mktemp -d /tmp/vps-manager-resolv-backup.XXXXXX)" || return 1
  if ! cp -a -- "$RESOLV_CONF_FILE" "$rollback_dir/resolv.conf"; then
    rm -rf -- "$rollback_dir"
    return 1
  fi
  backup_file "$RESOLV_CONF_FILE" || { rm -rf -- "$rollback_dir"; return 1; }
  temporary="$(mktemp /tmp/vps-manager-resolv.XXXXXX)" || { rm -rf -- "$rollback_dir"; return 1; }
  read -r -a dns_servers <<< "$dns"
  read -r -a fallback_servers <<< "$fallback"
  all_servers=("${dns_servers[@]}" "${fallback_servers[@]}")
  {
    printf '# Managed by vps-manager on %s\n' "$(date '+%F %T %z')"
    for server in "${all_servers[@]}"; do
      [[ -z "$server" ]] || printf 'nameserver %s\n' "$server"
    done
  } > "$temporary"
  if ! rm -f -- "$RESOLV_CONF_FILE" || ! atomic_install_file "$temporary" "$RESOLV_CONF_FILE" 0644; then
    rm -f -- "$RESOLV_CONF_FILE"
    cp -a -- "$rollback_dir/resolv.conf" "$RESOLV_CONF_FILE" || true
    rm -f -- "$temporary"
    rm -rf -- "$rollback_dir"
    error "写入 /etc/resolv.conf 失败，已尝试恢复原路径。"
    return 1
  fi
  if ! dns_resolution_works; then
    rm -f -- "$RESOLV_CONF_FILE"
    if ! cp -a -- "$rollback_dir/resolv.conf" "$RESOLV_CONF_FILE"; then
      error "新 DNS 不可用且原 resolv.conf 恢复失败，请立即使用控制台处理。"
    fi
    rm -f -- "$temporary"
    rm -rf -- "$rollback_dir"
    error "新 DNS 未通过解析测试，已尝试恢复原 ${RESOLV_CONF_FILE}。"
    return 1
  fi
  rm -f -- "$temporary"
  rm -rf -- "$rollback_dir"
  ok "${RESOLV_CONF_FILE} 已更新为普通 0644 文件，并通过解析测试。"
  show_dns_status
}

custom_dns() {
  local dns fallback
  read -r -p "主 DNS（空格分隔，例如 1.1.1.1 8.8.8.8）：" dns
  dns="$(trim "$dns")"
  [[ -n "$dns" ]] || { error "主 DNS 不能为空。"; return 1; }
  validate_dns_server_list "$dns" || return 1
  read -r -p "备用 DNS（空格分隔，可留空）：" fallback
  fallback="$(trim "$fallback")"
  validate_dns_server_list "$fallback" 1 || return 1
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
    read -r -p "请选择：" choice || return 0
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

configured_ssh_ports() {
  local sshd output
  sshd="$(sshd_bin)"
  [[ -x "$sshd" ]] || return 1
  output="$("$sshd" -T 2>/dev/null)" || return 1
  awk '$1=="port" && $2 ~ /^[0-9]+$/ && $2>=1 && $2<=65535 && !seen[$2]++ {print $2}' <<< "$output"
}

ssh_socket_ports() {
  local listeners
  ssh_socket_activated || return 0
  listeners="$(systemctl show ssh.socket --property=Listen --value 2>/dev/null)" || return 1
  awk '{
    line=$0
    while (match(line, /[^[:space:]]+:[0-9]+[[:space:]]+\(Stream\)/)) {
      entry=substr(line,RSTART,RLENGTH); sub(/[[:space:]].*/,"",entry); sub(/^.*:/,"",entry)
      if (entry>=1 && entry<=65535 && !seen[entry]++) print entry
      line=substr(line,RSTART+RLENGTH)
    }
  }' <<< "$listeners"
}

live_ssh_ports() {
  local listeners socket_ports
  command -v ss >/dev/null 2>&1 || { error "缺少 ss，无法核对实际 SSH 监听。"; return 1; }
  listeners="$(ss -H -ltnp 2>/dev/null)" || return 1
  socket_ports="$(ssh_socket_ports)" || return 1
  awk -v socket_ports="$socket_ports" '
    BEGIN {split(socket_ports, values, "\n"); for (i in values) sockets[values[i]]=1}
    {
      port=$4; sub(/^.*:/,"",port)
      if (port !~ /^[0-9]+$/ || port<1 || port>65535) next
      if ($0 ~ /"sshd"|"sshd-session"/ || ($0 ~ /"systemd"/ && sockets[port])) {
        if (!seen[port]++) print port
      }
    }
  ' <<< "$listeners"
}

current_ssh_ports() {
  local configured live socket_ports connection_port=""
  live="$(live_ssh_ports)" || return 1
  [[ -n "$live" ]] || { error "未能确认由 SSH 或 ssh.socket 实际监听的端口。"; return 1; }
  configured="$(configured_ssh_ports || true)"
  socket_ports="$(ssh_socket_ports)" || return 1
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    connection_port="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
  fi
  printf '%s\n' "$live" "$configured" "$socket_ports" "$connection_port" |
    awk '/^[0-9]+$/ && $1>=1 && $1<=65535 && !seen[$1]++ {print $1}' | sort -n
}

ssh_socket_activated() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null
}

ssh_port_listening() {
  local port="$1"
  live_ssh_ports | grep -Fxq "$port"
}

show_ssh_status() {
  local sshd config
  sshd="$(sshd_bin)"
  config="$(sshd_config_file)"
  if [[ -x "$sshd" ]]; then
    printf 'sshd 有效配置：\n'
    "$sshd" -T 2>/dev/null | awk '/^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) / {print "  " $0}' || true
  else
    warn "未找到 sshd。"
  fi
  printf '\n%s 中的相关配置：\n' "$config"
  grep -Ein '^[#[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+' "$config" 2>/dev/null || true
  printf '\n实际 SSH 监听端口：\n'
  live_ssh_ports | sed 's/^/  /' || true
  printf '\nssh.socket 端口：\n'
  ssh_socket_ports | sed 's/^/  /' || true
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
  command -v systemctl >/dev/null 2>&1 || return 1
  if ssh_socket_activated; then
    if systemctl is-active --quiet ssh.service 2>/dev/null &&
      [[ "$(systemctl show ssh.service --property=KillMode --value 2>/dev/null)" != process ]]; then
      error "ssh.service 的 KillMode 不是 process，无法保证重启主进程时保留已有会话。"
      return 1
    fi
    timeout 35s systemctl daemon-reload || return 1
    timeout 35s systemctl restart ssh.socket || return 1
    if systemctl is-active --quiet ssh.service 2>/dev/null; then
      # Socket-activated sshd must receive the newly opened descriptors.
      timeout 35s systemctl restart ssh.service || return 1
    fi
    return 0
  fi
  timeout 35s systemctl reload ssh 2>/dev/null && return 0
  timeout 35s systemctl reload sshd 2>/dev/null
}

apply_sshd_options() {
  local config sshd option value candidate index
  local -a settings=("$@")
  (( ${#settings[@]} > 0 && ${#settings[@]} % 2 == 0 )) || return 1
  require_root
  require_ubuntu || return 1
  config="$(sshd_config_file)"
  sshd="$(sshd_bin)"
  [[ -f "$config" && -x "$sshd" ]] || { error "未找到有效的 OpenSSH 配置。"; return 1; }
  show_ssh_status
  printf '\n准备设置：\n'
  for (( index=0; index<${#settings[@]}; index+=2 )); do
    printf '  %s %s\n' "${settings[$index]}" "${settings[$((index+1))]}"
  done
  confirm "确认修改 SSH 配置？未确认保留时将自动恢复。" || return 2
  acquire_lock || return 1
  install -d -m 0755 "$(dirname "$SSHD_MANAGED_FILE")" || return 1
  candidate="$(mktemp /tmp/vps-manager-sshd.XXXXXX)" || return 1
  if [[ -f "$SSHD_MANAGED_FILE" ]]; then
    cp -a -- "$SSHD_MANAGED_FILE" "$candidate" || { rm -f -- "$candidate"; return 1; }
  fi
  if grep -qiE '^[[:space:]]*Match[[:space:]]' "$candidate"; then
    error "管理文件包含自定义 Match 区块，请先手动整理，避免修改错误的范围。"
    rm -f -- "$candidate"
    return 1
  fi
  for (( index=0; index<${#settings[@]}; index+=2 )); do
    option="${settings[$index]}"; value="${settings[$((index+1))]}"
    set_sshd_option_in_file "$candidate" "$option" "$value" || { rm -f -- "$candidate"; return 1; }
  done
  apply_ssh_candidate "$candidate" options "${settings[@]}"
}

apply_ssh_candidate() {
  local candidate="$1" mode="$2" config sshd effective key value index valid=1
  shift 2
  local -a expected=("$@")
  config="$(sshd_config_file)"; sshd="$(sshd_bin)"
  backup_file "$SSHD_MANAGED_FILE" || { rm -f -- "$candidate"; return 1; }
  start_network_guard ssh || { rm -f -- "$candidate"; return 1; }
  atomic_install_file "$candidate" "$SSHD_MANAGED_FILE" 0644 || valid=0
  rm -f -- "$candidate"
  if (( valid )); then "$sshd" -t -f "$config" || valid=0; fi
  if (( valid )); then
    effective="$("$sshd" -T -f "$config" 2>/dev/null)" || valid=0
    if [[ "$mode" == ports ]]; then
      for value in "${expected[@]}"; do
        awk -v value="$value" '$1=="port" && $2==value {found=1} END {exit !found}' <<< "$effective" || valid=0
      done
    else
      for (( index=0; index<${#expected[@]}; index+=2 )); do
        key="${expected[$index],,}"; value="${expected[$((index+1))]}"
        [[ "$key" != challengeresponseauthentication ]] || key=kbdinteractiveauthentication
        [[ "$(awk -v key="$key" '$1==key {print $2; exit}' <<< "$effective")" == "$value" ]] || valid=0
      done
    fi
  fi
  if (( valid )); then reload_ssh_service || valid=0; fi
  if (( valid )); then
    if [[ "$mode" == ports ]]; then
      for value in "${expected[@]}"; do
        ssh_port_listening "$value" || { error "SSH 未实际监听 ${value}/tcp。"; valid=0; }
      done
      if (( valid )); then sync_fail2ban_ssh_ports || valid=0; fi
    else
      [[ -n "$(live_ssh_ports)" ]] || valid=0
    fi
  fi
  if (( valid == 0 )); then
    error "SSH 配置、实际监听或 Fail2ban 配套检查未通过，正在恢复。"
    abort_network_guard
    return 1
  fi
  ok "本机检查通过；请从新窗口验证 SSH 登录。"
  finish_network_guard
}

apply_sshd_option() {
  apply_sshd_options "$1" "$2"
}

apply_ssh_ports() {
  local port candidate
  local -a unique=()
  local -A seen=()
  (( $# > 0 )) || return 1
  require_root
  require_ubuntu || return 1
  for port in "$@"; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port>=1 && 10#$port<=65535 )) || return 1
    port="$((10#$port))"
    [[ -z "${seen[$port]:-}" ]] || continue
    unique+=("$port"); seen["$port"]=1
  done
  show_ssh_status
  printf '\n准备保留并监听：%s\n' "${unique[*]}"
  confirm "确认修改 SSH 端口？未确认保留时将自动恢复。" || return 2
  acquire_lock || return 1
  install -d -m 0755 "$(dirname "$SSHD_MANAGED_FILE")" || return 1
  candidate="$(mktemp /tmp/vps-manager-sshd.XXXXXX)" || return 1
  if [[ -f "$SSHD_MANAGED_FILE" ]]; then
    if grep -qiE '^[[:space:]]*Match[[:space:]]' "$SSHD_MANAGED_FILE"; then
      error "管理文件包含自定义 Match 区块，已停止自动修改。"
      rm -f -- "$candidate"; return 1
    fi
    awk 'tolower($1)!="port"' "$SSHD_MANAGED_FILE" > "$candidate" || { rm -f -- "$candidate"; return 1; }
  fi
  for port in "${unique[@]}"; do
    printf 'Port %s\n' "$port" >> "$candidate" || { rm -f -- "$candidate"; return 1; }
  done
  apply_ssh_candidate "$candidate" ports "${unique[@]}"
}

change_ssh_port() {
  local port rc ufw_rule_added=0
  local -a current_ports=() target_ports=()
  mapfile -t current_ports < <(current_ssh_ports)
  if (( ${#current_ports[@]} == 0 )); then
    error "无法识别当前 SSH 端口，拒绝修改。"
    return 1
  fi
  read -r -p "要新增的 SSH 端口（1-65535）：" port
  if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    error "端口不正确。"
    return 1
  fi
  port="$((10#$port))"
  if printf '%s\n' "${current_ports[@]}" | grep -Fxq "$port"; then
    info "SSH 当前已经监听 ${port}/tcp。"
    return 0
  fi
  warn "请先在 VPS 控制台安全组中放行 ${port}/tcp，并保持当前 SSH 会话。"
  confirm "确认安全组已放行并继续？" || return 0
  acquire_lock || return 1
  if ufw_is_active && ! ufw_rule_exists "${port}/tcp"; then
    info "检测到 UFW 已启用，先放行新的 SSH TCP ${port}。"
    log_command interactive ufw allow "${port}/tcp" comment "SSH added by vps-manager" || return 1
    ufw_rule_added=1
  fi

  target_ports=("${current_ports[@]}" "$port")
  apply_ssh_ports "${target_ports[@]}"
  rc=$?
  if (( rc == 0 )); then
    ok "新端口 ${port}/tcp 已生效；原 SSH 端口 ${current_ports[*]} 均继续保留。"
    warn "请先用新窗口验证 ${port}/tcp，再考虑手动清理任何旧端口。"
    return 0
  fi
  if (( rc == 2 && ufw_rule_added )); then
    log_command quiet ufw --force delete allow "${port}/tcp" || warn "已取消 SSH 修改，但新增 UFW 规则需要手动检查：${port}/tcp"
  elif (( rc != 2 && ufw_rule_added )); then
    warn "SSH 修改失败；为避免误封，暂时保留新增 UFW 规则 ${port}/tcp，请检查后手动处理。"
  fi
  (( rc == 2 )) && { info "已取消 SSH 端口修改。"; return 0; }
  return 1
}

default_authorized_keys_enabled() {
  local sshd_output path
  sshd_output="$("$(sshd_bin)" -T 2>/dev/null || true)"
  [[ "$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$sshd_output")" == "yes" ]] || return 1
  while IFS= read -r path; do
    case "$path" in
      .ssh/authorized_keys|%h/.ssh/authorized_keys) return 0 ;;
    esac
  done < <(awk '$1=="authorizedkeysfile" {for (i=2; i<=NF; i++) print $i}' <<< "$sshd_output")
  return 1
}

authorized_keys_present() {
  local file user shell permit_root="no"
  default_authorized_keys_enabled || return 1
  permit_root="$("$(sshd_bin)" -T 2>/dev/null | awk '$1=="permitrootlogin" {print $2; exit}')"
  if [[ -s /root/.ssh/authorized_keys && "$permit_root" != "no" ]]; then
    return 0
  fi
  for file in /home/*/.ssh/authorized_keys; do
    [[ -s "$file" ]] || continue
    user="${file#/home/}"
    user="${user%%/*}"
    shell="$(getent passwd "$user" 2>/dev/null | awk -F: '{print $7}')"
    case "$shell" in
      ""|*/false|*/nologin) continue ;;
      *) return 0 ;;
    esac
  done
  return 1
}

disable_password_login() {
  if ! authorized_keys_present; then
    error "未检测到已启用的默认公钥登录配置和候选 authorized_keys，拒绝关闭密码登录。"
    return 1
  fi
  warn "关闭密码登录前，请保持当前会话，并另开窗口验证公钥登录。"
  apply_sshd_options \
    PasswordAuthentication no \
    KbdInteractiveAuthentication no \
    ChallengeResponseAuthentication no
}

sudo_authorized_key_present() {
  local file user shell
  default_authorized_keys_enabled || return 1
  for file in /home/*/.ssh/authorized_keys; do
    [[ -s "$file" ]] || continue
    user="${file#/home/}"
    user="${user%%/*}"
    shell="$(getent passwd "$user" 2>/dev/null | awk -F: '{print $7}')"
    case "$shell" in
      ""|*/false|*/nologin) continue ;;
    esac
    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo && return 0
  done
  return 1
}

disable_root_login() {
  if ! sudo_authorized_key_present; then
    error "未检测到已启用默认公钥登录且具备 sudo 权限的普通用户，拒绝关闭 root 登录。"
    return 1
  fi
  warn "请先用该 sudo 用户在新窗口验证 SSH 登录，再关闭 root 登录。"
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
    printf '  6. 新增 SSH 端口（保留现有端口）\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice || return 0
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

fail2ban_runtime_actions() {
  fail2ban-client get "$FAIL2BAN_JAIL" actions 2>/dev/null | tr ',' '\n' |
    awk '/^[[:space:]]*[[:alnum:]_.-]+[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$0); print}'
}

fail2ban_runtime_ports() {
  local action ports found=0
  while IFS= read -r action; do
    ports="$(fail2ban-client get "$FAIL2BAN_JAIL" action "$action" port 2>/dev/null)" || continue
    [[ -n "$ports" ]] || continue
    printf '%s: %s\n' "$action" "$ports"
    found=1
  done < <(fail2ban_runtime_actions)
  (( found ))
}

show_fail2ban_status() {
  local status maxretry findtime bantime
  if ! command -v fail2ban-client >/dev/null 2>&1; then printf 'Fail2ban：未安装（可选功能）\n'; return 0; fi
  if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    printf 'Fail2ban：未运行\n开机启动：%s\n' "$(systemctl is-enabled fail2ban 2>/dev/null || true)"
    return 0
  fi
  if ! status="$(LC_ALL=C fail2ban-client status "$FAIL2BAN_JAIL" 2>/dev/null)"; then
    printf 'Fail2ban：运行中；SSH 防护未启用或未就绪\n'
    return 0
  fi
  printf 'Fail2ban：运行中；SSH 防护已启用\n实际封禁动作与端口：\n'
  fail2ban_runtime_ports || printf '  自定义动作，无法自动读取端口，请核对其配置。\n'
  printf '%s\n' "$status" | awk -F: '
    /Currently failed/ {print "当前失败记录：" $2}
    /Total failed/ {print "累计失败记录：" $2}
    /Currently banned/ {print "当前封禁数量：" $2}
    /Total banned/ {print "累计封禁数量：" $2}
    /Banned IP list/ {sub(/^[^:]*:/, ""); print "封禁 IP：" $0}'
  maxretry="$(fail2ban-client get "$FAIL2BAN_JAIL" maxretry 2>/dev/null || true)"
  findtime="$(fail2ban-client get "$FAIL2BAN_JAIL" findtime 2>/dev/null || true)"
  bantime="$(fail2ban-client get "$FAIL2BAN_JAIL" bantime 2>/dev/null || true)"
  printf '生效规则：%s 秒内失败 %s 次，封禁 %s 秒\n' "$findtime" "$maxretry" "$bantime"
}

wait_for_fail2ban_sshd() {
  local attempt
  for (( attempt=1; attempt<=10; attempt++ )); do
    fail2ban-client status sshd >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

fail2ban_sshd_rule_matches() {
  [[ "$(fail2ban-client get "$FAIL2BAN_JAIL" maxretry 2>/dev/null || true)" == "${1:-5}" ]] &&
    [[ "$(fail2ban-client get "$FAIL2BAN_JAIL" findtime 2>/dev/null || true)" == "${2:-600}" ]] &&
    [[ "$(fail2ban-client get "$FAIL2BAN_JAIL" bantime 2>/dev/null || true)" == "${3:-3600}" ]]
}

ports_cover_expected() {
  local required_ports="$1" configured="$2" token wanted start end found
  local -a tokens=() requested=()
  configured="${configured//,/ }"; required_ports="${required_ports//,/ }"
  read -r -a tokens <<< "$configured"
  read -r -a requested <<< "$required_ports"
  (( ${#tokens[@]} && ${#requested[@]} )) || return 1
  for wanted in "${requested[@]}"; do
    [[ "$wanted" =~ ^[0-9]{1,5}$ ]] || return 1
    found=0
    for token in "${tokens[@]}"; do
      if [[ "$token" == ssh ]]; then token=22; fi
      if [[ "$token" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
        (( 10#$start<=10#$wanted && 10#$wanted<=10#$end )) && found=1
      elif [[ "$token" =~ ^[0-9]{1,5}$ ]] && (( 10#$token == 10#$wanted )); then
        found=1
      fi
    done
    (( found )) || return 1
  done
}

fail2ban_effective_ports_match() {
  local required_ports="$1" action ports protocol ban type
  while IFS= read -r action; do
    ban="$(fail2ban-client get "$FAIL2BAN_JAIL" action "$action" actionban 2>/dev/null)" || continue
    case "$ban" in *nft*|*iptables*|*ip6tables*|*ufw*|*firewall-cmd*) ;; *) continue ;; esac
    protocol="$(fail2ban-client get "$FAIL2BAN_JAIL" action "$action" protocol 2>/dev/null)" || continue
    [[ "$protocol" == tcp || "$protocol" == all ]] || continue
    type="$(fail2ban-client get "$FAIL2BAN_JAIL" action "$action" type 2>/dev/null || true)"
    [[ "$type" != allports ]] || return 0
    ports="$(fail2ban-client get "$FAIL2BAN_JAIL" action "$action" port 2>/dev/null)" || continue
    ports_cover_expected "$required_ports" "$ports" && return 0
  done < <(fail2ban_runtime_actions)
  return 1
}

fail2ban_disk_jail_enabled() {
  local dump
  dump="$(timeout 35s fail2ban-client -d 2>/dev/null)" || return 2
  [[ -n "$dump" ]] || return 2
  grep -Eq "^\\['add',[[:space:]]*'sshd'," <<< "$dump"
}

set_fail2ban_key() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$(mktemp /tmp/vps-manager-jail-key.XXXXXX)" || return 1
  awk -v key="$key" -v value="$value" '
    function finish() {if (inside && !written) {print key " = " value; written=1}}
    /^[[:space:]]*\[/ {
      finish(); inside=($0 ~ /^[[:space:]]*\[sshd\][[:space:]]*$/)
      if (inside) found=1
    }
    inside && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {if (!written) print key " = " value; written=1; next}
    {print}
    END {finish(); if (!found) print "\n[sshd]\n" key " = " value}
  ' "$file" > "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -f -- "$temporary" "$file" || { rm -f -- "$temporary"; return 1; }
}

validate_fail2ban_configuration() {
  local details candidate
  if details="$(timeout 35s fail2ban-client -t 2>&1)"; then return 0; fi
  # Fail2ban cannot interpolate known/ignoreip when no earlier file defines it.
  # Only our exact template is eligible for this fallback; all other errors fail.
  if [[ "$details" == *known/ignoreip* ]] &&
    grep -Fxq 'ignoreip = %(known/ignoreip)s %(vps_manager_whitelist)s' "$FAIL2BAN_JAIL_FILE"; then
    candidate="$(mktemp /tmp/vps-manager-jail-fallback.XXXXXX)" || return 1
    cp -- "$FAIL2BAN_JAIL_FILE" "$candidate" || { rm -f -- "$candidate"; return 1; }
    if ! set_fail2ban_key "$candidate" ignoreip '%(vps_manager_whitelist)s' ||
      ! atomic_install_file "$candidate" "$FAIL2BAN_JAIL_FILE" 0644; then
      rm -f -- "$candidate"; return 1
    fi
    rm -f -- "$candidate"
    timeout 35s fail2ban-client -t
    return $?
  fi
  printf '%s\n' "$details" >&2
  return 1
}

apply_fail2ban_candidate() {
  local candidate="$1" enabled="$2" ports="${3:-}" maxretry="${4:-5}" findtime="${5:-600}" bantime="${6:-3600}"
  local snapshot had_file=0 was_active=0 was_jail=0 failed=0 disk_rc
  snapshot="$(mktemp /tmp/vps-manager-jail-old.XXXXXX)" || { rm -f -- "$candidate"; return 1; }
  if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    cp -a -- "$FAIL2BAN_JAIL_FILE" "$snapshot" || { rm -f -- "$candidate" "$snapshot"; return 1; }
    had_file=1
  fi
  [[ ! -L "$FAIL2BAN_JAIL_FILE" ]] || { error "Fail2ban 管理路径是软链接，停止修改。"; rm -f -- "$candidate" "$snapshot"; return 1; }
  systemctl is-active --quiet fail2ban 2>/dev/null && was_active=1
  fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1 && was_jail=1
  backup_file "$FAIL2BAN_JAIL_FILE" || failed=1
  (( failed )) || atomic_install_file "$candidate" "$FAIL2BAN_JAIL_FILE" 0644 || failed=1
  rm -f -- "$candidate"
  (( failed )) || validate_fail2ban_configuration || failed=1
  if (( failed == 0 )); then
    fail2ban_disk_jail_enabled; disk_rc=$?
    if [[ "$enabled" == true ]]; then (( disk_rc == 0 )) || failed=1
    else (( disk_rc == 1 )) || failed=1; fi
  fi
  if (( failed == 0 )); then
    if [[ "$enabled" == true ]]; then
      if (( was_active )); then
        if (( was_jail )); then timeout 35s fail2ban-client reload --restart "$FAIL2BAN_JAIL" || failed=1
        else timeout 35s fail2ban-client reload || failed=1; fi
      else timeout 35s systemctl start fail2ban || failed=1; fi
      (( failed )) || wait_for_fail2ban_sshd || failed=1
      (( failed )) || fail2ban_sshd_rule_matches "$maxretry" "$findtime" "$bantime" || failed=1
      (( failed )) || fail2ban_effective_ports_match "$ports" || failed=1
      if (( failed == 0 )) && [[ -n "${8:-}" ]]; then
        fail2ban_ignored_network_present "$8" || failed=1
      fi
    elif (( was_active )); then
      timeout 35s fail2ban-client reload || failed=1
      if fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1; then failed=1; fi
    fi
  fi
  if (( failed )); then
    restore_file_snapshot "$snapshot" "$had_file" "$FAIL2BAN_JAIL_FILE" || warn "配置文件恢复失败，请检查备份。"
    if (( was_active )); then
      if (( was_jail )) && fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1; then
        timeout 35s fail2ban-client reload --restart "$FAIL2BAN_JAIL" >/dev/null 2>&1 || warn "原 SSH 防护重载失败。"
      else timeout 35s fail2ban-client reload >/dev/null 2>&1 || warn "原 Fail2ban 配置重载失败。"; fi
    else timeout 35s systemctl stop fail2ban >/dev/null 2>&1 || true; fi
    rm -f -- "$snapshot"
    error "Fail2ban 配置或实际生效状态不符，已尝试恢复；请检查其他 .local 覆盖或自定义封禁动作。"
    return 1
  fi
  rm -f -- "$snapshot"
  if [[ "$enabled" == true && "${7:-false}" == true ]] && ! systemctl enable fail2ban >/dev/null 2>&1; then
    warn "防护已运行，但开机启动设置失败，请检查服务状态。"
    return 1
  fi
}

fail2ban_candidate() {
  local candidate
  install -d -m 0755 "$(dirname "$FAIL2BAN_JAIL_FILE")" || return 1
  candidate="$(mktemp /tmp/vps-manager-jail.XXXXXX)" || return 1
  if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    cp -- "$FAIL2BAN_JAIL_FILE" "$candidate" || { rm -f -- "$candidate"; return 1; }
  fi
  printf '%s\n' "$candidate"
}

sync_fail2ban_ssh_ports() {
  local ports candidate maxretry findtime bantime
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1 || return 0
  ports="$(current_ssh_ports | paste -sd, -)" || return 1
  [[ -n "$ports" ]] || return 1
  maxretry="$(fail2ban-client get "$FAIL2BAN_JAIL" maxretry)" || return 1
  findtime="$(fail2ban-client get "$FAIL2BAN_JAIL" findtime)" || return 1
  bantime="$(fail2ban-client get "$FAIL2BAN_JAIL" bantime)" || return 1
  candidate="$(fail2ban_candidate)" || return 1
  set_fail2ban_key "$candidate" port "$ports" || { rm -f -- "$candidate"; return 1; }
  apply_fail2ban_candidate "$candidate" true "$ports" "$maxretry" "$findtime" "$bantime" || return 1
  ok "Fail2ban 已核对运行中的封禁动作，覆盖 SSH TCP 端口 ${ports}。"
}

enable_fail2ban() {
  local ports candidate key value
  require_root
  require_ubuntu || return 1
  ports="$(current_ssh_ports | paste -sd, -)" || return 1
  [[ -n "$ports" ]] || return 1
  info "Fail2ban 用于拦截重复失败的 SSH 登录，不是网站或 DDoS 防护。"
  info "将启用 SSH 端口 ${ports} 的防护：10 分钟内失败 5 次，封禁 1 小时。"
  if fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1; then
    info 'SSH 防护已经运行；如需调整规则，请使用安全菜单中的「调整规则」。'
    show_fail2ban_status
    return 0
  fi
  confirm "确认安装并启用？" || return 0
  acquire_lock || return 1
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y fail2ban python3-systemd || return 1
  candidate="$(fail2ban_candidate)" || return 1
  while read -r key value; do
    set_fail2ban_key "$candidate" "$key" "$value" || { rm -f -- "$candidate"; return 1; }
  done <<EOF
 enabled true
 filter sshd
 port ${ports}
 protocol tcp
 backend systemd
 maxretry 5
 findtime 600
 bantime 3600
EOF
  apply_fail2ban_candidate "$candidate" true "$ports" 5 600 3600 true || return 1
  ok "SSH 防护已启用，运行中的规则及封禁端口已核对。"
  log_line "fail2ban sshd enabled on verified ports ${ports}"
  show_fail2ban_status
}

disable_fail2ban() {
  local candidate
  require_root
  require_ubuntu || return 1
  command -v fail2ban-client >/dev/null 2>&1 || { info "未安装 Fail2ban。"; return 0; }
  warn "将明确停用 sshd 防护，包括其他配置启用的同名 jail；其他 jail 不变，也不卸载软件。"
  confirm "确认关闭 SSH 防护？" || return 0
  acquire_lock || return 1
  candidate="$(fail2ban_candidate)" || return 1
  set_fail2ban_key "$candidate" enabled false || { rm -f -- "$candidate"; return 1; }
  apply_fail2ban_candidate "$candidate" false || return 1
  ok "SSH 防护已关闭；配置合并结果与运行状态均已核对。"
  log_line "fail2ban sshd explicitly disabled and verified"
}

configure_fail2ban_rules() {
  local retry window_minutes ban_minutes candidate ports key value
  require_root
  require_ubuntu || return 1
  fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1 || { error "请先启用 SSH 防护。"; return 1; }
  show_fail2ban_status
  read -r -p "允许失败次数 [5]：" retry || return 1
  read -r -p "统计多少分钟内的失败 [10]：" window_minutes || return 1
  read -r -p "封禁多少分钟 [60]：" ban_minutes || return 1
  retry="${retry:-5}"; window_minutes="${window_minutes:-10}"; ban_minutes="${ban_minutes:-60}"
  [[ "$retry" =~ ^[0-9]{1,2}$ && "$window_minutes" =~ ^[0-9]{1,4}$ && "$ban_minutes" =~ ^[0-9]{1,5}$ ]] || { error "请输入整数。"; return 1; }
  retry="$((10#$retry))"; window_minutes="$((10#$window_minutes))"; ban_minutes="$((10#$ban_minutes))"
  (( retry>=1 && retry<=20 && window_minutes>=1 && window_minutes<=1440 && ban_minutes>=1 && ban_minutes<=10080 )) || {
    error "次数应为 1–20，统计窗口 1–1440 分钟，封禁 1–10080 分钟。"; return 1;
  }
  confirm "设置为 ${window_minutes} 分钟内失败 ${retry} 次，封禁 ${ban_minutes} 分钟？" || return 0
  acquire_lock || return 1
  ports="$(current_ssh_ports | paste -sd, -)" || return 1
  candidate="$(fail2ban_candidate)" || return 1
  while read -r key value; do
    set_fail2ban_key "$candidate" "$key" "$value" || { rm -f -- "$candidate"; return 1; }
  done <<EOF
 maxretry ${retry}
 findtime $((window_minutes*60))
 bantime $((ban_minutes*60))
 port ${ports}
EOF
  apply_fail2ban_candidate "$candidate" true "$ports" "$retry" "$((window_minutes*60))" "$((ban_minutes*60))" || return 1
  show_fail2ban_status
}

normalize_ip_network() {
  python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$1" 2>/dev/null
}

fail2ban_ignored_network_present() {
  local wanted="$1" raw token normalized
  raw="$(fail2ban-client get "$FAIL2BAN_JAIL" ignoreip 2>/dev/null)" || return 1
  raw="$(printf '%s' "$raw" | tr "[],'|" '     ')"
  for token in $raw; do
    [[ "$token" == *.* || "$token" == *:* ]] || continue
    normalized="$(normalize_ip_network "$token")" || continue
    [[ "$normalized" != "$wanted" ]] || return 0
  done
  return 1
}

edit_fail2ban_whitelist() {
  local operation="$1" address normalized current="" entry candidate ports maxretry findtime bantime expected_network=""
  local -a entries=() result=()
  require_root
  require_ubuntu || return 1
  fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1 || { error "请先启用 SSH 防护。"; return 1; }
  fail2ban-client get "$FAIL2BAN_JAIL" ignoreip || return 1
  info "只管理通过本工具添加的可信 IP；系统原有白名单继续保留。"
  read -r -p "可信 IP 或网段（例如 203.0.113.8；留空取消）：" address || return 1
  [[ -n "$address" ]] || return 0
  normalized="$(normalize_ip_network "$address")" || { error "IP 或网段格式不正确。"; return 1; }
  [[ "$normalized" != */0 ]] || { error "不能把整个互联网加入白名单。"; return 1; }
  if [[ -f "$FAIL2BAN_JAIL_FILE" ]]; then
    current="$(awk -F= '/^[[:space:]]*ignoreip[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$FAIL2BAN_JAIL_FILE")"
  fi
  if [[ "$current" == *'%(vps_manager_whitelist)s'* ]]; then
    current="$(awk '/^[[:space:]]*vps_manager_whitelist[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$FAIL2BAN_JAIL_FILE")"
  elif [[ -n "$current" && "$current" != '%(known/ignoreip)s'* ]]; then
    error "管理文件已有手工白名单，为保留原设置，请手动整理该行后再使用此菜单。"
    return 1
  else
    current="${current#'%(known/ignoreip)s'}"
  fi
  read -r -a entries <<< "$current"
  for entry in "${entries[@]}"; do [[ "$entry" == "$normalized" ]] || result+=("$entry"); done
  if [[ "$operation" == add ]]; then result+=("$normalized"); fi
  printf '本工具保留的可信地址：%s\n' "${result[*]:-无}"
  warn "白名单地址不会因失败登录被本 jail 自动封禁；仅添加你信任且稳定的来源。"
  confirm "确认更新白名单？" || return 0
  acquire_lock || return 1
  candidate="$(fail2ban_candidate)" || return 1
  set_fail2ban_key "$candidate" vps_manager_whitelist "${result[*]}" || { rm -f -- "$candidate"; return 1; }
  set_fail2ban_key "$candidate" ignoreip '%(known/ignoreip)s %(vps_manager_whitelist)s' || { rm -f -- "$candidate"; return 1; }
  ports="$(current_ssh_ports | paste -sd, -)" || { rm -f -- "$candidate"; return 1; }
  maxretry="$(fail2ban-client get "$FAIL2BAN_JAIL" maxretry)" || { rm -f -- "$candidate"; return 1; }
  findtime="$(fail2ban-client get "$FAIL2BAN_JAIL" findtime)" || { rm -f -- "$candidate"; return 1; }
  bantime="$(fail2ban-client get "$FAIL2BAN_JAIL" bantime)" || { rm -f -- "$candidate"; return 1; }
  [[ "$operation" != add ]] || expected_network="$normalized"
  apply_fail2ban_candidate "$candidate" true "$ports" "$maxretry" "$findtime" "$bantime" false "$expected_network" || return 1
  ok "白名单配置已更新。继承自系统其他文件的可信地址不会被此菜单删除。"
  fail2ban-client get "$FAIL2BAN_JAIL" ignoreip
}

unban_fail2ban_ip() {
  local address
  require_root
  require_ubuntu || return 1
  fail2ban-client status "$FAIL2BAN_JAIL" >/dev/null 2>&1 || { error "SSH 防护未运行。"; return 1; }
  show_fail2ban_status
  read -r -p "要解封的单个 IP（留空取消）：" address || return 1
  [[ -n "$address" ]] || return 0
  validate_ipv4 "$address" || validate_ipv6 "$address" || { error "请输入有效的单个 IP，不能填写网段。"; return 1; }
  confirm "确认从 SSH jail 解封 ${address}？" || return 0
  acquire_lock || return 1
  fail2ban-client set "$FAIL2BAN_JAIL" unbanip "$address" || return 1
  ok "已执行解封；如后续仍持续登录失败，该地址可能再次被封禁。"
  show_fail2ban_status
}

show_auto_updates_status() {
  local list_state="未启用" upgrade_state="未启用" reboot_state="未明确关闭" timer_state="异常" effective
  if ! dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    printf '自动安全更新：未安装\n'
    return 0
  fi
  effective="$(apt-config dump 2>/dev/null)" || { warn "无法读取 APT 生效配置。"; return 1; }
  grep -q 'APT::Periodic::Update-Package-Lists "1";' <<< "$effective" && list_state="每天"
  grep -q 'APT::Periodic::Unattended-Upgrade "1";' <<< "$effective" && upgrade_state="每天"
  grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$effective" && reboot_state="关闭"
  if systemctl is-active --quiet apt-daily.timer 2>/dev/null && systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
    timer_state="正常"
  fi
  printf '自动安全更新：已安装\n'
  printf '软件包列表更新：%s\n' "$list_state"
  printf '安全更新安装：%s\n' "$upgrade_state"
  printf '自动重启：%s\n' "$reboot_state"
  printf 'APT 定时器：%s\n' "$timer_state"
}

restore_file_snapshot() {
  local snapshot="$1" had_file="$2" target="$3"
  if (( had_file )); then
    cp -a -- "$snapshot" "$target"
  else
    rm -f -- "$target"
  fi
}

enable_auto_updates() {
  local periodic_tmp options_tmp periodic_snapshot options_snapshot apt_dump
  local had_periodic=0 had_options=0 failed=0 timer_attempted=0
  require_root
  require_ubuntu || return 1
  info "将启用 unattended-upgrades 周期执行，沿用系统现有允许来源；不会自动重启。"
  confirm "确认安装并启用自动安全更新？" || return 0
  acquire_lock || return 1
  relocate_legacy_apt_backups || { error "迁移旧版 APT 备份失败，已停止配置。"; return 1; }
  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1

  periodic_tmp="$(mktemp /tmp/vps-manager-auto-periodic.XXXXXX)" || return 1
  options_tmp="$(mktemp /tmp/vps-manager-auto-options.XXXXXX)" || { rm -f -- "$periodic_tmp"; return 1; }
  periodic_snapshot="$(mktemp /tmp/vps-manager-auto-periodic-old.XXXXXX)" || { rm -f -- "$periodic_tmp" "$options_tmp"; return 1; }
  options_snapshot="$(mktemp /tmp/vps-manager-auto-options-old.XXXXXX)" || { rm -f -- "$periodic_tmp" "$options_tmp" "$periodic_snapshot"; return 1; }
  if [[ -f "$AUTO_UPGRADES_FILE" ]]; then cp -a -- "$AUTO_UPGRADES_FILE" "$periodic_snapshot" || failed=1; had_periodic=1; fi
  if [[ -f "$AUTO_UPGRADES_OPTIONS_FILE" ]]; then cp -a -- "$AUTO_UPGRADES_OPTIONS_FILE" "$options_snapshot" || failed=1; had_options=1; fi
  (( failed == 0 )) || { rm -f -- "$periodic_tmp" "$options_tmp" "$periodic_snapshot" "$options_snapshot"; return 1; }
  backup_file "$AUTO_UPGRADES_FILE" || failed=1
  (( failed )) || backup_file "$AUTO_UPGRADES_OPTIONS_FILE" || failed=1
  {
    printf 'APT::Periodic::Update-Package-Lists "1";\n'
    printf 'APT::Periodic::Unattended-Upgrade "1";\n'
  } > "$periodic_tmp" || failed=1
  {
    printf 'Unattended-Upgrade::Automatic-Reboot "false";\n'
    printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";\n'
    printf 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";\n'
  } > "$options_tmp" || failed=1
  (( failed )) || atomic_install_file "$periodic_tmp" "$AUTO_UPGRADES_FILE" 0644 || failed=1
  (( failed )) || atomic_install_file "$options_tmp" "$AUTO_UPGRADES_OPTIONS_FILE" 0644 || failed=1

  if (( failed == 0 )); then
    apt_dump="$(apt-config dump 2>/dev/null || true)"
    grep -q 'APT::Periodic::Update-Package-Lists "1";' <<< "$apt_dump" || failed=1
    grep -q 'APT::Periodic::Unattended-Upgrade "1";' <<< "$apt_dump" || failed=1
    grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' <<< "$apt_dump" || failed=1
  fi
  if (( failed == 0 )); then
    timer_attempted=1
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || failed=1
  fi

  rm -f -- "$periodic_tmp" "$options_tmp"
  if (( failed )); then
    restore_file_snapshot "$periodic_snapshot" "$had_periodic" "$AUTO_UPGRADES_FILE" || true
    restore_file_snapshot "$options_snapshot" "$had_options" "$AUTO_UPGRADES_OPTIONS_FILE" || true
    rm -f -- "$periodic_snapshot" "$options_snapshot"
    (( timer_attempted == 0 )) || warn "APT timer 可能部分启用，请检查 systemctl 状态。"
    error "自动更新配置未通过验证，已恢复原配置文件。"
    return 1
  fi
  rm -f -- "$periodic_snapshot" "$options_snapshot"
  ok "自动更新已启用并通过配置与 timer 检查，自动重启保持关闭。"
  log_line "unattended-upgrades enabled without automatic reboot"
  show_auto_updates_status
}

disable_auto_updates() {
  local periodic_tmp periodic_snapshot options_snapshot apt_dump
  local had_periodic=0 had_options=0 failed=0
  require_root
  require_ubuntu || return 1
  warn "不会卸载 unattended-upgrades，只会关闭周期执行并删除脚本管理的附加选项。"
  confirm "确认关闭自动安全更新？" || return 0
  acquire_lock || return 1
  periodic_tmp="$(mktemp /tmp/vps-manager-auto-periodic.XXXXXX)" || return 1
  periodic_snapshot="$(mktemp /tmp/vps-manager-auto-periodic-old.XXXXXX)" || { rm -f -- "$periodic_tmp"; return 1; }
  options_snapshot="$(mktemp /tmp/vps-manager-auto-options-old.XXXXXX)" || { rm -f -- "$periodic_tmp" "$periodic_snapshot"; return 1; }
  if [[ -f "$AUTO_UPGRADES_FILE" ]]; then cp -a -- "$AUTO_UPGRADES_FILE" "$periodic_snapshot" || failed=1; had_periodic=1; fi
  if [[ -f "$AUTO_UPGRADES_OPTIONS_FILE" ]]; then cp -a -- "$AUTO_UPGRADES_OPTIONS_FILE" "$options_snapshot" || failed=1; had_options=1; fi
  (( failed == 0 )) || { rm -f -- "$periodic_tmp" "$periodic_snapshot" "$options_snapshot"; return 1; }
  backup_file "$AUTO_UPGRADES_FILE" || failed=1
  (( failed )) || backup_file "$AUTO_UPGRADES_OPTIONS_FILE" || failed=1
  {
    printf 'APT::Periodic::Update-Package-Lists "0";\n'
    printf 'APT::Periodic::Unattended-Upgrade "0";\n'
  } > "$periodic_tmp" || failed=1
  (( failed )) || atomic_install_file "$periodic_tmp" "$AUTO_UPGRADES_FILE" 0644 || failed=1
  (( failed )) || rm -f -- "$AUTO_UPGRADES_OPTIONS_FILE" || failed=1
  if (( failed == 0 )); then
    apt_dump="$(apt-config dump 2>/dev/null || true)"
    grep -q 'APT::Periodic::Update-Package-Lists "0";' <<< "$apt_dump" || failed=1
    grep -q 'APT::Periodic::Unattended-Upgrade "0";' <<< "$apt_dump" || failed=1
  fi
  rm -f -- "$periodic_tmp"
  if (( failed )); then
    restore_file_snapshot "$periodic_snapshot" "$had_periodic" "$AUTO_UPGRADES_FILE" || true
    restore_file_snapshot "$options_snapshot" "$had_options" "$AUTO_UPGRADES_OPTIONS_FILE" || true
    rm -f -- "$periodic_snapshot" "$options_snapshot"
    error "关闭自动安全更新失败，已恢复原配置。"
    return 1
  fi
  rm -f -- "$periodic_snapshot" "$options_snapshot"
  ok "自动安全更新周期已关闭并通过配置检查。"
}

security_menu() {
  local choice
  require_root
  while true; do
    printf '\n安全防护：\n'
    printf '  1. 查看 Fail2ban 状态\n'
    printf '  2. 安装并启用 SSH 防护（推荐默认规则）\n'
    printf '  3. 关闭 SSH 防护（不影响其他 jail）\n'
    printf '  4. 查看自动安全更新状态\n'
    printf '  5. 安装并启用自动安全更新\n'
    printf '  6. 关闭自动安全更新\n'
    printf '  7. 调整 SSH 防护规则\n'
    printf '  8. 添加可信 IP / 网段\n'
    printf '  9. 移除本工具添加的可信 IP / 网段\n'
    printf ' 10. 解封单个 IP\n'
    printf '  0. 返回\n'
    read -r -p "请选择：" choice || return 0
    case "$choice" in
      1) show_fail2ban_status; pause ;;
      2) enable_fail2ban; pause ;;
      3) disable_fail2ban; pause ;;
      4) show_auto_updates_status; pause ;;
      5) enable_auto_updates; pause ;;
      6) disable_auto_updates; pause ;;
      7) configure_fail2ban_rules; pause ;;
      8) edit_fail2ban_whitelist add; pause ;;
      9) edit_fail2ban_whitelist remove; pause ;;
      10) unban_fail2ban_ip; pause ;;
      0) return 0 ;;
      *) error "无效选项。"; pause ;;
    esac
  done
}

http_access_status() {
  local url="$1" code
  code="$(curl -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36' \
    -sS -L --connect-timeout 4 -m 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
  case "$code" in
    2??|3??|400|401|404|405|409|422|429) printf '可以访问' ;;
    403|451) printf '不可访问' ;;
    *) printf '检测失败' ;;
  esac
}

show_access_origin() {
  local trace ip country
  trace="$(curl -fsS --connect-timeout 4 -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  ip="$(printf '%s\n' "$trace" | awk -F= '$1=="ip" {print $2; exit}')"
  country="$(printf '%s\n' "$trace" | awk -F= '$1=="loc" {print $2; exit}')"
  printf '公网出口 IP：%s\n' "${ip:-不可用}"
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
  rm -rf -- "$temporary"
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
  printf '\nDocker 官方源：\n'
  local source_file found_source=0
  while IFS= read -r source_file; do
    found_source=1
    printf '  %s\n' "$source_file"
    sed -n '1,20p' "$source_file"
  done < <(find_docker_official_sources)
  (( found_source )) || printf '  未检测到\n'
}

find_docker_official_sources() (
  local source_file
  local -a candidates=("${APT_SOURCE_ROOT}/sources.list")
  shopt -s nullglob
  candidates+=("${APT_SOURCE_ROOT}"/sources.list.d/*.list "${APT_SOURCE_ROOT}"/sources.list.d/*.sources)
  shopt -u nullglob
  for source_file in "${candidates[@]}"; do
    [[ -f "$source_file" ]] || continue
    if grep -Eq '^[[:space:]]*(deb([^[:alnum:]]|$)|URIs:).*https://download\.docker\.com/linux/ubuntu([[:space:]]|$)' "$source_file" 2>/dev/null; then
      printf '%s\n' "$source_file"
    fi
  done
)

restore_docker_repo_state() {
  local key_snapshot="$1" had_key="$2" source_snapshot="$3" had_source="$4"
  local failed=0
  restore_file_snapshot "$key_snapshot" "$had_key" "$DOCKER_KEY_FILE" || failed=1
  restore_file_snapshot "$source_snapshot" "$had_source" "$DOCKER_SOURCE_FILE" || failed=1
  (( failed == 0 ))
}

docker_pending_upgrades() {
  local package installed candidate
  for package in "$@"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || continue
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    candidate="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null | awk '/^[[:space:]]*Candidate:/{print $2; exit}')"
    [[ -n "$installed" && -n "$candidate" && "$candidate" != "(none)" && "$candidate" != "$installed" ]] || continue
    printf '%s: %s -> %s\n' "$package" "$installed" "$candidate"
  done
}

install_docker_official() {
  local codename architecture package key_candidate="" source_candidate="" key_snapshot="" source_snapshot="" rc=0
  local existing_source="" had_key=0 had_source=0 repo_ready=0 reuse_existing=0
  local -a conflicts=() official_sources=() pending_upgrades=()
  local -a conflict_packages=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
  local -a docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  require_root
  require_ubuntu || return 1
  codename="$(ubuntu_codename)"
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
  info "准备验证 Docker 官方 Ubuntu 仓库：${codename}/${architecture}。"
  if (( ${#conflicts[@]} > 0 )); then
    warn "检测到与 Docker CE 官方包冲突的软件包：${conflicts[*]}"
    warn "仓库和安装包验证完成后才会请求移除；不会自动删除 /var/lib/docker。"
  fi
  confirm "确认开始准备 Docker Engine 安装或更新？" || return 0
  acquire_lock || return 1

  mapfile -t official_sources < <(find_docker_official_sources)
  if (( ${#official_sources[@]} > 1 )); then
    error "检测到多个 Docker 官方仓库定义，拒绝继续以避免 Signed-By 冲突："
    printf '  %s\n' "${official_sources[@]}" >&2
    return 1
  fi
  if (( ${#official_sources[@]} == 1 )); then
    existing_source="${official_sources[0]}"
  fi

  log_command interactive apt-get update || return 1
  log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl || return 1

  if [[ -n "$existing_source" && "$existing_source" != "$DOCKER_SOURCE_FILE" ]]; then
    reuse_existing=1
    info "检测到现有 Docker 官方源，将原样复用，不创建重复源：${existing_source}"
    if log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install --download-only -y "${docker_packages[@]}"; then
      repo_ready=1
    fi
  else
    install -d -m 0755 "$(dirname "$DOCKER_KEY_FILE")" || return 1
    install -d -m 0755 "$(dirname "$DOCKER_SOURCE_FILE")" || return 1
    key_candidate="$(mktemp /tmp/vps-manager-docker-key.XXXXXX)" || return 1
    source_candidate="$(mktemp /tmp/vps-manager-docker-source.XXXXXX)" || { rm -f -- "$key_candidate"; return 1; }
    key_snapshot="$(mktemp /tmp/vps-manager-docker-key-old.XXXXXX)" || { rm -f -- "$key_candidate" "$source_candidate"; return 1; }
    source_snapshot="$(mktemp /tmp/vps-manager-docker-source-old.XXXXXX)" || { rm -f -- "$key_candidate" "$source_candidate" "$key_snapshot"; return 1; }
    if [[ -f "$DOCKER_KEY_FILE" ]]; then cp -a -- "$DOCKER_KEY_FILE" "$key_snapshot" || { rm -f -- "$key_candidate" "$source_candidate" "$key_snapshot" "$source_snapshot"; return 1; }; had_key=1; fi
    if [[ -f "$DOCKER_SOURCE_FILE" ]]; then cp -a -- "$DOCKER_SOURCE_FILE" "$source_snapshot" || { rm -f -- "$key_candidate" "$source_candidate" "$key_snapshot" "$source_snapshot"; return 1; }; had_source=1; fi

    if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_TOTAL_TIMEOUT" --retry 2 --retry-delay 2 -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_candidate" ||
       ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_candidate"; then
      rm -f -- "$key_candidate" "$source_candidate" "$key_snapshot" "$source_snapshot"
      error "Docker 官方 GPG key 下载或格式检查失败。"
      return 1
    fi
    {
      printf 'Types: deb\n'
      printf 'URIs: https://download.docker.com/linux/ubuntu\n'
      printf 'Suites: %s\n' "$codename"
      printf 'Components: stable\n'
      printf 'Architectures: %s\n' "$architecture"
      printf 'Signed-By: %s\n' "$DOCKER_KEY_FILE"
    } > "$source_candidate" || {
      rm -f -- "$key_candidate" "$source_candidate" "$key_snapshot" "$source_snapshot"
      return 1
    }
    backup_file "$DOCKER_KEY_FILE" || rc=1
    (( rc )) || backup_file "$DOCKER_SOURCE_FILE" || rc=1
    (( rc )) || atomic_install_file "$key_candidate" "$DOCKER_KEY_FILE" 0644 || rc=1
    (( rc )) || atomic_install_file "$source_candidate" "$DOCKER_SOURCE_FILE" 0644 || rc=1
    if (( rc == 0 )) && log_command interactive apt-get update &&
       log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install --download-only -y "${docker_packages[@]}"; then
      repo_ready=1
    fi
    rm -f -- "$key_candidate" "$source_candidate"
  fi

  if (( repo_ready == 0 )); then
    if (( reuse_existing == 0 )); then
      restore_docker_repo_state "$key_snapshot" "$had_key" "$source_snapshot" "$had_source" || warn "Docker 原仓库配置恢复不完整，请检查 APT 源。"
      rm -f -- "$key_snapshot" "$source_snapshot"
      log_command quiet apt-get update || true
    fi
    error "Docker 仓库或安装包预下载未通过，未移除现有冲突包。"
    return 1
  fi

  if (( ${#conflicts[@]} > 0 )); then
    confirm "仓库和安装包已验证。确认移除冲突包并安装 Docker CE？" || {
      if (( reuse_existing == 0 )); then
        restore_docker_repo_state "$key_snapshot" "$had_key" "$source_snapshot" "$had_source" || warn "Docker 原仓库配置恢复不完整，请检查 APT 源。"
        rm -f -- "$key_snapshot" "$source_snapshot"
        log_command quiet apt-get update || true
      fi
      info "已取消 Docker 安装，未移除冲突包。"
      return 0
    }
  fi

  mapfile -t pending_upgrades < <(docker_pending_upgrades "${docker_packages[@]}")
  if (( ${#pending_upgrades[@]} > 0 )); then
    warn "检测到已安装 Docker 组件有版本更新："
    printf '  %s\n' "${pending_upgrades[@]}"
    warn "安装更新可能重启 Docker daemon，并短暂中断正在运行的容器。"
    confirm "确认安装上述 Docker 更新？" || {
      if (( reuse_existing == 0 )); then
        restore_docker_repo_state "$key_snapshot" "$had_key" "$source_snapshot" "$had_source" || warn "Docker 原仓库配置恢复不完整，请检查 APT 源。"
        rm -f -- "$key_snapshot" "$source_snapshot"
        log_command quiet apt-get update || true
      fi
      info "已取消 Docker 更新；预下载的软件包可能仍保留在 APT 缓存中。"
      return 0
    }
  fi
  if (( reuse_existing == 0 )); then
    rm -f -- "$key_snapshot" "$source_snapshot"
  fi
  if (( ${#conflicts[@]} > 0 )); then
    log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${conflicts[@]}" || return 1
  fi
  if ! log_command interactive env DEBIAN_FRONTEND=noninteractive apt-get install -y "${docker_packages[@]}"; then
    error "Docker 安装失败；有效仓库与已下载包仍保留，可修复 APT/dpkg 后重新运行本操作。"
    return 1
  fi
  systemctl enable --now docker || { error "Docker 已安装，但服务启动或开机启用失败。"; return 1; }
  ok "Docker Engine、Buildx 和 Compose 插件已安装。"
  log_line "docker official engine installed for ${codename}/${architecture}; source=${existing_source:-$DOCKER_SOURCE_FILE}"
  show_docker_status
}

add_user_to_docker_group() {
  local username="${1:-}"
  require_root
  require_ubuntu || return 1
  command -v docker >/dev/null 2>&1 || { error "请先安装 Docker。"; return 1; }
  if [[ -z "$username" ]]; then
    read -r -p "要加入 docker 组的现有用户名：" username
  fi
  id "$username" >/dev/null 2>&1 || { error "用户不存在：${username}"; return 1; }
  warn "docker 组成员可以控制 Docker daemon，权限实际等同 root。"
  confirm "确认将 ${username} 加入 docker 组？" || return 0
  acquire_lock || return 1
  groupadd -f docker || { error "无法创建 docker 组。"; return 1; }
  usermod -aG docker "$username" || { error "添加 docker 组成员失败。"; return 1; }
  id -nG "$username" | tr ' ' '\n' | grep -Fxq docker || { error "未检测到 docker 组成员关系。"; return 1; }
  ok "${username} 已加入 docker 组；需要重新登录后生效。"
}

test_docker() {
  require_root
  require_ubuntu || return 1
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
    read -r -p "请选择：" choice || return 0
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
    read -r -p "请选择：" choice || return 0
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
  local installer installer_url source_url helper_url rc new_version remote_version
  require_root
  validate_manager_paths || return 1
  acquire_lock || return 1
  ensure_command curl curl || return 1
  installer_url="${MANAGER_RAW_BASE}/install.sh"
  source_url="${MANAGER_RAW_BASE}/vps-manager.sh"
  helper_url="${MANAGER_RAW_BASE}/network-rollback.sh"
  installer="$(mktemp /tmp/vps-manager-bootstrap.XXXXXX.sh)" || return 1
  info "正在检查 ${MANAGER_REPO}@${MANAGER_REF} 的完整版本..."
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_TOTAL_TIMEOUT" --retry 2 --retry-delay 2 -fsSL "$installer_url" -o "$installer"; then
    rm -f -- "$installer"
    error "下载安装器失败，当前版本未修改。"
    return 1
  fi
  if ! bash -n "$installer" || ! grep -q '^# Bootstrap installer for vps-manager\.$' "$installer"; then
    rm -f -- "$installer"
    error "安装器内容或语法不正确，拒绝更新。"
    return 1
  fi
  remote_version="$(awk -F '\"' '/^VERSION=/{print $2; exit}' "$installer")"
  if [[ ! "$remote_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    [[ "$(printf '%s\n' "$VERSION" "$remote_version" | sort -V | head -n1)" != "$VERSION" ]]; then
    rm -f -- "$installer"
    error "远程安装器版本 ${remote_version:-未知} 低于当前 ${VERSION} 或无法验证，已停止更新。"
    info "如果你还没有上传本次源码，请先把完整版本上传到自己的 GitHub 仓库。"
    return 1
  fi
  VPS_MANAGER_REPO="$MANAGER_REPO" VPS_MANAGER_REF="$MANAGER_REF" \
    VPS_MANAGER_SOURCE_URL="$source_url" VPS_MANAGER_ROLLBACK_SOURCE_URL="$helper_url" \
    VPS_MANAGER_INSTALL_PATH="$INSTALL_PATH" VPS_MANAGER_ROLLBACK_HELPER="$ROLLBACK_HELPER" \
    VPS_MANAGER_ALIAS_PATH="$ALIAS_PATH" VPS_MANAGER_LOCK_FILE="$LOCK_FILE" \
    bash "$installer" version
  rc=$?
  rm -f -- "$installer"
  if (( rc != 0 )); then
    error "更新失败；安装器会对主程序和恢复程序一起尝试恢复，详情见以上输出。"
    return "$rc"
  fi
  new_version="$("$INSTALL_PATH" version 2>/dev/null)" || return 1
  ok "更新完成：${new_version}；现有 SSH、防火墙等配置保持原样。"
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
    read -r -p "请选择：" choice || return 0
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
    status) require_root; show_status ;;
    system) system_menu ;;
    ports) firewall_menu ;;
    swap) swap_menu ;;
    security) security_menu ;;
    docker) docker_menu ;;
    hostname) shift; set_hostname "${1:-}" ;;
    check-ai|check-media) check_service_access ;;
    cleanup-system) safe_system_cleanup ;;
    update|update-manager) update_manager ;;
    confirm-network) confirm_pending_network ;;
    version|--version|-v) printf '%s %s\n' "$PROGRAM" "$VERSION" ;;
    help|--help|-h) show_help ;;
    *) error "未知命令：${subcommand}"; show_help; return 2 ;;
  esac
}

if [[ "${VPS_MANAGER_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
