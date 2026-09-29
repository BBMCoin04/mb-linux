#!/usr/bin/env bash
# vps-manager network rollback helper.
# This file is installed beside vps-manager as vps-manager.rollback.
set -uo pipefail
umask 077
VERSION="1.5.2"
PROGRAM="vps-manager-network-rollback"

restore_snapshot() {
  local name="$1" target="$2" candidate
  [[ "$target" == /* && "$target" != *$'\n'* ]] || return 1
  if [[ -f "$guard/${name}.exists" ]]; then
    candidate="$(mktemp "$(dirname "$target")/.vps-restore.XXXXXX")" || return 1
    if ! cp -a -- "$guard/$name" "$candidate" || ! mv -f -- "$candidate" "$target"; then
      rm -f -- "$candidate"
      return 1
    fi
  else
    rm -f -- "$target" || return 1
  fi
}

bounded() { timeout --signal=TERM --kill-after=5s 35s "$@"; }

rollback_require_root() { (( EUID == 0 )); }
private_guard_directory() {
  [[ "$1" == /* && -d "$1" && ! -L "$1" ]] &&
    [[ "$(stat -c %u "$1")" == 0 && "$(stat -c %a "$1")" == 700 ]]
}

rollback_main() {
  local guard="${1:-}" kind state failed=0 target service socket_active ufw_status apply_unit load_state stop_details
  if [[ "$guard" == version ]]; then printf '%s %s\n' "$PROGRAM" "$VERSION"; return 0; fi
  rollback_require_root || { printf 'Rollback requires root.\n' >&2; return 1; }
  # Never source a state file. Values are data and paths remain quoted.
  private_guard_directory "$guard" || return 1
  [[ -r "$guard/state" ]] || return 1
  state="$(<"$guard/state")"
  # Terminal states never become pending again. A late timer or repeated
  # foreground request has nothing left to stop or restore.
  case "$state" in
    confirmed|rolled-back) return 0 ;;
  esac
  # The apply service owns all network writes. Stop its entire cgroup before
  # taking the snapshot lock, so a stuck writer cannot prevent recovery.
  exec >>"$guard/rollback.log" 2>&1
  if [[ -f "$guard/apply-unit" ]]; then
    apply_unit="$(<"$guard/apply-unit")"
    [[ "$apply_unit" =~ ^vps-manager-apply-change\.[a-zA-Z0-9]+$ ]] || return 1
    if ! stop_details="$(timeout --kill-after=5s 20s systemctl stop "${apply_unit}.service" 2>&1)"; then
      load_state="$(timeout --kill-after=2s 5s systemctl show "${apply_unit}.service" --property=LoadState --value)" || load_state=""
      if [[ "$load_state" != not-found ]]; then
        [[ -z "$stop_details" ]] || printf '%s\n' "$stop_details"
        printf 'Cannot stop network apply service; refusing concurrent restoration. Retry from the console.\n'
        return 1
      fi
      # --collect removes a successfully completed apply service. Its absence
      # is expected here; only suppress the captured stop error in this case.
    fi
  fi
  exec 8>"$guard/lock" || return 1
  flock -w 15 -x 8 || { printf 'Cannot acquire recovery lock within 15 seconds.\n'; return 1; }
  state="$(<"$guard/state")"
  case "$state" in
    confirmed|rolled-back) return 0 ;;
    pending|rollback-failed|rolling-back) ;;
    *) return 1 ;;
  esac
  printf 'rolling-back\n' > "$guard/state" || return 1
  kind="$(<"$guard/kind")"
  printf '[%s] Restoring %s configuration\n' "$(date -Is)" "$kind"

  case "$kind" in
    ssh)
      target="$(<"$guard/ssh-target")"
      restore_snapshot ssh-config "$target" || failed=1
      target="$(<"$guard/fail2ban-target")"
      restore_snapshot fail2ban-config "$target" || failed=1
      if (( failed == 0 )); then
        bounded /usr/sbin/sshd -t || failed=1
        socket_active="$(<"$guard/socket-active")"
        if [[ "$socket_active" == 1 ]]; then
          bounded systemctl daemon-reload || failed=1
          bounded systemctl restart ssh.socket || failed=1
          if systemctl is-active --quiet ssh.service; then
            if [[ "$(systemctl show ssh.service --property=KillMode --value)" == process ]]; then
              bounded systemctl restart ssh.service || failed=1
            else
              printf 'Refusing to restart ssh.service with a non-process KillMode.\n'
              failed=1
            fi
          fi
        else
          service="$(<"$guard/ssh-service")"
          bounded systemctl reload "$service" || failed=1
        fi
        if [[ "$(<"$guard/fail2ban-active")" == 1 ]]; then
          bounded fail2ban-client -t || failed=1
          if [[ "$(<"$guard/fail2ban-sshd-active")" == 1 ]] && fail2ban-client status sshd >/dev/null 2>&1; then
            bounded fail2ban-client reload --restart sshd || failed=1
          else
            bounded fail2ban-client reload || failed=1
          fi
        fi
      fi
      ;;
    ufw)
      target="$(<"$guard/ufw-target")"
      [[ "$target" == /* ]] || return 1
      cp -a -- "$guard/ufw/." "$target/" || failed=1
      target="$(<"$guard/ufw-default-target")"
      restore_snapshot ufw-default "$target" || failed=1
      target="$(<"$guard/port-target")"
      restore_snapshot port-config "$target" || failed=1
      if [[ "$(<"$guard/ufw-active")" == 1 ]]; then
        bounded ufw --force enable || failed=1
        ufw_status="$(LC_ALL=C ufw status)" || failed=1
        grep -q '^Status: active' <<< "$ufw_status" || failed=1
      else
        bounded ufw disable || failed=1
        ufw_status="$(LC_ALL=C ufw status)" || failed=1
        grep -q '^Status: inactive' <<< "$ufw_status" || failed=1
      fi
      if [[ "$(<"$guard/fail2ban-active")" == 1 ]]; then
        # A UFW rebuild can remove a running jail's rules. Restore active actions.
        bounded fail2ban-client reload --restart || failed=1
      fi
      ;;
    *) failed=1 ;;
  esac
  if (( failed )); then
    printf 'rollback-failed\n' > "$guard/state"
    printf 'Some restore commands failed; use the VPS console and this snapshot.\n'
    return 1
  fi
  printf 'rolled-back\n' > "$guard/state"
  printf 'Original configuration restored.\n'
}

if [[ "${VPS_MANAGER_ROLLBACK_NO_MAIN:-0}" != 1 ]]; then rollback_main "$@"; fi
