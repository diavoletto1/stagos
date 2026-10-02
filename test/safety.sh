#!/usr/bin/env bash
# Unit tests for the safety net: stag-backup (restic), stag-update (news, snapshot, pacman, pacdiff, archive
# pin), stag-battery (TLP) and the modules that install them (snapshots, update, power). No network, no root:
# restic, pacman, curl, ssh, sudo, tlp, systemctl and pacdiff are fakes from test/fixtures/bin.
# Run: ./test/safety.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"
FX="$ROOT/test/fixtures"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ORIG_PATH="$PATH"
pass=0; fail=0
check() { # check "name" command...
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi
}
has() { grep -q -- "$2" "$1"; }   # has FILE REGEX
# sandbox: fresh HOME, fakes on PATH, the repo's scripts under their installed names
sandbox() {
  rm -rf "${T:?}/sb"; mkdir -p "$T/sb/bin" "$T/sb/fake" "$T/sb/home" "$T/sb/sys"
  export FAKE_DIR="$T/sb/fake" FAKE_LOG="$T/sb/fake/log" HOME="$T/sb/home" STAGOS_SYS="$T/sb/sys"
  unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME STAGOS_BACKUP_ENV DIFFPROG
  : > "$FAKE_LOG"
  local t
  for t in curl ssh tlp systemctl pacdiff findmnt; do ln -s "$FX/bin/fake-cmd" "$T/sb/bin/$t"; done
  ln -s "$FX/bin/fake-restic" "$T/sb/bin/restic"
  ln -s "$FX/bin/fake-pacman-sync" "$T/sb/bin/pacman"
  ln -s "$FX/bin/fake-sudo" "$T/sb/bin/sudo"
  for t in stag-backup stag-update stag-battery; do ln -s "$ROOT/desktop/bin/$t.sh" "$T/sb/bin/$t"; done
  PATH="$T/sb/bin:$ORIG_PATH"
}
# backup_env [REPO]: what `stagos-desktop snapshots` writes, plus a password file
backup_env() {
  mkdir -p "$HOME/.config/stagos"
  printf 'secret-not-printed\n' > "$HOME/.config/stagos/restic.pass"; chmod 600 "$HOME/.config/stagos/restic.pass"
  {
    printf 'STAGOS_RESTIC_REPO=%q\n' "${1:-sftp:backuphost:/srv/restic/laptop}"
    printf 'STAGOS_RESTIC_PASSWORD_FILE=%q\n' "$HOME/.config/stagos/restic.pass"
    printf 'STAGOS_RESTIC_PATHS=%q\n' "$HOME /etc"
    printf 'STAGOS_NTFY_URL=%q\n' "${NTFY:-}"
    printf 'STAGOS_NTFY_TOKEN_FILE=%q\n' "${NTFY_TOKEN:-}"
  } > "$HOME/.config/stagos/backup.env"
  cp "$ROOT/desktop/backup/backup.exclude" "$HOME/.config/stagos/backup.exclude"
}
# power_supply ac|bat: a laptop with BAT0 and AC (online or not)
power_supply() {
  mkdir -p "$STAGOS_SYS/class/power_supply/AC" "$STAGOS_SYS/class/power_supply/BAT0"
  echo Mains > "$STAGOS_SYS/class/power_supply/AC/type"; echo Battery > "$STAGOS_SYS/class/power_supply/BAT0/type"
  if [ "$1" = ac ]; then echo 1 > "$STAGOS_SYS/class/power_supply/AC/online"; else echo 0 > "$STAGOS_SYS/class/power_supply/AC/online"; fi
}
ST() { echo "$HOME/.local/state/stagos/backup.state"; }

# ---- stag-backup ----
sandbox; backup_env; power_supply ac
printf 'linux-lts 6.6.1-1\nbash 5.2-1\n' > "$FAKE_DIR/pacman.installed"; echo yay > "$FAKE_DIR/pacman.foreign"
out="$(stag-backup now 2>&1)"; rc=$?
check "backup: first run exits 0" test "$rc" = 0
check "backup: a missing repo is initialised (restic rc 10)" has "$FAKE_LOG" '^restic init repo=sftp:backuphost:/srv/restic/laptop pass=yes'
check "backup: backs up \$HOME and /etc with the exclude file and --exclude-caches" \
  has "$FAKE_LOG" "^restic backup --json --exclude-caches --exclude-file=$HOME/.config/stagos/backup.exclude --tag stagos $HOME /etc "
