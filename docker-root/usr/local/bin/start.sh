#!/bin/bash
# Container entrypoint: starts VNC, noVNC, Cisco vpnagentd and vpnui, the SOCKS5 and HTTP proxies,
# and keeps them running. Each service's output is prefixed with [service] in docker logs.

CSC_BIN=/opt/cisco/secureclient/bin
# Unprivileged user that runs the Cisco GUI, created in the Dockerfile
VPN_USER=vpnuser

log() {
    echo "[start] $*"
}

# Run a service in a loop: when it exits, print the exit code and restart it after 1 second.
# The prefixing sed ignores TERM/INT and ends only after the service closes its output,
# so wait in stop_all returns after the services have stopped and their last logs are kept.
run_service() {
    local name=$1
    shift
    while true; do
        "$@"
        echo "exited (code $?), restarting in 1 second"
        sleep 1
    done 2>&1 | (
        trap '' TERM INT
        exec sed -u "s/^/[$name] /"
    ) &
}

# On SIGTERM/SIGINT, stop every service in this process group and exit.
# The background services share this script's process group, so kill 0 also stops the loops' children.
stop_all() {
    trap '' TERM INT
    log "received exit signal, stopping all services"
    kill -TERM 0 2>/dev/null
    wait
    exit 0
}
trap stop_all TERM INT

# Remove stale X locks from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# Docker bind-mounts /etc/resolv.conf and /etc/hosts into the container, and a mount point cannot be renamed;
# vpnagentd renames them to a backup and replaces them when it sets up VPN DNS.
# Same approach as the EyeSeeTea troubleshooting notes and darrencocco/anyconnect-client:
# copy the content, unmount, write the content back (requires SYS_ADMIN).
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

# VNC
VNC_PASSWORD=${VNC_PASSWORD:-password}
if [ "$VNC_PASSWORD" = password ]; then
    log "warning: VNC_PASSWORD is the default value 'password'"
fi
mkdir -p "$HOME/.vnc"
printf %s "$VNC_PASSWORD" | tigervncpasswd -f >"$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"

run_service vnc Xtigervnc :1 -geometry "${VNC_SIZE:-1280x800}" -depth 24 -rfbport 5901 -localhost=1 \
    -SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd"
export DISPLAY=:1

# Wait up to about 10 seconds for X display :1
for _ in $(seq 20); do
    [ -e /tmp/.X11-unix/X1 ] && break
    sleep 0.5
done
[ -e /tmp/.X11-unix/X1 ] || log "warning: X display :1 not ready after 10 seconds"

run_service flwm flwm

# noVNC: make the root path open vnc.html
[ -e /usr/share/novnc/index.html ] || ln -s vnc.html /usr/share/novnc/index.html
run_service novnc python3 -m websockify --web=/usr/share/novnc 6080 127.0.0.1:5901

# Cisco daemon, in the foreground
run_service vpnagentd "$CSC_BIN/vpnagentd" -execv_instance

# Cisco GUI: once vpnagentd is up, run it as the unprivileged user and reopen it when closed.
# vpnagentd verifies the server certificate as the logged-in user running the GUI and refuses to do so as root;
# it finds that user from a utmp login record whose PID must be an ancestor of vpnui.
# On a desktop the display manager writes this record; the container has none, so utmpdump (util-linux) writes it.
register_login() {
    local pid=$1
    printf '[7] [%05d] [%-4s] [%-8s] [%-12s] [%-20s] [0.0.0.0        ] [%s]\n' \
        "$pid" "$DISPLAY" "$VPN_USER" "$DISPLAY" "$DISPLAY" "$(date -u +%Y-%m-%dT%H:%M:%S,000000+00:00)" |
        utmpdump -r >/var/run/utmp 2>/dev/null
}
sleep 2
# The container cannot create user namespaces, so the WebKit sandbox cannot be created; disable it
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# The VNC display has no GPU; disable WebKit hardware compositing
export WEBKIT_DISABLE_COMPOSITING_MODE=1
run_vpnui() {
    setpriv --reuid="$VPN_USER" --regid="$VPN_USER" --init-groups \
        env HOME="/home/$VPN_USER" USER="$VPN_USER" LOGNAME="$VPN_USER" \
        dbus-run-session -- "$CSC_BIN/vpnui" &
    local session_pid=$!
    register_login "$session_pid"
    wait "$session_pid"
    : >/var/run/utmp
}
run_service vpnui run_vpnui

# SOCKS5 proxy: forwards by kernel routing, not bound to the tunnel interface
socks_args=(-i 0.0.0.0 -p 1080)
if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASSWD" ]; then
    socks_args+=(-u "$SOCKS_USER" -P "$SOCKS_PASSWD")
fi
run_service socks5 microsocks "${socks_args[@]}"

# HTTP proxy
run_service http tinyproxy -d -c /etc/tinyproxy.conf

log "all services started"
wait
