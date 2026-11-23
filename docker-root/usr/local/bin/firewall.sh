#!/bin/bash
# Firewall rules of the container, in the container's own network namespace:
#   - the VPN side cannot open TCP connections to the container: new TCP connections that come in through
#     the tunnel are dropped, after packets of established connections are accepted;
#   - the services stay reachable from the local network: new TCP connections that come in through the local
#     network's interface to the service ports are accepted, and so is what leaves from these ports through it;
#   - route mode: the container forwards packets from the local network to the tunnel and the replies back,
#     and masquerades what leaves through the tunnel.
# The VPN client adds chains of its own when it connects and jumps to them from INPUT, OUTPUT and FORWARD, and it may
# rebuild them on every connect, so each chain here starts with these rules, before the client's.
#
# Usage: firewall.sh apply   put the rules first in their chains; changes nothing when they already are
#        firewall.sh watch   apply every 5 seconds; logs only when it changes a chain or starts failing
# Environment:
#   VPN_TUN        the VPN client's tunnel interface (required; start.sh exports it)
#   SERVICE_PORTS  the TCP ports of the container's services, separated by spaces (required; start.sh exports it)
#   LAN_IF         the interface to the local network (default eth0)

if [ -z "${VPN_TUN:-}" ]; then
    echo "error: VPN_TUN is not set; it must name the VPN client's tunnel interface" >&2
    exit 1
fi
if [ -z "${SERVICE_PORTS:-}" ]; then
    echo "error: SERVICE_PORTS is not set; it must list the TCP ports of the container's services" >&2
    exit 1
fi
LAN_IF=${LAN_IF:-eth0}
# The service ports as the multiport match lists them
SERVICE_PORT_LIST=${SERVICE_PORTS// /,}

# Comment match that marks the rules of this script. Only marked rules are ever deleted or moved. iptables
# compares the comment when it looks for a rule, so a rule of another owner that is otherwise identical to one
# of these is never taken for it.
MARK="-m comment --comment cisco-vpn-docker"

# Each rule is written exactly as iptables -S prints it: put_first compares that output with these strings.
#
# INPUT, as in docker-easyconnect's config_vpn_iptables (docker-root/usr/local/bin/start.sh), with the conntrack
# match in place of the older state match: accept packets of established connections, then drop new TCP
# connections from the tunnel. The Cisco client's own chain returns packets from the tunnel interface, which
# INPUT then accepts.
# In between, accept new TCP connections from the local network to the service ports. Once connected, the Cisco
# client's chains, which INPUT and OUTPUT jump to, let through the tunnel, the local network's addresses and the
# gateway and drop the rest (seen with a real connection), so a client outside the Docker host could not connect to a
# port that the host publishes on all its addresses. This rule and the OUTPUT rule let such clients through; start.sh's
# route_replies routes the replies back through the local network, as docker-easyconnect's detect-route.sh does.
INPUT_RULES=(
    "-m conntrack --ctstate RELATED,ESTABLISHED $MARK -j ACCEPT"
    "-i $LAN_IF -p tcp -m multiport --dports $SERVICE_PORT_LIST -m conntrack --ctstate NEW $MARK -j ACCEPT"
    "-i $VPN_TUN -p tcp $MARK -j DROP"
)
# OUTPUT: accept what the services send from their ports to the local network, the replies to the clients above
OUTPUT_RULES=(
    "-o $LAN_IF -p tcp -m multiport --sports $SERVICE_PORT_LIST $MARK -j ACCEPT"
)
# FORWARD, for route mode: accept packets from the local network to the tunnel, and the replies.
# The Cisco client's chains, which FORWARD jumps to, drop forwarded packets whose source is not the tunnel's
# address (seen with a real connection), so these accept rules go before the client's rules, as in
# https://forums.docker.com/t/docker-desktop-windows-and-vpn-no-network-connection-inside-container/91234
FORWARD_RULES=(
    "-i $LAN_IF -o $VPN_TUN $MARK -j ACCEPT"
    "-i $VPN_TUN -o $LAN_IF -m conntrack --ctstate RELATED,ESTABLISHED $MARK -j ACCEPT"
)
# nat POSTROUTING, as in docker-easyconnect's config_vpn_iptables: forwarded packets leave through the tunnel
# with the tunnel's address
POSTROUTING_RULES=(
    "-o $VPN_TUN $MARK -j MASQUERADE"
)

# Make the rules $3... the first rules of chain $2 in table $1, in this order, and the chain's only marked
# rules, unless they already are. A repair deletes every marked rule of the chain and inserts the rules at the
# top, in one iptables-restore transaction, so the chain is never without them and no unmarked rule is deleted
# or moved. If the chain changes between reading it and the transaction so that a marked rule to delete is gone,
# the whole transaction fails; the repair then reads the chain again, up to 3 times.
# Prints a line when it changes the chain. Fails, printing iptables' errors, when it cannot read the chain or
# its last transaction fails. -w 5 waits up to 5 seconds for the xtables lock, which only the legacy backend takes.
put_first() {
    local table=$1 chain=$2 expected current marked changes errors rule i _
    shift 2
    expected=$(printf -- "-A $chain %s\n" "$@")
    for _ in 1 2 3; do
        # A chain that cannot be read is an error, never an empty chain. A warning in the output, such as one
        # about tables of the legacy backend, is not a rule line, so the comparisons below ignore it.
        if ! current=$(iptables -w 5 -t "$table" -S "$chain" 2>&1); then
            printf '%s\n' "$current" >&2
            return 1
        fi
        marked=$(grep -F -- " $MARK " <<<"$current")
        if [ "$marked" = "$expected" ] && [ "$(grep -- '^-A ' <<<"$current" | head -n "$#")" = "$expected" ]; then
            return 0
        fi
        changes="*$table"$'\n'
        if [ -n "$marked" ]; then
            while read -r rule; do
                changes+="-D ${rule#-A }"$'\n'
            done <<<"$marked"
        fi
        i=0
        for rule; do
            i=$((i + 1))
            changes+="-I $chain $i $rule"$'\n'
        done
        changes+=COMMIT
        if errors=$(iptables-restore -w 5 --noflush <<<"$changes" 2>&1); then
            echo "put the rules first in the $chain chain of the $table table"
            return 0
        fi
    done
    printf '%s\n' "$errors" >&2
    return 1
}

apply_rules() {
    local status=0
    put_first filter INPUT "${INPUT_RULES[@]}" || status=1
    put_first filter OUTPUT "${OUTPUT_RULES[@]}" || status=1
    put_first filter FORWARD "${FORWARD_RULES[@]}" || status=1
    put_first nat POSTROUTING "${POSTROUTING_RULES[@]}" || status=1
    return "$status"
}

# Apply the rules every 5 seconds. Each repair is printed when it happens, and nothing while the rules are first.
# Errors are printed when a run of failures starts, and not again until an apply succeeds.
watch_rules() {
    local errors failing=
    while true; do
        sleep 5
        # The repair lines go to the output through fd 3; the errors are kept in $errors
        if errors=$(apply_rules 2>&1 >&3); then
            failing=
        elif [ -z "$failing" ]; then
            failing=1
            printf '%s\n' "$errors" "error: cannot put the rules first; trying again every 5 seconds"
        fi
    done 3>&1
}

case ${1:-} in
    apply) apply_rules ;;
    watch) watch_rules ;;
    *)
        echo "usage: $0 apply|watch" >&2
        exit 2
        ;;
esac