check "backup: retention keep 7 daily / 4 weekly / 6 monthly" has "$FAKE_LOG" '^restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --tag stagos'
check "backup: package lists written before the run" bash -c "grep -qx linux-lts '$HOME/.local/state/stagos/pkglist-explicit.txt' && grep -qx yay '$HOME/.local/state/stagos/pkglist-foreign.txt'"
check "backup: pacman -Qqe ran before restic backup" bash -c "grep -n . '$FAKE_LOG' | grep -E 'pacman -Qqe|restic backup' | head -1 | grep -q pacman"
check "backup: state has last_ok, rc 0 and the snapshot id" bash -c "grep -q '^last_ok=[0-9]' '$(ST)' && grep -qx 'last_rc=0' '$(ST)' && grep -qx 'last_snapshot=0123abcd4567ef89' '$(ST)'"
check "backup: says the snapshot id" grep -q 'snapshot 0123abcd4567ef89' <<< "$out"
check "backup: first run also checks (weekly) and prunes" bash -c "grep -q '^restic check --read-data-subset=5%' '$FAKE_LOG' && grep -q '^restic prune' '$FAKE_LOG' && grep -q '^last_check=' '$(ST)'"
check "backup: probes the sftp host over ssh in batch mode" has "$FAKE_LOG" '^ssh -o BatchMode=yes -o ConnectTimeout=8 backuphost true'
check "backup: the password never reaches the log or output" bash -c "! grep -rq secret-not-printed '$HOME/.local/state' '$FAKE_LOG' && ! grep -q secret-not-printed <<< \"\$1\"" _ "$out"
: > "$FAKE_LOG"; stag-backup now >/dev/null 2>&1
check "backup: second run: no init, no check (done this week)" bash -c "! grep -q '^restic init' '$FAKE_LOG' && ! grep -q '^restic check' '$FAKE_LOG' && grep -q '^restic backup' '$FAKE_LOG'"
# restic rc 3: snapshot saved, some files unreadable (/etc root-only files)
echo 3 > "$FAKE_DIR/restic.backup.rc"; out="$(stag-backup now 2>&1)"; rc=$?
check "backup: restic rc 3 (unreadable root-only files) still counts as a good backup" bash -c "test $rc = 0 && grep -qx 'last_rc=0' '$(ST)' && grep -q unreadable <<< \"\$1\"" _ "$out"
# failure: state, exit code, ntfy only when configured
echo 1 > "$FAKE_DIR/restic.backup.rc"; : > "$FAKE_LOG"
stag-backup now >/dev/null 2>&1; rc=$?
check "backup: restic failure exits 1 and records last_rc=1" bash -c "test $rc = 1 && grep -qx 'last_rc=1' '$(ST)'"
check "backup: no ntfy without STAGOS_NTFY_URL" bash -c "! grep -q '^curl' '$FAKE_LOG'"
printf 'tok-not-printed\n' > "$T/sb/ntfy.token"; chmod 600 "$T/sb/ntfy.token"
NTFY="https://ntfy.example.invalid/laptop" NTFY_TOKEN="$T/sb/ntfy.token" backup_env; : > "$FAKE_LOG"
stag-backup now >/dev/null 2>&1
check "backup: failure pings ntfy (title, priority high) when configured" has "$FAKE_LOG" '^curl -fsS -m 15 -K - -H Title: .* backup failed -H Priority: high .*https://ntfy.example.invalid/laptop'
check "backup: the ntfy token goes through curl's stdin, never argv" bash -c "grep -q 'Authorization: Bearer tok-not-printed' '$FAKE_DIR/curl.stdin' && ! grep -q tok-not-printed '$FAKE_LOG'"
rm -f "$FAKE_DIR/restic.backup.rc"; backup_env
# unreachable host
echo 255 > "$FAKE_DIR/ssh.rc"; : > "$FAKE_LOG"
stag-backup now >/dev/null 2>&1; rc=$?
check "backup now: host away exits 75, no restic call" bash -c "test $rc = 75 && ! grep -q '^restic' '$FAKE_LOG'"
check "backup now: host away is not a failure (no ntfy, last_rc unchanged)" bash -c "! grep -q '^curl' '$FAKE_LOG' && grep -q '^last_skip_reason=host unreachable' '$(ST)'"
rm "$FAKE_DIR/ssh.rc"
# wrong password / network error on `cat config`: no init over an existing repo
echo 1 > "$FAKE_DIR/restic.cat.rc"; : > "$FAKE_LOG"
stag-backup now >/dev/null 2>&1; rc=$?
check "backup: an unusable repo (rc 1, not 10) fails without restic init" bash -c "test $rc = 1 && ! grep -q '^restic init' '$FAKE_LOG'"
rm "$FAKE_DIR/restic.cat.rc"
# timer mode gates
: > "$FAKE_LOG"; stag-backup run >/dev/null 2>&1; rc=$?
check "backup run: last good backup is fresh, nothing to do" bash -c "test $rc = 0 && ! grep -q '^restic' '$FAKE_LOG'"
sed -i 's/^last_ok=.*/last_ok=1000/' "$(ST)"; power_supply bat; : > "$FAKE_LOG"
stag-backup run >/dev/null 2>&1; rc=$?
check "backup run: on battery skips (rc 0, logged)" bash -c "test $rc = 0 && ! grep -q '^restic' '$FAKE_LOG' && grep -q 'skipped: on battery' '$HOME/.local/state/stagos/backup.log'"
power_supply ac; echo 255 > "$FAKE_DIR/ssh.rc"
stag-backup run >/dev/null 2>&1; rc=$?
check "backup run: host away exits 0 (the next hourly run retries)" bash -c "test $rc = 0 && ! grep -q '^restic backup' '$FAKE_LOG'"
rm "$FAKE_DIR/ssh.rc"
stag-backup run >/dev/null 2>&1; rc=$?
check "backup run: stale + AC + host up backs up" bash -c "test $rc = 0 && grep -q '^restic backup' '$FAKE_LOG'"
rm -rf "$STAGOS_SYS/class/power_supply"; sed -i 's/^last_ok=.*/last_ok=1000/' "$(ST)"; : > "$FAKE_LOG"
stag-backup run >/dev/null 2>&1
check "backup run: a box without a battery counts as on AC" has "$FAKE_LOG" '^restic backup'
# non-sftp repos are not probed over ssh
backup_env "rest:https://u:pw-not-shown@backup.example.invalid/laptop"; : > "$FAKE_LOG"; echo 255 > "$FAKE_DIR/ssh.rc"
stag-backup now >/dev/null 2>&1
check "backup: rest: repos skip the ssh probe" bash -c "! grep -q '^ssh' '$FAKE_LOG' && grep -q '^restic backup' '$FAKE_LOG'"
st="$(stag-backup status 2>&1)"
check "status: repo shown with the URL password masked" bash -c "grep -q 'repo: *rest:https://u:\*\*\*@backup.example.invalid/laptop' <<< \"\$1\" && ! grep -q pw-not-shown <<< \"\$1\"" _ "$st"
rm "$FAKE_DIR/ssh.rc"; backup_env
sed -i "s/^last_ok=.*/last_ok=$(( $(date +%s) - 2 * 86400 - 3 * 3600 ))/" "$(ST)"
st="$(stag-backup status 2>&1)"
check "status: last snapshot age" grep -q '^last ok:  2d 3h ago' <<< "$st"
check "status: timer line from systemctl --user list-timers" bash -c "grep -q '^timer:' <<< \"\$1\" && grep -q 'systemctl --user list-timers stagos-restic.timer' '$FAKE_LOG'" _ "$st"
rm -rf "$HOME/.local/state"
check "status: never backed up" bash -c "stag-backup status | grep -q '^last ok:  never'"
# restore-test
: > "$FAKE_LOG"; out="$(stag-backup restore-test 2>&1)"; rc=$?
check "restore-test: restores the package list and /etc/hostname with --verify into a temp dir" \
  bash -c "test $rc = 0 && grep -q '^restic restore latest --tag stagos --target .* --verify --include $HOME/.local/state/stagos/pkglist-explicit.txt --include /etc/hostname' '$FAKE_LOG'"
