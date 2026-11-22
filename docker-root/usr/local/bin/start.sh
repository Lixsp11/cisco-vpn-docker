#!/bin/bash
# Container entrypoint: starts VNC, noVNC, the VPN client, the SOCKS5 and HTTP proxies,
# and keeps them running. Each service's output is prefixed with [service] in docker logs.

# Unprivileged user that runs the VPN client's GUI, created in the Dockerfile.
# Its home directory is the volume that keeps the client's settings.
VPN_USER=vpnuser

# VPN client steps: defines VPN_TUN, vpn_prepare and vpn_start
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

# VNC password file, in the GUI user's home so that it is kept with the user's other settings
VNC_PASSWD_FILE=/home/$VPN_USER/.vnc/passwd

# Set the VNC password from PASSWORD. The password is the first 8 characters of PASSWORD's first line:
# VncAuth uses only 8 characters, and tigervncpasswd -f, which reads a password per line of up to
# 255 characters, would store a second password from the rest as a view-only password.
# An empty PASSWORD keeps the saved password, and without a saved password the password is "password".
# The GUI user writes the file, so root writes nothing below the volume; Xtigervnc, running as root, only reads it.
# The password goes to a new file from mktemp (created exclusively, mode 600) in the same directory, which
# replaces the old file only once it is complete, so a failed write keeps the old password.
# The home directory must already belong to the GUI user (prepare_home).
prepare_vnc_password() {
    local vnc_password=${PASSWORD%%$'\n'*}
    vnc_password=${vnc_password:0:8}
    if [ -z "$vnc_password" ]; then
        [ -e "$VNC_PASSWD_FILE" ] && return
        vnc_password=password
        log "warning: PASSWORD is not set and no VNC password is saved; the VNC password is 'password'"
    fi
    # The single-quoted script is expanded by the sh that runs it
    # shellcheck disable=SC2016
    printf %s "$vnc_password" | setpriv --reuid="$VPN_USER" --regid="$VPN_USER" --init-groups sh -c '
        umask 077
        mkdir -p "$(dirname "$1")" && new=$(mktemp "$1.XXXXXX") || exit 1
        if tigervncpasswd -f >"$new" && [ -s "$new" ] && mv -f "$new" "$1"; then
            exit 0
        fi
        rm -f "$new"
        exit 1
    ' sh "$VNC_PASSWD_FILE" || log "warning: cannot write the VNC password file $VNC_PASSWD_FILE"
}

# Configuration that start_danted writes from the template /etc/danted.conf.sample
DANTED_CONF=/run/danted.conf
# Address of the temporary tunnel interface, which tells that interface apart from the VPN client's own
TEMP_TUN_ADDR=10.0.0.1/32
# Comment (GECOS field) of the accounts that set_socks_user creates. Only an account with this comment is
# reused by a later start; any other existing account is never changed.
SOCKS_ACCOUNT_COMMENT="SOCKS5 proxy account"

# Start the SOCKS5 proxy: set up SOCKS_USER's account, write DANTED_CONF and run danted with run_service.
# The template's VPN_TUN becomes the tunnel interface $VPN_TUN. When SOCKS_USER and SOCKS_PASSWD are both set,
# the proxy requires them: dante's username method checks them against the system's user database.
# If the account cannot be set up, danted is not started at all: the causes are settings that only a new
# SOCKS_USER or SOCKS_PASSWD can fix, so restarting danted every second would only repeat the error.
start_danted() {
    local socksmethod=none
    if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASSWD" ]; then
        set_socks_user || return
        socksmethod=username
    elif [ -n "$SOCKS_USER" ]; then
        log "warning: SOCKS_USER is set but SOCKS_PASSWD is empty; the SOCKS5 proxy requires no username"
    fi
    sed -e "s/^external: VPN_TUN\$/external: $VPN_TUN/" -e "s/^socksmethod: none\$/socksmethod: $socksmethod/" \
        /etc/danted.conf.sample >"$DANTED_CONF"
    run_service socks5 run_danted
}

