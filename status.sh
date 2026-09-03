#!/usr/bin/env bash
#
# status.sh — Reports the mount status of an rclone remote as JSON,
# and exposes mount/unmount actions.
#
# Usage:
#   status.sh check   <remote> <mountpoint>
#   status.sh mount    <remote> <mountpoint>
#   status.sh unmount  <mountpoint>
#
set -euo pipefail

expand_path() {
  # Expand a leading ~ to $HOME without invoking a subshell eval.
  local p="$1"
  if [[ "$p" == "~"* ]]; then
    printf '%s' "${HOME}${p:1}"
  else
    printf '%s' "$p"
  fi
}

is_mounted() {
  local mountpoint="$1"
  mountpoint -q "$mountpoint" 2>/dev/null
}

cmd_check() {
  local remote="$1"
  local mountpoint
  mountpoint="$(expand_path "$2")"

  if is_mounted "$mountpoint"; then
    # Space usage on the mounted path, best-effort.
    local used avail
    read -r _ _ used avail _ < <(df -Pk "$mountpoint" | tail -1)
    printf '{"status":"mounted","remote":"%s","mountpoint":"%s","usedKb":%s,"availKb":%s}\n' \
      "$remote" "$mountpoint" "${used:-0}" "${avail:-0}"
  else
    printf '{"status":"unmounted","remote":"%s","mountpoint":"%s"}\n' \
      "$remote" "$mountpoint"
  fi
}

cmd_mount() {
  local remote="$1"
  local mountpoint
  mountpoint="$(expand_path "$2")"

  mkdir -p "$mountpoint"

  if is_mounted "$mountpoint"; then
    printf '{"status":"already_mounted","remote":"%s","mountpoint":"%s"}\n' "$remote" "$mountpoint"
    exit 0
  fi

  # Prefer the user's systemd unit if present; fall back to a direct daemonized mount.
  local unit="rclone-${remote}.service"
  if systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
    systemctl --user start "$unit"
  else
    rclone mount "${remote}:" "$mountpoint" --daemon --vfs-cache-mode writes
  fi

  sleep 2
  cmd_check "$remote" "$mountpoint"
}

cmd_unmount() {
  local mountpoint
  mountpoint="$(expand_path "$1")"

  if ! is_mounted "$mountpoint"; then
    printf '{"status":"already_unmounted","mountpoint":"%s"}\n' "$mountpoint"
    exit 0
  fi

  fusermount -u "$mountpoint" 2>/dev/null || umount "$mountpoint"
  printf '{"status":"unmounted","mountpoint":"%s"}\n' "$mountpoint"
}

action="${1:-}"
case "$action" in
  check)
    cmd_check "${2:?remote name required}" "${3:?mountpoint required}"
    ;;
  mount)
    cmd_mount "${2:?remote name required}" "${3:?mountpoint required}"
    ;;
  unmount)
    cmd_unmount "${2:?mountpoint required}"
    ;;
  *)
    echo "Usage: $0 {check|mount|unmount} <remote> <mountpoint>" >&2
    exit 1
    ;;
esac
