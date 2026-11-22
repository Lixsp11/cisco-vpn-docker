#!/bin/bash
# Smoke tests that need no VPN login. Run on the Docker host after `docker compose up -d --build`.
# Waits until the container is ready and runs every check. Stops danted twice, the second time while a tunnel
# interface of another address exists, and checks the SOCKS5 proxy after run_service restarts it. Puts a rule
# before the firewall's rules in INPUT and in FORWARD, as the VPN client may do when it connects, and replaces the
# firewall's DROP rule with an unmarked copy at the end of INPUT; checks that the firewall puts its rules back at
# the top and leaves the other rules in their order, and removes those rules again. Restarts the
# container, waits again and runs every check once more, then restarts it once more while giving the temporary
# tunnel interface its address fails. Then recreates the container on an empty data directory of its own under
# the repository's tmp/ and runs every check there. On that directory it makes iptables fail while
# iptables-restore works and checks that the firewall changes nothing. It restarts the container while iptables
# and iptables-restore fail and checks that it stops before it starts the VPN client. It recreates the container
# with SOCKS_USER and SOCKS_PASSWD set and restarts it, recreates it with only SOCKS_USER set, with a SOCKS_PASSWD
# that cannot be set (and restarts it with an account of the proxy's left from an earlier start), with
# SOCKS_USER naming each of the image's accounts and a malformed SOCKS_USER, and with NODANTED set. It recreates
# it with PING_ADDR set to an address that does not answer, with PING_ADDR and PING_ADDR_URL set to the
# container's own address and a web server that the checks start in it (and restarts it, then stops it while a
# keepalive request waits for a server that never answers), with PING_INTERVAL empty and with a PING_INTERVAL of
# 0. Then it
# checks the persistent home directory: it changes a preference and recreates the container again, recreates
# it with PASSWORD and VNC_SIZE set, once more with both empty and once with a PASSWORD of two lines, once with
# another PASSWORD that cannot be written because the VNC password's directory is read-only, and finally
# recreates it on the configured data directory.
# The test data directory and the copies of the files compared across a recreate are removed before the
# container is recreated on it and left in place afterwards.
# Exits 0 when every check passes, 1 otherwise.

# lib.sh is linted on its own
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
# Data directory used by the persistence checks instead of the configured one, which they never modify
test_data=$repo/tmp/smoke-data
prefs=.vpn/.anyconnect
# Copy of the preference file as edited by the checks, compared with the file after a recreate
edited_prefs=$repo/tmp/smoke-prefs-edited
vnc_passwd=.vnc/passwd
# Copy of the saved VNC password file, compared with the file after a recreate that must not change it
saved_vnc_passwd=$repo/tmp/smoke-vnc-passwd
# VNC uses only the first 8 characters of a password. This one has a space and special characters and goes on
# past the 255 characters that tigervncpasswd -f reads as one password; the "xyz" after them must not become
# a second, view-only password.
long_password="p@ss w0rd!$(printf '%0245d' 0)xyz"
# The second line of a password must not become a view-only password either
two_line_password=$'pw1\npw2'
# Address of the documentation range (TEST-NET-1) that no host answers, for the keepalive's failed pings
unreachable_addr=192.0.2.1
# Web server that the keepalive checks start in the container for PING_ADDR_URL, and the file of its request log
keepalive_url=http://127.0.0.1:18080/
keepalive_log=/tmp/ka.log

# Server for PING_ADDR_URL that never answers: it listens on the web server's port and never accepts a connection.
# The kernel still completes the connections in the listen queue, so a request is sent and then waits.
silent_server=$(
    cat <<'EOF'
import socket
import time

sock = socket.socket()
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", 18080))
sock.listen()
time.sleep(3600)
EOF
)

# Minimal RFB client that tries VncAuth with the password in argv[1] against the VNC server in the container.
# Exits 0 when the server accepts the password, 2 when it rejects it and 1 on any other error.
# python3-cryptography is in the image as a dependency of noVNC's websockify.
vnc_auth=$(
    cat <<'EOF'
import socket
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            sys.exit("the VNC server closed the connection")
        data += chunk
    return data


# VncAuth encrypts the server's 16-byte challenge with DES. The key is the password cut or zero-padded
# to 8 bytes, with the bits of each byte reversed. TripleDES with an 8-byte key is single DES.
password = sys.argv[1].encode()
key = bytes(int(f"{b:08b}"[::-1], 2) for b in password[:8].ljust(8, b"\0"))
with socket.create_connection(("127.0.0.1", 5901), timeout=5) as sock:
    recv_exact(sock, 12)  # the server's protocol version
    sock.sendall(b"RFB 003.008\n")
    types = recv_exact(sock, recv_exact(sock, 1)[0])
    if 2 not in types:
        sys.exit(f"the VNC server offers security types {list(types)}, not VncAuth (2)")
    sock.sendall(b"\x02")
    encryptor = Cipher(algorithms.TripleDES(key), modes.ECB()).encryptor()
    sock.sendall(encryptor.update(recv_exact(sock, 16)) + encryptor.finalize())
    if recv_exact(sock, 4) != b"\0\0\0\0":
        print("the VNC server rejected the password")
        sys.exit(2)
EOF
)

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
# The arguments are environment assignments for docker compose, such as CISCO_VPN_DATA=<directory>;
# an empty assignment such as PASSWORD= replaces a value set in .env.
recreate() {
    env "$@" docker compose -f "$repo/docker-compose.yml" up -d --force-recreate
}