check "restore-test: reports ok and records it" bash -c "grep -q 'restore-test ok' <<< \"\$1\" && grep -q '^last_restore_test=' '$(ST)'" _ "$out"
echo 1 > "$FAKE_DIR/restic.restore.rc"
check "restore-test: a failed restore exits 1" bash -c "! stag-backup restore-test"
rm "$FAKE_DIR/restic.restore.rc"
rm "$HOME/.config/stagos/backup.env"
check "backup: no backup.env is a clear error" bash -c "stag-backup now 2>&1 | grep -q 'stagos-desktop snapshots'; test \${PIPESTATUS[0]} = 1"

# ---- stag-update ----
upd_sandbox() {
  sandbox; backup_env; power_supply ac
  printf 'bash 5.2-1\nlinux-lts 6.6.1-1\nmesa 24.1-1\n' > "$FAKE_DIR/pacman.installed"
  printf 'bash 5.2-1\nlinux-lts 6.6.2-1\nmesa 24.1-1\n' > "$FAKE_DIR/pacman.upgrade"
  cp "$FX/arch-news.xml" "$FAKE_DIR/curl.out"
  mkdir -p "$T/sb/modules/$(uname -r)"; export STAGOS_MODULES_DIR="$T/sb/modules"
  export STAGOS_MIRRORLIST="$T/sb/mirrorlist" STAGOS_ROOT_FSTYPE=ext4
  # shellcheck disable=SC2016  # pacman variables, literal
  printf '## Arch mirrorlist\nServer = https://mirror.example.invalid/$repo/os/$arch\n' > "$STAGOS_MIRRORLIST"
}
UL() { echo "$HOME/.local/state/stagos/update.log"; }
upd_sandbox
out="$(printf 'y\nn\n' | stag-update 2>&1)"; rc=$?
check "update: full run exits 0" test "$rc" = 0
check "update: first run shows the three newest news items, newest first" bash -c "grep -A6 '3 news item' <<< \"\$1\" | grep -c archlinux.org/news | grep -qx 3 && grep -q 'Manual intervention for foo & bar' <<< \"\$1\" && ! grep -q Prehistoric <<< \"\$1\"" _ "$out"
check "update: snapshot before pacman" bash -c "grep -n . '$FAKE_LOG' | grep -E '^[0-9]+:(restic backup|pacman -Syu)' | head -1 | grep -q restic"
check "update: sudo pacman -Syu" has "$FAKE_LOG" '^sudo pacman -Syu$'
check "update: reboot recommended for linux-lts" grep -q 'reboot recommended: linux-lts' <<< "$out"
check "update: logs the changed packages" has "$(UL)" 'changed: linux-lts'
check "update: lists failed units (system and user)" bash -c "grep -q '^systemctl --failed' '$FAKE_LOG' && grep -q '^systemctl --user --failed' '$FAKE_LOG'"
check "update: news marked read" test -s "$HOME/.local/state/stagos/update.news-seen"
# second run: no news since, nothing to ask about news
: > "$FAKE_LOG"; out="$(printf '' | stag-update 2>&1)"; rc=$?
check "update: no news since the last run, no question" bash -c "test $rc = 0 && grep -q 'no news since the last update' <<< \"\$1\" && grep -q '^sudo pacman -Syu' '$FAKE_LOG'" _ "$out"
check "update: nothing reboot-worthy changed" grep -q '^not needed' <<< "$out"
# a news item newer than the last run
date -d '2026-09-10' +%s > "$HOME/.local/state/stagos/update.news-seen"; : > "$FAKE_LOG"
out="$(printf 'n\n' | stag-update 2>&1)"; rc=$?
check "update: only news newer than the last run; no = stop before anything" bash -c "test $rc = 1 && grep -q '1 news item(s) since 2026-09-10' <<< \"\$1\" && ! grep -q Older <<< \"\$1\" && ! grep -q '^sudo' '$FAKE_LOG' && ! grep -q '^restic' '$FAKE_LOG'" _ "$out"
check "update: declined news stays unread" test "$(cat "$HOME/.local/state/stagos/update.news-seen")" = "$(date -d '2026-09-10' +%s)"
# feed down
echo 22 > "$FAKE_DIR/curl.rc"; : > "$FAKE_LOG"
out="$(printf 'n\n' | stag-update 2>&1)"; rc=$?
check "update: news unreachable asks; no = stop" bash -c "test $rc = 1 && grep -q 'could not fetch' <<< \"\$1\" && ! grep -q '^sudo' '$FAKE_LOG'" _ "$out"
rm "$FAKE_DIR/curl.rc"
# backup host away: warns and asks
echo 255 > "$FAKE_DIR/ssh.rc"; : > "$FAKE_LOG"
out="$(printf 'y\nn\n' | stag-update 2>&1)"; rc=$?
check "update: backup host away warns, asks, no = no pacman" bash -c "test $rc = 1 && grep -q 'backup host does not answer' <<< \"\$1\" && ! grep -q '^sudo pacman' '$FAKE_LOG'" _ "$out"
date -d '2026-09-10' +%s > "$HOME/.local/state/stagos/update.news-seen"; : > "$FAKE_LOG"
printf 'y\ny\n' | stag-update >/dev/null 2>&1; rc=$?
check "update: backup host away, yes = update without a snapshot" bash -c "test $rc = 0 && grep -q '^sudo pacman -Syu' '$FAKE_LOG'"
rm "$FAKE_DIR/ssh.rc"
# btrfs: snap-pac's job
ln -s "$FX/bin/fake-cmd" "$T/sb/bin/snapper"; : > "$FAKE_LOG"
STAGOS_ROOT_FSTYPE=btrfs stag-update </dev/null >/dev/null 2>&1
check "update: btrfs root leaves the snapshot to snap-pac (no restic)" bash -c "! grep -q '^restic' '$FAKE_LOG' && grep -q '^sudo pacman -Syu' '$FAKE_LOG'"
rm "$T/sb/bin/snapper"
# pacnew / pacsave
echo "/etc/pacman.conf.pacnew" > "$FAKE_DIR/pacdiff.out"; : > "$FAKE_LOG"
out="$(printf 'y\n' | stag-update 2>&1)"
check "update: lists .pacnew files (pacdiff -o) and runs pacdiff on yes" bash -c "grep -q '/etc/pacman.conf.pacnew' <<< \"\$1\" && grep -q '^pacdiff -o' '$FAKE_LOG' && grep -qE '^sudo (env DIFFPROG=.* )?pacdiff$' '$FAKE_LOG'" _ "$out"
: > "$FAKE_LOG"; DIFFPROG="meld" stag-update <<< 'y' >/dev/null 2>&1
check "update: DIFFPROG reaches pacdiff through sudo env" has "$FAKE_LOG" '^sudo env DIFFPROG=meld pacdiff$'
: > "$FAKE_LOG"; out="$(printf 'n\n' | stag-update 2>&1)"
check "update: pacdiff declined: says how to do it later" bash -c "grep -q 'later: sudo pacdiff' <<< \"\$1\" && ! grep -q '^sudo.*pacdiff' '$FAKE_LOG'" _ "$out"
rm "$FAKE_DIR/pacdiff.out"
# pacman fails
echo 1 > "$FAKE_DIR/pacman.rc"; : > "$FAKE_LOG"
stag-update </dev/null >/dev/null 2>&1; rc=$?
check "update: pacman failure exits 1" test "$rc" = 1
rm "$FAKE_DIR/pacman.rc"
# the running kernel is gone
rm -rf "$T/sb/modules/$(uname -r)"
check "update: REBOOT NEEDED when the running kernel's modules are gone" bash -c "stag-update </dev/null 2>&1 | grep -q 'REBOOT NEEDED'"
mkdir -p "$T/sb/modules/$(uname -r)"
# dry run
upd_sandbox; : > "$FAKE_LOG"; cp "$STAGOS_MIRRORLIST" "$T/ml.before"
out="$(stag-update --dry-run </dev/null 2>&1)"; rc=$?
check "update --dry-run: exits 0, prints the plan" bash -c "test $rc = 0 && grep -q '\[dry\] sudo pacman -Syu' <<< \"\$1\" && grep -q '\[dry\] stag-backup now' <<< \"\$1\"" _ "$out"
check "update --dry-run: no sudo, no restic, no news stamp" bash -c "! grep -qE '^(sudo|restic)' '$FAKE_LOG' && test ! -e '$HOME/.local/state/stagos/update.news-seen'"
out="$(stag-update --dry-run --pin 2026/01/15 </dev/null 2>&1)"
check "update --dry-run --pin: mirrorlist untouched" bash -c "cmp -s '$T/ml.before' '$STAGOS_MIRRORLIST' && ! grep -q '^sudo' '$FAKE_LOG' && grep -q '\[dry\] sudo install' <<< \"\$1\"" _ "$out"

