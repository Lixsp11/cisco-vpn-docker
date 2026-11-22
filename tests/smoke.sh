#!/bin/bash
# Smoke tests that need no VPN login. Run on the Docker host after `docker compose up -d --build`.
# Waits until the container is ready, runs every check, restarts the container, waits again
# and runs every check once more. Then checks the persistent home directory: it recreates the container
# on an empty data directory of its own under the repository's tmp/, changes a preference there and
# recreates the container again, recreates it with PASSWORD and VNC_SIZE set, once more with both empty and
# once with a PASSWORD of two lines, restarts it with a link named passwd.new next to the VNC password file,
# and finally recreates it on the configured data directory.
# The test data directory and the copies of the files compared across a recreate are removed at the start
# of these checks and left in place afterwards.
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
# Copy of the VNC password file written for PASSWORD, compared with the file after a recreate without PASSWORD
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
}

check "services started" wait_ready
run_checks

echo "--- after docker restart ---"
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
run_checks

# Docker creates a missing data directory as root
echo "--- on an empty data directory ---"
check "test data directory is removed" rm -rf "$test_data" "$edited_prefs" "$saved_vnc_passwd"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE=
check "services started after recreate" wait_ready
run_checks
check "default preferences are in the test data directory" test -f "$test_data/$prefs"
check "VNC password file holds the default password" vnc_passwd_holds password
check "default VNC password warning is logged" wait_log '^\[start\] warning: PASSWORD is not set'
check "VNC accepts the default password" vnc_accepts password

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

# A link named passwd.new must not lead the write to the password file itself
echo "--- with a link named passwd.new ---"
check "passwd.new is created as a link to the VNC password file" plant_passwd_new link
check "container restarts" docker restart cisco-vpn
check "services started after restart" wait_ready
check "VNC password file is a regular file of vpnuser's with mode 600" vnc_passwd_is_private
check "VNC password file holds the first line of PASSWORD" vnc_passwd_holds pw1
check "VNC accepts the first line of PASSWORD" vnc_accepts pw1

echo "--- back on the configured data directory ---"
check "container is recreated" recreate
check "services started after recreate" wait_ready

finish