# Give SOCKS_USER an account with the password SOCKS_PASSWD: create a system account with SOCKS_ACCOUNT_COMMENT,
# or reuse one that an earlier start created. Fails, and logs why, when SOCKS_USER is not a plain user name
# (lowercase letters, digits, _ and -, not starting with a digit or -, at most 32 characters), names an
# existing account without that comment, such as root or vpnuser, or SOCKS_PASSWD contains a newline,
# or when creating the account or setting its password fails.
# chpasswd reads "user:password" lines on stdin, so the password is neither on a command line nor in the logs;
# a newline would start another line, which sets the password of another account.
set_socks_user() {
    local account
    if ! [[ $SOCKS_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        log "error: SOCKS_USER is not a valid user name; the SOCKS5 proxy is not started"
        return 1
    fi
    if [[ $SOCKS_PASSWD == *$'\n'* ]]; then
        log "error: SOCKS_PASSWD contains a newline; the SOCKS5 proxy is not started"
        return 1
    fi
    if account=$(getent passwd "$SOCKS_USER"); then
        if [ "$(cut -d: -f5 <<<"$account")" != "$SOCKS_ACCOUNT_COMMENT" ]; then
            log "error: SOCKS_USER names the existing account $SOCKS_USER, which is not a SOCKS5 proxy account;" \
                "the SOCKS5 proxy is not started"
            return 1
        fi
    elif ! useradd -r -M -s /usr/sbin/nologin -c "$SOCKS_ACCOUNT_COMMENT" "$SOCKS_USER"; then
        log "error: cannot create the account $SOCKS_USER; the SOCKS5 proxy is not started"
        return 1
    fi
    if ! printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASSWD" | chpasswd; then
        log "error: cannot set the password of $SOCKS_USER; the SOCKS5 proxy is not started"
        return 1
    fi
    log "the SOCKS5 proxy requires the username $SOCKS_USER and the password in SOCKS_PASSWD"
}

# Run danted in the foreground on port 1080 and remove the temporary tunnel interface once it listens.
# danted does not start when an external interface is missing, and the VPN client creates the tunnel interface
# only when it connects. As in docker-easyconnect's start.sh, a tun interface with the tunnel's name and the
# address TEMP_TUN_ADDR stands in for it while danted starts. The interface is removed once danted listens or
# has exited, so that the VPN client can create its own, and only while it has that address. An interface
# that cannot get the address is removed at once and danted is not started; run_service then tries again.
run_danted() {
    local pid
    if ! ip link show "$VPN_TUN" >/dev/null 2>&1; then
        ip tuntap add mode tun "$VPN_TUN" || return
        if ! ip addr add "$TEMP_TUN_ADDR" dev "$VPN_TUN"; then
            echo "warning: cannot give the temporary interface $VPN_TUN its address; danted is not started"
            ip tuntap del mode tun "$VPN_TUN"
            return 1
        fi
    fi
    danted -f "$DANTED_CONF" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ -z "$(ss -Hltn 'sport = :1080')" ]; do
        sleep 0.5
    done
    # The ready line is logged only after the temporary interface is gone
    if ip -o addr show dev "$VPN_TUN" 2>/dev/null | grep -qF " inet $TEMP_TUN_ADDR " &&
        ! ip tuntap del mode tun "$VPN_TUN"; then
        echo "warning: cannot remove the temporary interface $VPN_TUN; the VPN client may fail to create its tunnel"
    elif kill -0 "$pid" 2>/dev/null; then
        echo "danted is listening on port 1080"
    fi
    wait "$pid"
}

# Remove stale X locks from a previous run
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

prepare_home
vpn_prepare
prepare_vnc_password

# VNC
run_service vnc Xtigervnc :1 -geometry "${VNC_SIZE:-1280x720}" -depth 24 -rfbport 5901 -localhost=1 \
    -SecurityTypes VncAuth -PasswordFile "$VNC_PASSWD_FILE"
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

# SOCKS5 proxy, unless NODANTED is set
if [ -n "$NODANTED" ]; then
    log "NODANTED is set; the SOCKS5 proxy is not started"
else
    start_danted
fi

# HTTP proxy
run_service http tinyproxy -d -c /etc/tinyproxy.conf

log "all services started"
wait
