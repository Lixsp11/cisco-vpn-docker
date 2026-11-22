#!/bin/bash
# openconnect steps of the entrypoint. start.sh sources this file and uses only:
#   VPN_TUN      the tunnel interface of the client
#   vpn_prepare  preparation before any service starts
#   vpn_start    starts the client processes with start.sh's run_service
# diag.sh sources it as well and uses only vpn_diag, which prints the client's part of the diagnostics.
# Uses log and run_service from start.sh, section and show_processes from diag.sh, and VPN_SERVER from the
# environment.

# Tunnel interface that openconnect creates when it connects; start.sh uses it
# shellcheck disable=SC2034
VPN_TUN=tun0

# Port of the callback of the single sign-on in an external browser. After the login, the browser opens
# http://localhost:29786/api/sso/...; openconnect listens for it on [::1]:29786 only, and only while it waits for
# the browser (handle_external_browser in hpke.c of openconnect 9.01).
SSO_CALLBACK_PORT=29786
# Port to which connections from outside the container to SSO_CALLBACK_PORT are redirected; socat listens on it
SSO_FORWARD_PORT=20000

# Nothing to prepare. When openconnect connects, its vpnc-script writes the VPN's name servers into /etc/resolv.conf
# in place and restores the file in place when it disconnects (modify_resolvconf_generic and
# restore_resolvconf_generic in /usr/share/vpnc-scripts/vpnc-script; the image has none of the resolver managers
# that the script would use instead), which works on the file that Docker bind-mounts, so it stays mounted.
vpn_prepare() {
    :
}

# Forward connections from outside the container to port SSO_CALLBACK_PORT to openconnect's callback listener, as
# docker-easyconnect's force_open_ports (docker-root/usr/local/bin/start.sh) does for the ports where its clients
# wait for the browser: a nat PREROUTING rule redirects the connections to SSO_FORWARD_PORT, where socat accepts them
# and connects to [::1]:SSO_CALLBACK_PORT. The rule matches only the container's own addresses, so route mode is not
# affected, and the container's own connections to its loopback addresses do not pass PREROUTING. Only this port is
# forwarded, so the container's other services on the loopback address, such as VNC on 5901, stay unreachable from
# outside; the firewall's INPUT rules still drop new connections from the tunnel after the redirect.
start_callback_forward() {
    local rule=(-p tcp --dport "$SSO_CALLBACK_PORT" -m addrtype --dst-type LOCAL -j REDIRECT --to-ports "$SSO_FORWARD_PORT")
    if ! iptables -w 5 -t nat -C PREROUTING "${rule[@]}" 2>/dev/null &&
        ! iptables -w 5 -t nat -A PREROUTING "${rule[@]}"; then
        log "warning: cannot redirect port $SSO_CALLBACK_PORT to openconnect; after a single sign-on, the browser" \
            "cannot return to openconnect"
        return 1
    fi
    run_service sso-callback socat "TCP4-LISTEN:$SSO_FORWARD_PORT,reuseaddr,fork" "TCP6:[::1]:$SSO_CALLBACK_PORT"
}

# Login terminal on the VNC desktop: an xterm that runs openconnect-login.sh. It runs as root, which openconnect needs
# to create its tunnel interface and to run vpnc-script.
run_login_terminal() {
    xterm -title openconnect -geometry 120x32 -e /usr/local/bin/openconnect-login.sh
}

vpn_start() {
    # Without VPN_SERVER the login terminal only says so and waits, and nothing is forwarded
    if [ -z "${VPN_SERVER:-}" ]; then
        log "error: VPN_SERVER is not set; openconnect is not started until VPN_SERVER is set and the container is" \
            "recreated"
    else
        start_callback_forward
    fi
    # Reopen the login terminal when it is closed
    run_service openconnect run_login_terminal
}

vpn_diag() {
    section "openconnect version"
    openconnect --version
    section "openconnect processes (RSS in KB)"
    show_processes 'openconnect|xterm|socat'
    section "Listeners on the callback port $SSO_CALLBACK_PORT and its forward port $SSO_FORWARD_PORT"
    ss -Hltnp "( sport = :$SSO_CALLBACK_PORT or sport = :$SSO_FORWARD_PORT )"
}
