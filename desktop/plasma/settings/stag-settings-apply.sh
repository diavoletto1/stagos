#!/bin/bash
# Run by stagos-desktop-apply.service whenever the StagOS Settings app changed desktop.conf or asked for
# a layout reset. The QML app cannot run commands, so "Reset layout" drops a request file
# (~/.local/state/stagos/reset-layout.request) that this script consumes.
APPLY="${STAG_PLASMA_APPLY:-stag-plasma-apply}"
req="${XDG_STATE_HOME:-$HOME/.local/state}/stagos/reset-layout.request"
if [ -e "$req" ]; then
  rm -f "$req"
  exec "$APPLY" --quiet --reset-layout
fi
exec "$APPLY" --quiet
