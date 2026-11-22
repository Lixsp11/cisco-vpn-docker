#!/bin/bash
# Print the state of the Cisco client, tunnel, routing, firewall, DNS and resources in one go.
# A failing command does not stop the script.

exec 2>&1
CSC_DIR=/opt/cisco/secureclient

section() {
    printf '\n===== %s =====\n' "$1"
}

section "Cisco version"
dpkg-query -W -f='${Package} ${Version}\n' cisco-secure-client-vpn

section "vpn state"
timeout 15 "$CSC_DIR/bin/vpn" state

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

section "Related processes (RSS in KB)"
ps -eo pid,rss,args | head -n 1
ps -eo pid,rss,args | grep -E 'vpn|Xtiger|websockify|microsocks|tinyproxy|flwm' | grep -vE 'grep|sed -u'

section "Memory (free -m)"
free -m

section "Files under $CSC_DIR newer than /etc/hostname (modified after the container was created or started)"
find "$CSC_DIR" -newer /etc/hostname -type f -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' | sort
