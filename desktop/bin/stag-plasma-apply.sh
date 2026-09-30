#!/bin/bash
# StagOS: apply ~/.config/stagos/desktop.conf to Plasma. Idempotent; safe when Plasma is not running
# (then it writes config only and says what it skipped; the next Plasma login finishes the job).
#   stag-plasma-apply                 [effects] -> kwinrc/kdeglobals, [dock] -> dock + remembered window rules
#   stag-plasma-apply --base          also the StagOS look (desktop/plasma/base.kconf + StagOS.colors)
#   stag-plasma-apply --reset-layout  rebuild top bar + dock now (Plasma running) or at the next Plasma start
#   stag-plasma-apply --session       Plasma autostart: waits for plasmashell, first-login layout and scale
#   --dry-run  print what would be written/called   --quiet  warnings only
# Data (installed by `stagos-desktop plasma`): ~/.local/share/stagos/plasma (STAGOS_PLASMA_DATA).
set -uo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/stagos"
SRC="${STAGOS_PLASMA_DATA:-$DATA_HOME/stagos/plasma}"
CONF="${STAGOS_DESKTOP_CONF:-$CFG/stagos/desktop.conf}"
LNF_ID=org.stagos.desktop
LNF="$DATA_HOME/plasma/look-and-feel/$LNF_ID"
LAYOUT_OUT="$LNF/contents/layouts/org.kde.plasma.desktop-layout.js"
MARK="$STATE/plasma-layout-applied"
SCALE_MARK="$STATE/plasma-scale-applied"
APPLETSRC="$CFG/plasma-org.kde.plasma.desktop-appletsrc"
QDBUS="${STAGOS_QDBUS:-qdbus6}"
WAIT="${STAGOS_PLASMA_WAIT:-60}"

base=0 reset=0 session=0 dry=0 quiet=0
for a in "$@"; do
  case "$a" in
    --base) base=1 ;;
    --reset-layout) reset=1 ;;
    --session) session=1 ;;
    --dry-run) dry=1 ;;
    --quiet) quiet=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "stag-plasma-apply: unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done

say()  { [ "$quiet" = 1 ] || echo "stag-plasma-apply: $*"; }
warn() { echo "stag-plasma-apply: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if ! have kwriteconfig6; then
  warn "Plasma is not installed (no kwriteconfig6); nothing to do"
  exit 0
fi
if [ ! -d "$SRC" ]; then
  warn "no StagOS Plasma data in $SRC (run: stagos-desktop plasma)"
  exit 1
fi
# one apply at a time (the settings path unit and the session autostart can overlap)
if [ "$dry" = 0 ] && have flock && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR:-}" ]; then
  exec 9>"$XDG_RUNTIME_DIR/stag-plasma-apply.lock"
  flock -w 30 9 || warn "another stag-plasma-apply is still running; continuing anyway"
fi

# ---- desktop.conf: INI, missing file or key = desktop.conf.default ----
ini_get() { # file section key: prints the value, rc 1 when absent
  awk -v s="$2" -v k="$3" '
    /^[[:space:]]*[#;]/ { next }
    /^[[:space:]]*\[/ { sec = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", sec); next }
    sec == s && index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == k) { v = substr($0, index($0, "=") + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); print v; found = 1; exit }
    }
    END { exit !found }' "$1" 2>/dev/null
}
conf() { ini_get "$CONF" "$1" "$2" || ini_get "$SRC/desktop.conf.default" "$1" "$2" || printf '%s\n' "${3:-}"; }

# ---- change tracking: which config files this run rewrote ----
FILES=(kdeglobals kwinrc kwinrulesrc kglobalshortcutsrc kcminputrc powerdevilrc kscreenlockerrc plasmarc
  ksplashrc breezerc kwalletrc kded6rc baloofilerc)
snap() {
  local f
  for f in "${FILES[@]}"; do [ -f "$CFG/$f" ] && md5sum "$CFG/$f"; done
  [ -f "$LAYOUT_OUT" ] && md5sum "$LAYOUT_OUT"
  true
}
before="$(snap)"

kw() { # kw FILE GROUP[/SUB...] KEY VALUE
  local file="$1" grp="$2" key="$3" val="$4" args=() g
  local IFS=/
  for g in $grp; do args+=(--group "$g"); done
  unset IFS
  if [ "$dry" = 1 ]; then say "[dry] $file [$grp] $key=$val"; return 0; fi
  kwriteconfig6 --file "$file" "${args[@]}" --key "$key" -- "$val" </dev/null || warn "could not write $file [$grp] $key"
}
kr() { # kr FILE GROUP KEY: current value
  kreadconfig6 --file "$1" --group "$2" --key "$3" 2>/dev/null
}

# ---- --base: StagOS look ----
apply_base() {
  local file grp key val colors
  while IFS='|' read -r file grp key val; do
    case "$file" in ''|'#'*) continue ;; esac
    kw "$file" "$grp" "$key" "${val//\\t/$'\t'}"
  done < "$SRC/base.kconf"
  # color scheme -> kdeglobals (what System Settings does; plasma-apply-colorscheme needs a display)
  colors="$DATA_HOME/color-schemes/StagOS.colors"
  [ -f "$colors" ] || colors="$SRC/StagOS.colors"
  while IFS='|' read -r grp key val; do
    kw kdeglobals "$grp" "$key" "$val"
  done < <(awk '
    /^[[:space:]]*#/ || !NF { next }
    /^\[/ { g = $0; gsub(/^\[|\]$/, "", g); gsub(/\]\[/, "/", g); next }
    g != "General" && index($0, "=") { print g "|" substr($0, 1, index($0, "=") - 1) "|" substr($0, index($0, "=") + 1) }
  ' "$colors")
  kw kdeglobals General ColorScheme StagOS
  say "base look applied (colors, fonts, decoration, shortcuts, touchpad, power)"
}

# ---- [effects] ----
apply_effects() {
  local blur factor
  blur="$(conf effects blur true)"
  case "$blur" in true|1|yes|on) blur=true ;; *) blur=false ;; esac
  factor="$(conf effects animation_factor 0.7)"
  [[ "$factor" =~ ^[0-9]+([.][0-9]+)?$ ]] || { warn "effects: animation_factor '$factor' is not a number, using 0.7"; factor=0.7; }
  kw kwinrc Plugins blurEnabled "$blur"
  kw kdeglobals KDE AnimationDurationFactor "$factor"
}

