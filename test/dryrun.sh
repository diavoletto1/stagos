#!/usr/bin/env bash
# Dry-run harness: lint everything, then walk both layers with DRY_RUN=1.
# Second provision pass mocks a monitor-capable card to exercise the gated path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== shellcheck =="
mapfile -t files < <(find . -name '*.sh' -o -name '*.conf' | sort)
shellcheck -x -s bash "${files[@]}" && echo "shellcheck clean"

echo; echo "== install.sh (dry) =="
DRY_RUN=1 ASSUME_YES=1 ./install.sh

echo; echo "== provision.sh (dry, no card) =="
DRY_RUN=1 ./provision.sh

echo; echo "== provision.sh (dry, mock card wlan1) =="
DRY_RUN=1 STAGOS_MOCK_WIFI=wlan1 ./provision.sh
