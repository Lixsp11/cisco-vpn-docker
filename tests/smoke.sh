#!/bin/bash
# Smoke tests that need no VPN login. Run as root on the Docker host after `docker compose up -d --build`.
# Preconditions and side effects (also in doc/usage.md, Tests):
#   - It restarts and recreates the configured container cisco-vpn, which ends any VPN session, and finally
#     recreates it with the configured settings. After an interrupted run, `docker compose up -d --force-recreate`
#     brings back the configured container.
#   - It needs internet access: the proxy checks request https://deb.debian.org/.
#   - The first checks run on the configured container and data directory: .env must set none of VNC_SIZE,
#     NODANTED, SOCKS_USER and SOCKS_PASSWD, and the saved preferences must keep LocalLanAccess true.
#   - The cases that change the data directory use tmp/smoke-data in the repository.
#   - On the openconnect image, the configured container starts openconnect for the configured VPN_SERVER, which
#     connects to that gateway without logging in: at the first checks, at its two restarts and at the final
#     recreate.
#
# Waits until the container is ready and runs every check. Stops danted twice, the second time while a tunnel
# interface of another address exists, and checks the SOCKS5 proxy after run_service restarts it. Puts a rule
# before the firewall's rules in INPUT and in FORWARD, as the VPN client may do when it connects, and replaces the
# firewall's DROP rule with an unmarked copy at the end of INPUT, all in one transaction; checks that the firewall
# puts its rules back at the top and leaves the other rules in their order, and removes those rules again. Restarts
# the container, waits again and runs every check once more, then restarts it once more while giving the temporary
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
# 0. It recreates it with VPN_SERVER set, checks the client profile and restarts it, runs vpn_prepare again in it
# with valid and invalid VPN_SERVER values after a profile was written, and with a directory in the profile's
# place, and recreates it with a VPN_SERVER that is not a host name. Then it checks the persistent home directory: it replaces the default preference file
# with one of the user's and recreates the container again, recreates it with PASSWORD and VNC_SIZE set, once more with both empty and once with a PASSWORD of two lines, once with
# another PASSWORD that cannot be written because the VNC password's directory is read-only, and finally
# recreates it on the configured data directory.
# The test data directory and the copies of the files compared across a recreate are removed before the
# container is recreated on it and left in place afterwards.
# The checks follow the VPN client of the container's image, cisco or openconnect, as its build wrote it to
# /etc/vpn-type: the tunnel interface is the client's, and the image must hold only that client's software, and
# diag.sh must print that client's version. The checks of the Cisco client's processes, login record, preferences
# and client profile, of the unmounted resolv.conf and hosts, and of the VPN_SERVER cases above run only on the
# Cisco image. On the openconnect image, every recreate but the final one leaves VPN_SERVER empty unless it sets
# it, so that openconnect connects to the configured gateway only in the configured container; the checks of the
# empty data directory also check that
# the login terminal waits for VPN_SERVER, which is logged once, and that the callback port is not forwarded. Then
# it recreates the container with VPN_SERVER=127.0.0.1 and CLI_OPTS set: it checks that the host reaches a test
# listener on [::1]:29786 in the container through 127.0.0.1:29786 and cannot reach VNC on 5901, then starts a test
# gateway in the container that asks for single sign-on in an external browser, and checks that the login URL is
# logged, that openconnect runs with --interface=tun0 before the arguments of CLI_OPTS and listens for the callback, and
# that the host reaches that listener, also after it stops socat and closes the login terminal. Then it recreates the
# container with CLI_OPTS=--interface=tun1 and checks that openconnect is refused, and checks how the container
# splits other values of CLI_OPTS and which of them set the tunnel interface.
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
# Client profile that the container writes from VPN_SERVER, and the gateway address of the checks (a reserved
# example domain)
csc_profile=/opt/cisco/secureclient/vpn/profile/cisco-vpn-docker.xml
test_server=vpn.example.com
# Host name labels of the longest length allowed and one character longer, and a host name of more than 253
# characters
label63=$(printf '%063d' 0 | tr 0 a)
label64=${label63}a
too_long_server=$label63.$label63.$label63.$label63
# Address of the documentation range (TEST-NET-1) that no host answers, for the keepalive's failed pings
unreachable_addr=192.0.2.1
# Web server that the keepalive checks start in the container for PING_ADDR_URL, and the file of its request log
keepalive_url=http://127.0.0.1:18080/
keepalive_log=/tmp/ka.log

# Port of openconnect's listener for the callback of a single sign-on in an external browser, which the compose file
# publishes on the host's 127.0.0.1
callback_port=29786
# Test gateway of the openconnect checks, in the container: its address, the certificate file that it writes and
# openconnect trusts through CLI_OPTS, and the login URL that it gives openconnect
test_gateway=127.0.0.1
test_gateway_cert=/tmp/smoke-gateway.pem
test_login_url=https://127.0.0.1/smoke-sso-login
# CLI_OPTS of the openconnect checks; it must reach openconnect as the three arguments --cafile=<certificate file>,
# --useragent=smoke test agent and -u. The -u at its end takes the next argument as its value, which must be neither
# --interface=tun0 nor the gateway.
test_cli_opts="--cafile=$test_gateway_cert --useragent='smoke test agent' -u"
# External browser of openconnect, which prints the login URL
login_url_printer=/usr/local/bin/print-login-url.sh