# ---- [dock]: resolve launchers; missing .desktop files are skipped with a warning ----
APPDIRS=()
app_dirs() {
  local d IFS=:
  APPDIRS=("$DATA_HOME/applications")
  for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do APPDIRS+=("$d/applications"); done
  APPDIRS+=("$DATA_HOME/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications)
}
find_desktop() {
  local d
  for d in "${APPDIRS[@]}"; do [ -f "$d/$1" ] && { printf '%s\n' "$d/$1"; return 0; }; done
  return 1
}
DOCK_JS=""       # JS literal: [[{id, path}...], ...]
DOCK_APPS=()     # id|path of every placed launcher (for the window rules)
parse_dock() {
  local raw item path groups="" cur="" first=1 items=()
  raw="$(conf dock launchers "")"
  app_dirs
  IFS=';' read -ra items <<< "$raw"
  items+=($'\x01')   # sentinel: closes the last group
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
    [ -z "$item" ] && continue
    if [ "$item" = "|" ] || [ "$item" = $'\x01' ]; then
      [ "$first" = 1 ] || groups+=","
      groups+="[${cur}]"; cur=""; first=0
      continue
    fi
    if [[ ! "$item" =~ ^[A-Za-z0-9._+-]+\.desktop$ ]]; then warn "dock: ignoring odd launcher name '$item'"; continue; fi
    if ! path="$(find_desktop "$item")"; then warn "dock: skipping $item (no .desktop file installed)"; continue; fi
    [ -n "$cur" ] && cur+=","
    cur+="{id: \"$item\", path: \"${path//\"/}\"}"
    DOCK_APPS+=("$item|$path")
  done
  DOCK_JS="[${groups}]"
}

# ---- remembered window position + size: one KWin rule per dock app ----
# A KWin rule remembers ONE geometry, so a catch-all rule would put every window where the last
# one closed. Per-app rules (exact app id / WM class, normal windows only: no dialogs, utility
# windows, plasmashell, krunner or spectacle) give each app its own memory.
apply_rules() {
  local entry id path cls name group want=() have_list keep=() r out
  for entry in "${DOCK_APPS[@]}"; do
    id="${entry%%|*}"; path="${entry#*|}"
    cls="$(sed -n 's/^StartupWMClass=//p' "$path" | head -1)"
    [ -n "$cls" ] || cls="${id%.desktop}"
    name="$(sed -n 's/^Name=//p' "$path" | head -1)"
    group="stagos-${id%.desktop}"
    want+=("$group")
    kw kwinrulesrc "$group" Description "StagOS: remember ${name:-$id} window"
    kw kwinrulesrc "$group" wmclass "(?i)^$(printf '%s' "$cls" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$"
    kw kwinrulesrc "$group" wmclassmatch 3
    kw kwinrulesrc "$group" wmclasscomplete false
    kw kwinrulesrc "$group" types 1
    kw kwinrulesrc "$group" positionrule 4
    kw kwinrulesrc "$group" sizerule 4
  done
  # rule list: keep Jack's own rules, replace the stagos-* ones
  have_list="$(kr kwinrulesrc General rules)"
  local IFS=,
  for r in $have_list; do [[ -n "$r" && "$r" != stagos-* ]] && keep+=("$r"); done
  unset IFS
  keep+=("${want[@]}")
  out="$(IFS=,; printf '%s' "${keep[*]}")"
  kw kwinrulesrc General rules "$out"
  kw kwinrulesrc General count "${#keep[@]}"
}

# ---- generated global-theme layout: header + dock.js + layout.js ----
js_header() {
  printf '// generated by stag-plasma-apply from ~/.config/stagos/desktop.conf; do not edit\n'
  printf 'var STAGOS_DOCK = %s;\n' "$DOCK_JS"
  printf 'var STAGOS_WALLPAPER = "file:///usr/share/stagos/stag-wall-stag.png";\n'
}
write_layout() {
  local tmp
  tmp="$(mktemp)"
  { js_header; cat "$SRC/dock.js" "$SRC/layout.js"; } > "$tmp"
  if [ -f "$LAYOUT_OUT" ] && cmp -s "$tmp" "$LAYOUT_OUT"; then rm -f "$tmp"; return 0; fi
  if [ "$dry" = 1 ]; then say "[dry] would write $LAYOUT_OUT"; rm -f "$tmp"; return 0; fi
  mkdir -p "$(dirname "$LAYOUT_OUT")"
  mv "$tmp" "$LAYOUT_OUT"; chmod 644 "$LAYOUT_OUT"
}

running() { have "$QDBUS" && "$QDBUS" "$1" "$2" >/dev/null 2>&1; }
shell_eval() { "$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "$1"; }
mark() { [ "$dry" = 1 ] || { mkdir -p "$STATE"; date -Is > "$1"; }; }

load_layout() {
  if [ "$dry" = 1 ]; then say "[dry] would load the StagOS layout (loadLookAndFeelDefaultLayout $LNF_ID)"; return 0; fi
  if "$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.loadLookAndFeelDefaultLayout "$LNF_ID" >/dev/null; then
    mark "$MARK"; say "layout: StagOS top bar + dock loaded"
  else
    warn "layout: plasmashell refused the StagOS layout (see journalctl --user -u plasma-plasmashell)"
  fi
}

apply_layout_and_dock() {
  if running org.kde.plasmashell /PlasmaShell; then
    local has
    if [ "$reset" = 1 ]; then load_layout; return; fi
    if [ ! -f "$MARK" ]; then
      has="$(shell_eval "$(js_header; cat "$SRC/dock.js"); stagosHasLayout();" 2>/dev/null)"
      if [[ "$has" == *"stagos-layout: yes"* ]]; then mark "$MARK"; say "layout: already StagOS (first start used the global theme)"
      else load_layout; fi
      return
    fi
    if [ "$dry" = 1 ]; then say "[dry] would sync the dock launchers"; return; fi
    out="$(shell_eval "$(js_header; cat "$SRC/dock.js"); stagosSyncDock(STAGOS_DOCK);" 2>&1)" || warn "dock: $out"
    [ -n "$out" ] && say "$out"
  else
    if [ "$reset" = 1 ]; then
      if [ -f "$APPLETSRC" ]; then
        if [ "$dry" = 1 ]; then say "[dry] would move $APPLETSRC aside"
        else mv "$APPLETSRC" "$APPLETSRC.stagos-bak-$(date +%Y%m%d-%H%M%S)"; fi
      fi
      [ "$dry" = 1 ] || rm -f "$MARK"
      say "layout: Plasma is not running; the StagOS layout is built at the next Plasma start"
    else
      say "Plasma is not running: config written, dock/layout left for the next Plasma login"
    fi
  fi
}

# ---- --session: first-login panel scale (STAGOS_OUTPUT_SCALE from desktop.env) ----
apply_scale() {
  [ -f "$SCALE_MARK" ] && return 0
  have kscreen-doctor || return 0
  local scale out
  scale="$(sed -n 's/^STAGOS_OUTPUT_SCALE=//p' "$CFG/stagos/desktop.env" 2>/dev/null | tail -1)"
  [[ "$scale" =~ ^[0-9]+([.][0-9]+)?$ ]] || scale=1.5
  out="$(kscreen-doctor -j 2>/dev/null | grep -o '"name": *"eDP[^"]*"' | head -1 | sed 's/.*"\(eDP[^"]*\)"$/\1/')"
  if [ -z "$out" ]; then say "scale: no internal eDP panel found, leaving output scale alone"; return 0; fi
  if [ "$dry" = 1 ]; then say "[dry] kscreen-doctor output.$out.scale.$scale"; return 0; fi
  if kscreen-doctor "output.$out.scale.$scale" >/dev/null 2>&1; then mark "$SCALE_MARK"; say "scale: $out at $scale"
  else warn "scale: kscreen-doctor could not set $out to $scale"; fi
}

if [ "$session" = 1 ]; then
  for _ in $(seq "$WAIT"); do running org.kde.plasmashell /PlasmaShell && break; sleep 1; done
fi

[ "$base" = 1 ] && apply_base
apply_effects
parse_dock
apply_rules
write_layout
if running org.kde.KWin /KWin; then
  [ "$dry" = 1 ] || "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || warn "KWin reconfigure failed"
else
  say "KWin is not running: effects and window rules load at the next Plasma login"
fi
[ "$session" = 1 ] && apply_scale
apply_layout_and_dock

changed="$(diff <(printf '%s\n' "$before") <(snap) | grep -c '^>')"
[ -n "${STAG_PLASMA_APPLY_COUNT_FILE:-}" ] && echo "$changed" > "$STAG_PLASMA_APPLY_COUNT_FILE"
say "done ($changed config file(s) changed)"
exit 0
