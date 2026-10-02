#!/usr/bin/env bash
# Behaviour test for desktop/firewall/nftables.conf in a throwaway user+network namespace (no root, nothing on the
# host changes): load the ruleset, then probe it from a peer namespace over veth pairs. Checks that inbound is denied
# on an ordinary interface, allowed on one named tailscale0, that pings, the KDE Connect drop-in ports and UDP 41641
# work, that replies to our own outbound connections come back, and that a reload is clean.
# Skips (exit 0) where unprivileged namespaces are unavailable. Run: ./test/firewall-netns.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
if [[ -z "${FWNS_INNER:-}" ]]; then
  for tool in unshare nsenter nft ip python3; do command -v "$tool" >/dev/null || { echo "skip: $tool missing"; exit 0; }; done
  unshare -Urnm true 2>/dev/null || { echo "skip: unprivileged namespaces unavailable"; exit 0; }
  FWNS_INNER=1 exec unshare -Urnm bash "$0"
fi

T="$(mktemp -d)"
pids=()
cleanup() { local p; for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   $n"; else fail=$((fail+1)); echo "FAIL $n"; fi; }

# ruleset with the drop-in dir pointed at a temp dir holding the KDE Connect fixture
mkdir -p "$T/nftables.d"; cp test/fixtures/nftables.d/*.nft "$T/nftables.d/"
sed "s|/etc/nftables.d|$T/nftables.d|" desktop/firewall/nftables.conf > "$T/nftables.conf"

# peer namespace and two veth pairs: eth9 (ordinary) and tailscale0 (trusted by name)
unshare -n sleep 600 & peer=$!; pids+=("$peer"); sleep 0.3
ip link set lo up
ip link add eth9 type veth peer name p9
ip link add tailscale0 type veth peer name pts
ip link set p9 netns "$peer"; ip link set pts netns "$peer"
ip addr add 10.9.0.1/24 dev eth9; ip addr add 10.8.0.1/24 dev tailscale0
ip link set eth9 up; ip link set tailscale0 up
P() { nsenter -t "$peer" -n "$@"; }
P ip link set lo up; P ip addr add 10.9.0.2/24 dev p9; P ip addr add 10.8.0.2/24 dev pts; P ip link set p9 up; P ip link set pts up

check "ruleset loads" nft -f "$T/nftables.conf"
check "ruleset reloads cleanly, one table" bash -c "nft -f '$T/nftables.conf' && test \$(nft list tables | grep -c 'inet stagos') -eq 1"

# listeners on the host side: tcp 8080 (not allowed), tcp 1714 (drop-in), udp echo on 41641 (allowed) and 41642 (not)
serve() { python3 -c "
import socket, sys
proto, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
if proto == 'tcp':
    s.listen(5)
    while True:
        c, _ = s.accept(); c.sendall(b'hi'); c.close()
else:
    while True:
        d, a = s.recvfrom(64); s.sendto(d, a)
" "$@" & pids+=("$!"); }
serve tcp 8080; serve tcp 1714; serve udp 41641; serve udp 41642
sleep 0.5
probe() { P python3 -c "
import socket, sys
proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM)
s.settimeout(1)
if proto == 'tcp':
    s.connect((host, port)); assert s.recv(2) == b'hi'
else:
    s.sendto(b'x', (host, port)); assert s.recv(2) == b'x'
" "$@"; }

if probe tcp 10.9.0.1 8080 2>/dev/null; then fail=$((fail+1)); echo "FAIL ordinary interface: tcp 8080 is dropped"; else pass=$((pass+1)); echo "ok   ordinary interface: tcp 8080 is dropped"; fi
if probe tcp 10.8.0.1 8080 2>/dev/null; then pass=$((pass+1)); echo "ok   tailscale0: tcp 8080 is allowed (everything on it)"; else fail=$((fail+1)); echo "FAIL tailscale0: tcp 8080 is allowed"; fi
if probe tcp 10.9.0.1 1714 2>/dev/null; then pass=$((pass+1)); echo "ok   drop-in: tcp 1714 reachable on the ordinary interface"; else fail=$((fail+1)); echo "FAIL drop-in: tcp 1714"; fi
if probe udp 10.9.0.1 41641 2>/dev/null; then pass=$((pass+1)); echo "ok   udp 41641 (tailscaled direct) reachable"; else fail=$((fail+1)); echo "FAIL udp 41641"; fi
if probe udp 10.9.0.1 41642 2>/dev/null; then fail=$((fail+1)); echo "FAIL udp 41642 is dropped"; else pass=$((pass+1)); echo "ok   udp 41642 is dropped"; fi
check "ping from the ordinary interface is answered" P ping -c1 -W2 10.9.0.1
# outbound open, and the reply to it comes back through the deny policy
P python3 -c "
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', 9090)); s.listen(1)
c, _ = s.accept(); c.sendall(b'hi'); c.close()
" & pids+=("$!"); sleep 0.5
check "outbound connection works and its replies are accepted" python3 -c "
import socket
s = socket.socket(); s.settimeout(2); s.connect(('10.9.0.2', 9090)); assert s.recv(2) == b'hi'"
check "stag-fw-style off: deleting the table opens everything, reloading closes it" bash -c "
  nft delete table inet stagos && ! nft list table inet stagos && nft -f '$T/nftables.conf' && nft list table inet stagos"

echo; echo "firewall-netns: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
