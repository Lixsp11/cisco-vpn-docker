#!/bin/bash
# Print the state of the VPN client, tunnel, routing, firewall, DNS and resources in one go.
# The client's part comes from vpn_diag in the client steps vpn-<client>.sh of the client that the build wrote to
# /etc/vpn-type, as in start.sh. A failing command does not stop the script.

exec 2>&1

section() {
    printf '\n===== %s =====\n' "$1"
}

# Print the processes whose command line matches the extended regular expression $1, with ps's header line
show_processes() {
    ps -eo pid,rss,args | head -n 1
    # Filter ps output rather than use pgrep, which cannot print the RSS column
    # shellcheck disable=SC2009
    ps -eo pid,rss,args | grep -E "$1" | grep -vE 'grep|sed -u'
}

VPN_TYPE=$(cat /etc/vpn-type)
# shellcheck source=/dev/null
if source "/usr/local/bin/vpn-$VPN_TYPE.sh"; then
    vpn_diag
else
    section "VPN client"
    echo "cannot load the steps of the VPN client '$VPN_TYPE' that /etc/vpn-type names"
fi

section "Interfaces (ip -br addr)"
ip -br addr

section "Routes (ip route show table all, without local/broadcast)"
ip route show table all | grep -vE '^(local|broadcast) '

section "Policy routing (ip rule)"
ip rule

section "iptables-save ($(iptables -V))"
iptables-save

section "ip6tables-save"
if command -v ip6tables-save >/dev/null; then
    ip6tables-save
else
    echo "ip6tables-save not found"
fi

section "iptables-legacy-save (rules on the legacy backend)"
if command -v iptables-legacy-save >/dev/null; then
    iptables-legacy-save
else
    echo "iptables-legacy-save not found"
fi

section "nft list ruleset"
if command -v nft >/dev/null; then
    nft list ruleset
else
    echo "nft not found"
fi

section "/etc/resolv.conf"
cat /etc/resolv.conf
echo "--- mounts ---"
mount | grep resolv

section "/dev/net/tun"
ls -l /dev/net/tun

section "Other related processes (RSS in KB)"
show_processes 'Xtiger|websockify|danted|tinyproxy|flwm'

section "Memory (free -m)"
free -m
