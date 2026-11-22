#!/bin/bash
# Cisco Secure Client steps of the entrypoint. start.sh sources this file and calls only:
#   vpn_prepare  preparation before any service starts
#   vpn_start    starts the client processes with start.sh's run_service
# Uses log, run_service, VPN_USER and DISPLAY from start.sh.

CSC_BIN=/opt/cisco/secureclient/bin

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

# Run the Cisco GUI as the unprivileged user with a login record for it; clear the record when the GUI exits
run_vpnui() {
    setpriv --reuid="$VPN_USER" --regid="$VPN_USER" --init-groups \
        env HOME="/home/$VPN_USER" USER="$VPN_USER" LOGNAME="$VPN_USER" \
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