# Wait until vpnui (csc_ui) of the container's current start has logged the preferences it read
wait_prefs_logged() {
    wait_log 'csc_ui\[[0-9]+\]: .*Current Preference Settings'
}

# Succeed when Xtigervnc in the container runs with -geometry $1
vnc_size_is() {
    local args
    args=$(in_c ps -o args= -C Xtigervnc) || return 1
    grep -q -- "-geometry $1 " <<<"$args" && return 0
    echo "Xtigervnc runs as: $args"
    return 1
}

# Succeed when the VNC password file in the container holds the password $1, as tigervncpasswd writes it
vnc_passwd_holds() {
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    in_c sh -c 'printf %s "$1" | tigervncpasswd -f | cmp - "$2"' sh "$1" "/home/vpnuser/$vnc_passwd"
}

# Succeed when the VNC password file in the container is a regular file of vpnuser's with mode 600.
# stat reports an empty file as "regular empty file" and a link as "symbolic link", so both fail.
vnc_passwd_is_private() {
    local file_info
    file_info=$(in_c stat -c '%F %U:%G %a' "/home/vpnuser/$vnc_passwd") || return 1
    [ "$file_info" = "regular file vpnuser:vpnuser 600" ] && return 0
    echo "VNC password file is: $file_info"
    return 1
}

# Create a passwd.new next to the VNC password file in the container, as vpnuser: with "file", a regular file
# with mode 644; with "link", a link to the password file itself
plant_passwd_new() {
    # The single-quoted scripts are expanded by the sh that runs them
    # shellcheck disable=SC2016
    case $1 in
        file) in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
            sh -c 'rm -f "$1.new" && umask 022 && printf x >"$1.new"' sh "/home/vpnuser/$vnc_passwd" ;;
        link) in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
            sh -c 'rm -f "$1.new" && ln -s passwd "$1.new"' sh "/home/vpnuser/$vnc_passwd" ;;
    esac
}

# Succeed when the VNC server in the container accepts the password $1
vnc_accepts() {
    in_c python3 -c "$vnc_auth" "$1"
}

# Succeed when the VNC server in the container rejects the password $1
vnc_rejects() {
    local status=0
    vnc_accepts "$1" || status=$?
    [ "$status" -eq 2 ] && return 0
    echo "VNC client exited with $status, expected 2 (rejected)"
    return 1
}

# Wait until danted logs that it listens on port 1080, since the container's current start or since the time $1
wait_danted() {
    wait_log '^\[socks5\] danted is listening on port 1080$' "$@"
}

# Succeed when a request through the SOCKS5 proxy URL $1, such as socks5h://user:password@127.0.0.1:1080, succeeds.
# --noproxy '' keeps a NO_PROXY setting on the host from sending the request around the proxy.
socks5_works() {
    curl -fsS -o /dev/null --noproxy '' -x "$1" https://deb.debian.org/
}

# Succeed when the SOCKS5 proxy refuses a request through the proxy URL $1 in its handshake.
# curl then exits with 97 (CURLE_PROXY), and with other codes for other errors, such as 7 when nothing listens.
socks5_refuses() {
    local status=0
    socks5_works "$1" || status=$?
    [ "$status" -eq 97 ] && return 0
    echo "curl exited with $status, expected 97 (refused by the SOCKS5 proxy)"
    return 1
}

# Succeed when a request through the SOCKS5 proxy URL $1 fails, for whatever reason
socks5_fails() {
    socks5_works "$1" || return 0
    echo "the request succeeded"
    return 1
}

# Succeed when danted does not run in the container and nothing listens on port 1080
danted_is_off() {
    in_c sh -c '! pgrep -x danted && ! ss -ltn | grep ":1080 "'
}

