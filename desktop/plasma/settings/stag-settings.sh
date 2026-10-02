#!/bin/bash
# StagOS Settings: a Kirigami QML app run by the Qt 6 `qml` runtime. Edits ~/.config/stagos/desktop.conf
# in place (every change saves at once; the stagos-desktop-apply path unit then runs stag-plasma-apply).
#   stag-settings [--page=bar|dock|look|session|recon|about]
#   stag-settings --print-context      print the JSON the app reads (paths, apps, wireless interfaces, version)
# Test hooks (passed through to the app): --selftest=ACTIONS  --shot=FILE  --context=FILE
# Env: STAGOS_SETTINGS_DIR (QML dir), STAGOS_DESKTOP_CONF, STAGOS_SETTINGS_ROOT (git checkout for the
# version, default /opt/stagos), STAGOS_PLASMA_DATA (desktop.conf.default), STAGOS_SESSION_BIN, QML_BIN.
set -uo pipefail

CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/stagos"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
QMLDIR="${STAGOS_SETTINGS_DIR:-$DATA/stagos/settings}"
[ -f "$QMLDIR/main.qml" ] || QMLDIR="$HERE"
CONF="${STAGOS_DESKTOP_CONF:-$CFG/stagos/desktop.conf}"
DEFAULTS="${STAGOS_PLASMA_DATA:-$DATA/stagos/plasma}/desktop.conf.default"
[ -f "$DEFAULTS" ] || DEFAULTS="$HERE/../desktop.conf.default"
ROOT="${STAGOS_SETTINGS_ROOT:-/opt/stagos}"
SESSION="${STAGOS_SESSION_BIN:-stag-session}"

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g'; }

apps_json() { # every launchable .desktop file: id, Name, Icon (user dir first, first id wins)
  local dirs=("$DATA/applications") d IFS=:
  for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs+=("$d/applications"); done
  dirs+=("$DATA/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications)
  unset IFS
  local files=()
  for d in "${dirs[@]}"; do compgen -G "$d/*.desktop" >/dev/null && files+=("$d"/*.desktop); done
  [ "${#files[@]}" -gt 0 ] || return 0
  # shellcheck disable=SC2016  # awk program
  awk '
      function esc(s) { gsub(/[\\"]/, "\\\\&", s); gsub(/\t/, " ", s); return s }
      function flush() {
        if (id != "" && !seen[id]++ && name != "" && nodisplay != "true" && hidden != "true" && type == "Application")
          lines[n++] = sprintf("{\"id\":\"%s\",\"name\":\"%s\",\"icon\":\"%s\"}", esc(id), esc(name), esc(icon))
      }
      FNR == 1 { flush(); f = FILENAME; sub(/.*\//, "", f); id = f; name = icon = nodisplay = hidden = type = ""; grp = "" }
      /^\[/ { grp = $0; next }
      grp != "[Desktop Entry]" { next }
      /^Name=/ && name == "" { name = substr($0, 6) }
      /^Icon=/ && icon == "" { icon = substr($0, 6) }
      /^NoDisplay=/ { nodisplay = substr($0, 11) }
      /^Hidden=/ { hidden = substr($0, 8) }
      /^Type=/ { type = substr($0, 6) }
      END { flush(); for (i = 0; i < n; i++) printf "%s%s", (i ? "," : ""), lines[i] }' "${files[@]}"
}

ifaces_json() {
  local d out="" n
  for d in /sys/class/net/*; do
    [ -e "$d/wireless" ] || [ -e "$d/phy80211" ] || continue
    n="$(basename "$d")"; out+="${out:+,}\"$(json "$n")\""
  done
  printf '%s' "$out"
}

context() {
  local version="unknown" readme="$ROOT/README.md"
  if [ -d "$ROOT/.git" ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    version="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)"
  fi
  [ -f "$readme" ] || readme="$ROOT/README.md (not installed)"
  # tty1 session state (stag-session --status): the Session page shows the crash fallback and can clear it
  local st next="plasma" fails=0
  if st="$("$SESSION" --status 2>/dev/null)"; then
    next="$(sed -n 's/^next=//p' <<< "$st")"; fails="$(sed -n 's/^fails=//p' <<< "$st")"
  fi
  [[ "$fails" =~ ^[0-9]+$ ]] || fails=0
  mkdir -p "$STATE" "$(dirname "$CONF")"
  printf '{"conf":"%s","defaults":"%s","request":"%s","apps":[%s],"ifaces":[%s],"version":"%s","host":"%s","readme":"%s",' \
    "$(json "$CONF")" "$(json "$DEFAULTS")" "$(json "$STATE/reset-layout.request")" "$(apps_json)" "$(ifaces_json)" \
    "$(json "$version")" "$(json "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)")" "$(json "$readme")"
  printf '"session_next":"%s","session_fails":%s,"session_fails_file":"%s"}\n' \
    "$(json "${next:-plasma}")" "$fails" "$(json "${XDG_CACHE_HOME:-$HOME/.cache}/stagos/session-plasma-fails")"
}

case "${1:-}" in
  --print-context) context; exit 0 ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \?//'; exit 0 ;;
esac

QML="${QML_BIN:-}"
[ -n "$QML" ] || for QML in qml6 qml /usr/lib/qt6/bin/qml; do command -v "$QML" >/dev/null 2>&1 && break; done
command -v "$QML" >/dev/null 2>&1 || { echo "stag-settings: the Qt 6 qml runtime is missing (pacman -S qt6-declarative kirigami)" >&2; exit 1; }

# a config file to start from (the app keeps the comments of whatever is there)
[ -f "$CONF" ] || { mkdir -p "$(dirname "$CONF")"; [ -f "$DEFAULTS" ] && cp "$DEFAULTS" "$CONF"; }

ctxfile="${STAGOS_SETTINGS_CONTEXT:-}"
if [ -z "$ctxfile" ]; then
  ctxdir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/stag-settings.XXXXXX")" || exit 1
  trap 'rm -rf "$ctxdir"' EXIT
  ctxfile="$ctxdir/context.json"
  context > "$ctxfile"
fi

# The qml runtime has no file API; XMLHttpRequest may read and write local files only with these set.
export QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1
# HUD look: the StagOS color scheme comes from kdeglobals (plasma-integration) outside Plasma too
if [ -z "${QT_QUICK_CONTROLS_STYLE:-}" ] && [ -d /usr/lib/qt6/qml/org/kde/desktop ]; then export QT_QUICK_CONTROLS_STYLE=org.kde.desktop; fi
if [ -z "${QT_QPA_PLATFORMTHEME:-}" ] && [ -e /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so ]; then
  export QT_QPA_PLATFORMTHEME=kde
fi
export KDE_KIRIGAMI_FORMS_STYLE=flat QT_FORCE_STDERR_LOGGING=1   # console.log and QML warnings on stderr, also without a tty

"$QML" "$QMLDIR/main.qml" -- --context="$ctxfile" "$@"
