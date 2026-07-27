#!/usr/bin/env bash
# Bootstrap installer for vps-manager.

set -uo pipefail
umask 077

VERSION="1.1.0"
DEFAULT_REPO="BBMCoin04/mb-linux"
REPO="${VPS_MANAGER_REPO:-$DEFAULT_REPO}"
REF="${VPS_MANAGER_REF:-main}"
INSTALL_PATH="${VPS_MANAGER_INSTALL_PATH:-/usr/local/sbin/vps-manager}"
ALIAS_PATH="${VPS_MANAGER_ALIAS_PATH:-/usr/local/sbin/lm}"
SOURCE_URL="${VPS_MANAGER_SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${REF}/vps-manager.sh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
BUNDLED_SOURCE=""
if [[ -z "${VPS_MANAGER_SOURCE_URL+x}" && -n "$SCRIPT_DIR" && -s "${SCRIPT_DIR}/vps-manager.sh" ]]; then
  BUNDLED_SOURCE="${SCRIPT_DIR}/vps-manager.sh"
fi
TEMP_FILE=""

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

cleanup() {
  [[ -n "$TEMP_FILE" ]] && rm -f "$TEMP_FILE"
}
trap cleanup EXIT HUP INT TERM

if (( EUID != 0 )); then
  error "安装需要 root 权限，请在命令前使用 sudo。"
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
    wget -qO "$TEMP_FILE" "$SOURCE_URL"
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

install -d -m 0755 "$(dirname "$INSTALL_PATH")" || {
  error "无法创建管理器安装目录。"
  exit 1
}
install -m 0755 "$TEMP_FILE" "$INSTALL_PATH" || {
  error "无法安装管理器到 ${INSTALL_PATH}。"
  exit 1
}
if [[ -n "$ALIAS_PATH" && "$ALIAS_PATH" != "$INSTALL_PATH" ]]; then
  install -d -m 0755 "$(dirname "$ALIAS_PATH")"
  if [[ -e "$ALIAS_PATH" || -L "$ALIAS_PATH" ]]; then
    if [[ "$(readlink -f "$ALIAS_PATH" 2>/dev/null || true)" != "$INSTALL_PATH" ]]; then
      info "${ALIAS_PATH} 已被其他文件占用，跳过快捷命令配置。"
    fi
  elif ln -s "$INSTALL_PATH" "$ALIAS_PATH"; then
    ok "快捷命令已配置：sudo $(basename "$ALIAS_PATH")"
  fi
fi
hash_value="$(sha256sum "$INSTALL_PATH" 2>/dev/null | awk '{print $1}' || true)"
ok "vps-manager 已安装到 ${INSTALL_PATH}"
[[ -n "$hash_value" ]] && printf 'SHA-256: %s\n' "$hash_value"

cleanup
TEMP_FILE=""
trap - EXIT HUP INT TERM

if (( $# > 0 )); then
  exec "$INSTALL_PATH" "$@"
fi

if [[ -r /dev/tty && -w /dev/tty ]]; then
  exec "$INSTALL_PATH" </dev/tty >/dev/tty
fi

info "当前环境没有交互终端。稍后运行：sudo ${INSTALL_PATH} 或 sudo ${ALIAS_PATH}"
