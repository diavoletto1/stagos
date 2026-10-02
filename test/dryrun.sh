#!/usr/bin/env bash
# Dry-run harness: lint everything, then walk both layers with DRY_RUN=1.
# Second provision pass mocks a monitor-capable card to exercise the gated path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== shellcheck =="
mapfile -t files < <(find . -name '*.sh' -o -path './config/*.conf' | sort)
shellcheck -x -s bash "${files[@]}"
echo "shellcheck clean"

echo; echo "== xmllint =="
mapfile -t xml < <(find . -name '*.xml' -not -path './.git/*' | sort)
xmllint --noout "${xml[@]}" desktop/fontconfig/fonts.conf
echo "xml clean"

echo; echo "== install.sh (dry) =="
if [[ -n "${CI:-}" && ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "skipped: install.sh needs root (CI=${CI})"
else
  DRY_RUN=1 ASSUME_YES=1 ./install.sh
fi

echo; echo "== provision.sh (dry, no card) =="
DRY_RUN=1 ./provision.sh

echo; echo "== provision.sh (dry, mock card wlan1) =="
DRY_RUN=1 STAGOS_MOCK_WIFI=wlan1 STAGOS_CAPTURE_IFACE=wlan1 ./provision.sh

echo; echo "== stagos-desktop (dry, all modules) =="
DRY_RUN=1 ./stagos-desktop

echo; echo "== desktop helper unit tests =="
./test/desktop-scripts.sh

echo; echo "== stag-ctl / stag-status / plasmoid unit tests =="
./test/stag-widgets.sh

echo; echo "== stag-field (field mode) + sync contract =="
./test/field.sh

echo; echo "== Plasma: stag-plasma-apply, tty1 session, StagOS Settings (app tests need qml: container) =="
./test/plasma-apply.sh
./test/plasma-session.sh
./test/plasma-settings.sh

echo; echo "== keyd per-app keys under Plasma (module side and config invariants; KWin end to end: test/keyd-apps-container.sh) =="
./test/keyd-apps.sh

echo; echo "== safety net: stag-backup, stag-update, stag-battery and their modules (fakes) =="
./test/safety.sh

echo; echo "== labwc-era cleanup (stagos-desktop cleanup-labwc, fakes) =="
./test/labwc-cleanup.sh
