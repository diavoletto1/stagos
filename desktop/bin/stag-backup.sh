#!/bin/bash
# StagOS restic backups ($HOME, /etc and the package lists) to STAGOS_RESTIC_REPO (config/local.conf).
#   stag-backup now            back up now (any power source); exit 75 when the backup host does not answer
#   stag-backup run            what the stagos-restic.timer runs: skips quietly on battery, when the last good
#                              backup is younger than STAGOS_BACKUP_EVERY_H hours, or when the host is away
#   stag-backup status         last snapshot age, last run result, the timer (local, no network)
#   stag-backup restore-test   restore a few files of the newest snapshot to a temp dir and verify them
#   stag-backup check          restic check (a data subset) + prune now (the timer does it weekly)
# Settings come from ~/.config/stagos/backup.env (written by `stagos-desktop snapshots`). State and log:
# ~/.local/state/stagos/backup.state, backup.log. A failed run pings ntfy when STAGOS_NTFY_URL is set.
set -uo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/stagos"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/stagos"
ENV_FILE="${STAGOS_BACKUP_ENV:-$CONF/backup.env}"
STATE="$STATE_DIR/backup.state"
LOG="$STATE_DIR/backup.log"
SYS="${STAGOS_SYS:-/sys}"
EX_UNREACHABLE=75
mkdir -p "$STATE_DIR"

say() { printf '%s\n' "$*"; }
log() { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
die() { log "error: $*"; printf 'stag-backup: %s\n' "$*" >&2; exit 1; }

load_env() {
  [ -r "$ENV_FILE" ] || die "no $ENV_FILE: set STAGOS_RESTIC_REPO in config/local.conf, then run ./stagos-desktop snapshots"
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  [ -n "${STAGOS_RESTIC_REPO:-}" ] || die "STAGOS_RESTIC_REPO is empty in $ENV_FILE"
  PASS_FILE="${STAGOS_RESTIC_PASSWORD_FILE:-$CONF/restic.pass}"
  [ -s "$PASS_FILE" ] || die "no restic password file $PASS_FILE (./stagos-desktop snapshots creates one)"
  export RESTIC_REPOSITORY="$STAGOS_RESTIC_REPO" RESTIC_PASSWORD_FILE="$PASS_FILE"
  EXCLUDES="${STAGOS_RESTIC_EXCLUDES:-$CONF/backup.exclude}"
}

# ---- state: key=value lines, rewritten whole ----
state_get() { local k v; while IFS='=' read -r k v; do [ "$k" = "$1" ] && { printf '%s' "$v"; return 0; }; done < "$STATE" 2>/dev/null; return 1; }
state_set() { # KEY=VALUE...
  local kv tmp; mkdir -p "$STATE_DIR"; tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  [ -r "$STATE" ] && cat "$STATE" > "$tmp"
  for kv in "$@"; do sed -i "/^${kv%%=*}=/d" "$tmp"; printf '%s\n' "$kv" >> "$tmp"; done
  mv -f "$tmp" "$STATE"
}
now() { date +%s; }
age() { # SECONDS -> "3d 4h" / "5h 12m" / "7m"
  local s="$1"
  if [ "$s" -ge 86400 ]; then printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ]; then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}
# the repo URL without a password (rest:https://user:secret@host/ -> rest:https://user:***@host/)
repo_shown() { sed -E 's#(//[^:/@]+):[^@/]*@#\1:***@#' <<< "$1"; }

