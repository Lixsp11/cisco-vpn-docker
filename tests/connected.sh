#!/bin/bash
# Acceptance checks with a real VPN connection. Run as root on the Docker host while the cisco-vpn container runs,
# after logging in to the VPN in the Cisco window through noVNC.
#
# Checks that the Cisco client is connected through a tunnel interface of its own, not the temporary one that
# start.sh creates for danted; that the client's ciscovpn* chains exist and the firewall's rules are still the
# first rules of INPUT, OUTPUT, FORWARD and nat POSTROUTING and stay first without repairs; that forwarding is still
# on; that routing table 2 and the policy rules that route the service ports' replies by it are still in place;
# that vpnui reads LocalLanAccess: true and the gateway grants local LAN access; that noVNC is still reachable;
# and that the SOCKS5 and HTTP proxies leave through the VPN: an IP echo service sees the same IPv4 address
# through both, and another one for a direct request from the host.
# Route mode: adds a host route for one IPv4 address of the echo service through the container, with the tunnel's
# MTU, as docs/usage.md describes, checks that a request to that address arrives with the proxies' address, and
# deletes the route. The route is added only when the VPN is connected, the proxies leave through it, the host's
# state was recorded and the host has no route to that address yet. The script deletes only a route that its own
# add created, also from a trap when it ends early, after a signal or a write to a closed output. The route is the
# only change to the host: the host's routes, iptables rules and resolv.conf are recorded at the start and
# compared at the end.
# Finally it reports, without checking, what the persistence acceptance needs to know: the gateway address that
# the data directory holds and the files in it that changed since the container started, and also the
# firewall's log lines since then.
#
# Environment:
#   ECHO_URL      https URL, without a port, that answers with the client's IP address as plain text
#                 (default https://ifconfig.me/ip)
#   SOCKS5_PROXY  SOCKS5 proxy URL, with the username and password when the proxy requires them
#                 (default socks5h://127.0.0.1:1080)
#   GATEWAY       VPN gateway address; when set, the report lists the files in the data directory that contain it
# Exits 0 when every check passes, 1 otherwise, and 2 when it cannot run. Sourcing the script defines its
# functions without running the checks.

# lib.sh is linted on its own
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The Cisco client's tunnel interface, which the firewall's rules name
set_vpn_tun cscotun0

