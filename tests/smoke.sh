#!/bin/bash
# Smoke tests that need no VPN login. Run on the Docker host after `docker compose up -d --build`.
# Waits until the container is ready, runs every check, restarts the container, waits again
# and runs every check once more. Exits 0 when every check passes, 1 otherwise.

# lib.sh is linted on its own
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# start.sh writes a utmp USER_PROCESS record so that vpnagentd can find the user running vpnui.
# The record must have user vpnuser, line :1, and a PID on vpnui's parent chain below PID 1.
# The PID field of utmpdump is zero-padded and the user and line fields are space-padded.
utmp_check=$(
    cat <<'EOF'
record=$(utmpdump /var/run/utmp | awk -F '[][]' '$2 == 7 { print $4 + 0, $8, $10; exit }')
read -r pid user line <<END
$record
END
[ "$user" = vpnuser ] || { echo "utmp user is '$user', expected vpnuser"; exit 1; }
[ "$line" = :1 ] || { echo "utmp line is '$line', expected :1"; exit 1; }
p=$(pgrep -o -x vpnui) || { echo "vpnui is not running"; exit 1; }
while :; do
    # The parent PID is the second field after the parenthesized command name
    p=$(sed 's/.*) //' "/proc/$p/stat" | cut -d ' ' -f 2)
    [ "$p" -gt 1 ] || break
    [ "$p" = "$pid" ] && exit 0
done
echo "utmp PID '$pid' is not an ancestor of vpnui"
exit 1
EOF
)

# The single-quoted commands are expanded by the sh -c that runs them
# shellcheck disable=SC2016
run_checks() {
    check "noVNC page is reachable" curl -fsS -o /dev/null http://127.0.0.1:6080/vnc.html
    check "resolv.conf is unmounted" in_c sh -c '! mountpoint -q /etc/resolv.conf'
    check "hosts is unmounted" in_c sh -c '! mountpoint -q /etc/hosts'
    check "DNS works in the container" in_c getent hosts deb.debian.org
    check "vpnagentd runs as root" in_c sh -c '[ "$(ps -o user= -C vpnagentd | head -1)" = root ]'
    check "vpnui runs as vpnuser" in_c sh -c '[ "$(ps -o user= -C vpnui | head -1)" = vpnuser ]'
    check "utmp record points to an ancestor of vpnui" in_c sh -c "$utmp_check"
    # --noproxy '' keeps a NO_PROXY setting on the host from sending the request around the proxy
    check "HTTP proxy works" curl -fsS -o /dev/null --noproxy '' -x http://127.0.0.1:8888 https://deb.debian.org/
    check "only NET_ADMIN and SYS_ADMIN are added" sh -c '[ "$(docker inspect -f "{{.HostConfig.CapAdd}}" cisco-vpn)" = "[CAP_NET_ADMIN CAP_SYS_ADMIN]" ]'
}

check "services started" wait_ready
run_checks

echo "--- after docker restart ---"
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
run_checks

finish