# ---- archive pin ----
upd_sandbox; cp "$STAGOS_MIRRORLIST" "$T/ml.orig"
check "pin: rejects a bad date" bash -c "! stag-update --pin 2026-01-15 && ! stag-update --pin 2026/02/30 && ! stag-update --pin 2999/01/01"
echo 22 > "$FAKE_DIR/curl.rc"
check "pin: refuses a date the archive does not have, mirrorlist untouched" bash -c "! stag-update --pin 2026/01/15 && cmp -s '$T/ml.orig' '$STAGOS_MIRRORLIST'"
rm "$FAKE_DIR/curl.rc"; : > "$FAKE_LOG"
stag-update --pin 2026/01/15 </dev/null >/dev/null 2>&1; rc=$?
check "pin: exits 0, archive probed" bash -c "test $rc = 0 && grep -q '^curl -fsSI -m 20 https://archive.archlinux.org/repos/2026/01/15/core/os/x86_64/core.db' '$FAKE_LOG'"
check "pin: mirrorlist points at the archive date only" bash -c "grep -c '^Server' '$STAGOS_MIRRORLIST' | grep -qx 1 && grep -qF 'Server = https://archive.archlinux.org/repos/2026/01/15/\$repo/os/\$arch' '$STAGOS_MIRRORLIST'"
check "pin: the original mirrorlist is backed up" cmp -s "$T/ml.orig" "$STAGOS_MIRRORLIST.stagos-unpinned"
check "pin: --status says pinned" bash -c "stag-update --status | grep -qx 'pinned: 2026/01/15 (Arch Linux Archive)'"
stag-update --pin 2026/02/01 </dev/null >/dev/null 2>&1
check "pin again: the backup still holds the unpinned list" cmp -s "$T/ml.orig" "$STAGOS_MIRRORLIST.stagos-unpinned"
check "to: needs a pinned system" bash -c "cp '$STAGOS_MIRRORLIST' '$T/pinned'; cp '$T/ml.orig' '$STAGOS_MIRRORLIST'; ! stag-update --to 2026/03/01 </dev/null; cp '$T/pinned' '$STAGOS_MIRRORLIST'"
date -d '2026-09-30' +%s > "$HOME/.local/state/stagos/update.news-seen"; : > "$FAKE_LOG"
stag-update --to 2026/03/01 </dev/null >/dev/null 2>&1; rc=$?
check "to: moves the pin and updates with -Syuu" bash -c "test $rc = 0 && grep -q 'repos/2026/03/01/' '$STAGOS_MIRRORLIST' && grep -q '^sudo pacman -Syuu$' '$FAKE_LOG'"
echo 1 > "$FAKE_DIR/pacman.rc"
stag-update --to 2026/04/01 </dev/null >/dev/null 2>&1; rc=$?
check "to: pacman fails, the previous pin comes back" bash -c "test $rc != 0 && grep -q 'repos/2026/03/01/' '$STAGOS_MIRRORLIST' && ! grep -q 2026/04/01 '$STAGOS_MIRRORLIST'"
rm "$FAKE_DIR/pacman.rc"; date -d '2026-09-10' +%s > "$HOME/.local/state/stagos/update.news-seen"
printf 'n\n' | stag-update --to 2026/04/01 >/dev/null 2>&1
check "to: news declined, the previous pin comes back" grep -q 'repos/2026/03/01/' "$STAGOS_MIRRORLIST"
stag-update --unpin </dev/null >/dev/null 2>&1; rc=$?
check "unpin: restores the original mirrorlist (backup kept)" bash -c "test $rc = 0 && cmp -s '$T/ml.orig' '$STAGOS_MIRRORLIST' && test -s '$STAGOS_MIRRORLIST.stagos-unpinned'"
check "unpin: --status says not pinned; unpin again is a no-op" bash -c "stag-update --status | grep -qx 'pinned: no' && stag-update --unpin | grep -q 'not pinned'"

