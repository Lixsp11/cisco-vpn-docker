#!/bin/bash
# openconnect steps of the entrypoint. start.sh sources this file and uses only:
#   VPN_TUN      the tunnel interface of the client
#   vpn_prepare  preparation before any service starts
#   vpn_start    starts the client processes with start.sh's run_service
# diag.sh sources it as well and uses only vpn_diag, which prints the client's part of the diagnostics.
# Uses log and run_service from start.sh, section and show_processes from diag.sh, and VPN_SERVER and CLI_OPTS from
# the environment.

# Tunnel interface of openconnect, which vpn_start passes to it with --interface; start.sh uses it
VPN_TUN=tun0

# Port of the callback of the single sign-on in an external browser. After the login, the browser opens
# http://localhost:29786/api/sso/...; openconnect listens for it on [::1]:29786 only, and only while it waits for
# the browser (handle_external_browser in hpke.c of openconnect 9.01).
SSO_CALLBACK_PORT=29786
# Port to which connections from outside the container to SSO_CALLBACK_PORT are redirected; socat listens on it
SSO_FORWARD_PORT=20000

# Short options of openconnect 9.01 that take an argument, from the option string of getopt_long in main.c
# ("bC:c:Dde:F:g:hi:k:lm:P:p:Q:qSs:U:u:Vvx:")
OPENCONNECT_SHORT_OPTIONS_WITH_ARGUMENT=CceFgikmPpQsUux

# Arguments of openconnect, or the reason why it is not started; vpn_start sets them for run_login_terminal
OPENCONNECT_ARGS=()
LOGIN_ERROR=

# Nothing to prepare. When openconnect connects, its vpnc-script writes the VPN's name servers into /etc/resolv.conf
# in place and restores the file in place when it disconnects (modify_resolvconf_generic and
# restore_resolvconf_generic in /usr/share/vpnc-scripts/vpnc-script; the image has none of the resolver managers
# that the script would use instead), which works on the file that Docker bind-mounts, so it stays mounted.
vpn_prepare() {
    :
}

# Split CLI_OPTS into the array CLI_ARGS as bash splits a command line, as docker-easyconnect does by running
# bash -c "exec easyconn login $CLI_OPTS" (docker-root/usr/local/bin/vpn-config.sh): quotes and backslashes keep
# whitespace in an argument, $ expansions are made and # starts a comment. Unlike there, patterns such as * are not
# expanded, and a bash of its own parses CLI_OPTS alone and passes back only the arguments, so nothing in CLI_OPTS
# changes the rest of openconnect's command line or this script. Fails when that bash cannot parse CLI_OPTS.
parse_cli_opts() {
    # The single-quoted script is expanded by the bash that runs it
    # shellcheck disable=SC2016
    mapfile -d '' -t CLI_ARGS < <(
        bash -c 'set -f
            eval "args=($1
)" </dev/null >/dev/null 2>&1 || exit 1
            [ "${#args[@]}" = 0 ] || printf "%s\0" "${args[@]}"' bash "$CLI_OPTS"
    )
    wait "$!"
}

# Succeed when the openconnect arguments $@ set the tunnel interface before a "--" that ends the options: -i, alone,
# with its value attached or after other short options without an argument, or --interface or any abbreviation of it,
# which getopt_long accepts since no other long option of openconnect starts with "i". The value of a short option
# is skipped, but that of a long option given as the next argument is not, so such a value that starts with -i counts.
sets_interface() {
    local arg options skip=
    for arg; do
        if [ -n "$skip" ]; then
            skip=
            continue
        fi
        case $arg in
            --) return 1 ;;
            --*)
                arg=${arg#--}
                arg=${arg%%=*}
                [ -n "$arg" ] && [[ interface == "$arg"* ]] && return 0
                ;;
            -?*)
                options=${arg#-}
                while [ -n "$options" ]; do
                    [ "${options:0:1}" = i ] && return 0
                    if [[ $OPENCONNECT_SHORT_OPTIONS_WITH_ARGUMENT == *"${options:0:1}"* ]]; then
                        [ -n "${options:1}" ] || skip=1
                        break
                    fi
                    options=${options:1}
                done
                ;;
        esac
    done
    return 1
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

# Login terminal on the VNC desktop: an xterm that runs openconnect-login.sh with OPENCONNECT_ARGS, or that shows
# LOGIN_ERROR. It runs as root, which openconnect needs to create its tunnel interface and to run vpnc-script.
run_login_terminal() {
    LOGIN_ERROR=$LOGIN_ERROR xterm -title openconnect -geometry 120x32 \
        -e /usr/local/bin/openconnect-login.sh "${OPENCONNECT_ARGS[@]}"
}

vpn_start() {
    if [ -z "${VPN_SERVER:-}" ]; then
        LOGIN_ERROR="VPN_SERVER is not set"
    elif ! parse_cli_opts; then
        LOGIN_ERROR="CLI_OPTS cannot be split into arguments (check its quotes)"
    elif sets_interface "${CLI_ARGS[@]}"; then
        LOGIN_ERROR="CLI_OPTS sets the tunnel interface with -i or --interface, which must stay $VPN_TUN"
    fi
    if [ -n "$LOGIN_ERROR" ]; then
        # The login terminal only shows the error and waits, and nothing is forwarded
        log "error: $LOGIN_ERROR; openconnect is not started until that is changed and the container is recreated"
    else
        # The firewall, danted and the forward use VPN_TUN, so openconnect must not choose another interface. The
        # fixed options come before the arguments of CLI_OPTS, so that an option at its end that takes a value, such
        # as -u, cannot take one of them as its value, and "--" ends the options before VPN_SERVER.
        OPENCONNECT_ARGS=(--protocol=anyconnect --external-browser=/usr/local/bin/print-login-url.sh
            "--interface=$VPN_TUN" "${CLI_ARGS[@]}" -- "$VPN_SERVER")
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
