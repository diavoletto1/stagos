#!/usr/bin/env bash
# Firewall: nftables, default deny inbound, outbound open (ruleset: desktop/firewall/nftables.conf).
# Allowed in: established/related, loopback, everything on tailscale0 (Tailscale SSH), ICMP basics, DHCP replies,
# mDNS, tailscaled's UDP 41641, libvirt's bridge. Drop-ins in /etc/nftables.d/*.nft (module link installs the
# KDE Connect one) are included inside the input chain. Only table inet stagos is managed, never "flush ruleset".
# stag-fw (status | off-for 10m | on | check) is the debugging switch.
# ufw and firewalld are not used; if either is installed the module refuses to enable nftables next to it.
stagos_dm_firewall() {
  dm_pkgs nftables
  local conf=/etc/nftables.conf src="$HERE/desktop/firewall/nftables.conf" before=$DM_CHANGED
  # keep the package's stock file once, the first time we replace it
  if ! dm_dry && [[ -f "$conf" ]] && ! cmp -s "$src" "$conf" && [[ ! -e "$conf.stagos-orig" ]]; then
    run sudo cp -p "$conf" "$conf.stagos-orig"
  fi
  run sudo install -dm755 /etc/nftables.d
  dm_install "$src" "$conf" 644 sudo
  dm_bins stag-fw

  if ! dm_dry; then
    local out
    if ! out="$(sudo nft -c -f "$conf" 2>&1)"; then
      if [[ "$out" == *"Operation not permitted"* ]]; then
        dm_note "firewall: nft -c needs CAP_NET_ADMIN, so $conf was not syntax-checked here (run: stag-fw check)"
      else
        printf '%s\n' "$out" >&2
        die "firewall: $conf does not parse; not enabling it"
      fi
    fi
  fi

  local other
  for other in ufw firewalld; do
    if systemctl is-enabled --quiet "$other.service" 2>/dev/null; then
      warn "$other is enabled; not enabling nftables next to it (disable $other first, then rerun)"
      return 0
    fi
  done
  dm_enable_system nftables.service
  # apply a changed ruleset to the running firewall without flushing other tables
  if [[ $DM_CHANGED -gt $before ]] && dm_have_systemd && ! dm_dry; then
    sudo nft -f "$conf" || warn "could not load $conf; run: stag-fw check"
  fi
  ok "firewall ready (stag-fw status)"
}