# provision/00-repos.sh: reflector must not overwrite a pin
reflector_plan() { bash -c 'HERE="$1"; DRY_RUN=1; source "$HERE/lib/common.sh"; source "$HERE/provision/00-repos.sh"; stagos_00_repos' _ "$ROOT" 2>&1; }
export -f reflector_plan; export ROOT
stag-update --pin 2026/01/15 </dev/null >/dev/null 2>&1
check "provision 00-repos: a pinned mirrorlist skips reflector" bash -c "out=\"\$(STAGOS_MIRRORLIST='$STAGOS_MIRRORLIST' reflector_plan)\"; ! grep -q 'sudo reflector' <<< \"\$out\" && grep -q 'reflector skipped' <<< \"\$out\""
stag-update --unpin </dev/null >/dev/null 2>&1
check "provision 00-repos: unpinned runs reflector" bash -c "STAGOS_MIRRORLIST='$STAGOS_MIRRORLIST' reflector_plan | grep -q 'sudo reflector'"

# ---- stag-battery ----
sandbox
B="$STAGOS_SYS/class/power_supply/BAT0"; mkdir -p "$B"
echo 78 > "$B/capacity"; echo Discharging > "$B/status"; echo 75 > "$B/charge_control_start_threshold"; echo 80 > "$B/charge_control_end_threshold"
echo 40000000 > "$B/energy_full"; echo 46000000 > "$B/energy_full_design"
st="$(stag-battery status)"
check "battery status: charge, health and thresholds" bash -c "grep -q 'battery: *78% discharging' <<< \"\$1\" && grep -q 'health: *86%' <<< \"\$1\" && grep -q 'starts below 75%, stops at 80%' <<< \"\$1\"" _ "$st"
: > "$FAKE_LOG"; stag-battery full >/dev/null 2>&1
check "battery full: sudo tlp fullcharge BAT0" has "$FAKE_LOG" '^sudo tlp fullcharge BAT0$'
: > "$FAKE_LOG"; stag-battery normal >/dev/null 2>&1
check "battery normal: sudo tlp setcharge BAT0" has "$FAKE_LOG" '^sudo tlp setcharge BAT0$'
echo 100 > "$B/charge_control_end_threshold"
check "battery status: stop 100 = thresholds off" bash -c "stag-battery | grep -q 'thresholds: off'"
check "battery: unknown command exits 2" bash -c "stag-battery nope; test \$? = 2"

