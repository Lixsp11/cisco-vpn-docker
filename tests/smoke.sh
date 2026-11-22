#!/bin/bash
# Smoke tests that need no VPN login. Run on the Docker host after `docker compose up -d --build`.
# Waits until the container is ready and runs every check. Stops danted twice, the second time while a tunnel
# interface of another address exists, and checks the SOCKS5 proxy after run_service restarts it. Puts a rule
# before the firewall's rules in INPUT and in FORWARD, as the VPN client may do when it connects, checks that the
# firewall moves its rules back to the top and keeps the other rule, and removes that rule again. Restarts the
# container, waits again and runs every check once more, then restarts it once more while giving the temporary
# tunnel interface its address fails. Then recreates the container on an empty data directory of its own under
# the repository's tmp/ and runs every check there. On that directory it restarts the container while iptables
# and iptables-restore fail and checks that it stops before it starts the VPN client. It recreates the container
# with SOCKS_USER and SOCKS_PASSWD set and restarts it, recreates it with only SOCKS_USER set, with a SOCKS_PASSWD
# that cannot be set (and restarts it with an account of the proxy's left from an earlier start), with
# SOCKS_USER naming each of the image's accounts and a malformed SOCKS_USER, and with NODANTED set. Then it
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

# Succeed when the last "Current Preference Settings" line of vpnui (csc_ui) has LocalLanAccess: $1
local_lan_access_is() {
    local line
    line=$(docker logs cisco-vpn 2>&1 | grep "csc_ui" | grep "Current Preference Settings" | tail -1)
    grep -q "LocalLanAccess: $1" <<<"$line" && return 0
    echo "last csc_ui preference line has '$(grep -o 'LocalLanAccess: [a-z]*' <<<"$line")'"
    return 1
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

# Succeed when each of the firewall's rules appears exactly once in the container's filter and nat tables.
# iptables -S may print the conntrack states in either order.
firewall_rules_are_unique() {
    local rules rule count
    rules=$(in_c sh -c 'iptables -S && iptables -t nat -S') || return 1
    for rule in \
        '-A INPUT -m conntrack --ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT' \
        '-A INPUT -i cscotun0 -p tcp -j DROP' \
        '-A FORWARD -i eth0 -o cscotun0 -j ACCEPT' \
        '-A FORWARD -i cscotun0 -o eth0 -m conntrack --ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT' \
        '-A POSTROUTING -o cscotun0 -j MASQUERADE'; do
        count=$(grep -cxE -- "$rule" <<<"$rules")
        if [ "$count" != 1 ]; then
            echo "'$rule' appears $count times"
            return 1
        fi
    done
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

# Checks of the firewall's rules and of forwarding for route mode
# The single-quoted commands are expanded by the sh -c that runs them
# shellcheck disable=SC2016
run_firewall_checks() {
    check "container forwards IPv4 packets" in_c sh -c '[ "$(sysctl -n net.ipv4.ip_forward)" = 1 ]'
    check "container is created with net.ipv4.ip_forward=1" ip_forward_is_set
    check "INPUT starts with the firewall's two rules" in_c sh -c 'iptables -S INPUT | sed -n 2,3p | tr "\n" " " | grep -qE -- "(RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT.*-i cscotun0 -p tcp -j DROP"'
    check "FORWARD starts with the firewall's two rules" in_c sh -c 'iptables -S FORWARD | sed -n 2,3p | tr "\n" " " | grep -q -- "-i eth0 -o cscotun0 -j ACCEPT.*-i cscotun0 -o eth0"'
    check "traffic out of the tunnel is masqueraded" in_c sh -c 'iptables -t nat -S POSTROUTING | grep -q -- "-o cscotun0 -j MASQUERADE"'
    check "each firewall rule appears once" firewall_rules_are_unique
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
sleep 12
run_firewall_checks
check "inserted rules are kept" in_c sh -c 'iptables -S INPUT | grep -qx -- "-A INPUT -j RETURN" && iptables -S FORWARD | grep -qx -- "-A FORWARD -j RETURN"'
check "firewall logged one repair of INPUT and one of FORWARD" firewall_repaired_input_and_forward_once "$inserted_at"
check "inserted rules are removed" in_c sh -c 'iptables -D INPUT -j RETURN && iptables -D FORWARD -j RETURN && ! iptables -S | grep -q -- "-j RETURN"'

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