# Succeed when the account $1 in the container has no password: its shadow entry has no hash, which starts with $
account_has_no_password() {
    local field
    field=$(in_c getent shadow "$1" | cut -d: -f2)
    [ -n "$field" ] && [ "${field#\$}" = "$field" ] && return 0
    echo "the password field of $1 is '${field:0:4}...'"
    return 1
}

# Flag file in the container: while it exists, the ip wrapper of install_ip_wrapper fails "ip addr add"
fail_ip_addr_flag=/run/smoke-fail-ip-addr-add

# Install an ip wrapper in the container's /usr/local/sbin, which comes before ip's own directory in PATH, and
# create fail_ip_addr_flag. The wrapper runs the real ip, found in PATH without /usr/local, for everything else.
install_ip_wrapper() {
    local real_ip
    real_ip=$(in_c env PATH=/usr/sbin:/usr/bin:/sbin:/bin sh -c 'command -v ip') || return 1
    docker exec -i cisco-vpn sh -c 'cat >/usr/local/sbin/ip && chmod 755 /usr/local/sbin/ip' <<EOF || return 1
#!/bin/sh
# Installed by tests/smoke.sh: "ip addr add" fails while $fail_ip_addr_flag exists
if [ "\$1" = addr ] && [ "\$2" = add ] && [ -e $fail_ip_addr_flag ]; then
    echo "ip addr add fails for the smoke test" >&2
    exit 2
fi
exec $real_ip "\$@"
EOF
    in_c touch "$fail_ip_addr_flag"
}

# Install a command named $1 in the container's /usr/local/sbin, which comes before the system's directories in
# PATH, that fails every time
install_failing_command() {
    docker exec -i cisco-vpn sh -c 'cat >"/usr/local/sbin/$1" && chmod 755 "/usr/local/sbin/$1"' sh "$1" <<EOF
#!/bin/sh
# Installed by tests/smoke.sh: fails every time
echo "$1 fails for the smoke test" >&2
exit 1
EOF
}

# Succeed when the container stops within 30 seconds with an exit code other than 0
container_exits_with_error() {
    local state deadline=$((SECONDS + 30))
    while state=$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' cisco-vpn); do
        case $state in
            "false 0")
                echo "the container exited with code 0"
                return 1
                ;;
            false\ *) return 0 ;;
        esac
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "the container still runs after 30 seconds"
            return 1
        fi
        sleep 1
    done
    return 1
}

# Succeed when vpnagentd logged nothing since the container's current start, which it does when it starts
vpnagentd_logged_nothing() {
    local since
    since=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    ! docker logs --since "$since" cisco-vpn 2>&1 | grep '^\[vpnagentd\]'
}

# Succeed when cscotun0 is missing at least once in about 3 seconds. While giving the temporary interface its
# address fails, run_service retries every second, and each try creates the interface and removes it at once,
# so only an interface that stays exists every time.
tunnel_interface_is_not_kept() {
    for _ in $(seq 10); do
        in_c sh -c '! ip link show cscotun0 >/dev/null 2>&1' && return 0
        sleep 0.3
    done
    echo "cscotun0 exists on every try"
    return 1
}

# Stop danted in the container and check the SOCKS5 proxy after run_service restarts it
restart_danted_checks() {
    local stopped_at
    stopped_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    check "danted is stopped" in_c pkill -x danted
    check "danted listens again" wait_danted "$stopped_at"
    check "SOCKS5 proxy works after danted restarts" socks5_works socks5h://127.0.0.1:1080
}

# Succeed when danted runs as the user socks and the socket listening on port 1080 in the container belongs to socks.
# danted runs with the effective user socks, and reading the sockets of such a process needs CAP_SYS_PTRACE,
# which the container does not have, so ss -p shows no process for the port; ss -e shows the socket's owner.
socks5_port_is_danteds() {
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    in_c sh -c 'pgrep -x -u socks danted >/dev/null && ss -Hltne "sport = :1080" | grep -q " uid:$(id -u socks) "'
}

# Succeed when the firewall logged, since the time $1, exactly one line that it put its rules first in INPUT and
# one that it did so in FORWARD, and nothing else: it logs a repair once, and nothing when its rules are first
firewall_repaired_input_and_forward_once() {
    local lines expected
    lines=$(docker logs --since "$1" cisco-vpn 2>&1 | grep '^\[firewall\]' | sort)
    expected=$(printf '[firewall] put the rules first in the %s chain of the filter table\n' FORWARD INPUT)
    [ "$lines" = "$expected" ] && return 0
    echo "firewall lines since $1:"
    printf '%s\n' "$lines"
    return 1
}

