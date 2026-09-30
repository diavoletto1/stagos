#!/bin/bash
# StagOS: lock the screen (swaylock + faillock PAM). Idempotent: does nothing if already locked.
pgrep -x swaylock >/dev/null && exit 0
exec swaylock -f
