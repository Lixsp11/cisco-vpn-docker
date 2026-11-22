#!/bin/bash
# Container entrypoint: starts VNC, noVNC, the VPN client, the SOCKS5 and HTTP proxies,
# and keeps them running. Each service's output is prefixed with [service] in docker logs.

# Unprivileged user that runs the VPN client's GUI, created in the Dockerfile.
# Its home directory is the volume that keeps the client's settings.
VPN_USER=vpnuser

# VPN client steps: defines vpn_prepare and vpn_start
# shellcheck source=/dev/null
source /usr/local/bin/vpn-cisco.sh

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

# Docker creates the volume's host directory as root when it does not exist, so give the directory itself
# to the GUI user, which saves its settings there. Not recursive: files that root keeps there stay root's.
prepare_home() {
    chown "$VPN_USER:" "/home/$VPN_USER"
}

# Remove stale X locks from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

prepare_home
vpn_prepare

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

vpn_start

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
