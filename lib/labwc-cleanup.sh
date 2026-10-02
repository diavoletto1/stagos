#!/usr/bin/env bash
# labwc-cleanup.sh - `./stagos-desktop cleanup-labwc` (sourced): remove what the labwc-era StagOS installed on a
# box that ran it (before StagOS went Plasma-only). Idempotent and DRY_RUN aware; a second run finds nothing.
#   1. user configs and the Plasma coexistence files (NotShowIn=KDE autostart overrides, systemd drop-ins, the
#      notification D-Bus file, the labwc window theme) are MOVED into ~/.cache/stagos-labwc-backup-<date>/,
#      under their path relative to $HOME. Nothing is deleted.
#   2. the labwc-era helpers in /usr/local/bin move into the same backup (sudo; listed first), and the current
#      stag-session is installed (a labwc-era one would fall back to the removed labwc).
#   3. the labwc-era packages that are installed and that nothing outside the list requires (pacman -Qi
#      Required By) are listed and removed with `sudo pacman -Rns` after a y/N question (ASSUME_YES=1 skips it).
#      The dependencies -s would take along are listed too; any StagOS installs by name itself is first marked
#      explicitly installed (pacman -D --asexplicit) so it stays.
# shellcheck disable=SC2034  # the lists are read by the tests too

# packages StagOS installed for the labwc session (60-desktop, 65-extras and the old modules bar, launcher,
# notify, network, trackpad, capture, clipboard, nightlight, power, hidpi). Plasma and the kept modules need
# none of them; anything still required by another installed package is kept anyway (see lc_removable).
STAGOS_LABWC_PKGS=(labwc swaybg swayidle swaylock waybar fuzzel mako swaync swayosd wlr-randr
  grim slurp swappy wf-recorder wtype libinput-gestures cliphist wlsunset qt6ct nwg-look kanshi wlopm
  xdg-desktop-portal-wlr blueman network-manager-applet nm-connection-editor)
# /usr/local/bin helpers that only served labwc (stag-lib, stag-kismet, stag-mon stay)
STAGOS_LABWC_BINS=(stag-battery stag-clip stag-dock stag-lock stag-menu stag-nightlight stag-power
  stag-record stag-screenshot stag-spotlight stag-toggle)
# ~/.config entries the labwc-era modules wrote (or the labwc-only tools created)
STAGOS_LABWC_CONFIGS=(labwc waybar waybar-dock fuzzel mako swaync swayosd swaylock libinput-gestures.conf
  qt6ct swappy nwg-look)
# drop-ins the plasma module of the coexistence era wrote (ConditionEnvironment=!XDG_CURRENT_DESKTOP=KDE)
STAGOS_LABWC_DROPINS=(mako swaync waybar libinput-gestures swayosd)

LC_BACKUP=""
LC_PLAN=()

# lc_stash SRC [sudo]: move SRC (under $HOME, or /usr/local/bin) into the backup, keeping its relative path
lc_stash() {
  local src="$1" as="${2:-}" rel dst n=1
  case "$src" in
    "$HOME"/*) rel="${src#"$HOME"/}" ;;
    *) rel="usr-local-bin/${src##*/}" ;;
  esac
  dst="$LC_BACKUP/$rel"
  if dm_dry; then log "[dry] would move $src -> $dst"; return 0; fi
  # never overwrite an earlier backup of the same path (same day, run twice): suffix .1, .2, ...
  while [[ -e "$dst" || -L "$dst" ]]; do dst="$LC_BACKUP/$rel.$n"; n=$((n + 1)); done
  mkdir -p "$(dirname "$dst")"
  ${as:+sudo} mv -- "$src" "$dst" || { warn "could not move $src"; return 1; }
  DM_CHANGED=$((DM_CHANGED + 1))
  log "moved $src -> $dst"
}

