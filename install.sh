#!/usr/bin/env bash
# Bootstrap installer for vps-manager.

set -uo pipefail
umask 077

VERSION="1.4.3"
DEFAULT_REPO="BBMCoin04/mb-linux"
REPO="${VPS_MANAGER_REPO:-$DEFAULT_REPO}"
REF="${VPS_MANAGER_REF:-main}"
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
CACHE_BUST="$(date +%s)"
SOURCE_URL="${VPS_MANAGER_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/vps-manager.sh?ts=${CACHE_BUST}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
BUNDLED_SOURCE=""
if [[ -z "${VPS_MANAGER_SOURCE_URL+x}" && -n "$SCRIPT_DIR" && -s "${SCRIPT_DIR}/vps-manager.sh" ]]; then
  BUNDLED_SOURCE="${SCRIPT_DIR}/vps-manager.sh"
fi
TEMP_FILE=""
BACKUP_FILE=""
ALIAS_CREATED=0
INSTALL_CHANGED=0
COMMITTED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_GREEN=""
  C_CYAN=""
  C_RESET=""
fi

info() { printf '%s[信息]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

restore_manager() {
  if [[ -n "$BACKUP_FILE" && -s "$BACKUP_FILE" ]]; then
    install -m 0755 "$BACKUP_FILE" "$INSTALL_PATH" || true
  else
    rm -f -- "$INSTALL_PATH"
  fi
  (( ALIAS_CREATED == 0 )) || rm -f -- "$ALIAS_PATH"
}

cleanup() {
  local rc=$?
  if (( INSTALL_CHANGED == 1 && COMMITTED == 0 )); then
    restore_manager
  fi
  [[ -z "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
  [[ -z "$BACKUP_FILE" ]] || rm -f -- "$BACKUP_FILE"
  return "$rc"
}

on_signal() {
  trap - HUP INT TERM
  exit "$1"
}

trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

if (( EUID != 0 )); then
  error "安装需要 root 权限，请在命令前使用 sudo。"
  exit 1
fi
if [[ "$INSTALL_PATH" != /* || "$INSTALL_PATH" == *[[:space:]]* ]]; then
  error "管理器安装路径必须是不含空白的绝对路径。"
  exit 1
fi
if [[ -n "$ALIAS_PATH" && ( "$ALIAS_PATH" != /* || "$ALIAS_PATH" == *[[:space:]]* || "$ALIAS_PATH" == "$INSTALL_PATH" ) ]]; then
  error "快捷命令路径必须是不含空白且不同于安装路径的绝对路径。"
  exit 1
fi

for command_name in install bash; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    error "缺少必要命令：${command_name}"
    exit 1
  fi
done
if [[ -z "$BUNDLED_SOURCE" && "$SOURCE_URL" != https://* ]]; then
  error "仅允许从 HTTPS 地址下载主程序。"
  exit 1
fi

TEMP_FILE="$(mktemp /tmp/vps-manager.XXXXXX.sh)" || exit 1
info "vps-manager 引导安装器 ${VERSION}"
if [[ -n "$BUNDLED_SOURCE" ]]; then
  info "正在使用安装包内的 vps-manager.sh"
  if ! cp "$BUNDLED_SOURCE" "$TEMP_FILE"; then
    error "无法读取安装包内的主程序。"
    exit 1
  fi
else
  info "正在下载 ${SOURCE_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -fsSL "$SOURCE_URL" -o "$TEMP_FILE"
    download_rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -qO "$TEMP_FILE" "$SOURCE_URL"
    download_rc=$?
  else
    error "需要 curl 或 wget 才能下载安装。"
    exit 1
  fi
  if (( download_rc != 0 )); then
    error "下载失败，请检查仓库地址和网络。"
    exit 1
  fi
fi

if [[ ! -s "$TEMP_FILE" ]]; then
  error "下载结果为空，拒绝安装。"
  exit 1
fi
if ! bash -n "$TEMP_FILE"; then
  error "下载的脚本未通过 Bash 语法检查，拒绝安装。"
  exit 1
fi
if ! grep -q '^PROGRAM="vps-manager"$' "$TEMP_FILE"; then
  error "下载内容不是预期的 vps-manager 主程序，拒绝安装。"
  exit 1
fi
MANAGER_VERSION="$(awk -F '"' '/^VERSION="[0-9]/{print $2; exit}' "$TEMP_FILE")"
if [[ ! "$MANAGER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "无法识别管理器版本，拒绝安装。"
  exit 1
fi
if [[ -x "$INSTALL_PATH" ]]; then
  EXISTING_VERSION="$("$INSTALL_PATH" version 2>/dev/null | awk '{print $2; exit}' || true)"
  if [[ "$EXISTING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
     [[ "$(printf '%s\n' "$EXISTING_VERSION" "$MANAGER_VERSION" | sort -V | head -n 1)" != "$EXISTING_VERSION" ]]; then
    error "拒绝用 ${MANAGER_VERSION} 覆盖已安装的新版本 ${EXISTING_VERSION}。"
    exit 1
  fi
fi

install -d -m 0755 "$(dirname "$INSTALL_PATH")" || {
  error "无法创建管理器安装目录。"
  exit 1
}
[[ ! -L "$INSTALL_PATH" ]] || { error "安装目标不能是软链接：${INSTALL_PATH}"; exit 1; }
[[ ! -e "$INSTALL_PATH" || -f "$INSTALL_PATH" ]] || { error "安装目标必须是普通文件路径：${INSTALL_PATH}"; exit 1; }
if [[ -n "$ALIAS_PATH" ]]; then
  install -d -m 0755 "$(dirname "$ALIAS_PATH")" || exit 1
  if [[ ( -e "$ALIAS_PATH" || -L "$ALIAS_PATH" ) && "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
    error "快捷命令路径已被其他程序占用，不会覆盖：${ALIAS_PATH}"
    exit 1
  fi
fi
if [[ -f "$INSTALL_PATH" ]]; then
  BACKUP_FILE="$(mktemp /tmp/vps-manager-existing.XXXXXX.sh)" || exit 1
  cp -a -- "$INSTALL_PATH" "$BACKUP_FILE" || exit 1
fi
INSTALL_CHANGED=1
if ! install -m 0755 "$TEMP_FILE" "$INSTALL_PATH"; then
  restore_manager
  INSTALL_CHANGED=0
  error "管理器安装失败，已尝试恢复原版本。"
  exit 1
fi
if [[ -n "$ALIAS_PATH" && ! -e "$ALIAS_PATH" && ! -L "$ALIAS_PATH" ]]; then
  if ! ln -s "$INSTALL_PATH" "$ALIAS_PATH"; then
    restore_manager
    INSTALL_CHANGED=0
    error "无法创建快捷命令 ${ALIAS_PATH}。"
    exit 1
  fi
  ALIAS_CREATED=1
  ok "快捷命令已配置：sudo $(basename "$ALIAS_PATH")"
fi
if [[ "$("$INSTALL_PATH" version 2>/dev/null)" != "vps-manager ${MANAGER_VERSION}" ]]; then
  restore_manager
  INSTALL_CHANGED=0
  error "安装后的版本自检失败，已恢复原版本。"
  exit 1
fi
COMMITTED=1

hash_value="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || true)"
ok "vps-manager ${MANAGER_VERSION} 已安装到 ${INSTALL_PATH}"
[[ -n "$hash_value" ]] && printf 'SHA-256: %s\n' "$hash_value"

cleanup
TEMP_FILE=""
BACKUP_FILE=""
trap - EXIT HUP INT TERM

if (( $# > 0 )); then
  exec "$INSTALL_PATH" "$@"
fi

if [[ -r /dev/tty && -w /dev/tty ]]; then
  exec "$INSTALL_PATH" </dev/tty >/dev/tty
fi

info "当前环境没有交互终端。稍后运行：sudo ${INSTALL_PATH} 或 sudo ${ALIAS_PATH}"