# ---- modules (DRY_RUN off, package/system steps stubbed): power battery conf, snapshots, update ----
mod() { # mod SCRIPT FUNC [VAR=VAL...]: source the module with the helpers and run it; prints DM_CHANGED
  local script="$1" fn="$2"; shift 2
  # shellcheck disable=SC2016  # expands in the inner bash
  # shellcheck disable=SC2016  # expands in the inner bash
  env "$@" bash -c '
    HERE="$1"; DRY_RUN=0; script="$2"; fn="$3"
    source "$HERE/lib/common.sh"; source "$HERE/lib/desktop.sh"; source "$HERE/config/stagos.conf"; source "$script"
    dm_pkgs() { :; }; dm_bins() { :; }; dm_enable_user() { :; }; dm_enable_system() { :; }
    run() { echo "run $*" >> "$FAKE_LOG"; }
    dm_install() { # into $HOME/root for absolute system paths
      local d="$2"; case "$d" in /etc/*|/usr/*) d="$HOME/root$d" ;; esac
      if [[ -f "$d" ]] && cmp -s "$1" "$d" && [[ "$(stat -c %a "$d")" == "${3:-644}" ]]; then return 0; fi
      install -Dm"${3:-644}" "$1" "$d"; DM_CHANGED=$((DM_CHANGED + 1))
    }
    "$fn" >/dev/null 2>"$FAKE_DIR/mod.err"
    echo "$DM_CHANGED"' _ "$ROOT" "$script" "$fn"
}
sandbox
BC="$HOME/root/etc/tlp.d/51-stagos-battery.conf"
check "power: battery conf written (75/80 default) on run 1" test "$(mod provision/desktop/12-power.sh stagos_dm_power)" -ge 1
check "power: TLP keys START/STOP_CHARGE_THRESH_BAT0 = 75/80" bash -c "grep -qx START_CHARGE_THRESH_BAT0=75 '$BC' && grep -qx STOP_CHARGE_THRESH_BAT0=80 '$BC'"
check "power: run 2 changes 0 files" test "$(mod provision/desktop/12-power.sh stagos_dm_power)" = 0
mod provision/desktop/12-power.sh stagos_dm_power STAGOS_BAT_FULL=1 >/dev/null
check "power: STAGOS_BAT_FULL=1 writes the factory values 96/100 (thresholds off)" bash -c "grep -qx START_CHARGE_THRESH_BAT0=96 '$BC' && grep -qx STOP_CHARGE_THRESH_BAT0=100 '$BC'"
mod provision/desktop/12-power.sh stagos_dm_power STAGOS_BAT_START=85 STAGOS_BAT_STOP=80 >/dev/null
check "power: start >= stop falls back to 75/80 with a warning" bash -c "grep -qx START_CHARGE_THRESH_BAT0=75 '$BC' && grep -q 'out of range' '$FAKE_DIR/mod.err'"
mod provision/desktop/12-power.sh stagos_dm_power STAGOS_BAT_START=40 STAGOS_BAT_STOP=60 >/dev/null
check "power: custom thresholds" bash -c "grep -qx START_CHARGE_THRESH_BAT0=40 '$BC' && grep -qx STOP_CHARGE_THRESH_BAT0=60 '$BC'"

sandbox
SN=(provision/desktop/13-snapshots.sh stagos_dm_snapshots STAGOS_ROOT_FSTYPE=ext4 "STAGOS_RESTIC_REPO=sftp:backuphost:/srv/restic/laptop")
n1="$(mod "${SN[@]}")"
PF="$HOME/.config/stagos/restic.pass"
check "snapshots: run 1 writes backup.env, excludes, units and a password" bash -c "test $n1 -ge 5 && test -s '$HOME/.config/stagos/backup.env' && test -s '$HOME/.config/stagos/backup.exclude' && test -s '$HOME/.config/systemd/user/stagos-restic.timer'"
check "snapshots: password file is 600, 44 random chars" bash -c "test \$(stat -c %a '$PF') = 600 && test \$(wc -c < '$PF') = 44"
check "snapshots: the loud note names the file, never the password" bash -c "grep -q 'COPY IT SOMEWHERE SAFE' '$FAKE_DIR/mod.err' && grep -q '$PF' '$FAKE_DIR/mod.err' && ! grep -qF \"\$(cat '$PF')\" '$FAKE_DIR/mod.err'"
cp "$PF" "$T/pass1"
n2="$(mod "${SN[@]}")"
check "snapshots: run 2 changes 0 files, password kept" bash -c "test '$n2' = 0 && cmp -s '$T/pass1' '$PF'"
check "snapshots: default paths \$HOME and /etc, hourly attempts" bash -c "(. '$HOME/.config/stagos/backup.env' && test \"\$STAGOS_RESTIC_PATHS\" = '$HOME /etc') && grep -qx 'OnCalendar=hourly' '$HOME/.config/systemd/user/stagos-restic.timer'"
check "snapshots: the unit runs stag-backup run" grep -qx 'ExecStart=/usr/local/bin/stag-backup run' "$HOME/.config/systemd/user/stagos-restic.service"
mkdir -p "$HOME/.local/bin"; echo old > "$HOME/.local/bin/stagos-backup"
n3="$(mod "${SN[@]}")"
check "snapshots: the labwc-era ~/.local/bin/stagos-backup is removed" bash -c "test '$n3' = 1 && grep -qx 'run rm -f $HOME/.local/bin/stagos-backup' '$FAKE_LOG'"
sandbox
n4="$(mod provision/desktop/13-snapshots.sh stagos_dm_snapshots STAGOS_ROOT_FSTYPE=ext4 STAGOS_RESTIC_REPO=)"
check "snapshots: no repo, no password file, no units" bash -c "test '$n4' = 0 && test ! -e '$HOME/.config/stagos/restic.pass'"

# ---- static ----
check "unit files parse as systemd INI (section headers, key=value)" bash -c "! grep -vE '^(\[[A-Za-z]+\]|[A-Za-z]+=.*|#.*|)$' '$ROOT/desktop/systemd/stagos-restic.service' '$ROOT/desktop/systemd/stagos-restic.timer'"
check "backup.exclude covers caches, Trash, Steam, node_modules, .venv" bash -c "for p in '\$HOME/.cache' '\$HOME/.local/share/Trash' '\$HOME/.local/share/Steam' node_modules .venv; do grep -qxF \"\$p\" '$ROOT/desktop/backup/backup.exclude' || exit 1; done"
check "shellcheck (info) clean: safety scripts, modules, this test" shellcheck -S info -x -s bash \
  "$ROOT"/desktop/bin/stag-{backup,update,battery}.sh "$ROOT"/provision/desktop/{12-power,13-snapshots,18-update}.sh "$ROOT/test/safety.sh" \
  "$FX"/bin/fake-{restic,sudo,pacman-sync}

echo; echo "safety: $pass passed, $fail failed"
[ "$fail" = 0 ]