# Test gateway for openconnect: an HTTPS server on 127.0.0.1:443 that answers openconnect's first request, the
# XML POST of the AnyConnect protocol, with a login form that asks for single sign-on in an external browser. The
# form is the one that a Cisco gateway sent openconnect 9.01 for single sign-on, with sso-v2-browser-mode
# "external" added, which makes openconnect run its external browser (process_auth_form in library.c). It writes a
# self-signed certificate for 127.0.0.1 to argv[1] and its key next to it before it listens.
gateway_server=$(
    cat <<'EOF'
import datetime
import http.server
import ipaddress
import ssl
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

AUTH_REQUEST = b"""<?xml version="1.0" encoding="UTF-8"?>
<config-auth client="vpn" type="auth-request" aggregate-auth-version="2">
<opaque is-for="sg">
<tunnel-group>smoke</tunnel-group>
<auth-method>single-sign-on-v2</auth-method>
<auth-method>single-sign-on-external-browser</auth-method>
</opaque>
<auth id="main">
<title>Login</title>
<message>Log in with single sign-on.</message>
<sso-v2-login>https://127.0.0.1/smoke-sso-login</sso-v2-login>
<sso-v2-login-final>https://127.0.0.1/smoke-sso-final</sso-v2-login-final>
<sso-v2-token-cookie-name>acSamlv2Token</sso-v2-token-cookie-name>
<sso-v2-browser-mode>external</sso-v2-browser-mode>
<form>
<input type="sso" name="sso-token"></input>
</form>
</auth>
</config-auth>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(AUTH_REQUEST)))
        self.end_headers()
        self.wfile.write(AUTH_REQUEST)


cert_file = sys.argv[1]
key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now - datetime.timedelta(hours=1))
    .not_valid_after(now + datetime.timedelta(days=1))
    .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
    .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
    .sign(key, hashes.SHA256())
)
with open(cert_file + ".key", "wb") as f:
    f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
with open(cert_file, "wb") as f:
    f.write(cert.public_bytes(serialization.Encoding.PEM))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert_file, cert_file + ".key")
server = http.server.HTTPServer(("127.0.0.1", 443), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
EOF
)

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

# Checks the client profile argv[1] against argv[2]. The profile must have exactly the structure that the
# container writes, which was validated against the client's AnyConnectProfile.xsd: ClientInitialization with
# LocalLanAccess true and UserControllable true, and a ServerList with one HostEntry whose HostName and
# HostAddress are argv[2]. Exits with a message on the first difference.
profile_check=$(
    cat <<'EOF'
import sys
import xml.etree.ElementTree as ET

NS = "{http://schemas.xmlsoap.org/encoding/}"


def tags(element):
    return [child.tag.replace(NS, "") for child in element]


root = ET.parse(sys.argv[1]).getroot()
if root.tag != NS + "AnyConnectProfile":
    sys.exit(f"root element is {root.tag}")
if tags(root) != ["ClientInitialization", "ServerList"]:
    sys.exit(f"profile has {tags(root)}")
init, servers = root
if tags(init) != ["LocalLanAccess"]:
    sys.exit(f"ClientInitialization has {tags(init)}")
if init[0].text != "true" or init[0].attrib != {"UserControllable": "true"}:
    sys.exit(f"LocalLanAccess is {init[0].text!r} with {init[0].attrib}")
if tags(servers) != ["HostEntry"]:
    sys.exit(f"ServerList has {tags(servers)}")
if tags(servers[0]) != ["HostName", "HostAddress"]:
    sys.exit(f"HostEntry has {tags(servers[0])}")
name, address = servers[0]
if name.text != sys.argv[2] or address.text != sys.argv[2]:
    sys.exit(f"HostEntry has {name.text!r} and {address.text!r}")
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
# an empty assignment such as PASSWORD= replaces a value set in .env. On the openconnect image, VPN_SERVER is empty
# unless an argument sets it, so that openconnect connects to the configured gateway only in the configured container.
recreate() {
    local defaults=()
    [ "$vpn_type" = openconnect ] && defaults=(VPN_SERVER=)
    env "${defaults[@]}" "$@" docker compose -f "$repo/docker-compose.yml" up -d --force-recreate
}

# Recreate the container with the configured settings of the compose file and .env
recreate_configured() {
    docker compose -f "$repo/docker-compose.yml" up -d --force-recreate
}

# Wait until vpnui (csc_ui) of the container's current start has logged the preferences it read
wait_prefs_logged() {
    wait_log 'csc_ui\[[0-9]+\]: .*Current Preference Settings'
}

# Succeed when the client profile in the container is a regular file of root's with mode 644 that lists the
# gateway $1 and turns on local LAN access
profile_lists() {
    local file_info
    file_info=$(in_c stat -c '%F %U:%G %a' "$csc_profile") || return 1
    if [ "$file_info" != "regular file root:root 644" ]; then
        echo "client profile is: $file_info"
        return 1
    fi
    in_c python3 -c "$profile_check" "$csc_profile" "$1"
}

# Succeed when the client profile in the container is $1, "present" or "absent", and the profile directory holds
# no temporary file of the profile (cisco-vpn-docker.xml.*). The directory's other files come with the Cisco
# package and are not checked.
profile_is() {
    local files name state=absent
    name=$(basename "$csc_profile")
    files=$(in_c ls -A "$(dirname "$csc_profile")") || return 1
    grep -qxF -- "$name" <<<"$files" && state=present
    if [ "$state" = "$1" ] && ! grep -qF -- "$name." <<<"$files"; then
        return 0
    fi
    printf 'the client profile is %s, expected %s; the profile directory holds:\n%s\n' "$state" "$1" "$files"
    return 1
}

# Succeed when the entrypoint logged no line about VPN_SERVER since the container's current start
nothing_logged_about_vpn_server() {
    local since lines
    since=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    lines=$(docker logs --since "$since" cisco-vpn 2>&1 | grep '^\[start\].*VPN_SERVER')
    [ -z "$lines" ] && return 0
    printf '%s\n' "$lines"
    return 1
}

# Run vpn-cisco.sh's vpn_prepare again in the container with VPN_SERVER=$1, as start.sh runs it at start, and
# print what it logs. The run keeps the container's file system, with the profile of earlier runs.
rerun_prepare() {
    # The single-quoted script is expanded by the bash that runs it
    # shellcheck disable=SC2016
    docker exec -e VPN_SERVER="$1" cisco-vpn bash -c \
        'log() { echo "[start] $*"; }; VPN_USER=vpnuser; source /usr/local/bin/vpn-cisco.sh; vpn_prepare' 2>&1
}

# Succeed when vpn_prepare, run again with VPN_SERVER=$1, logs nothing and writes a profile for it
accepts_server() {
    local output
    output=$(rerun_prepare "$1") || return 1
    if [ -n "$output" ]; then
        printf 'vpn_prepare logged:\n%s\n' "$output"
        return 1
    fi
    profile_lists "$1" && profile_is present
}

# Succeed when vpn_prepare, run again with VPN_SERVER=$1 after a run that wrote a profile, logs a line that
# matches the extended regular expression $2 and removes that profile
removes_profile_for() {
    local output
    accepts_server "$test_server" || return 1
    output=$(rerun_prepare "$1")
    if ! grep -qE "$2" <<<"$output"; then
        printf 'vpn_prepare logged:\n%s\n' "$output"
        return 1
    fi
    profile_is absent
}

# Succeed when vpn_prepare, run again with VPN_SERVER=$1 while a directory that is not empty has the profile's
# name, logs a line that matches $2 and leaves the directory as it is. The directory is removed afterwards.
logs_profile_failure() {
    local output status=0
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    in_c sh -c 'rm -f "$1" && mkdir "$1" && touch "$1/keep"' sh "$csc_profile" || return 1
    output=$(rerun_prepare "$1")
    grep -qE "$2" <<<"$output" && in_c test -f "$csc_profile/keep" || status=1
    in_c rm -r "$csc_profile" || status=1
    [ "$status" = 0 ] && return 0
    printf 'vpn_prepare logged:\n%s\n' "$output"
    return 1
}

# Write a preference file of the user's to the container, as vpnuser and in the client's own format: it names
# a gateway and turns LocalLanAccess off
write_user_prefs() {
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    docker exec -i cisco-vpn setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
        sh -c 'mkdir -p "$(dirname "$1")" && cat >"$1"' sh "/home/vpnuser/$prefs" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectPreferences>
<DefaultHostName>$test_server</DefaultHostName>
<ControllablePreferences>
<LocalLanAccess>false</LocalLanAccess></ControllablePreferences>
</AnyConnectPreferences>
EOF
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

# Succeed when the tunnel interface does not exist in the container
tunnel_interface_is_gone() {
    # The single-quoted script is expanded by the sh that runs it, and set_vpn_tun in lib.sh sets vpn_tun
    # shellcheck disable=SC2016,SC2154
    in_c sh -c '! ip link show "$1"' sh "$vpn_tun"
}

# Succeed when the tunnel interface is missing at least once in about 3 seconds. While giving the temporary
# interface its address fails, run_service retries every second, and each try creates the interface and removes it
# at once, so only an interface that stays exists every time.
tunnel_interface_is_not_kept() {
    for _ in $(seq 10); do
        # The single-quoted script is expanded by the sh that runs it
        # shellcheck disable=SC2016
        in_c sh -c '! ip link show "$1" >/dev/null 2>&1' sh "$vpn_tun" && return 0
        sleep 0.3
    done
    echo "$vpn_tun exists on every try"
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

# Succeed when every TCP socket in the container that listens on IPv6 listens on the loopback address ::1. The
# firewall's rules are IPv4 rules, so a service on any other IPv6 address, or on all of them, could be reached from
# the VPN side.
only_loopback_listens_on_ipv6() {
    local listeners others
    listeners=$(in_c ss -Hltn -6) || return 1
    others=$(awk '$4 !~ /^\[::1\]:/' <<<"$listeners")
    [ -z "$others" ] && return 0
    printf 'TCP sockets that listen on IPv6 addresses other than ::1:\n%s\n' "$others"
    return 1
}

# Succeed when vpnui runs and no process of vpnuser's has PASSWORD or SOCKS_PASSWD in its environment. The
# container's root lacks CAP_SYS_PTRACE and cannot read the environment of another user's processes, so the check
# runs as vpnuser. It runs without these variables itself, which docker exec gives it from the container's settings.
gui_has_no_secrets() {
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    docker exec cisco-vpn env -u PASSWORD -u SOCKS_PASSWD setpriv --reuid=vpnuser --regid=vpnuser --init-groups sh -c '
        pgrep -u vpnuser -x vpnui >/dev/null || { echo "vpnui is not running"; exit 1; }
        found=
        for pid in $(pgrep -u vpnuser); do
            names=$(tr "\0" "\n" 2>/dev/null <"/proc/$pid/environ" | grep -oE "^(PASSWORD|SOCKS_PASSWD)=")
            [ -z "$names" ] || { echo "process $pid has" $names; found=1; }
        done
        [ -z "$found" ]'
}

# In one iptables-restore transaction, insert a rule at the top of INPUT and of FORWARD and replace the firewall's
# DROP rule with an unmarked copy at the end of INPUT
displace_firewall_rules() {
    docker exec -i cisco-vpn iptables-restore -w 5 --noflush <<EOF
*filter
-I INPUT 1 -j RETURN
-I FORWARD 1 -j RETURN
-D INPUT -i $vpn_tun -p tcp $fw_mark -j DROP
-A INPUT -i $vpn_tun -p tcp -j DROP
COMMIT
EOF
}

# Checks of the SOCKS5 proxy of a container started without SOCKS_PASSWD and NODANTED, while no VPN is
# connected. The temporary tunnel interface for danted's start is removed before danted's ready line is logged.
run_socks5_checks() {
    check "danted listens on port 1080" wait_danted
    check "SOCKS5 port is danted's" socks5_port_is_danteds
    check "SOCKS5 proxy works" socks5_works socks5h://127.0.0.1:1080
    check "no temporary tunnel interface is left" tunnel_interface_is_gone
}

# Succeed when diag.sh in the container prints the version of the image's client and no error about a missing
# file or package, as it would for the other client's
diag_shows_client() {
    local output pattern
    output=$(in_c diag.sh) || return 1
    case $vpn_type in
        cisco) pattern='^cisco-secure-client-vpn [0-9]' ;;
        openconnect) pattern='^OpenConnect version v[0-9]' ;;
    esac
    if ! grep -qE "$pattern" <<<"$output"; then
        echo "diag.sh prints no line that matches '$pattern'"
        return 1
    fi
    ! grep -E 'No such file or directory|no packages found' <<<"$output"
}

# Succeed when the login terminal of the openconnect image waits without openconnect: the only process that the
# xterm runs is sleep infinity
login_terminal_waits() {
    local xterm_pid children
    xterm_pid=$(in_c pgrep -x xterm) || {
        echo "xterm is not running"
        return 1
    }
    children=$(in_c pgrep -a -P "$xterm_pid")
    if [ "$(grep -c . <<<"$children")" != 1 ] || ! grep -qE '^[0-9]+ sleep infinity$' <<<"$children"; then
        printf 'the processes of the xterm are:\n%s\n' "$children"
        return 1
    fi
    ! in_c pgrep -a -x openconnect
}

# Succeed when, after the container has run for 15 seconds, the entrypoint has logged exactly one line about
# VPN_SERVER since its current start, the error that it is not set, and the login terminal has logged nothing:
# run_service would log each restart of a terminal that exits, and openconnect-login.sh would pause 10 seconds
# between two starts of openconnect.
missing_vpn_server_logged_once() {
    local started lines
    started=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    while [ "$(date +%s)" -lt "$(($(date -d "$started" +%s) + 15))" ]; do
        sleep 1
    done
    lines=$(docker logs --since "$started" cisco-vpn 2>&1 | grep -E '^\[start\].*VPN_SERVER|^\[openconnect\]')
    if [ "$(grep -c . <<<"$lines")" = 1 ] && grep -q '^\[start\] error: VPN_SERVER is not set' <<<"$lines"; then
        return 0
    fi
    printf 'lines about VPN_SERVER and of the login terminal since %s:\n%s\n' "$started" "$lines"
    return 1
}

# Succeed when the callback port is not forwarded in the container: no nat rule redirects it and socat does not run
callback_port_is_not_forwarded() {
    local rules
    rules=$(in_c iptables -t nat -S PREROUTING) || return 1
    if grep -- "--dport $callback_port " <<<"$rules"; then
        return 1
    fi
    ! in_c pgrep -a -x socat
}

# Succeed when the entrypoint started no part of the openconnect login since the container's current start: it
# logged nothing about VPN_SERVER, which it does when it starts the login terminal without it, and the login
# terminal logged nothing
openconnect_logged_nothing() {
    local since
    since=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    ! docker logs --since "$since" cisco-vpn 2>&1 | grep -E '^\[start\].*VPN_SERVER|^\[openconnect\]'
}

# Start a web server on [::1]:29786 in the container, the address and port where openconnect listens for the
# callback, which answers the path /callback-test with "reached"
start_test_listener() {
    docker exec -d cisco-vpn sh -c "mkdir -p /tmp/smoke-callback && echo reached >/tmp/smoke-callback/callback-test &&
        exec python3 -m http.server $callback_port --bind ::1 --directory /tmp/smoke-callback"
}

# Succeed when the host gets "reached" for http://127.0.0.1:29786/callback-test within 10 seconds
host_reaches_test_listener() {
    local body deadline=$((SECONDS + 10))
    while [ "$SECONDS" -lt "$deadline" ]; do
        body=$(curl -fsS --noproxy '' --max-time 5 "http://127.0.0.1:$callback_port/callback-test" 2>&1) &&
            [ "$body" = reached ] && return 0
        sleep 1
    done
    echo "the host got: $body"
    return 1
}

# Succeed when the host can connect to port $1 of the container's address on the compose network; with "not" as $2,
# when it cannot
host_connects_to_port() {
    local ip status=0
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cisco-vpn) || return 1
    # The single-quoted script is expanded by the bash that runs it
    # shellcheck disable=SC2016
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$ip" "$1" 2>/dev/null || status=1
    if [ "${2:-}" = not ]; then
        [ "$status" = 1 ] && return 0
        echo "the host connects to $ip:$1"
        return 1
    fi
    [ "$status" = 0 ] && return 0
    echo "the host cannot connect to $ip:$1"
    return 1
}

# Succeed when openconnect runs in the container with exactly the arguments $@, the first one being its name
openconnect_argv_is() {
    local pid argv
    pid=$(in_c pgrep -x openconnect) || {
        echo "openconnect is not running"
        return 1
    }
    argv=$(in_c cat "/proc/$pid/cmdline" | tr '\0' '\n')
    [ "$argv" = "$(printf '%s\n' "$@")" ] && return 0
    printf 'openconnect runs with the arguments:\n%s\n' "$argv"
    return 1
}

# Succeed when the output of openconnect, which its external browser inherits, goes to the login terminal
openconnect_writes_to_terminal() {
    local pid fd target
    pid=$(in_c pgrep -x openconnect) || {
        echo "openconnect is not running"
        return 1
    }
    for fd in 1 2; do
        target=$(in_c readlink "/proc/$pid/fd/$fd") || return 1
        if ! [[ $target =~ ^/dev/pts/[0-9]+$ ]]; then
            echo "file descriptor $fd of openconnect is $target"
            return 1
        fi
    done
}

# Succeed when openconnect, and nothing else, listens on the callback port in the container, on [::1]
callback_listener_is_openconnects() {
    local listeners
    listeners=$(in_c ss -Hltnp "sport = :$callback_port") || return 1
    if [ "$(grep -c . <<<"$listeners")" = 1 ] &&
        grep -qE "^LISTEN .* \[::1\]:$callback_port .*\"openconnect\"" <<<"$listeners"; then
        return 0
    fi
    printf 'listeners on port %s:\n%s\n' "$callback_port" "$listeners"
    return 1
}

# Succeed when the host gets openconnect's answer to a request that is not a callback, 404 Not Found, from
# http://127.0.0.1:29786/callback-test within 10 seconds. openconnect closes the connection without an answer when the
# request line is shorter than 15 characters, as "GET / HTTP/1.1" is (handle_external_browser in hpke.c of
# openconnect 9.01).
host_reaches_callback_listener() {
    local code deadline=$((SECONDS + 10))
    while :; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '' --max-time 5 \
            "http://127.0.0.1:$callback_port/callback-test")
        [ "$code" = 404 ] && return 0
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 1
    done
    echo "the host got the status $code"
    return 1
}

# Succeed when, within 30 seconds, the login URL has been logged $1 times since the container's current start
login_url_logged_times() {
    local started count deadline=$((SECONDS + 30))
    started=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    while :; do
        count=$(docker logs --since "$started" cisco-vpn 2>&1 |
            grep -cxF "[openconnect] open this URL in your browser to log in: $test_login_url")
        [ "$count" -ge "$1" ] && return 0
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 1
    done
    echo "the login URL was logged $count times"
    return 1
}

# Print the arguments, one per line, that vpn-openconnect.sh in the container makes of CLI_OPTS=$1, and then
# "(sets the interface)" when they set openconnect's tunnel interface. Fails when it cannot split CLI_OPTS.
split_cli_opts() {
    # The single-quoted script is expanded by the bash that runs it
    # shellcheck disable=SC2016
    docker exec -e CLI_OPTS="$1" cisco-vpn bash -c 'source /usr/local/bin/vpn-openconnect.sh && parse_cli_opts || exit 1
        [ "${#CLI_ARGS[@]}" = 0 ] || printf "%s\n" "${CLI_ARGS[@]}"
        if sets_interface "${CLI_ARGS[@]}"; then echo "(sets the interface)"; fi'
}

# Succeed when vpn-openconnect.sh in the container makes exactly the arguments $2... of CLI_OPTS=$1, which do not
# set the tunnel interface
cli_opts_split_into() {
    local output
    output=$(split_cli_opts "$1") || {
        echo "CLI_OPTS cannot be split"
        return 1
    }
    [ "$output" = "$(printf '%s\n' "${@:2}")" ] && return 0
    printf 'CLI_OPTS is split into:\n%s\n' "$output"
    return 1
}

# Succeed when vpn-openconnect.sh in the container finds that CLI_OPTS=$1 sets the tunnel interface
cli_opts_set_interface() {
    local output
    output=$(split_cli_opts "$1") || {
        echo "CLI_OPTS cannot be split"
        return 1
    }
    [ "$(tail -n 1 <<<"$output")" = "(sets the interface)" ] && return 0
    printf 'CLI_OPTS is split into:\n%s\n' "$output"
    return 1
}

# Succeed when vpn-openconnect.sh in the container cannot split CLI_OPTS=$1
cli_opts_cannot_be_split() {
    local output
    output=$(split_cli_opts "$1") || return 0
    printf 'CLI_OPTS is split into:\n%s\n' "$output"
    return 1
}

# Succeed when exactly one openconnect runs in the container
one_openconnect_runs() {
    local processes
    processes=$(in_c pgrep -a -x openconnect)
    [ "$(grep -c . <<<"$processes")" = 1 ] && return 0
    printf 'openconnect processes:\n%s\n' "$processes"
    return 1
}

# Succeed when the container finds none of the commands $@; print the ones that it finds
commands_are_missing() {
    local cmd status=0
    for cmd; do
        # The single-quoted script is expanded by the sh that runs it
        # shellcheck disable=SC2016
        in_c sh -c 'command -v "$1"' sh "$cmd" && status=1
    done
    return "$status"
}

# Checks that the image holds only the software of its own client: the Cisco image has none of the openconnect
# image's packages, and the openconnect image has no Cisco files and no browser
run_image_checks() {
    local cmd
    case $vpn_type in
        cisco)
            check "openconnect, xterm and socat are not installed" commands_are_missing openconnect xterm socat
            ;;
        openconnect)
            check "no Cisco files are installed" in_c sh -c '! ls -d /opt/cisco'
            for cmd in openconnect xterm socat; do
                # The single-quoted script is expanded by the sh that runs it
                # shellcheck disable=SC2016
                check "$cmd is installed" in_c sh -c 'command -v "$1"' sh "$cmd"
            done
            check "no browser is installed" commands_are_missing chromium chromium-browser firefox firefox-esr
            ;;
    esac
}

# The single-quoted commands are expanded by the sh -c that runs them
# shellcheck disable=SC2016
run_checks() {
    # A recreate that started an image of another client would change which checks apply
    check "image is the $vpn_type image" in_c sh -c '[ "$(cat /etc/vpn-type)" = "$1" ]' sh "$vpn_type"
    check "noVNC page is reachable" curl -fsS -o /dev/null http://127.0.0.1:6080/vnc.html
    if [ "$vpn_type" = cisco ]; then
        check "resolv.conf is unmounted" in_c sh -c '! mountpoint -q /etc/resolv.conf'
        check "hosts is unmounted" in_c sh -c '! mountpoint -q /etc/hosts'
    fi
    check "DNS works in the container" in_c getent hosts deb.debian.org
    if [ "$vpn_type" = cisco ]; then
        check "vpnagentd runs as root" in_c sh -c '[ "$(ps -o user= -C vpnagentd | head -1)" = root ]'
        check "vpnui runs as vpnuser" in_c sh -c '[ "$(ps -o user= -C vpnui | head -1)" = vpnuser ]'
        check "vpnuser's processes have neither PASSWORD nor SOCKS_PASSWD" gui_has_no_secrets
        check "utmp record points to an ancestor of vpnui" in_c sh -c "$utmp_check"
    else
        check "login terminal runs as root" in_c sh -c '[ "$(ps -o user= -C xterm | head -1)" = root ]'
    fi
    # --noproxy '' keeps a NO_PROXY setting on the host from sending the request around the proxy
    check "HTTP proxy works" curl -fsS -o /dev/null --noproxy '' -x http://127.0.0.1:8888 https://deb.debian.org/
    check "only the loopback address ::1 listens on IPv6" only_loopback_listens_on_ipv6
    check "only NET_ADMIN and SYS_ADMIN are added" sh -c '[ "$(docker inspect -f "{{.HostConfig.CapAdd}}" cisco-vpn)" = "[CAP_NET_ADMIN CAP_SYS_ADMIN]" ]'
    if [ "$vpn_type" = cisco ]; then
        check "vpnui logged its preferences" wait_prefs_logged
        check "preferences allow local LAN access by default" local_lan_access_is true
    fi
    check "vpnuser can write its home" in_c setpriv --reuid=vpnuser --regid=vpnuser --init-groups \
        sh -c 'touch /home/vpnuser/.write-test && rm /home/vpnuser/.write-test'
    check "default VNC size is 1280x720" vnc_size_is 1280x720
    check "VNC reads the password file in vpnuser's home" in_c sh -c 'ps -o args= -C Xtigervnc | grep -q -- "-PasswordFile $1"' sh "/home/vpnuser/$vnc_passwd"
    check "VNC password file is a regular file of vpnuser's with mode 600" vnc_passwd_is_private
    run_firewall_checks
}

# The VPN client of the container's image and its tunnel interface
if ! vpn_type=$(docker exec cisco-vpn cat /etc/vpn-type); then
    echo "error: cannot read /etc/vpn-type in the container cisco-vpn; start it with docker compose up -d first"
    exit 1
fi
case $vpn_type in
    cisco) set_vpn_tun cscotun0 ;;
    openconnect) set_vpn_tun tun0 ;;
    *)
        echo "error: /etc/vpn-type in the container cisco-vpn names the unknown VPN client '$vpn_type'"
        exit 1
        ;;
esac
echo "--- image of the $vpn_type client, tunnel interface $vpn_tun ---"

check "services started" wait_ready
run_image_checks
check "diag.sh prints the $vpn_type client's version and no missing file" diag_shows_client
run_checks
run_socks5_checks

# With no VPN connected, danted's restart creates the temporary tunnel interface again and removes it
echo "--- after danted exits ---"
restart_danted_checks
check "no temporary tunnel interface is left after danted restarts" tunnel_interface_is_gone

# A tunnel interface without the temporary interface's address is the VPN client's and is kept
echo "--- after danted exits while a tunnel interface exists ---"
# The single-quoted scripts are expanded by the sh that runs them
# shellcheck disable=SC2016
check "tunnel interface with address 10.0.0.2/32 is created" in_c sh -c 'ip tuntap add mode tun "$1" && ip addr add 10.0.0.2/32 dev "$1"' sh "$vpn_tun"
restart_danted_checks
# shellcheck disable=SC2016
check "tunnel interface is kept" in_c sh -c 'ip -o addr show dev "$1" | grep -q " inet 10.0.0.2/32 "' sh "$vpn_tun"
check "tunnel interface is removed" in_c ip tuntap del mode tun "$vpn_tun"

# The firewall checks its rules every 5 seconds, so within 12 seconds it repairs each chain once and then finds
# its rules first at least once more. The rules change in one transaction, so a check of the firewall finds
# either none or all of the changes.
echo "--- after a rule is put before the firewall's rules ---"
inserted_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
# Another owner's rule that is identical to the firewall's DROP rule apart from the mark is not the firewall's
check "rules are inserted at the top of INPUT and FORWARD and the DROP rule is replaced by an unmarked copy" \
    displace_firewall_rules
sleep 12
run_firewall_checks
check "other rules keep their order" unmarked_rules_are "-A INPUT -j RETURN"$'\n'"-A INPUT -i $vpn_tun -p tcp -j DROP" \
    "-A FORWARD -j RETURN"
check "firewall logged one repair of INPUT and one of FORWARD" firewall_repaired_input_and_forward_once "$inserted_at"
# The single-quoted script is expanded by the sh that runs it
# shellcheck disable=SC2016
check "inserted rules are removed" in_c sh -c \
    'iptables -D INPUT -j RETURN && iptables -D INPUT -i "$1" -p tcp -j DROP && iptables -D FORWARD -j RETURN' sh "$vpn_tun"
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
check "failed address assignment is logged" wait_log "^\[socks5\] warning: cannot give the temporary interface $vpn_tun its address"
check "danted is not started" danted_is_off
check "temporary tunnel interface is not kept" tunnel_interface_is_not_kept
assignable_at=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "ip addr add works again" in_c rm "$fail_ip_addr_flag"
check "danted listens once ip addr add works" wait_danted "$assignable_at"
check "SOCKS5 proxy works" socks5_works socks5h://127.0.0.1:1080
check "no temporary tunnel interface is left" tunnel_interface_is_gone

# Docker creates a missing data directory as root
echo "--- on an empty data directory ---"
check "test data directory is removed" rm -rf "$test_data" "$edited_prefs" "$saved_vnc_passwd"
check "container is recreated on the test data directory" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
    SOCKS_USER= SOCKS_PASSWD= NODANTED= VPN_SERVER=
check "services started after recreate" wait_ready
run_checks
run_socks5_checks
if [ "$vpn_type" = cisco ]; then
    check "default preferences are in the test data directory" test -f "$test_data/$prefs"
    check "no client profile is written without VPN_SERVER" profile_is absent
    check "missing VPN_SERVER warning is logged" wait_log '^\[start\] warning: VPN_SERVER is not set'
else
    # openconnect needs VPN_SERVER: the login terminal says so and waits, without retrying
    check "missing VPN_SERVER error is logged" wait_log '^\[start\] error: VPN_SERVER is not set'
    check "login terminal waits without openconnect" login_terminal_waits
    check "callback port is not forwarded without VPN_SERVER" callback_port_is_not_forwarded
    check "missing VPN_SERVER is logged once and the login terminal logs nothing" missing_vpn_server_logged_once
fi
check "VNC password file holds the default password" vnc_passwd_holds password
check "default VNC password warning is logged" wait_log '^\[start\] warning: PASSWORD is not set'
check "VNC accepts the default password" vnc_accepts password

# A chain that the firewall cannot read is not an empty chain: it must change nothing, although iptables-restore
# would work. The watch checks the rules at least once in 6 seconds.
echo "--- while iptables fails and iptables-restore works ---"
failing_from=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
check "failing iptables is installed" install_failing_command iptables
# The single-quoted script is expanded by the sh that runs it
# shellcheck disable=SC2016
check "firewall.sh apply fails" sh -c '! docker exec -e VPN_TUN="$1" cisco-vpn firewall.sh apply' sh "$vpn_tun"
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
if [ "$vpn_type" = cisco ]; then
    check "vpnagentd is not started" vpnagentd_logged_nothing
else
    check "login terminal is not started" openconnect_logged_nothing
fi

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

# The VPN_SERVER cases and the preference file case check the Cisco client's profile and preferences
if [ "$vpn_type" = cisco ]; then
    # The profile turns on local LAN access for the gateway VPN_SERVER, and both client processes load it.
    # docker restart keeps the container's files, so the restart replaces the profile of the first start.
    echo "--- with VPN_SERVER set ---"
    check "container is recreated with VPN_SERVER=$test_server" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
        SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR= PING_ADDR_URL= PING_INTERVAL= VPN_SERVER="$test_server"
    check "services started after recreate" wait_ready
    check "client profile lists VPN_SERVER and turns on local LAN access" profile_lists "$test_server"
    check "no temporary profile file is left" profile_is present
    check "vpnagentd loaded the client profile" wait_log 'csc_vpnagent\[[0-9]+\]: .*Loaded profiles: .*/cisco-vpn-docker\.xml'
    check "vpnui loaded the client profile" wait_log 'csc_ui\[[0-9]+\]: .*Loaded profiles: .*/cisco-vpn-docker\.xml'
    check "nothing is logged about VPN_SERVER" nothing_logged_about_vpn_server
    check "container restarts" docker restart cisco-vpn
    check "services started after restart" wait_ready
    check "client profile lists VPN_SERVER after restart" profile_lists "$test_server"
    check "no temporary profile file is left after restart" profile_is present
    for server in 192.0.2.1 2001:db8::1 "$label63.example.com"; do
        check "VPN_SERVER=${server:0:24} is accepted" accepts_server "$server"
    done
    for server in : ... vpn..example.com -vpn.example.com vpn-.example.com "$label64.example.com" 192.0.2.256 \
        01.2.3.4 1:::2 'vpn.example.com"/><x' "$too_long_server"; do
        check "VPN_SERVER=${server:0:24} is refused and the profile of an earlier run is removed" \
            removes_profile_for "$server" '^\[start\] error: VPN_SERVER is not a host name or an IP address'
    done
    check "empty VPN_SERVER removes the profile of an earlier run" \
        removes_profile_for "" '^\[start\] warning: VPN_SERVER is not set'
    check "a profile that cannot be removed is logged" \
        logs_profile_failure "" '^\[start\] error: cannot remove the client profile'
    check "a profile that cannot be replaced is logged" \
        logs_profile_failure "$test_server" '^\[start\] error: cannot write the client profile'

    # The value goes into the profile's XML, so anything but a host name or an IP address is refused
    echo "--- with a VPN_SERVER that is not a host name ---"
    check "container is recreated with an invalid VPN_SERVER" recreate CISCO_VPN_DATA="$test_data" PASSWORD= VNC_SIZE= \
        SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR= PING_ADDR_URL= PING_INTERVAL= VPN_SERVER='vpn.example.com"/><x'
    check "services started after recreate" wait_ready
    check "refused VPN_SERVER is logged" wait_log '^\[start\] error: VPN_SERVER is not a host name or an IP address'
    check "no client profile is written for an invalid VPN_SERVER" profile_is absent

    # A preference file that already exists holds the user's choices and must be kept as a whole: the file that
    # replaces the default one turns LocalLanAccess off and names a gateway, and it is compared byte for byte after
    # a recreate with VPN_SERVER set
    echo "--- with a preference file of the user's ---"
    check "default preference file is replaced by one with LocalLanAccess false and a gateway" write_user_prefs
    check "preference file is copied for comparison" cp "$test_data/$prefs" "$edited_prefs"
    check "container is recreated with VPN_SERVER" recreate CISCO_VPN_DATA="$test_data" VPN_SERVER="$test_server"
    check "services started after recreate" wait_ready
    # cmp fails when either file is missing
    check "preference file is unchanged" cmp "$edited_prefs" "$test_data/$prefs"
    check "vpnui logged its preferences" wait_prefs_logged
    check "vpnui reads the user's LocalLanAccess: false" local_lan_access_is false
fi

# The login of the openconnect image, up to the point where the user would open the login URL. Until the test gateway
# runs, openconnect fails to connect and starts again after a pause, and nothing listens on the callback port, so a
# test listener takes its place first. The test gateway writes its certificate before it listens, so openconnect
# never connects to it without the certificate it trusts.
if [ "$vpn_type" = openconnect ]; then
    echo "--- with VPN_SERVER set to a test gateway that asks for single sign-on in an external browser ---"
    check "container is recreated with VPN_SERVER=$test_gateway and CLI_OPTS" recreate CISCO_VPN_DATA="$test_data" \
        PASSWORD= VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR= PING_ADDR_URL= PING_INTERVAL= \
        VPN_SERVER="$test_gateway" CLI_OPTS="$test_cli_opts"
    check "services started after recreate" wait_ready
    check "nothing is logged about VPN_SERVER" nothing_logged_about_vpn_server
    check "test listener on [::1]:$callback_port is started" start_test_listener
    check "host reaches the test listener through 127.0.0.1:$callback_port" host_reaches_test_listener
    check "host connects to the container's port 6080 (noVNC)" host_connects_to_port 6080
    check "host cannot connect to the container's port 5901 (VNC)" host_connects_to_port 5901 not
    check "test listener is stopped" in_c pkill -f "http.server $callback_port"
    check "test gateway is started" docker exec -d cisco-vpn python3 -c "$gateway_server" "$test_gateway_cert"
    check "login URL is logged within 45 seconds" \
        wait_log "^\[openconnect\] open this URL in your browser to log in: $test_login_url\$" "" 45
    # The login URL above shows that openconnect still took the gateway as its server
    check "openconnect runs with --interface=$vpn_tun before the arguments of CLI_OPTS, the quoted one whole" \
        openconnect_argv_is openconnect --protocol=anyconnect --external-browser="$login_url_printer" \
        --interface="$vpn_tun" --cafile="$test_gateway_cert" "--useragent=smoke test agent" -u -- "$test_gateway"
    check "openconnect writes to the login terminal" openconnect_writes_to_terminal
    check "openconnect listens for the callback on [::1]:$callback_port" callback_listener_is_openconnects
    check "host reaches openconnect's callback listener through 127.0.0.1:$callback_port" host_reaches_callback_listener
    # run_service restarts the forward and reopens the login terminal
    check "socat is stopped" in_c pkill -x socat
    check "host reaches openconnect's callback listener after socat restarts" host_reaches_callback_listener
    check "login terminal is closed" in_c pkill -x xterm
    check "login URL is logged again after the terminal reopens" login_url_logged_times 2
    check "one openconnect runs after the terminal reopens" one_openconnect_runs
    check "openconnect listens for the callback after the terminal reopens" callback_listener_is_openconnects

    # openconnect must use the tunnel interface that the firewall, danted and the forward use
    echo "--- with CLI_OPTS that sets the tunnel interface ---"
    check "container is recreated with CLI_OPTS=--interface=tun1" recreate CISCO_VPN_DATA="$test_data" PASSWORD= \
        VNC_SIZE= SOCKS_USER= SOCKS_PASSWD= NODANTED= PING_ADDR= PING_ADDR_URL= PING_INTERVAL= \
        VPN_SERVER="$test_gateway" CLI_OPTS=--interface=tun1
    check "services started after recreate" wait_ready
    check "refused CLI_OPTS is logged" wait_log '^\[start\] error: CLI_OPTS sets the tunnel interface'
    check "login terminal waits without openconnect" login_terminal_waits
    check "callback port is not forwarded" callback_port_is_not_forwarded
    for opts in "-i tun1" -itun1 "--interface tun1" --inter=tun1 "-bi tun1"; do
        check "CLI_OPTS=$opts sets the tunnel interface" cli_opts_set_interface "$opts"
    done
    check "CLI_OPTS=-uivan does not set the tunnel interface" cli_opts_split_into -uivan -uivan
    check "CLI_OPTS is split as bash splits a command line" cli_opts_split_into \
        "--useragent='AnyConnect Linux_64 5.1.20.333' x\\ y \"-u\" ivan # comment" \
        "--useragent=AnyConnect Linux_64 5.1.20.333" "x y" -u ivan
    check "CLI_OPTS with an unmatched quote cannot be split" cli_opts_cannot_be_split "--useragent='a b"
fi

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
check "container is recreated" recreate_configured
check "services started after recreate" wait_ready

finish
