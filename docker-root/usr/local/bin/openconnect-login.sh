#!/bin/bash
# Runs in the login terminal that vpn-openconnect.sh opens on the VNC desktop, with the arguments of openconnect as
# its arguments. Runs openconnect with them, and again after it exits; the user answers its prompts, such as the
# username, password, one-time password or group, in the terminal. For a gateway that asks for single sign-on in an
# external browser, openconnect runs print-login-url.sh, which prints the login URL.
# When LOGIN_ERROR is set, a setting keeps openconnect from starting: it only shows LOGIN_ERROR and waits.

# Seconds between the exit of openconnect and its next start, so that its last messages can be read and a gateway
# that refuses every connection is not asked again at once. Enter starts it at once.
RESTART_DELAY=10

if [ -n "${LOGIN_ERROR:-}" ]; then
    echo "$LOGIN_ERROR, so openconnect is not started."
    echo "Change the setting in the container's environment and recreate the container."
    exec sleep infinity
fi

while true; do
    openconnect "$@"
    status=$?
    echo
    echo "openconnect exited with code $status. It starts again in $RESTART_DELAY seconds, or when you press Enter."
    read -r -t "$RESTART_DELAY"
done
