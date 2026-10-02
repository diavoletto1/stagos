#!/bin/bash
# StagOS safe system update.
#   stag-update                  Arch news since the last run (asks), restic snapshot (stag-backup now), sudo pacman -Syu,
#                                .pacnew/.pacsave review (pacdiff), failed units, reboot hint
#   stag-update --dry-run        print what would happen; changes nothing (news is still fetched and shown)
#   stag-update --pin YYYY/MM/DD point pacman at the Arch Linux Archive snapshot of that date (mirrorlist backed up)
#   stag-update --to YYYY/MM/DD  move a pinned system to another archive date, then update with -Syuu
#   stag-update --unpin          restore the mirrorlist saved by --pin (then run stag-update)
#   stag-update --status         pinned or not, last run
# Log: ~/.local/state/stagos/update.log. The archive pin is off unless --pin is used.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/stagos"
LOG="$STATE_DIR/update.log"
NEWS_STAMP="$STATE_DIR/update.news-seen"
MIRRORLIST="${STAGOS_MIRRORLIST:-/etc/pacman.d/mirrorlist}"
MIRROR_BAK="$MIRRORLIST.stagos-unpinned"
NEWS_URL="${STAGOS_NEWS_URL:-https://archlinux.org/feeds/news/}"
ARCHIVE="${STAGOS_ARCHIVE_URL:-https://archive.archlinux.org}"
PIN_TAG="# StagOS archive pin:"
# a reboot is worth it when one of these changed (kernel, microcode, init, libc, graphics, the session)
REBOOT_RE='^(linux|linux-lts|linux-zen|linux-hardened|intel-ucode|amd-ucode|systemd|glibc|mesa|vulkan-intel|nvidia.*|wayland|dbus|dbus-broker|plasma-workspace|kwin|qt6-base)$'
DRY=0

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
say() { printf '%s\n' "$*"; log "$*"; }
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; log "== $*"; }
die() { printf 'stag-update: %s\n' "$*" >&2; log "error: $*"; exit 1; }
# run CMD...: execute, or print it under --dry-run
run() { if [ "$DRY" = 1 ]; then printf '[dry] %s\n' "$*"; return 0; fi; log "run: $*"; "$@"; }
ask() { # ask "question": rc 0 on y/yes; a dry run never asks (answers yes, to show the rest)
  local a
  [ "$DRY" = 1 ] && { printf '[dry] %s [y/N] y\n' "$1"; return 0; }
  printf '%s [y/N] ' "$1"; read -r a || a=""
  log "ask: $1 -> ${a:-no}"
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- Arch news ----
# feed_items: "EPOCH<TAB>TITLE<TAB>LINK" per <item> of the RSS on stdin, newest first
feed_items() {
  tr '\n' ' ' | sed 's/<item>/\n<item>/g' | while IFS= read -r it; do
    case "$it" in '<item>'*) ;; *) continue ;; esac
    local t l d e
    t="$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' <<< "${it%%</title>*}</title>")"
    l="$(sed -n 's:.*<link>\(.*\)</link>.*:\1:p' <<< "${it%%</link>*}</link>")"
    d="$(sed -n 's:.*<pubDate>\(.*\)</pubDate>.*:\1:p' <<< "${it%%</pubDate>*}</pubDate>")"
    e="$(date -d "$d" +%s 2>/dev/null)" || continue
    t="$(sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g' <<< "$t")"
    printf '%s\t%s\t%s\n' "$e" "$t" "$l"
  done | sort -rn
}
news() {
  local feed since items n
  hdr "Arch news"
  if ! feed="$(curl -fsSL -m 20 "$NEWS_URL" </dev/null 2>/dev/null)" || [ -z "$feed" ]; then
    say "could not fetch $NEWS_URL: read https://archlinux.org/news/ before updating"
    ask "Continue without the news?" || { say "stopped"; exit 1; }
    return 0
  fi
  since="$(cat "$NEWS_STAMP" 2>/dev/null)"
  items="$(feed_items <<< "$feed")"
  if [[ "$since" =~ ^[0-9]+$ ]]; then
    items="$(awk -F'\t' -v s="$since" '$1 > s' <<< "$items")"
  else
    items="$(head -n 3 <<< "$items")"   # first run: the three newest
  fi
  if [ -z "$items" ]; then say "no news since the last update"; mark_news; return 0; fi
  n="$(wc -l <<< "$items")"
  say "$n news item(s) $([[ "$since" =~ ^[0-9]+$ ]] && echo "since $(date -d "@$since" +%F)" || echo "(latest)"):"
  while IFS=$'\t' read -r e t l; do say "  $(date -d "@$e" +%F)  $t"; say "              $l"; done <<< "$items"
  ask "Read them? Continue with the update?" || { say "stopped (news not marked read)"; exit 1; }
  mark_news
}
mark_news() { [ "$DRY" = 1 ] || date +%s > "$NEWS_STAMP"; }

