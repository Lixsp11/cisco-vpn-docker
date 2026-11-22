#!/bin/bash
# Firewall rules of the container, in the container's own network namespace:
#   - the VPN side cannot open TCP connections to the container: new TCP connections that come in through
#     the tunnel are dropped, after packets of established connections are accepted;
#   - route mode: the container forwards packets from the local network to the tunnel and the replies back,
#     and masquerades what leaves through the tunnel.
# The VPN client adds chains of its own when it connects and jumps to them from INPUT and FORWARD, and it may
# rebuild them on every connect, so each chain here starts with these rules, before the client's.
#
# Usage: firewall.sh apply   put the rules first in their chains; changes nothing when they already are
#        firewall.sh watch   apply every 5 seconds; logs only when it changes a chain or starts failing
# Environment:
#   VPN_TUN  the VPN client's tunnel interface (required; start.sh exports it)
#   LAN_IF   the interface to the local network (default eth0)

if [ -z "${VPN_TUN:-}" ]; then
    echo "error: VPN_TUN is not set; it must name the VPN client's tunnel interface" >&2
    exit 1
fi
LAN_IF=${LAN_IF:-eth0}

# Each rule is written exactly as iptables -S prints it: put_first compares that output with these strings.
#
# INPUT, as in docker-easyconnect's config_vpn_iptables (docker-root/usr/local/bin/start.sh), with the conntrack
# match in place of the older state match: accept packets of established connections, then drop new TCP
# connections from the tunnel. The Cisco client's own chain returns packets from the tunnel interface, which
# INPUT then accepts.
INPUT_RULES=(
    "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    "-i $VPN_TUN -p tcp -j DROP"
)
# FORWARD, for route mode: accept packets from the local network to the tunnel, and the replies.
# The Cisco client's chains, which FORWARD jumps to, drop forwarded packets whose source is not the tunnel's
# address (seen with a real connection), so these accept rules go before the client's rules, as in
# https://forums.docker.com/t/docker-desktop-windows-and-vpn-no-network-connection-inside-container/91234
FORWARD_RULES=(
    "-i $LAN_IF -o $VPN_TUN -j ACCEPT"
    "-i $VPN_TUN -o $LAN_IF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
)
# nat POSTROUTING, as in docker-easyconnect's config_vpn_iptables: forwarded packets leave through the tunnel
# with the tunnel's address
POSTROUTING_RULES=(
    "-o $VPN_TUN -j MASQUERADE"
)

# Make the rules $3... the first rules of chain $2 in table $1, in this order, unless they already are.
# Otherwise one copy of each rule that the chain holds is deleted and the rules are inserted at the top, in one
# iptables-restore transaction, so the chain is never without them. The chain's other rules keep their order.
# Prints a line when it changes the chain; fails when iptables does.
put_first() {
    local table=$1 chain=$2 rule expected first i=0
    shift 2
    expected=$(printf -- "-A $chain %s\n" "$@")
    # iptables prints warnings, such as one about tables of the legacy backend, on stderr
    first=$(iptables -t "$table" -S "$chain" 2>/dev/null | grep -- '^-A ' | head -n "$#")
    [ "$first" = "$expected" ] && return 0
    {
        echo "*$table"
        for rule; do
            # The rules hold no quoted words, so splitting them into words gives iptables its arguments
            # shellcheck disable=SC2086
            if iptables -t "$table" -C "$chain" $rule 2>/dev/null; then
                echo "-D $chain $rule"
            fi
        done
        for rule; do
            i=$((i + 1))
            echo "-I $chain $i $rule"
        done
        echo COMMIT
    } | iptables-restore --noflush || return
    echo "put the rules first in the $chain chain of the $table table"
}

apply_rules() {
    local status=0
    put_first filter INPUT "${INPUT_RULES[@]}" || status=1
    put_first filter FORWARD "${FORWARD_RULES[@]}" || status=1
    put_first nat POSTROUTING "${POSTROUTING_RULES[@]}" || status=1
    return "$status"
}

# Apply the rules every 5 seconds. Prints what apply_rules prints when it succeeds, which is nothing while the
# rules are first. When it fails, prints its errors once, and nothing more until it succeeds again.
watch_rules() {
    local output failing=
    while true; do
        sleep 5
        if output=$(apply_rules 2>&1); then
            failing=
        elif [ -n "$failing" ]; then
            continue
        else
            failing=1
            output+=$'\n'"error: cannot put the rules first; trying again every 5 seconds"
        fi
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
        fi
    done
}

case ${1:-} in
    apply) apply_rules ;;
    watch) watch_rules ;;
    *)
        echo "usage: $0 apply|watch" >&2
        exit 2
        ;;
esac
