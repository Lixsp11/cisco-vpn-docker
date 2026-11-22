#!/bin/bash
# Runs in the login terminal that vpn-openconnect.sh opens on the VNC desktop. Runs openconnect for the gateway
# VPN_SERVER with the extra arguments CLI_OPTS, and runs it again after it exits; the user answers its prompts, such
# as the username, password, one-time password or group, in the terminal. For a gateway that asks for single sign-on
# in an external browser, openconnect runs print-login-url.sh, which prints the login URL.
# Without VPN_SERVER, it only says so and waits.

# Seconds between the exit of openconnect and its next start, so that its last messages can be read and a gateway
# that refuses every connection is not asked again at once. Enter starts it at once.
RESTART_DELAY=10

if [ -z "${VPN_SERVER:-}" ]; then
    echo "VPN_SERVER is not set, so openconnect is not started."
    echo "Set VPN_SERVER to the address of the VPN gateway and recreate the container."
    exec sleep infinity
fi

# CLI_OPTS is split on whitespace into arguments. Quotes in it are not removed, so no argument can contain
# whitespace; set -f keeps patterns such as * in it from being expanded.
set -f
while true; do
    # shellcheck disable=SC2086
    openconnect --protocol=anyconnect --external-browser=/usr/local/bin/print-login-url.sh $CLI_OPTS "$VPN_SERVER"
    status=$?
    echo
    echo "openconnect exited with code $status. It starts again in $RESTART_DELAY seconds, or when you press Enter."
    read -r -t "$RESTART_DELAY"
done
