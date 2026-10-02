#!/usr/bin/env bash
# Lab: stagpad as a stag-lab node. stag-lab has no node agent: its web terminal is the server (stagmini,
# user staglab) opening SSH to the node over the tailnet with its own key per host (paramiko, pinned host
# key, an interactive login shell, nothing else). So the node side is only:
#  - sshd, key only (no passwords, no root, no forwarding), via /etc/ssh/sshd_config.d/50-stagos-lab.conf,
#    on STAGOS_LAB_SSH_PORT (default 22). With Tailscale SSH on (tailscale set --ssh), tailscaled answers port 22
#    on the tailnet address itself, so sshd needs another port there (e.g. 2222, and port: 2222 in hosts.yaml)
#  - stag-lab's public key for this host in ~/.ssh/authorized_keys, limited to stagmini's address
#    (STAGOS_LAB_SSH_PUBKEY, STAGOS_LAB_SSH_FROM in config/local.conf; one managed line, marked stagos-lab)
#  - optional metrics for the stag-lab monitor tile: prometheus-node-exporter (STAGOS_LAB_METRICS=1)
# The server side (hosts.yaml entry, pinned host key, Prometheus target) is Jack's; see the README.
# Without STAGOS_LAB_SSH_PUBKEY nothing is opened: no sshd is installed or enabled.
stagos_dm_lab() {
  local key="${STAGOS_LAB_SSH_PUBKEY:-}" from="${STAGOS_LAB_SSH_FROM:-}" port="${STAGOS_LAB_SSH_PORT:-22}"
  if [[ -z "$key" ]]; then
    warn "lab: STAGOS_LAB_SSH_PUBKEY not set in config/local.conf: no sshd for the stag-lab terminal"
  elif ! [[ "$key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]]; then
    warn "lab: STAGOS_LAB_SSH_PUBKEY is not an OpenSSH public key line: skipped"
  elif ! [[ "$from" =~ ^[0-9A-Fa-f.:/,]+$ ]]; then
    warn "lab: STAGOS_LAB_SSH_FROM must be stagmini's tailnet address(es) (comma separated, CIDR ok): skipped"
  elif ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    warn "lab: STAGOS_LAB_SSH_PORT must be a port number: skipped"
  else
    if [[ "$port" == 22 ]] && have tailscale && tailscale debug prefs 2>/dev/null | grep -q '"RunSSH": *true'; then
      dm_note "lab: Tailscale SSH is on, so tailscaled (not sshd) answers port 22 on the tailnet: set STAGOS_LAB_SSH_PORT=2222 and port: 2222 for stag-pad in stag-lab's hosts.yaml"
    fi
    stagos_lab_sshd "$port"
    stagos_lab_authorized_key "$key" "$from"
  fi
  if [[ "${STAGOS_LAB_METRICS:-0}" == 1 ]]; then
    dm_pkgs prometheus-node-exporter
    dm_enable_system prometheus-node-exporter.service
    dm_note "lab: node exporter on :9100; the firewall must only allow it on tailscale0"
  fi
}

stagos_lab_sshd() {
  dm_pkgs openssh
  local before="$DM_CHANGED"
  dm_write /etc/ssh/sshd_config.d/50-stagos-lab.conf 644 sudo <<CONF
# StagOS (module lab): sshd for the stag-lab web terminal. Keys only, no root, no forwarding.
# Reached over the tailnet; the authorized_keys line itself is limited to stagmini (from=...).
Port $1
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
CONF
  if dm_dry; then run sudo systemctl enable --now sshd.service; return 0; fi
  if ! grep -qs '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
    warn "lab: /etc/ssh/sshd_config does not include sshd_config.d/*.conf; the hardening drop-in is not read"
  fi
  if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 && ! sudo sshd -t; then
    warn "lab: sshd -t rejects the config, sshd left as it was"; return 0
  fi
  dm_enable_system sshd.service
  if [[ "$DM_CHANGED" != "$before" ]] && dm_have_systemd; then
    sudo systemctl reload sshd.service 2>/dev/null || true
  fi
}

# stagos_lab_authorized_key KEY FROM: exactly one line marked stagos-lab in ~/.ssh/authorized_keys
stagos_lab_authorized_key() {
  local f="$HOME/.ssh/authorized_keys" kt kb line tmp
  read -r kt kb _ <<< "$1"
  line="from=\"$2\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc $kt $kb stagos-lab"
  if dm_dry; then log "[dry] would put the stag-lab key in $f"; return 0; fi
  tmp="$(mktemp)"
  if [[ -f "$f" ]]; then grep -v ' stagos-lab$' "$f" > "$tmp" || true; fi
  printf '%s\n' "$line" >> "$tmp"
  [[ -d "$HOME/.ssh" ]] || install -d -m 700 "$HOME/.ssh"
  [[ "$(stat -c %a "$HOME/.ssh")" == 700 ]] || { chmod 700 "$HOME/.ssh"; DM_CHANGED=$((DM_CHANGED + 1)); }
  dm_install "$tmp" "$f" 600
  rm -f "$tmp"
}