# ---- snapshot ----
snapshot() {
  local rc
  hdr "Snapshot"
  if [ "${STAGOS_ROOT_FSTYPE:-$(findmnt -no FSTYPE / 2>/dev/null)}" = btrfs ] && command -v snapper >/dev/null 2>&1; then
    say "btrfs root: snap-pac takes a snapper snapshot around the pacman transaction"; return 0
  fi
  if ! command -v stag-backup >/dev/null 2>&1 || [ ! -r "${XDG_CONFIG_HOME:-$HOME/.config}/stagos/backup.env" ]; then
    say "WARNING: backups are not set up (STAGOS_RESTIC_REPO, ./stagos-desktop snapshots)"
    ask "Update without a snapshot?" || { say "stopped"; exit 1; }
    return 0
  fi
  if [ "$DRY" = 1 ]; then run stag-backup now; return 0; fi
  stag-backup now </dev/null; rc=$?
  case "$rc" in
    0) log "snapshot ok" ;;
    75) say "WARNING: the backup host does not answer, no snapshot"
        ask "Update without a snapshot?" || { say "stopped"; exit 1; } ;;
    *) say "WARNING: the snapshot failed (rc $rc, see stag-backup status)"
       ask "Update without a snapshot?" || { say "stopped"; exit 1; } ;;
  esac
}

# ---- pacman ----
pkg_versions() { pacman -Q </dev/null 2>/dev/null | sort; }
upgrade() { # FLAGS (-Syu or -Syuu)
  local before after changed rc
  hdr "pacman $1"
  before="$(mktemp)"; after="$(mktemp)"
  pkg_versions > "$before"
  run sudo pacman "$1"; rc=$?
  pkg_versions > "$after"
  changed="$(comm -13 "$before" "$after" | awk '{print $1}')"
  rm -f "$before" "$after"
  if [ -n "$changed" ]; then log "changed: $(tr '\n' ' ' <<< "$changed")"; fi
  [ "$rc" = 0 ] || { say "pacman exited $rc"; return "$rc"; }
  REBOOT_PKGS="$(grep -E "$REBOOT_RE" <<< "$changed" | tr '\n' ' ')"
  say "$(grep -c . <<< "$changed") package(s) changed"
}

pacnew() {
  local files
  hdr ".pacnew / .pacsave"
  if ! command -v pacdiff >/dev/null 2>&1; then say "pacdiff missing (pacman-contrib): skipped"; return 0; fi
  files="$(pacdiff -o </dev/null 2>/dev/null)"
  if [ -z "$files" ]; then say "none"; return 0; fi
  say "$files"
  if ask "Merge them now with pacdiff?"; then
    local dp="${DIFFPROG:-}"
    [ -z "$dp" ] && command -v nvim >/dev/null 2>&1 && dp="nvim -d"
    if [ -n "$dp" ]; then run sudo env DIFFPROG="$dp" pacdiff; else run sudo pacdiff; fi
  else
    say "later: sudo pacdiff"
  fi
}

units() {
  local sys usr
  hdr "Failed units"
  sys="$(systemctl --failed --no-legend --plain </dev/null 2>/dev/null | awk '{print $1}')"
  usr="$(systemctl --user --failed --no-legend --plain </dev/null 2>/dev/null | awk '{print $1}')"
  [ -z "$sys$usr" ] && { say "none"; return 0; }
  [ -n "$sys" ] && say "system: $(tr '\n' ' ' <<< "$sys") (journalctl -u NAME -b)"
  [ -n "$usr" ] && say "user:   $(tr '\n' ' ' <<< "$usr") (journalctl --user -u NAME -b)"
}

reboot_hint() {
  local k; k="$(uname -r)"
  hdr "Reboot"
  if [ ! -d "${STAGOS_MODULES_DIR:-/usr/lib/modules}/$k" ]; then
    say "REBOOT NEEDED: the running kernel $k is no longer installed (new modules will not load)"
  elif [ -n "${REBOOT_PKGS:-}" ]; then
    say "reboot recommended: $REBOOT_PKGS"
  else
    say "not needed"
  fi
}