# Print the rules of chain $1 in the container's filter table that do not have the firewall's mark
unmarked_rules() {
    local rules
    rules=$(in_c iptables -S "$1") || return 1
    # fw_mark is set in lib.sh
    # shellcheck disable=SC2154
    grep -- '^-A ' <<<"$rules" | grep -vF -- " $fw_mark "
    return 0
}

# Succeed when the rules of the container's INPUT and FORWARD that do not have the firewall's mark are $1 and $2,
# one rule per line, in this order
unmarked_rules_are() {
    local input forward
    input=$(unmarked_rules INPUT) && forward=$(unmarked_rules FORWARD) || return 1
    [ "$input" = "$1" ] && [ "$forward" = "$2" ] && return 0
    printf 'unmarked rules of INPUT:\n%s\nunmarked rules of FORWARD:\n%s\n' "$input" "$forward"
    return 1
}

# Succeed when the firewall logged, since the time $1, exactly one line that it cannot put its rules first, and no repair
firewall_logged_one_failure() {
    local lines
    lines=$(docker logs --since "$1" cisco-vpn 2>&1 | grep '^\[firewall\]')
    if [ "$(grep -c '^\[firewall\] error: cannot put the rules first' <<<"$lines")" = 1 ] &&
        ! grep -q '^\[firewall\] put the rules first' <<<"$lines"; then
        return 0
    fi
    echo "firewall lines since $1:"
    printf '%s\n' "$lines"
    return 1
}

# Wait up to 10 seconds for a GET / request in the log of the web server that run_keepalive_url_checks starts
wait_get_request() {
    local deadline=$((SECONDS + 10))
    while [ "$SECONDS" -lt "$deadline" ]; do
        in_c grep -qsF 'GET /' "$keepalive_log" && return 0
        sleep 1
    done
    echo "no 'GET /' in $keepalive_log after 10 seconds"
    return 1
}

# Succeed when the keepalive logs nothing in the next $1 seconds
keepalive_logs_nothing_for() {
    local since lines
    since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    sleep "$1"
    lines=$(docker logs --since "$since" cisco-vpn 2>&1 | grep '^\[keepalive\]')
    [ -z "$lines" ] && return 0
    printf 'keepalive lines since %s:\n%s\n' "$since" "$lines"
    return 1
}

# Succeed when no keepalive check runs in the container. run_service prefixes a service's output with a sed whose
# command line holds the service's name in brackets, so the keepalive runs while a process has "[keepalive]" in it.
keepalive_is_off() {
    local processes status=0
    processes=$(in_c pgrep -af '\[keepalive\]') || status=$?
    [ "$status" -eq 1 ] && return 0
    printf 'pgrep exited with %s; keepalive processes:\n%s\n' "$status" "$processes"
    return 1
}

