#!/usr/bin/env bash
# Bootstrap installer for vps-manager.
set -uo pipefail
umask 077
VERSION="1.5.0"
DEFAULT_REPO="BBMCoin04/mb-linux"
REPO="${VPS_MANAGER_REPO:-$DEFAULT_REPO}"
REF="${VPS_MANAGER_REF:-main}"
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
HELPER_PATH="${VPS_MANAGER_ROLLBACK_HELPER:-${INSTALL_PATH}.rollback}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
LOCK_FILE="${VPS_MANAGER_LOCK_FILE:-/run/lock/vps-manager.lock}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORK_DIR=""
COMMITTED=0
ALIAS_CREATED=0
LOCK_INHERITED=0
MODIFIED_COUNT=0
TARGETS=()
STAGED=()
HAD_FILE=()

info() { printf '[信息] %s\n' "$*"; }
error() { printf '[错误] %s\n' "$*" >&2; }
installer_require_root() { (( EUID == 0 )); }

valid_target() {
  [[ "$1" == /* && "$1" != *[[:space:]]* && ! -L "$1" && ( ! -e "$1" || -f "$1" ) ]]
}

trusted_bundle() {
  local file owner mode invoking_uid="${SUDO_UID:-$EUID}"
  [[ -z "${VPS_MANAGER_SOURCE_URL+x}" ]] || return 1
  for file in "$SCRIPT_DIR" "$SCRIPT_DIR/vps-manager.sh" "$SCRIPT_DIR/network-rollback.sh"; do
    [[ -e "$file" && ! -L "$file" ]] || return 1
    owner="$(stat -c %u "$file")" || return 1
    mode="$(stat -c %a "$file")" || return 1
    [[ "$owner" == 0 || "$owner" == "$invoking_uid" ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
  done
}

fetch_source() {
  local url="$1" target="$2"
  [[ "$url" == https://* ]] || { error "只允许 HTTPS 下载。"; return 1; }
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 90 \
      --retry 2 --retry-delay 2 -fsSL "$url" -o "$target"
  elif command -v wget >/dev/null 2>&1; then
    timeout 120s wget --https-only --timeout=20 --tries=2 -qO "$target" "$url"
  else
    error "需要 curl 或 wget 才能下载。"
    return 1
  fi
}

installer_cleanup() {
  local rc=$? index temporary failed=0
  if (( COMMITTED == 0 )); then
    for (( index=MODIFIED_COUNT-1; index>=0; index-- )); do
      if [[ "${HAD_FILE[$index]}" == 1 ]]; then
        temporary="$(mktemp "$(dirname "${TARGETS[$index]}")/.vps-restore.XXXXXX")" || { failed=1; continue; }
        if ! cp -a -- "$WORK_DIR/backup-$index" "$temporary" || ! mv -f -- "$temporary" "${TARGETS[$index]}"; then
          failed=1
          rm -f -- "$temporary"
        fi
      else
        rm -f -- "${TARGETS[$index]}" || failed=1
      fi
    done
    (( ALIAS_CREATED == 0 )) || rm -f -- "$ALIAS_PATH" || failed=1
  fi
  for temporary in "${STAGED[@]}"; do rm -f -- "$temporary"; done
  if (( failed )); then
    error "自动恢复不完整，请保留备份目录并手动检查：${WORK_DIR}"
    return 1
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  return "$rc"
}

installer_main() {
  local command_name manager_version helper_version current_version="" index source_url helper_url
  installer_require_root || { error "请使用 sudo bash install.sh。"; return 1; }
  for command_name in install bash mktemp flock stat sort timeout; do
    command -v "$command_name" >/dev/null 2>&1 || { error "缺少命令：${command_name}"; return 1; }
  done
  valid_target "$INSTALL_PATH" && valid_target "$HELPER_PATH" && [[ "$INSTALL_PATH" != "$HELPER_PATH" ]] || {
    error "程序和恢复程序路径必须是不含空白、互不相同的普通绝对文件路径。"; return 1;
  }
  if [[ -n "$ALIAS_PATH" ]]; then
    [[ "$ALIAS_PATH" == /* && "$ALIAS_PATH" != *[[:space:]]* && "$ALIAS_PATH" != "$INSTALL_PATH" && "$ALIAS_PATH" != "$HELPER_PATH" ]] || return 1
    if [[ ( -e "$ALIAS_PATH" || -L "$ALIAS_PATH" ) && "$(readlink -f "$ALIAS_PATH" 2>/dev/null)" != "$INSTALL_PATH" ]]; then
      error "快捷命令已被其他程序占用：${ALIAS_PATH}"; return 1
    fi
  fi
  [[ "$LOCK_FILE" == /* && "$LOCK_FILE" != *[[:space:]]* && ! -L "$LOCK_FILE" ]] || return 1
  install -d -m 0755 "$(dirname "$LOCK_FILE")" || return 1
  if [[ "$(readlink /proc/self/fd/9 2>/dev/null || true)" == "$LOCK_FILE" ]]; then LOCK_INHERITED=1
  else exec 9>"$LOCK_FILE" || return 1; fi
  flock -n 9 || { error "另一个安装或管理任务正在运行。"; return 1; }

  WORK_DIR="$(mktemp -d /tmp/vps-manager-install.XXXXXXXX)" || return 1
  trap installer_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  info "vps-manager ${VERSION} 安装器"
  if trusted_bundle; then
    info "使用同目录的完整本地源码，不联网下载。"
    cp -- "$SCRIPT_DIR/vps-manager.sh" "$WORK_DIR/manager" && cp -- "$SCRIPT_DIR/network-rollback.sh" "$WORK_DIR/helper" || return 1
  else
    info "下载同一仓库引用的程序和恢复程序（不使用公共临时目录中的旁置脚本）。"
    source_url="${VPS_MANAGER_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/vps-manager.sh}"
    helper_url="${VPS_MANAGER_ROLLBACK_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/network-rollback.sh}"
    fetch_source "$source_url" "$WORK_DIR/manager" && fetch_source "$helper_url" "$WORK_DIR/helper" || return 1
  fi
  for command_name in manager helper; do
    if [[ ! -s "$WORK_DIR/$command_name" ]] || ! bash -n "$WORK_DIR/$command_name"; then
      error "下载内容为空或语法错误。"; return 1
    fi
  done
  if ! grep -q '^PROGRAM="vps-manager"$' "$WORK_DIR/manager" ||
    ! grep -q '^PROGRAM="vps-manager-network-rollback"$' "$WORK_DIR/helper"; then
    error "程序标识不匹配。"; return 1
  fi
  manager_version="$(awk -F '"' '/^VERSION=/{print $2; exit}' "$WORK_DIR/manager")"
  helper_version="$(awk -F '"' '/^VERSION=/{print $2; exit}' "$WORK_DIR/helper")"
  [[ "$manager_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$manager_version" == "$helper_version" && "$manager_version" == "$VERSION" ]] || {
    error "安装器、主程序和恢复程序版本不一致；请取得完整的同一版本。"; return 1;
  }
  if [[ -x "$INSTALL_PATH" ]]; then
    current_version="$("$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}')"
    if [[ "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$(printf '%s\n' "$current_version" "$manager_version" | sort -V | head -n1)" != "$current_version" ]]; then
      error "拒绝用 ${manager_version} 覆盖较新的 ${current_version}。"; return 1
    fi
  fi

  TARGETS=("$HELPER_PATH" "$INSTALL_PATH")
  local -a sources=("$WORK_DIR/helper" "$WORK_DIR/manager")
  for index in 0 1; do
    install -d -m 0755 "$(dirname "${TARGETS[$index]}")" || return 1
    HAD_FILE[index]=0
    if [[ -f "${TARGETS[$index]}" ]]; then
      cp -a -- "${TARGETS[$index]}" "$WORK_DIR/backup-$index" || return 1
      HAD_FILE[index]=1
    fi
    STAGED[index]="$(mktemp "$(dirname "${TARGETS[$index]}")/.vps-install.XXXXXX")" || return 1
    install -m 0755 "${sources[$index]}" "${STAGED[$index]}" || return 1
  done
  for index in 0 1; do
    MODIFIED_COUNT=$((index+1))
    mv -f -- "${STAGED[$index]}" "${TARGETS[$index]}" || return 1
  done
  if [[ -n "$ALIAS_PATH" && ! -e "$ALIAS_PATH" && ! -L "$ALIAS_PATH" ]]; then
    install -d -m 0755 "$(dirname "$ALIAS_PATH")" || return 1
    ln -s "$INSTALL_PATH" "$ALIAS_PATH" || return 1
    ALIAS_CREATED=1
  fi
  [[ "$("$INSTALL_PATH" version 2>/dev/null)" == "vps-manager ${manager_version}" &&
     "$("$HELPER_PATH" version 2>/dev/null)" == "vps-manager-network-rollback ${helper_version}" ]] || {
    error "安装后自检失败，将恢复原版本。"; return 1;
  }
  COMMITTED=1
  info "vps-manager ${manager_version} 已安装；原有系统配置不会自动修改。"
  installer_cleanup
  WORK_DIR=""
  trap - EXIT HUP INT TERM
  (( LOCK_INHERITED )) || flock -u 9
  exec 9>&-
  if (( $# > 0 )); then "$INSTALL_PATH" "$@"; return $?; fi
  if [[ -t 0 && -t 1 ]]; then exec "$INSTALL_PATH"; fi
  info "稍后运行 sudo lm 打开菜单。"
}

if [[ "${VPS_MANAGER_INSTALLER_NO_MAIN:-0}" != 1 ]]; then installer_main "$@"; fi
