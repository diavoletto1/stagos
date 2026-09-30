#!/usr/bin/env bash
# Keyring: gnome-keyring + seahorse. Autologin after LUKS means PAM never sees a password, so a
# normal (password-protected) login keyring can never unlock and every app asks each session.
# With STAGOS_KEYRING_EMPTY=1 we create the default "login" keyring with an EMPTY password: it opens
# silently; secrets are protected at rest by LUKS only, and not from anything running as you.
# Off by default: it is a security tradeoff for Jack to confirm. Never overwrites an existing keyring.
stagos_dm_keyring() {
  dm_pkgs gnome-keyring seahorse libsecret
  dm_enable_user gnome-keyring-daemon.socket
  local dir="$HOME/.local/share/keyrings"
  if [[ "${STAGOS_KEYRING_EMPTY:-0}" != "1" ]]; then
    log "STAGOS_KEYRING_EMPTY=0: keyring keeps its own password (prompts once per session under autologin)"
    dm_note "keyring: decide STAGOS_KEYRING_EMPTY=1 (silent) or 0 (prompt); see README"
    return 0
  fi
  if [[ -e "$dir/login.keyring" || -e "$dir/default" ]]; then
    warn "a keyring already exists in $dir; leaving it alone (delete it in seahorse to switch to the empty-password one)"
    return 0
  fi
  if dm_dry; then log "[dry] would create empty-password login keyring in $dir"; return 0; fi
  mkdir -p "$dir"; chmod 700 "$dir"
  printf 'login\n' > "$dir/default"
  cat > "$dir/login.keyring" <<'KR'
[keyring]
display-name=Login
ctime=0
mtime=0
lock-on-idle=false
lock-after=false
KR
  chmod 600 "$dir/login.keyring"
  DM_CHANGED=$((DM_CHANGED + 1))
  ok "empty-password login keyring created (LUKS protects it at rest)"
}
