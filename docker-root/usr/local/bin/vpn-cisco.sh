#!/bin/bash
# Cisco Secure Client steps of the entrypoint. start.sh sources this file and uses only:
#   VPN_TUN      the tunnel interface of the client
#   vpn_prepare  preparation before any service starts
#   vpn_start    starts the client processes with start.sh's run_service
# Uses log, run_service, VPN_USER and DISPLAY from start.sh, and VPN_SERVER from the environment; vpn_prepare runs
# after start.sh has given the home directory to VPN_USER.

# Tunnel interface that the Cisco client creates when it connects; start.sh uses it
# shellcheck disable=SC2034
VPN_TUN=cscotun0

CSC_BIN=/opt/cisco/secureclient/bin

# Give the GUI user default preferences when it has no preference file yet; an existing file holds
# the user's own choices and is left alone. vpnui reads its preferences from ~/.vpn/.anyconnect
# (found with strace) and logs the values it read as "Current Preference Settings".
# The default turns on "Allow local (LAN) access" so that the Cisco window shows the setting that the client
# profile of write_profile applies at connect time. vpnagentd does not read this file, so it does not turn local
# LAN access on by itself; and before a connection, vpnui does not take the setting from the profile: with the
# profile and no preference file, vpnui reads LocalLanAccess: false (observed in testing). The client rewrites
# this file when it connects, keeping its preferences (observed in testing).
# The copy runs as the GUI user, so what it creates is the user's, and links inside the volume can only
# lead it where that user may write anyway. cp -n creates the file exclusively and never replaces one.
# The home directory must already belong to the GUI user (start.sh's prepare_home).
seed_preferences() {
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    setpriv --reuid="$VPN_USER" --regid="$VPN_USER" --init-groups \
        sh -c 'mkdir -p "$1" && cp -n /etc/skel-vpnuser/.vpn/.anyconnect "$1/.anyconnect"' sh "/home/$VPN_USER/.vpn" ||
        log "warning: cannot create the default preference file /home/$VPN_USER/.vpn/.anyconnect; the Cisco window" \
            "may show \"Allow local (LAN) access\" turned off"
}

# Client profile that write_profile writes; the client loads every profile in this directory
CSC_PROFILE=/opt/cisco/secureclient/vpn/profile/cisco-vpn-docker.xml

# Write a client profile that lists the gateway VPN_SERVER and turns on "Allow local (LAN) access", so that the
# host can still reach the container's ports while the tunnel is up; otherwise Cisco's firewall drops new
# connections from the local network. vpnagentd takes this setting at connect time from the profile whose server
# list holds the gateway, or from the Cisco window when the user changes the checkbox there; it does not read the
# GUI user's preference file ~/.vpn/.anyconnect. Observed in testing: with only that file set, the connection log
# shows "IPv4 Local LAN Wildcard: local LAN access preference is disabled", and with this profile and that file
# "IPv4 Local LAN Wildcard: received". The profile setting is Cisco's own way to turn local LAN access on:
# https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/221024-configure-local-lan-access-for-secure-cl.html
# The gateway must allow local LAN access as well. UserControllable keeps the checkbox in the Cisco window, so
# the user can still turn local LAN access off.
# The profile goes to a new file that replaces the old one once it is complete. It is in the image's file system,
# not in the data directory. When VPN_SERVER is empty or refused, the profile of an earlier run is removed, so
# that no gateway and no local LAN access from an earlier configuration stay in effect.
write_profile() {
    local new
    if [ -z "${VPN_SERVER:-}" ]; then
        remove_profile
        log "warning: VPN_SERVER is not set, so no client profile turns on local LAN access; once the VPN is" \
            "connected, the host cannot reach noVNC or the proxies unless \"Allow local (LAN) access\" is turned on" \
            "in the Cisco window"
        return
    fi
    if ! is_host_or_ip "$VPN_SERVER"; then
        remove_profile
        log "error: VPN_SERVER is not a host name or an IP address; no client profile is written, so once the VPN" \
            "is connected, the host cannot reach noVNC or the proxies"
        return
    fi
    # mv -T fails instead of moving the file into a directory of the profile's name
    if new=$(mktemp "$CSC_PROFILE.XXXXXX") &&
        cat >"$new" <<EOF &&
<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile xmlns="http://schemas.xmlsoap.org/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://schemas.xmlsoap.org/encoding/ AnyConnectProfile.xsd">
  <ClientInitialization>
    <LocalLanAccess UserControllable="true">true</LocalLanAccess>
  </ClientInitialization>
  <ServerList>
    <HostEntry>
      <HostName>$VPN_SERVER</HostName>
      <HostAddress>$VPN_SERVER</HostAddress>
    </HostEntry>
  </ServerList>
</AnyConnectProfile>
EOF
        chmod 644 "$new" && mv -fT "$new" "$CSC_PROFILE"; then
        return
    fi
    rm -f "$new"
    log "error: cannot write the client profile $CSC_PROFILE; once the VPN is connected, the host cannot reach" \
        "noVNC or the proxies"
}

