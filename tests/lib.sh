# shellcheck shell=bash
# Helpers shared by the test scripts. The scripts run on the Docker host against the cisco-vpn container;
# each check prints "ok" or "FAIL" with its name, and finish exits 1 if any check failed.

failures=0

# Run a command as a named check: ok when it exits 0, FAIL otherwise. Returns 0 for ok and 1 for FAIL.
# The command runs in a subshell, so variables that it sets are not kept.
# The command's output is shown, indented, only when it fails.
check() {
    local name=$1 output
    shift
    if output=$("$@" 2>&1); then
        echo "ok   $name"
        return 0
    fi
    echo "FAIL $name"
    if [ -n "$output" ]; then
        printf '%s\n' "$output" | sed 's/^/     /'
    fi
    failures=$((failures + 1))
    return 1
}

# Run a command inside the container
in_c() {
    docker exec cisco-vpn "$@"
}

# Wait up to $3 seconds (90 when $3 is empty) for a log line that matches the extended regular expression $1
# and was logged since the time $2 (RFC 3339). Without $2, only lines from the container's current start count:
# docker logs keeps the output of earlier starts, so the time is then State.StartedAt.
wait_log() {
    local pattern=$1 since=${2:-} seconds=${3:-90} logs deadline
    deadline=$((SECONDS + seconds))
    if [ -z "$since" ]; then
        since=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    fi
    while [ "$SECONDS" -lt "$deadline" ]; do
        logs=$(docker logs --since "$since" cisco-vpn 2>&1)
        if grep -qE "$pattern" <<<"$logs"; then
            return 0
        fi
        sleep 1
    done
    echo "no line matching '$pattern' in the logs since $since after $seconds seconds"
    return 1
}

# Wait for the entrypoint's ready line from the container's current start
wait_ready() {
    wait_log '^\[start\] all services started$'
}

# Succeed when the last "Current Preference Settings" line of vpnui (csc_ui) has LocalLanAccess: $1
local_lan_access_is() {
    local line
    line=$(docker logs cisco-vpn 2>&1 | grep "csc_ui" | grep "Current Preference Settings" | tail -1)
    grep -q "LocalLanAccess: $1" <<<"$line" && return 0
    echo "last csc_ui preference line has '$(grep -o 'LocalLanAccess: [a-z]*' <<<"$line")'"
    return 1
}

# Succeed when the container was created with the sysctl net.ipv4.ip_forward=1. Forwarding in the container is
# also on when the container inherits the host's setting, as a new network namespace does by default, so its
# value in the container alone does not show that the compose file sets it.
ip_forward_is_set() {
    local value
    value=$(docker inspect -f '{{index .HostConfig.Sysctls "net.ipv4.ip_forward"}}' cisco-vpn) || return 1
    [ "$value" = 1 ] && return 0
    echo "net.ipv4.ip_forward in the container's sysctls is '$value'"
    return 1
}

# The firewall marks its rules with a comment, and iptables may print the conntrack states in either order
fw_mark='-m comment --comment cisco-vpn-docker'
fw_states='(RELATED,ESTABLISHED|ESTABLISHED,RELATED)'

# TCP ports of the container's services (SOCKS5, HTTP proxy and noVNC): the firewall accepts connections to them from
# eth0 and their replies to eth0, and policy rules route their replies by routing table 2
service_ports=(1080 8888 6080)

# Set vpn_tun to the VPN client's tunnel interface $1, and fw_input_rules, fw_output_rules, fw_forward_rules and
# fw_postrouting_rules to the firewall's rules for it, as iptables -S prints them, as extended regular expressions
# that match a whole rule. The scripts call it before any firewall check.
set_vpn_tun() {
    local ports
    vpn_tun=$1
    ports=$(
        IFS=,
        echo "${service_ports[*]}"
    )
    fw_input_rules=(
        "-A INPUT -m conntrack --ctstate $fw_states $fw_mark -j ACCEPT"
        "-A INPUT -i eth0 -p tcp -m multiport --dports $ports -m conntrack --ctstate NEW $fw_mark -j ACCEPT"
        "-A INPUT -i $vpn_tun -p tcp $fw_mark -j DROP"
    )
    fw_output_rules=(
        "-A OUTPUT -o eth0 -p tcp -m multiport --sports $ports $fw_mark -j ACCEPT"
    )
    fw_forward_rules=(
        "-A FORWARD -i eth0 -o $vpn_tun $fw_mark -j ACCEPT"
        "-A FORWARD -i $vpn_tun -o eth0 -m conntrack --ctstate $fw_states $fw_mark -j ACCEPT"
    )
    fw_postrouting_rules=(
        "-A POSTROUTING -o $vpn_tun $fw_mark -j MASQUERADE"
    )
}

