#!/bin/bash
# Smoke tests that need no VPN login. Run on the Docker host after `docker compose up -d --build`.
# Waits until the container is ready, runs every check, restarts the container, waits again
# and runs every check once more. Then checks the persistent home directory: it recreates the container
# on an empty data directory of its own under the repository's tmp/, changes a preference there and
# recreates the container again, and finally recreates it on the configured data directory.
# The test data directory is removed at the start of these checks and left in place afterwards.
# Exits 0 when every check passes, 1 otherwise.

# lib.sh is linted on its own
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
# Data directory used by the persistence checks instead of the configured one, which they never modify
test_data=$repo/tmp/smoke-data
prefs=.vpn/.anyconnect

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

# Recreate the container with the repository's compose file and .env, from any working directory.
# The arguments are environment assignments for docker compose, such as CISCO_VPN_DATA=<directory>.
recreate() {
    env "$@" docker compose -f "$repo/docker-compose.yml" up -d --force-recreate
}

# Wait until vpnui (csc_ui) of the container's current start has logged the preferences it read
wait_prefs_logged() {
    wait_log 'csc_ui\[[0-9]+\]: .*Current Preference Settings'
}

# Succeed when the last "Current Preference Settings" line of vpnui (csc_ui) has LocalLanAccess: $1
local_lan_access_is() {
    local line
    line=$(docker logs cisco-vpn 2>&1 | grep "csc_ui" | grep "Current Preference Settings" | tail -1)
    grep -q "LocalLanAccess: $1" <<<"$line" && return 0
    echo "last csc_ui preference line has '$(grep -o 'LocalLanAccess: [a-z]*' <<<"$line")'"
    return 1
}

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
    check "vpnui logged its preferences" wait_prefs_logged
    check "preferences allow local LAN access by default" local_lan_access_is true
    check "vpnuser can write its home" in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
        sh -c 'touch /home/vpnuser/.write-test && rm /home/vpnuser/.write-test'
}

check "services started" wait_ready
run_checks

echo "--- after docker restart ---"
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
run_checks

# Docker creates a missing data directory as root
echo "--- on an empty data directory ---"
check "test data directory is removed" rm -rf "$test_data"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data"
check "services started after recreate" wait_ready
run_checks
check "default preferences are in the test data directory" test -f "$test_data/$prefs"

# A preference file that already exists holds the user's choices and must be kept
echo "--- with a preference changed by the user ---"
check "LocalLanAccess is changed to false" in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
    sh -c "sed -i 's#<LocalLanAccess>true</LocalLanAccess>#<LocalLanAccess>false</LocalLanAccess>#' /home/vpnuser/$prefs && grep -q '<LocalLanAccess>false</LocalLanAccess>' /home/vpnuser/$prefs"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data"
check "services started after recreate" wait_ready
check "changed preference is kept in the file" grep -q '<LocalLanAccess>false</LocalLanAccess>' "$test_data/$prefs"
check "vpnui logged its preferences" wait_prefs_logged
check "vpnui reads the changed preference" local_lan_access_is false

echo "--- back on the configured data directory ---"
check "container is recreated" recreate
check "services started after recreate" wait_ready

finish
