#!/bin/bash
# StagOS: start kismet if it isn't running, then open its web UI (localhost:2501).
# Logs land in ~/.kismet/logs. Sources come from kismet's own config / the web UI.
if ! pgrep -x kismet >/dev/null; then
  mkdir -p "$HOME/.kismet/logs"
  (cd "$HOME/.kismet/logs" && setsid -f kismet --no-ncurses >"$HOME/.kismet/kismet.out" 2>&1 </dev/null)
  for _ in $(seq 30); do
    (exec 3<>/dev/tcp/127.0.0.1/2501) 2>/dev/null && break
    sleep 0.5
  done
fi
exec firefox --new-window http://localhost:2501