# lc_user_files: every labwc-era file or dir under $HOME, one per line
lc_user_files() {
  local c d n f
  c="$(dm_cfg)"; d="${XDG_DATA_HOME:-$HOME/.local/share}"
  for n in "${STAGOS_LABWC_CONFIGS[@]}"; do [[ -e "$c/$n" || -L "$c/$n" ]] && echo "$c/$n"; done
  # autostart overrides written by dm_autostart_not_in: first line "# StagOS: <src> with NotShowIn=KDE ..."
  for f in "$c"/autostart/*.desktop; do
    [[ -f "$f" ]] && head -1 "$f" | grep -q '^# StagOS: .* with NotShowIn=' && echo "$f"
  done
  for n in "${STAGOS_LABWC_DROPINS[@]}"; do
    f="$c/systemd/user/$n.service.d/50-stagos-not-plasma.conf"
    [[ -f "$f" ]] && echo "$f"
  done
  f="$d/dbus-1/services/org.freedesktop.Notifications.service"
  [[ -f "$f" ]] && grep -q 'stag-session notify-daemon' "$f" && echo "$f"
  # the labwc window theme (openbox-3 buttons); a StagOS GTK theme next to it would stay
  [[ -d "$d/themes/StagOS/openbox-3" ]] && echo "$d/themes/StagOS/openbox-3"
  return 0
}

# lc_bins: labwc-era helpers still in /usr/local/bin (only StagOS copies: "StagOS" in the header). A name
# the current tree ships again (stag-battery: TLP charge thresholds, module power) is kept when it is that copy.
lc_bins() {
  local b f
  for b in "${STAGOS_LABWC_BINS[@]}"; do
    f="${STAGOS_LOCAL_BIN:-/usr/local/bin}/$b"
    [[ -f "$HERE/desktop/bin/$b.sh" ]] && cmp -s "$f" "$HERE/desktop/bin/$b.sh" && continue
    [[ -f "$f" ]] && head -5 "$f" | grep -q 'StagOS' && echo "$f"
  done
  return 0
}

# lc_required_by PKG: the installed packages that depend on PKG (pacman -Qi "Required By", wrapped lines joined)
lc_required_by() {
  LC_ALL=C pacman -Qi "$1" 2>/dev/null | awk '
    /^Required By/ { on = 1; sub(/^[^:]*:[[:space:]]*/, ""); print; next }
    on && /^[[:space:]]/ { print; next }
    { on = 0 }' | tr -s ' \t' '\n' | grep -v -e '^$' -e '^None$'
}