# ---- Arch Linux Archive pin ----
valid_date() { [[ "$1" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] && date -d "${1//\//-}" +%F >/dev/null 2>&1 && [ "$(date -d "${1//\//-}" +%s)" -le "$(date +%s)" ]; }
pinned_date() { sed -n "s|^$PIN_TAG \([0-9/]*\).*|\1|p" "$MIRRORLIST" 2>/dev/null | head -n1; }
archive_has() { curl -fsSI -m 20 "$ARCHIVE/repos/$1/core/os/x86_64/core.db" </dev/null >/dev/null 2>&1; }
write_mirrorlist() { # DATE
  local tmp; tmp="$(mktemp)"
  printf '%s %s (stag-update --unpin restores %s)\n' "$PIN_TAG" "$1" "$MIRROR_BAK" > "$tmp"
  # shellcheck disable=SC2016  # $repo and $arch are pacman's variables
  printf 'Server = %s/repos/%s/$repo/os/$arch\n' "$ARCHIVE" "$1" >> "$tmp"
  run sudo install -m644 "$tmp" "$MIRRORLIST"; local rc=$?
  rm -f "$tmp"; return "$rc"
}
pin() { # DATE
  valid_date "$1" || die "bad date $1 (want YYYY/MM/DD, not in the future)"
  archive_has "$1" || die "the Arch Linux Archive has no snapshot for $1 ($ARCHIVE/repos/$1/)"
  if [ -z "$(pinned_date)" ]; then
    run sudo cp -p "$MIRRORLIST" "$MIRROR_BAK" || die "could not back up $MIRRORLIST"
  fi
  write_mirrorlist "$1" || die "could not write $MIRRORLIST"
  say "pinned to $1. Next: stag-update --to $1 syncs the system to that date (downgrades anything newer);"
  say "plain stag-update only ever reaches $1. Undo: stag-update --unpin"
}
unpin() {
  [ -n "$(pinned_date)" ] || { say "not pinned"; return 0; }
  [ -s "$MIRROR_BAK" ] || die "no $MIRROR_BAK to restore; edit $MIRRORLIST by hand (or reinstall pacman-mirrorlist)"
  run sudo cp -p "$MIRROR_BAK" "$MIRRORLIST" || die "could not restore $MIRRORLIST"
  say "unpinned ($MIRRORLIST restored, $MIRROR_BAK kept). Next: stag-update"
}
# --to: the previous mirrorlist, put back if the update does not finish (pacman fails, a question is answered
# no, Ctrl-C). Set only while --to runs.
PIN_RESTORE=""
# shellcheck disable=SC2317,SC2329  # run by the EXIT trap
restore_pin() {
  [ -n "$PIN_RESTORE" ] || return 0
  printf 'stag-update: the update did not finish, the pin goes back to %s\n' "$(sed -n "s|^$PIN_TAG \([0-9/]*\).*|\1|p" "$PIN_RESTORE")" >&2
  log "restoring the previous pin"
  sudo install -m644 "$PIN_RESTORE" "$MIRRORLIST" || printf 'stag-update: COULD NOT restore %s: sudo cp %s %s\n' "$MIRRORLIST" "$PIN_RESTORE" "$MIRRORLIST" >&2
  rm -f "$PIN_RESTORE"; PIN_RESTORE=""
}
trap restore_pin EXIT
trap 'exit 130' INT TERM
move_to() { # DATE: write the new date, update with -Syuu; the old pin comes back unless that finishes
  local old prev
  old="$(pinned_date)"
  [ -n "$old" ] || die "not pinned: use --pin $1 first"
  valid_date "$1" || die "bad date $1 (want YYYY/MM/DD, not in the future)"
  archive_has "$1" || die "the Arch Linux Archive has no snapshot for $1"
  prev="$(mktemp)"; cp "$MIRRORLIST" "$prev"
  write_mirrorlist "$1" || { rm -f "$prev"; die "could not write $MIRRORLIST"; }
  if [ "$DRY" = 1 ]; then rm -f "$prev"; else PIN_RESTORE="$prev"; fi
  say "pin: $old -> $1"
  update_flow -Syuu || exit 1
  rm -f "$PIN_RESTORE"; PIN_RESTORE=""
}

update_flow() { # FLAGS
  log "---- stag-update $([ "$DRY" = 1 ] && echo '(dry run) ')$1 $([ -n "$(pinned_date)" ] && echo "pinned $(pinned_date)")"
  news
  snapshot
  upgrade "$1" || return 1
  pacnew
  units
  reboot_hint
  say "done ($(date '+%F %H:%M'), log: $LOG)"
}

status() {
  local p; p="$(pinned_date)"
  if [ -n "$p" ]; then echo "pinned: $p (Arch Linux Archive)"; else echo "pinned: no"; fi
  if [ -s "$NEWS_STAMP" ]; then echo "news read: $(date -d "@$(cat "$NEWS_STAMP")" '+%F %H:%M')"; fi
  grep -- '---- stag-update' "$LOG" 2>/dev/null | tail -n1 | sed 's/ ---- stag-update.*//; s/^/last run: /'
  echo "log: $LOG"
}

args=()
for a in "$@"; do
  case "$a" in --dry-run|-n) DRY=1 ;; *) args+=("$a") ;; esac
done
set -- "${args[@]}"
case "${1:-}" in
  '') update_flow -Syu ;;
  --pin) [ -n "${2:-}" ] || die "--pin needs a date (YYYY/MM/DD)"; pin "$2" ;;
  --to) [ -n "${2:-}" ] || die "--to needs a date (YYYY/MM/DD)"; move_to "$2" ;;
  --unpin) unpin ;;
  --status|status) status ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "stag-update: unknown option $1 (see --help)" >&2; exit 2 ;;
esac