# ---- gates ----
on_ac() { # true when any mains supply is online, or when there is no battery at all
  local p seen=0
  for p in "$SYS"/class/power_supply/*; do
    [ -r "$p/type" ] || continue
    case "$(cat "$p/type")" in
      Mains) [ "$(cat "$p/online" 2>/dev/null)" = 1 ] && return 0 ;;
      Battery) seen=1 ;;
    esac
  done
  [ "$seen" = 0 ]
}
# sftp:HOST:/path, sftp:USER@HOST:/path, sftp://USER@HOST[:PORT]//path -> the ssh target; empty otherwise
sftp_host() {
  local r="$1"
  case "$r" in
    sftp://*) r="${r#sftp://}"; r="${r%%/*}"; printf '%s' "${r%%:*}" ;;
    sftp:*) r="${r#sftp:}"; printf '%s' "${r%%:*}" ;;
  esac
}
reachable() {
  local h; h="$(sftp_host "$RESTIC_REPOSITORY")"
  [ -n "$h" ] || return 0
  timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" true </dev/null >/dev/null 2>&1
}

# ---- ntfy: only when configured (no defaults, no invented tokens) ----
notify_fail() {
  local msg="$1" host
  host="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo laptop)"
  [ -n "${STAGOS_NTFY_URL:-}" ] || return 0
  {
    if [ -n "${STAGOS_NTFY_TOKEN_FILE:-}" ] && [ -s "$STAGOS_NTFY_TOKEN_FILE" ]; then
      # the header goes through curl's config on stdin, never argv (ps) or the log
      printf 'header = "Authorization: Bearer %s"\n' "$(tr -d '\n' < "$STAGOS_NTFY_TOKEN_FILE")"
    fi
  } | curl -fsS -m 15 -K - -H "Title: $host backup failed" -H "Priority: high" -H "Tags: warning,floppy_disk" \
      -d "$msg" "$STAGOS_NTFY_URL" >/dev/null 2>&1 || log "ntfy ping failed"
}

pkglists() {
  mkdir -p "$STATE_DIR"
  pacman -Qqe > "$STATE_DIR/pkglist-explicit.txt" 2>/dev/null || log "warning: pacman -Qqe failed"
  pacman -Qqm > "$STATE_DIR/pkglist-foreign.txt" 2>/dev/null || true
}

ensure_repo() {
  local rc
  restic cat config >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && return 0
  # 10 = the repository does not exist (restic >= 0.17); anything else is a real error (network, password)
  if [ "$rc" = 10 ]; then
    log "initialising $(repo_shown "$RESTIC_REPOSITORY")"
    restic init >> "$LOG" 2>&1 || return 1
    return 0
  fi
  log "restic cat config failed (rc $rc): wrong password, or the repo is unreachable"
  return 1
}

maintain() { # weekly: check a data subset, then prune
  log "check: restic check --read-data-subset=${STAGOS_RESTIC_CHECK_SUBSET:-5%}"
  restic check --read-data-subset="${STAGOS_RESTIC_CHECK_SUBSET:-5%}" >> "$LOG" 2>&1 || { log "check FAILED"; return 1; }
  restic prune >> "$LOG" 2>&1 || { log "prune FAILED"; return 1; }
  state_set "last_check=$(now)"
  log "check + prune ok"
}

# do_backup: rc 0 ok, 1 failed, 75 host unreachable
do_backup() {
  local rc paths out snap warn=""
  mkdir -p "$STATE_DIR"
  # keep the log bounded (restic check/prune output lands there weekly)
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 4000 ]; then tail -n 2000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; fi
  exec 9> "$STATE_DIR/backup.lock"
  flock -n 9 || { say "another backup is running"; log "skipped: another backup is running"; return 0; }
  if ! reachable; then
    log "skipped: $(sftp_host "$RESTIC_REPOSITORY") does not answer"
    state_set "last_skip=$(now)" "last_skip_reason=host unreachable"
    say "backup host $(sftp_host "$RESTIC_REPOSITORY") does not answer (offline, or not on the tailnet?)"
    return "$EX_UNREACHABLE"
  fi
  state_set "last_run=$(now)"
  ensure_repo || { fail_run "repository not usable (see $LOG)"; return 1; }
  pkglists
  read -r -a paths <<< "${STAGOS_RESTIC_PATHS:-$HOME /etc}"
  log "backup: ${paths[*]}"
  out="$(mktemp)"
  restic backup --json --exclude-caches ${EXCLUDES:+--exclude-file="$EXCLUDES"} --tag stagos "${paths[@]}" \
    > "$out" 2>> "$LOG"
  rc=$?
  snap="$(grep '"message_type":"summary"' "$out" | sed -n 's/.*"snapshot_id":"\([0-9a-f]*\)".*/\1/p' | tail -n1)"
  rm -f "$out"
  # 3 = snapshot saved but some files were unreadable (root-only files under /etc): kept, noted
  if [ "$rc" = 3 ]; then warn=" (some files unreadable, e.g. root-only files in /etc)"; rc=0; fi
  if [ "$rc" != 0 ]; then fail_run "restic backup exited $rc"; return 1; fi
  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --tag stagos >> "$LOG" 2>&1 || log "forget failed"
  state_set "last_ok=$(now)" "last_rc=0" "last_snapshot=${snap:-?}" "last_msg=ok$warn"
  log "backup ok: snapshot ${snap:-?}$warn"
  say "backup ok: snapshot ${snap:-?}$warn"
  local lc; lc="$(state_get last_check || echo 0)"
  if [ $(( $(now) - lc )) -ge $((7 * 86400)) ]; then maintain || notify_fail "restic check/prune failed, see $LOG"; fi
  return 0
}
fail_run() {
  state_set "last_rc=1" "last_msg=$1"
  log "FAILED: $1"
  printf 'stag-backup: FAILED: %s\n' "$1" >&2
  notify_fail "$1"
}