# Stop the container while a keepalive request waits for silent_server, and succeed when the request's timeout and
# wget processes are in start.sh's process group, which the kill in stop_all signals, the container stops with
# code 0 within 5 seconds, before Docker's grace period of 10 seconds ends, and neither process is left.
# The PIDs and process groups are the host's, as docker top shows them.
stop_during_stalled_request() {
    local start_pgid processes pid pgid started stop_ms code deadline=$((SECONDS + 10))
    start_pgid=$(ps -o pgid= -p "$(docker inspect -f '{{.State.Pid}}' cisco-vpn)") || return 1
    start_pgid=${start_pgid// /}
    # A request that started at most 2 seconds ago has about 8 seconds left before its timeout of 10 seconds
    while :; do
        processes=$(docker top cisco-vpn -o pid,pgid,etimes,args | awk 'NR > 1 && / busybox wget / && $3 <= 2')
        [ "$(grep -c . <<<"$processes")" = 2 ] && break
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "no new keepalive request with its timeout and wget processes within 10 seconds"
            return 1
        fi
        sleep 0.5
    done
    while read -r pid pgid _; do
        if [ "$pgid" != "$start_pgid" ]; then
            echo "process $pid of the request is in process group $pgid, start.sh in $start_pgid:"
            printf '%s\n' "$processes"
            return 1
        fi
    done <<<"$processes"
    started=$(date +%s%N)
    docker stop cisco-vpn >/dev/null || return 1
    stop_ms=$((($(date +%s%N) - started) / 1000000))
    code=$(docker inspect -f '{{.State.ExitCode}}' cisco-vpn) || return 1
    if [ "$stop_ms" -ge 5000 ] || [ "$code" != 0 ]; then
        echo "the container stopped in $stop_ms ms with code $code"
        return 1
    fi
    while read -r pid _; do
        if [ -e "/proc/$pid" ]; then
            echo "process $pid of the request is left after the stop"
            return 1
        fi
    done <<<"$processes"
}

# Checks of the keepalive of a container started with PING_ADDR=127.0.0.1, PING_ADDR_URL=$keepalive_url and
# PING_INTERVAL=2: starts the web server for PING_ADDR_URL in the container, then stops it again.
# A request through the keepalive appears in the server's log within 10 seconds; while the ping and the request
# work, the keepalive logs nothing, and once the server is gone it logs that PING_ADDR_URL is unreachable.
run_keepalive_url_checks() {
    local stopped_at
    # docker restart keeps the container's files, so a log of an earlier start would already hold a request
    check "web server log of an earlier start is removed" in_c rm -f "$keepalive_log"
    check "web server is started in the container" docker exec -d cisco-vpn \
        sh -c "exec python3 -u -m http.server 18080 --bind 127.0.0.1 >$keepalive_log 2>&1"
    check "keepalive requests PING_ADDR_URL within 10 seconds" wait_get_request
    check "keepalive logs nothing while PING_ADDR answers and PING_ADDR_URL works" keepalive_logs_nothing_for 5
    stopped_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    check "web server is stopped" in_c pkill -f 'http.server 18080'
    check "unreachable PING_ADDR_URL is logged within 10 seconds" \
        wait_log "^\[keepalive\] $keepalive_url unreachable\$" "$stopped_at" 10
}

# Checks of the SOCKS5 proxy of a container started without SOCKS_PASSWD and NODANTED, while no VPN is
# connected. The temporary tunnel interface for danted's start is removed before danted's ready line is logged.
run_socks5_checks() {
    check "danted listens on port 1080" wait_danted
    check "SOCKS5 port is danted's" socks5_port_is_danteds
    check "SOCKS5 proxy works" socks5_works socks5h://127.0.0.1:1080
    check "no temporary tunnel interface is left" in_c sh -c '! ip link show cscotun0'
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
    check "default VNC size is 1280x720" vnc_size_is 1280x720
    check "VNC reads the password file in vpnuser's home" in_c sh -c 'ps -o args= -C Xtigervnc | grep -q -- "-PasswordFile $1"' sh "/home/vpnuser/$vnc_passwd"
    check "VNC password file is a regular file of vpnuser's with mode 600" vnc_passwd_is_private
    run_firewall_checks
}

check "services started" wait_ready
run_checks
run_socks5_checks

# With no VPN connected, danted's restart creates the temporary tunnel interface again and removes it
echo "--- after danted exits ---"
restart_danted_checks
check "no temporary tunnel interface is left after danted restarts" in_c sh -c '! ip link show cscotun0'

# A tunnel interface without the temporary interface's address is the VPN client's and is kept
echo "--- after danted exits while a tunnel interface exists ---"
check "tunnel interface with address 10.0.0.2/32 is created" in_c sh -c 'ip tuntap add mode tun cscotun0 && ip addr add 10.0.0.2/32 dev cscotun0'
restart_danted_checks
check "tunnel interface is kept" in_c sh -c 'ip -o addr show dev cscotun0 | grep -q " inet 10.0.0.2/32 "'
check "tunnel interface is removed" in_c ip tuntap del mode tun cscotun0

# The firewall checks its rules every 5 seconds, so within 12 seconds it repairs each chain once and then finds
# its rules first at least once more
echo "--- after a rule is put before the firewall's rules ---"
inserted_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "a rule is inserted at the top of INPUT" in_c iptables -I INPUT 1 -j RETURN
check "a rule is inserted at the top of FORWARD" in_c iptables -I FORWARD 1 -j RETURN
# Another owner's rule that is identical to the firewall's DROP rule apart from the mark is not the firewall's
check "the firewall's DROP rule is replaced by an unmarked copy at the end of INPUT" in_c sh -c \
    "iptables -D INPUT -i cscotun0 -p tcp $fw_mark -j DROP && iptables -A INPUT -i cscotun0 -p tcp -j DROP"
sleep 12
run_firewall_checks
check "other rules keep their order" unmarked_rules_are $'-A INPUT -j RETURN\n-A INPUT -i cscotun0 -p tcp -j DROP' \
    "-A FORWARD -j RETURN"
check "firewall logged one repair of INPUT and one of FORWARD" firewall_repaired_input_and_forward_once "$inserted_at"
check "inserted rules are removed" in_c sh -c \
    'iptables -D INPUT -j RETURN && iptables -D INPUT -i cscotun0 -p tcp -j DROP && iptables -D FORWARD -j RETURN'
check "only the firewall's rules are left in INPUT and FORWARD" unmarked_rules_are "" ""

echo "--- after docker restart ---"
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
run_checks
run_socks5_checks

# The restart makes start.sh find the ip wrapper first in PATH; the recreate of the next section removes it
echo "--- while giving the temporary tunnel interface its address fails ---"
check "ip wrapper that fails ip addr add is installed" install_ip_wrapper
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
check "failed address assignment is logged" wait_log '^\[socks5\] warning: cannot give the temporary interface cscotun0 its address'
check "danted is not started" danted_is_off
check "temporary tunnel interface is not kept" tunnel_interface_is_not_kept
assignable_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "ip addr add works again" in_c rm "$fail_ip_addr_flag"
check "danted listens once ip addr add works" wait_danted "$assignable_at"
check "SOCKS5 proxy works" socks5_works socks5h://127.0.0.1:1080
check "no temporary tunnel interface is left" in_c sh -c '! ip link show cscotun0'

# Docker creates a missing data directory as root
echo "--- on an empty data directory ---"
check "test data directory is removed" rm -rf "$test_data" "$edited_prefs" "$saved_vnc_passwd"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER= SOCKS_PASSWD= NODANTED=
check "services started after recreate" wait_ready
run_checks
run_socks5_checks
check "default preferences are in the test data directory" test -f "$test_data/$prefs"
check "VNC password file holds the default password" vnc_passwd_holds password
check "default VNC password warning is logged" wait_log '^\[start\] warning: PASSWORD is not set'
check "VNC accepts the default password" vnc_accepts password

# A chain that the firewall cannot read is not an empty chain: it must change nothing, although iptables-restore
# would work. The watch checks the rules at least once in 6 seconds.
echo "--- while iptables fails and iptables-restore works ---"
failing_from=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "failing iptables is installed" install_failing_command iptables
check "firewall.sh apply fails" sh -c '! docker exec -e VPN_TUN=cscotun0 cisco-vpn firewall.sh apply'
sleep 6
check "failing iptables is removed" in_c rm /usr/local/sbin/iptables
run_firewall_checks
check "firewall logged one failure and no repair" firewall_logged_one_failure "$failing_from"

# Without its firewall rules the container would accept connections from the VPN side, so it must stop instead.
# The restart makes start.sh find the failing commands first in PATH; the recreate of the next section removes them.
echo "--- while the firewall rules cannot be put in place ---"
check "failing iptables is installed" install_failing_command iptables
check "failing iptables-restore is installed" install_failing_command iptables-restore
check "container restarts" docker restart cisco-vpn
check "container exits with an error" container_exits_with_error
check "firewall failure is logged" wait_log '^\[start\] error: cannot put the firewall rules in place'
check "vpnagentd is not started" vpnagentd_logged_nothing

echo "--- with SOCKS_USER and SOCKS_PASSWD set ---"
check "container is recreated with SOCKS_USER and SOCKS_PASSWD" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER=u SOCKS_PASSWD=p NODANTED=
check "services started after recreate" wait_ready
check "danted listens on port 1080" wait_danted
check "SOCKS5 proxy refuses a client without a username" socks5_refuses socks5h://127.0.0.1:1080
check "SOCKS5 proxy refuses a wrong password" socks5_refuses socks5h://u:wrong@127.0.0.1:1080
check "SOCKS5 proxy accepts SOCKS_USER and SOCKS_PASSWD" socks5_works socks5h://u:p@127.0.0.1:1080
# The restart finds the account that the first start created for SOCKS_USER and sets its password again
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
check "danted listens on port 1080 after restart" wait_danted
check "SOCKS5 proxy refuses a client without a username after restart" socks5_refuses socks5h://127.0.0.1:1080
check "SOCKS5 proxy accepts SOCKS_USER and SOCKS_PASSWD after restart" socks5_works socks5h://u:p@127.0.0.1:1080

# Without SOCKS_PASSWD the proxy needs no username, as in docker-easyconnect
echo "--- with only SOCKS_USER set ---"
check "container is recreated with only SOCKS_USER" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER=u SOCKS_PASSWD= NODANTED=
check "services started after recreate" wait_ready
run_socks5_checks
check "empty SOCKS_PASSWD warning is logged" wait_log '^\[start\] warning: SOCKS_USER is set but SOCKS_PASSWD is empty'

# A SOCKS_PASSWD that cannot be set leaves the proxy off, so no older password of SOCKS_USER's account is accepted.
# The account u is made by hand as an earlier start would have left it: with the comment that start.sh gives
# the accounts it creates and the password "old". The restart runs start.sh with that account in place.
echo "--- with a SOCKS_PASSWD that cannot be set ---"
check "container is recreated with a SOCKS_PASSWD of two lines" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER=u SOCKS_PASSWD=$'new\nroot:x' NODANTED=
check "services started after recreate" wait_ready
check "refused SOCKS_PASSWD is logged" wait_log '^\[start\] error: SOCKS_PASSWD contains a newline'
check "danted is not started" danted_is_off
check "root has no password" account_has_no_password root
check "account u with the password old is created" in_c sh -c \
    'useradd -r -M -s /usr/sbin/nologin -c "SOCKS5 proxy account" u && echo u:old | chpasswd'
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
check "refused SOCKS_PASSWD is logged after restart" wait_log '^\[start\] error: SOCKS_PASSWD contains a newline'
check "danted is not started after restart" danted_is_off
check "SOCKS5 proxy does not accept the old password" socks5_fails socks5h://u:old@127.0.0.1:1080

# SOCKS_USER must not take over an account that start.sh did not create for the proxy
for account in root vpnuser socks; do
    echo "--- with SOCKS_USER=$account ---"
    check "container is recreated with SOCKS_USER=$account" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
        SOCKS_USER="$account" SOCKS_PASSWD=p NODANTED=
    check "services started after recreate" wait_ready
    check "refused SOCKS_USER is logged" wait_log "^\[start\] error: SOCKS_USER names the existing account $account,"
    check "danted is not started" danted_is_off
    check "$account has no password" account_has_no_password "$account"
done

echo "--- with a malformed SOCKS_USER ---"
check "container is recreated with SOCKS_USER=bad:name" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER=bad:name SOCKS_PASSWD=p NODANTED=
check "services started after recreate" wait_ready
check "refused SOCKS_USER is logged" wait_log '^\[start\] error: SOCKS_USER is not a valid user name'
check "danted is not started" danted_is_off
check "no account is created" in_c sh -c '! grep "^bad" /etc/passwd'

# run_checks takes several seconds, so danted would be listening by the end of it if it had been started
echo "--- with NODANTED set ---"
check "container is recreated with NODANTED" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER= SOCKS_PASSWD= NODANTED=1
check "services started after recreate" wait_ready
check "NODANTED is logged" wait_log '^\[start\] NODANTED is set'
run_checks
check "danted does not run" in_c sh -c '! pgrep -x danted'
check "nothing listens on port 1080" in_c sh -c '! ss -ltn | grep ":1080 "'

# The keepalive starts just before the ready line and pings for the first time one PING_INTERVAL later;
# a ping that gets no answer gives up after 1 second
echo "--- with PING_ADDR set to an address that does not answer ---"
check "container is recreated with PING_ADDR=$unreachable_addr and PING_INTERVAL=2" recreate CISCO_VPN_DATA="$test_data" \
    PASSWORD= VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR="$unreachable_addr" PING_ADDR_URL= PING_INTERVAL=2
check "services started after recreate" wait_ready
ready_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "unreachable PING_ADDR is logged within 10 seconds" \
    wait_log "^\[keepalive\] $unreachable_addr unreachable\$" "$ready_at" 10

echo "--- with PING_ADDR and PING_ADDR_URL set to the container's own address ---"
check "container is recreated with PING_ADDR, PING_ADDR_URL and PING_INTERVAL=2" recreate CISCO_VPN_DATA="$test_data" \
    PASSWORD= VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR=127.0.0.1 PING_ADDR_URL="$keepalive_url" PING_INTERVAL=2
check "services started after recreate" wait_ready
run_keepalive_url_checks
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
run_keepalive_url_checks

# The stop's signal must reach a request in progress, so that it ends with the other services
echo "--- while a keepalive request waits for a server that never answers ---"
check "server that never answers is started in the container" docker exec -d cisco-vpn python3 -c "$silent_server"
check "container stops during the request" stop_during_stalled_request

# The keepalive starts its first wait before the ready line
echo "--- with PING_INTERVAL empty ---"
check "container is recreated with PING_ADDR and PING_INTERVAL empty" recreate CISCO_VPN_DATA="$test_data" \
    PASSWORD= VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR="$unreachable_addr" PING_ADDR_URL= PING_INTERVAL=
check "services started after recreate" wait_ready
check "keepalive waits 1800 seconds by default" in_c pgrep -fx 'sleep 1800'

# An interval of 0 seconds would ping and request without a pause, so the keepalive must not start at all, with
# this interval or with the default one
echo "--- with a PING_INTERVAL of 0 ---"
check "container is recreated with PING_INTERVAL=0" recreate CISCO_VPN_DATA="$test_data" \
    PASSWORD= VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR="$unreachable_addr" PING_ADDR_URL="$keepalive_url" \
    PING_INTERVAL=0
check "services started after recreate" wait_ready
check "refused PING_INTERVAL is logged" wait_log '^\[start\] error: PING_INTERVAL is not a whole number of seconds above 0'
check "keepalive does not run" keepalive_is_off

# A preference file that already exists holds the user's choices and must be kept as a whole:
# the edit turns LocalLanAccess off and adds a gateway address, and the file is compared byte for byte
echo "--- with a preference changed by the user ---"
check "LocalLanAccess is changed to false and a gateway is added" in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
    sh -c "sed -i -e 's#<LocalLanAccess>true</LocalLanAccess>#<LocalLanAccess>false</LocalLanAccess>#' -e 's#^<ControllablePreferences>#<DefaultHostName>vpn.example.com</DefaultHostName>\n&#' /home/vpnuser/$prefs && grep -q '<LocalLanAccess>false</LocalLanAccess>' /home/vpnuser/$prefs && grep -q '<DefaultHostName>vpn.example.com</DefaultHostName>' /home/vpnuser/$prefs"
check "edited preference file is copied for comparison" cp "$test_data/$prefs" "$edited_prefs"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data"
check "services started after recreate" wait_ready
# cmp fails when either file is missing
check "edited preference file is unchanged" cmp "$edited_prefs" "$test_data/$prefs"
check "changed preference is kept in the file" grep -q '<LocalLanAccess>false</LocalLanAccess>' "$test_data/$prefs"
check "vpnui logged its preferences" wait_prefs_logged
check "vpnui reads the changed preference" local_lan_access_is false

# A passwd.new left next to the password file must not decide the new file's mode
echo "--- with PASSWORD and VNC_SIZE set ---"
check "passwd.new with mode 644 is created" plant_passwd_new file
check "container is recreated with PASSWORD and VNC_SIZE" recreate CISCO_VPN_DATA="$test_data" PASSWORD="$long_password" VNC_SIZE=1024x768
check "services started after recreate" wait_ready
check "VNC password file holds the first 8 characters of PASSWORD" vnc_passwd_holds "${long_password:0:8}"
check "VNC password file is a regular file of vpnuser's with mode 600" vnc_passwd_is_private
check "VNC accepts the first 8 characters of PASSWORD" vnc_accepts "${long_password:0:8}"
check "VNC rejects the default password" vnc_rejects password
check "VNC rejects the characters of PASSWORD after the first 255" vnc_rejects xyz
check "VNC size is VNC_SIZE" vnc_size_is 1024x768
check "VNC password file is copied for comparison" cp "$test_data/$vnc_passwd" "$saved_vnc_passwd"

# An empty PASSWORD keeps the saved password
echo "--- with PASSWORD and VNC_SIZE empty ---"
check "container is recreated with PASSWORD and VNC_SIZE empty" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE=
check "services started after recreate" wait_ready
# cmp fails when either file is missing
check "VNC password file is unchanged" cmp "$saved_vnc_passwd" "$test_data/$vnc_passwd"
check "VNC accepts the first 8 characters of the saved PASSWORD" vnc_accepts "${long_password:0:8}"
check "default VNC size is 1280x720" vnc_size_is 1280x720

echo "--- with PASSWORD of two lines ---"
check "container is recreated with PASSWORD of two lines" recreate CISCO_VPN_DATA="$test_data" PASSWORD="$two_line_password" VNC_SIZE=
check "services started after recreate" wait_ready
check "VNC password file holds the first line of PASSWORD" vnc_passwd_holds pw1
check "VNC accepts the first line of PASSWORD" vnc_accepts pw1
check "VNC rejects the second line of PASSWORD" vnc_rejects pw2

# A failed write keeps the saved password, also when a link named passwd.new leads to the password file
# itself. The write fails because vpnuser cannot create files in a read-only .vnc.
echo "--- with a failed write and a link named passwd.new ---"
check "VNC password file is copied for comparison" cp "$test_data/$vnc_passwd" "$saved_vnc_passwd"
check "passwd.new is created as a link to the VNC password file" plant_passwd_new link
check ".vnc is made read-only" in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups chmod 500 /home/vpnuser/.vnc
check "container is recreated with another PASSWORD" recreate CISCO_VPN_DATA="$test_data" PASSWORD=another1 VNC_SIZE=
check "services started after recreate" wait_ready
check "failed write is logged" wait_log '^\[start\] warning: cannot write the VNC password file'
check "VNC password file is unchanged" cmp "$saved_vnc_passwd" "$test_data/$vnc_passwd"
check "VNC accepts the saved password" vnc_accepts pw1

echo "--- back on the configured data directory ---"
check "container is recreated" recreate
check "services started after recreate" wait_ready

finish