# Remove the profile that write_profile writes, and only that file; log when it exists and cannot be removed
remove_profile() {
    rm -f "$CSC_PROFILE" && return 0
    log "error: cannot remove the client profile $CSC_PROFILE of an earlier run; it may still name a gateway" \
        "and turn on local LAN access"
    return 1
}

# Succeed when $1 is a host name or an IPv4 or IPv6 address. Only letters, digits, dots, hyphens and colons are
# accepted, so the value cannot change the XML around it. Python's ipaddress module parses the addresses, and a
# value of only digits and dots or with a colon must be one. A host name has at most 253 characters in labels of
# 1 to 63 letters, digits and hyphens that neither start nor end with a hyphen (RFC 1123).
is_host_or_ip() {
    [[ $1 =~ ^[A-Za-z0-9.:-]+$ ]] || return 1
    python3 - "$1" <<'EOF'
import ipaddress
import re
import sys

value = sys.argv[1]
try:
    ipaddress.ip_address(value)
    sys.exit(0)
except ValueError:
    pass
if re.fullmatch(r"[0-9.]+", value) or ":" in value:
    sys.exit(1)
label = r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
sys.exit(0 if len(value) <= 253 and re.fullmatch(rf"{label}(\.{label})*", value) else 1)
EOF
}

vpn_prepare() {
    # Docker bind-mounts /etc/resolv.conf and /etc/hosts into the container, and a mount point cannot be renamed;
    # vpnagentd renames them to a backup and replaces them when it sets up VPN DNS.
    # Same approach as the EyeSeeTea troubleshooting notes and darrencocco/anyconnect-client:
    # copy the content, unmount, write the content back (requires SYS_ADMIN).
    local f content
    for f in /etc/resolv.conf /etc/hosts; do
        if mountpoint -q "$f"; then
            content=$(cat "$f")
            if umount "$f"; then
                printf '%s\n' "$content" >"$f"
            else
                log "warning: cannot unmount $f; VPN DNS setup will fail (the container needs SYS_ADMIN)"
            fi
        fi
    done

    seed_preferences
    write_profile
}

# vpnagentd verifies the server certificate as the logged-in user running the GUI and refuses to do so as root;
# it finds that user from a utmp login record whose PID must be an ancestor of vpnui.
# On a desktop the display manager writes this record; the container has none, so utmpdump (util-linux) writes it.
register_login() {
    local pid=$1
    printf '[7] [%05d] [%-4s] [%-8s] [%-12s] [%-20s] [0.0.0.0        ] [%s]\n' \
        "$pid" "$DISPLAY" "$VPN_USER" "$DISPLAY" "$DISPLAY" "$(date -u +%Y-%m-%dT%H:%M:%S,000000+00:00)" |
        utmpdump -r >/var/run/utmp 2>/dev/null
}

# Run the Cisco GUI as the unprivileged user with a login record for it; clear the record when the GUI exits.
# The GUI and the pages of its login window get neither PASSWORD nor SOCKS_PASSWD: processes of the same user can
# read each other's environment.
run_vpnui() {
    setpriv --reuid="$VPN_USER" --regid="$VPN_USER" --init-groups \
        env -u PASSWORD -u SOCKS_PASSWD HOME="/home/$VPN_USER" USER="$VPN_USER" LOGNAME="$VPN_USER" \
        dbus-run-session -- "$CSC_BIN/vpnui" &
    local session_pid=$!
    register_login "$session_pid"
    wait "$session_pid"
    : >/var/run/utmp
}

vpn_start() {
    # Cisco daemon, in the foreground
    run_service vpnagentd "$CSC_BIN/vpnagentd" -execv_instance

    # Cisco GUI: once vpnagentd is up, run it as the unprivileged user and reopen it when closed
    sleep 2
    # The container cannot create user namespaces, so the WebKit sandbox cannot be created; disable it
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    # The VNC display has no GPU; disable WebKit hardware compositing
    export WEBKIT_DISABLE_COMPOSITING_MODE=1
    run_service vpnui run_vpnui
}