cmd_status() {
  local ok rc msg snap t
  say "repo:     $(repo_shown "${STAGOS_RESTIC_REPO:-}")"
  if ok="$(state_get last_ok)"; then
    snap="$(state_get last_snapshot || echo '?')"
    say "last ok:  $(age $(( $(now) - ok ))) ago ($(date -d "@$ok" '+%F %H:%M'), snapshot $snap)"
  else
    say "last ok:  never"
  fi
  rc="$(state_get last_rc || true)"; msg="$(state_get last_msg || true)"
  [ -n "$rc" ] && say "last run: $([ "$rc" = 0 ] && echo ok || echo FAILED)${msg:+: $msg}"
  if t="$(state_get last_skip)"; then say "skipped:  $(age $(( $(now) - t ))) ago ($(state_get last_skip_reason || true))"; fi
  if t="$(state_get last_check)"; then say "checked:  $(age $(( $(now) - t ))) ago"; else say "checked:  never"; fi
  if command -v systemctl >/dev/null 2>&1; then
    t="$(systemctl --user list-timers stagos-restic.timer --no-legend 2>/dev/null | awk 'NR==1 {print $1, $2, $3}')"
    say "timer:    ${t:-not scheduled (stagos-restic.timer)}"
  fi
  say "log:      $LOG"
}

cmd_restore_test() {
  local tmp f n=0 rc
  reachable || { say "backup host does not answer"; return "$EX_UNREACHABLE"; }
  tmp="$(mktemp -d)"
  # files every snapshot has: the package lists written before each run, and /etc/hostname
  local want=("$STATE_DIR/pkglist-explicit.txt" /etc/hostname)
  local inc=(); for f in "${want[@]}"; do inc+=(--include "$f"); done
  say "restoring ${want[*]} from the latest snapshot into $tmp"
  restic restore latest --tag stagos --target "$tmp" --verify "${inc[@]}" >> "$LOG" 2>&1; rc=$?
  for f in "${want[@]}"; do
    if [ -s "$tmp$f" ]; then n=$((n + 1)); say "  ok   $f ($(wc -c < "$tmp$f") bytes)"; else say "  MISS $f"; fi
  done
  rm -rf "$tmp"
  if [ "$rc" = 0 ] && [ "$n" = "${#want[@]}" ]; then
    state_set "last_restore_test=$(now)"; log "restore-test ok"; say "restore-test ok"; return 0
  fi
  log "restore-test FAILED (restic rc $rc, $n/${#want[@]} files)"; say "restore-test FAILED (see $LOG)"; return 1
}

case "${1:-}" in
  now) load_env; do_backup ;;
  run)
    load_env
    if ! on_ac; then log "skipped: on battery"; exit 0; fi
    ok="$(state_get last_ok || echo 0)"
    if [ $(( $(now) - ok )) -lt $(( ${STAGOS_BACKUP_EVERY_H:-20} * 3600 )) ]; then exit 0; fi
    do_backup; rc=$?
    # an absent host is not a failure: the next hourly run tries again
    [ "$rc" = "$EX_UNREACHABLE" ] && exit 0
    exit "$rc" ;;
  status) if [ -r "$ENV_FILE" ]; then
            # shellcheck source=/dev/null
            . "$ENV_FILE"
          fi
          cmd_status ;;
  restore-test) load_env; cmd_restore_test ;;
  check) load_env; reachable || { say "backup host does not answer"; exit "$EX_UNREACHABLE"; }; maintain ;;
  -h|--help|'') sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] ;;
  *) echo "stag-backup: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