# lc_removable: installed labwc-era packages that no package outside the removal set requires.
# Fixed point: a package kept because something else needs it keeps its own dependencies in the list too.
lc_removable() {
  local p r set=() keep changed=1
  for p in "${STAGOS_LABWC_PKGS[@]}"; do pacman -Q "$p" >/dev/null 2>&1 && set+=("$p"); done
  while [[ "$changed" == 1 && ${#set[@]} -gt 0 ]]; do
    changed=0; keep=()
    for p in "${set[@]}"; do
      while read -r r; do
        [[ -n "$r" ]] || continue
        if [[ " ${set[*]} " != *" $r "* ]]; then
          warn "keeping $p: required by $r"; changed=1; continue 2
        fi
      done < <(lc_required_by "$p")
      keep+=("$p")
    done
    set=("${keep[@]}")
  done
  [[ ${#set[@]} -gt 0 ]] && printf '%s\n' "${set[@]}"
  return 0
}

# lc_cascade PKG...: what `pacman -Rns PKG...` would take besides PKG... (dependencies nothing else needs).
# pacman -p only prints, no root needed (and does not combine with -n).
lc_cascade() {
  LC_ALL=C pacman -Rsp --print-format '%n' "$@" 2>/dev/null | grep -vxF -f <(printf '%s\n' "$@")
  return 0
}

# lc_protected PKG...: cascade packages StagOS installs by name elsewhere (install/, provision/, the modules), e.g.
# gpsd, which waybar pulls in too. Marked explicitly installed before the removal, so pacman -Rns leaves them.
lc_protected() {
  local words p
  words="$(cat "$HERE"/install/*.sh "$HERE"/provision/*.sh "$HERE"/provision/desktop/*.sh 2>/dev/null \
    | grep -v '^[[:space:]]*#' | grep -oE '[A-Za-z0-9][A-Za-z0-9+._-]*' | sort -u)"
  while read -r p; do
    [[ -n "$p" ]] && grep -qxF -- "$p" <<< "$words" && echo "$p"
  done < <(lc_cascade "$@")
  return 0
}

stagos_cleanup_labwc() {
  local files=() bins=() pkgs=() units=() deps=() prot=() f u
  LC_BACKUP="${STAGOS_LABWC_BACKUP:-${XDG_CACHE_HOME:-$HOME/.cache}/stagos-labwc-backup-$(date +%F)}"
  mapfile -t files < <(lc_user_files)
  mapfile -t bins < <(lc_bins)
  mapfile -t pkgs < <(lc_removable)
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    mapfile -t prot < <(lc_protected "${pkgs[@]}")
    mapfile -t deps < <(lc_cascade "${pkgs[@]}" | grep -vxF -f <(printf '%s\n' "${prot[@]}" ''))
  fi
  # the caps-lock OSD backend was enabled system-wide by the old notify module
  if dm_have_systemd && systemctl is-enabled swayosd-libinput-backend.service >/dev/null 2>&1; then
    units+=(swayosd-libinput-backend.service)
  fi

  if [[ ${#files[@]} -eq 0 && ${#bins[@]} -eq 0 && ${#pkgs[@]} -eq 0 && ${#units[@]} -eq 0 ]]; then
    ok "nothing labwc-era left: no configs, helpers or packages to clean up"
  else
    log "labwc-era leftovers (configs are moved to $LC_BACKUP, nothing is deleted):"
    for f in "${files[@]}"; do printf '  config   %s\n' "${f/#$HOME/\~}"; done
    for f in "${bins[@]}"; do printf '  sudo mv  %s\n' "$f"; done
    printf '  sudo install %s (the Plasma-only one, when it differs)\n' "${STAGOS_LOCAL_BIN:-/usr/local/bin}/stag-session"
    for u in "${units[@]}"; do printf '  sudo systemctl disable --now %s\n' "$u"; done
    [[ ${#prot[@]} -gt 0 ]] && printf '  sudo pacman -D --asexplicit %s   (StagOS installs these itself: -Rns must not take them)\n' "${prot[*]}"
    [[ ${#pkgs[@]} -gt 0 ]] && printf '  sudo pacman -Rns %s\n' "${pkgs[*]}"
    [[ ${#deps[@]} -gt 0 ]] && printf '    (-s also takes their unneeded dependencies: %s)\n' "${deps[*]}"
  fi

  for f in "${files[@]}"; do lc_stash "$f"; done
  if ! dm_dry; then # empty dirs left behind by the moves: the drop-in dirs and the theme dir, nothing else
    for f in "${files[@]}"; do
      case "$f" in */*.service.d/*|*/themes/StagOS/*) rmdir --ignore-fail-on-non-empty -- "$(dirname "$f")" 2>/dev/null || true ;; esac
    done
  fi
  for f in "${bins[@]}"; do lc_stash "$f" sudo; done
  # the Plasma-only stag-session goes in before labwc goes out and before the tty1 block below: a labwc-era
  # stag-session falls back to `exec labwc`, which would loop tty1 once labwc is removed
  dm_install "$HERE/desktop/bin/stag-session.sh" "${STAGOS_LOCAL_BIN:-/usr/local/bin}/stag-session" 755 sudo
  for u in "${units[@]}"; do run sudo systemctl disable --now "$u" || warn "could not disable $u"; done

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    if dm_dry; then
      [[ ${#prot[@]} -gt 0 ]] && run sudo pacman -D --asexplicit "${prot[@]}"
      run sudo pacman -Rns "${pkgs[@]}"
    elif confirm "remove ${#pkgs[@]} labwc-era package(s) with pacman -Rns (Plasma and the kept modules need none of them)?"; then
      if [[ ${#prot[@]} -gt 0 ]] && ! sudo pacman -D --asexplicit "${prot[@]}"; then
        warn "pacman -D --asexplicit ${prot[*]} failed: packages kept (-Rns would take those too); rerun ./stagos-desktop cleanup-labwc"
      elif [[ "${ASSUME_YES:-0}" == 1 ]]; then
        sudo pacman -Rns --noconfirm "${pkgs[@]}" || warn "pacman -Rns failed; rerun ./stagos-desktop cleanup-labwc"
      else
        sudo pacman -Rns "${pkgs[@]}" || warn "pacman -Rns failed; rerun ./stagos-desktop cleanup-labwc"
      fi
    else
      log "packages kept; rerun ./stagos-desktop cleanup-labwc to remove them"
    fi
  fi
  # an old tty1 block (exec labwc, or the stag-session/labwc one) gives way to the Plasma one
  if grep -q '# StagOS: autostart' "$HOME/.zprofile" 2>/dev/null && stagos_zprofile_sync "$HOME/.zprofile" && ! dm_dry; then
    DM_CHANGED=$((DM_CHANGED + 1)); log "wrote $HOME/.zprofile"
  fi
  [[ -d "$LC_BACKUP" ]] && log "backup: $LC_BACKUP"
  return 0
}