# Succeed when the first rules of chain $2 in table $1 in the container match the expressions $3..., in this order
chain_starts_with() {
    local table=$1 chain=$2 output rules rule i=0
    shift 2
    output=$(in_c iptables -t "$table" -S "$chain") || return 1
    mapfile -t rules < <(grep -- '^-A ' <<<"$output" | head -n "$#")
    for rule; do
        if ! grep -qxE -- "$rule" <<<"${rules[i]}"; then
            echo "rule $((i + 1)) of $chain is '${rules[i]}', expected one that matches '$rule'"
            return 1
        fi
        i=$((i + 1))
    done
}

# Succeed when each of the firewall's rules appears exactly once in the container's filter and nat tables,
# and no other rule has the firewall's mark
firewall_rules_are_unique() {
    local rules rule count all_rules
    all_rules=("${fw_input_rules[@]}" "${fw_output_rules[@]}" "${fw_forward_rules[@]}" "${fw_postrouting_rules[@]}")
    rules=$(in_c sh -c 'iptables -S && iptables -t nat -S') || return 1
    for rule in "${all_rules[@]}"; do
        count=$(grep -cxE -- "$rule" <<<"$rules")
        if [ "$count" != 1 ]; then
            echo "'$rule' appears $count times"
            return 1
        fi
    done
    count=$(grep -cF -- " $fw_mark " <<<"$rules")
    [ "$count" = "${#all_rules[@]}" ] && return 0
    echo "$count rules have the firewall's mark, expected ${#all_rules[@]}"
    return 1
}

# Checks of the firewall's rules and of forwarding for route mode
# The single-quoted commands are expanded by the sh -c that runs them
# shellcheck disable=SC2016
run_firewall_checks() {
    : "${vpn_tun:?set_vpn_tun must be called before the firewall checks}"
    check "container forwards IPv4 packets" in_c sh -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
    check "container is created with net.ipv4.ip_forward=1" ip_forward_is_set
    check "INPUT starts with the firewall's three rules" chain_starts_with filter INPUT "${fw_input_rules[@]}"
    check "OUTPUT starts with the firewall's rule for the service ports" chain_starts_with filter OUTPUT "${fw_output_rules[@]}"
    check "FORWARD starts with the firewall's two rules" chain_starts_with filter FORWARD "${fw_forward_rules[@]}"
    check "POSTROUTING starts with masquerading out of the tunnel" chain_starts_with nat POSTROUTING "${fw_postrouting_rules[@]}"
    check "each firewall rule appears once" firewall_rules_are_unique
}

# Succeed when routing table 2 in the container has a default route through eth0
reply_table_has_default_route() {
    local routes
    routes=$(in_c ip route show table 2) || return 1
    grep -qE '^default via [0-9.]+ dev eth0( |$)' <<<"$routes" && return 0
    printf 'routing table 2:\n%s\n' "$routes"
    return 1
}

# Succeed when the container has exactly one policy rule per service port that routes what leaves the container
# from that port by table 2, as ip rule prints it
reply_rules_are_set() {
    local rules port count
    rules=$(in_c ip rule show) || return 1
    for port in "${service_ports[@]}"; do
        count=$(grep -cxE "[0-9]+:[[:space:]]+from all iif lo sport $port lookup 2" <<<"$rules")
        if [ "$count" != 1 ]; then
            printf 'the rule for port %s appears %s times; the policy rules are:\n%s\n' "$port" "$count" "$rules"
            return 1
        fi
    done
}

# Checks of the routing of the service ports' replies through eth0
run_reply_route_checks() {
    check "routing table 2 has a default route through eth0" reply_table_has_default_route
    check "one policy rule per service port routes its replies by table 2" reply_rules_are_set
}

# Print the result and exit: 0 when every check passed, 1 otherwise
finish() {
    if [ "$failures" -eq 0 ]; then
        echo "all checks passed"
        exit 0
    fi
    echo "$failures check(s) failed"
    exit 1
}