ECHO_URL=${ECHO_URL:-https://ifconfig.me/ip}
SOCKS5_PROXY=${SOCKS5_PROXY:-socks5h://127.0.0.1:1080}
GATEWAY=${GATEWAY:-}

echo_host=${ECHO_URL#https://}
echo_host=${echo_host%%/*}

# Address of the temporary tunnel interface that start.sh creates while danted starts
temp_tun_addr=10.0.0.1/32

# The host route that add_route created, while it may exist: its destination and gateway
route_dest=
route_via=
# Output of the last add_route
route_add_output=
# Set by the signal traps while add_route defers the signals
pending_signal=

# Add the host route to $1 via $2 with MTU $3, and record it as this script's own only when the add succeeds: a
# route that another process created first, for which the add fails with "File exists", is never deleted here.
# HUP, INT, TERM and PIPE are deferred from before the add until the route is recorded, and then end the script.
# The ip process ignores them: a signal that reached it after the kernel created the route but before it exited
# would otherwise kill it, and the route would stay without a record. The subshell ignores them before it execs
# ip, and ignored signals stay ignored across exec.
# Keeps ip's output in route_add_output and returns ip's exit status.
add_route() {
    local status=0
    pending_signal=
    trap 'pending_signal=1' HUP INT TERM PIPE
    route_add_output=$(
        trap '' HUP INT TERM PIPE
        exec ip route add "$1" via "$2" mtu "$3" 2>&1
    ) || status=$?
    if [ "$status" = 0 ]; then
        route_dest=$1
        route_via=$2
    fi
    trap 'exit 1' HUP INT TERM PIPE
    [ -z "$pending_signal" ] || exit 1
    return "$status"
}

# Delete the host route that add_route created, if any, and clear the record once the route is gone: when the
# delete succeeds, or when it fails and a lookup succeeds and finds no such route. Otherwise the record is kept,
# so that the EXIT trap tries again, and an error goes to stderr.
delete_route() {
    local output routes
    [ -n "$route_dest" ] || return 0
    if output=$(ip route del "$route_dest" via "$route_via" 2>&1) ||
        { routes=$(ip route show exact "$route_dest" via "$route_via") && [ -z "$routes" ]; }; then
        route_dest=
        route_via=
        return 0
    fi
    printf 'error: cannot delete the host route to %s via %s; delete it by hand: %s\n' \
        "$route_dest" "$route_via" "$output" >&2
    return 1
}

# EXIT trap: delete the host route. The signals, SIGPIPE among them, are ignored first, so that neither another
# signal nor a closed output stops the delete; a message about it may then fail to be written.
on_exit() {
    trap '' HUP INT TERM PIPE
    delete_route
}

# Run on_exit when the script ends, also after a signal. The script may run over SSH, where a lost connection
# sends SIGHUP and a write to the closed output sends SIGPIPE; both end it like an interrupt.
set_cleanup_traps() {
    trap on_exit EXIT
    trap 'exit 1' HUP INT TERM PIPE
}

# The host's state that the checks must leave as it was
host_routes() { ip route; }
host_rules() { iptables -w 5 -S; }
host_dns() { cat /etc/resolv.conf; }

# Succeed when the command $2 succeeds and prints $1; otherwise print its errors or the differences
output_is() {
    local now
    if ! now=$("$2" 2>&1); then
        printf '%s failed:\n%s\n' "$2" "$now"
        return 1
    fi
    [ "$now" = "$1" ] && return 0
    diff <(printf '%s\n' "$1") <(printf '%s\n' "$now")
    return 1
}

# Print the IPv4 address that the echo service sees for a request made with the curl options $@.
# --noproxy keeps the host's proxy environment variables out: '*' makes a request direct, and '' with -x makes
# it use the proxy given for every host.
egress_ip() {
    curl -4 -fsS --connect-timeout 10 --max-time 20 "$@" "$ECHO_URL"
}

# Succeed when $1 is an IPv4 address in dotted-quad form
is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    echo "'$1' is not an IPv4 address"
    return 1
}

# Succeed when $1 is empty; otherwise print it
no_errors() {
    [ -z "$1" ] && return 0
    printf '%s' "$1"
    return 1
}

# Succeed when the exit status $1 is 0; otherwise print $2
succeeded() {
    [ "$1" = 0 ] && return 0
    printf '%s\n' "$2"
    return 1
}

# Succeed when $1 and $2 are the same
same() {
    [ "$1" = "$2" ] && return 0
    echo "'$1' is not '$2'"
    return 1
}

# Succeed when $1 and $2 differ
different() {
    [ "$1" != "$2" ] && return 0
    echo "both are '$1'"
    return 1
}

# Succeed when the container runs
container_runs() {
    local running
    running=$(docker inspect -f '{{.State.Running}}' cisco-vpn) || return 1
    [ "$running" = true ] && return 0
    echo "the container is not running"
    return 1
}

# Succeed when the Cisco client's command line tool reports the state Connected. Its answers are the lines with
# ">>", such as "  >> state: Disconnected"; its debug log goes to the same output.
vpn_is_connected() {
    local output
    output=$(in_c timeout 30 /opt/cisco/secureclient/bin/vpn state 2>&1)
    grep -q '>> state: Connected$' <<<"$output" && return 0
    grep -F '>>' <<<"$output" || printf '%s\n' "$output"
    return 1
}

# Succeed when cscotun0 has an IPv4 address other than the temporary interface's, so it is the Cisco client's own
tunnel_is_ciscos() {
    local addrs
    addrs=$(in_c ip -o -4 addr show dev cscotun0) || return 1
    if grep -q ' inet ' <<<"$addrs" && ! grep -qF " inet $temp_tun_addr " <<<"$addrs"; then
        return 0
    fi
    printf 'IPv4 addresses of cscotun0:\n%s\n' "$addrs"
    return 1
}

# Succeed when the container's filter table has chains whose names start with ciscovpn, which the Cisco client
# adds when it connects
cisco_chains_exist() {
    local rules
    rules=$(in_c iptables -S) || return 1
    grep -q '^-N ciscovpn' <<<"$rules" && return 0
    printf 'no ciscovpn* chain; the chains are:\n%s\n' "$(grep '^-N ' <<<"$rules")"
    return 1
}

# Succeed when chain $1 of the container's filter table jumps to a ciscovpn* chain
jumps_to_cisco_chain() {
    local rules
    rules=$(in_c iptables -S "$1") || return 1
    grep -q -- ' -j ciscovpn' <<<"$rules" && return 0
    printf '%s\n' "$rules"
    return 1
}

# Succeed when the firewall logs nothing in the next 12 seconds, in which its watch checks the rules at least twice:
# it logs each repair and each failure, so the Cisco client does not move or remove the rules while connected
firewall_stays_quiet() {
    local since lines
    since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    sleep 12
    lines=$(docker logs --since "$since" cisco-vpn 2>&1 | grep '^\[firewall\]')
    [ -z "$lines" ] && return 0
    printf 'firewall lines since %s:\n%s\n' "$since" "$lines"
    return 1
}

# Succeed when a lookup of the host's routes succeeds and finds none whose destination is exactly $1
host_has_no_route_to() {
    local routes
    if ! routes=$(ip route show exact "$1" 2>&1); then
        printf 'cannot look up the host routes to %s:\n%s\n' "$1" "$routes"
        return 1
    fi
    [ -z "$routes" ] && return 0
    printf 'the host has a route to %s:\n%s\n' "$1" "$routes"
    return 1
}

# Route mode: route one address of the echo service through the container and check that a request to it
# arrives with the VPN's address $1
run_route_checks() {
    local vpn_ip=$1 echo_ip container_ip tun_mtu routed_ip status=0
    echo_ip=$(getent ahostsv4 "$echo_host" | awk 'NR == 1 { print $1 }')
    container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cisco-vpn)
    tun_mtu=$(in_c cat /sys/class/net/cscotun0/mtu)
    check "echo service $echo_host has an IPv4 address" is_ipv4 "$echo_ip" &&
        check "container has an IPv4 address" is_ipv4 "$container_ip" &&
        check "tunnel MTU is known" test "$tun_mtu" -gt 0 &&
        check "host has no route to $echo_ip/32 yet" host_has_no_route_to "$echo_ip/32" || return
    echo "     routing $echo_ip/32 via $container_ip mtu $tun_mtu"
    add_route "$echo_ip/32" "$container_ip" "$tun_mtu" || status=$?
    check "host route to $echo_ip/32 through the container is added" succeeded "$status" "$route_add_output" ||
        return
    routed_ip=$(egress_ip --noproxy '*' --resolve "$echo_host:443:$echo_ip" 2>&1)
    check "a routed request arrives with the VPN's address" same "$routed_ip" "$vpn_ip"
    delete_route
    check "host route to $echo_ip/32 is deleted" host_has_no_route_to "$echo_ip/32"
}

# Print the heading $1 and below it the lines of $2, indented, or "none" when $2 is empty
print_lines() {
    echo "     $1:"
    printf '%s\n' "${2:-none}" | sed 's/^/       /'
}

# Print what the persistence acceptance needs to know, without checking it: the gateway address that the data
# directory holds and the files in it that changed since the container started, and the firewall's lines since
# then. vpnui's "Current Preference Settings" line has no gateway address, so only the files are searched.
report_persistence() {
    local data_dir started changed
    data_dir=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/home/vpnuser"}}{{.Source}}{{end}}{{end}}' \
        cisco-vpn)
    started=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn)
    echo "     container started at $started; data directory $data_dir"
    if [ -z "$data_dir" ] || [ ! -d "$data_dir" ]; then
        echo "     the data directory is not found"
        return
    fi
    print_lines "DefaultHostName in the data directory" \
        "$(grep -rIo '<DefaultHostName>[^<]*</DefaultHostName>' "$data_dir")"
    if [ -n "$GATEWAY" ]; then
        print_lines "files in the data directory that contain GATEWAY" "$(grep -rlIF -- "$GATEWAY" "$data_dir")"
    fi
    changed=$(find "$data_dir" -newermt "@$(date -d "$started" +%s)" ! -type d -printf '%P\n' | sort)
    print_lines "files in the data directory changed since the container started: $(grep -c . <<<"$changed"), the first 50" \
        "$(head -n 50 <<<"$changed")"
    print_lines "firewall lines since the container started" \
        "$(docker logs --since "$started" cisco-vpn 2>&1 | grep '^\[firewall\]')"
}

main() {
    if [ "$(id -u)" != 0 ]; then
        echo "error: run this script as root; it reads the host's iptables rules and adds and deletes a host route"
        exit 2
    fi
    if ! [[ $ECHO_URL =~ ^https://[A-Za-z0-9.-]+(/.*)?$ ]]; then
        echo "error: ECHO_URL must be an https URL without a port"
        exit 2
    fi
    set_cleanup_traps

    # The host's state at the start; the route is added only when all of it was recorded
    snapshot_errors=
    host_routes_before=$(host_routes 2>&1) || snapshot_errors+="ip route: $host_routes_before"$'\n'
    host_rules_before=$(host_rules 2>&1) || snapshot_errors+="iptables -S: $host_rules_before"$'\n'
    host_dns_before=$(host_dns 2>&1) || snapshot_errors+="resolv.conf: $host_dns_before"$'\n'

    echo "--- connection ---"
    check "host routes, iptables rules and resolv.conf are recorded" no_errors "$snapshot_errors"
    check "container runs" container_runs
    connected=
    check "VPN is connected" vpn_is_connected && connected=1
    check "tunnel interface cscotun0 is the Cisco client's" tunnel_is_ciscos

    echo "--- firewall ---"
    check "Cisco client's ciscovpn* chains exist" cisco_chains_exist
    check "INPUT jumps to a Cisco client chain" jumps_to_cisco_chain INPUT
    check "FORWARD jumps to a Cisco client chain" jumps_to_cisco_chain FORWARD
    run_firewall_checks
    check "firewall logs no repair or failure in 12 seconds" firewall_stays_quiet
    run_reply_route_checks

    echo "--- local LAN access ---"
    check "vpnui reads LocalLanAccess: true" local_lan_access_is true
    check "gateway grants local LAN access" wait_log 'IPv4 Local LAN Wildcard: received' "" 1
    check "noVNC page is reachable" curl -fsS -o /dev/null --noproxy '*' --max-time 10 http://127.0.0.1:6080/vnc.html

    echo "--- proxies ---"
    host_ip=$(egress_ip --noproxy '*' 2>&1)
    socks_ip=$(egress_ip --noproxy '' -x "$SOCKS5_PROXY" 2>&1)
    http_ip=$(egress_ip --noproxy '' -x http://127.0.0.1:8888 2>&1)
    echo "     direct: $host_ip; SOCKS5: $socks_ip; HTTP: $http_ip"
    host_ip_found=
    socks_ip_found=
    check "host's direct egress address is found" is_ipv4 "$host_ip" && host_ip_found=1
    check "egress address through the SOCKS5 proxy is found" is_ipv4 "$socks_ip" && socks_ip_found=1
    check "egress address through the HTTP proxy is found" is_ipv4 "$http_ip"
    check "HTTP proxy leaves with the SOCKS5 proxy's address" same "$http_ip" "$socks_ip"
    # The VPN's egress address, once the SOCKS5 proxy is known to leave with another address than the host
    vpn_ip=
    if [ -n "$host_ip_found" ] && [ -n "$socks_ip_found" ]; then
        check "SOCKS5 proxy leaves with another address than the host" different "$socks_ip" "$host_ip" &&
            vpn_ip=$socks_ip
    fi

    echo "--- route mode ---"
    if [ -n "$connected" ] && [ -n "$vpn_ip" ] && [ -z "$snapshot_errors" ]; then
        run_route_checks "$vpn_ip"
    else
        check "route mode: not checked, since the VPN is not connected, the proxies do not leave through it or the host's state was not recorded" false
    fi

    echo "--- host ---"
    if [ -z "$snapshot_errors" ]; then
        check "host routes are unchanged" output_is "$host_routes_before" host_routes
        check "host iptables rules are unchanged" output_is "$host_rules_before" host_rules
        check "host resolv.conf is unchanged" output_is "$host_dns_before" host_dns
    else
        check "host state: not compared, since it was not recorded at the start" false
    fi

    echo "--- persistence (reported, not checked) ---"
    report_persistence

    finish
}

# Run the checks when the script is run; when it is sourced, only define its functions
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
