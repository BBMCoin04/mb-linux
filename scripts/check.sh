#!/usr/bin/env bash
# Read-only validation: no package installs, system services or real firewall changes.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for file in install.sh vps-manager.sh network-rollback.sh scripts/check.sh; do
  bash -n "$ROOT/$file"
done
python3 "$ROOT/tests/test_regression.py"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=style "$ROOT/install.sh" "$ROOT/vps-manager.sh" "$ROOT/network-rollback.sh" "$ROOT/scripts/check.sh"
else
  printf 'ShellCheck 未安装，跳过静态分析；回归测试仍已运行。\n'
fi
if [[ -n "${FAIL2BAN_SOURCE:-}" ]]; then
  python3 "$ROOT/tests/test_fail2ban_config.py"
else
  printf '未指定 FAIL2BAN_SOURCE，跳过第三方真实配置解析测试。\n'
fi
