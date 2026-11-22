# shellcheck shell=bash
# Helpers shared by the test scripts. The scripts run on the Docker host against the cisco-vpn container;
# each check prints "ok" or "FAIL" with its name, and finish exits 1 if any check failed.

failures=0

# Run a command as a named check: ok when it exits 0, FAIL otherwise.
# The command's output is shown, indented, only when it fails.
check() {
    local name=$1 output
    shift
    if output=$("$@" 2>&1); then
        echo "ok   $name"
    else
        echo "FAIL $name"
        if [ -n "$output" ]; then
            printf '%s\n' "$output" | sed 's/^/     /'
        fi
        failures=$((failures + 1))
    fi
}

# Run a command inside the container
in_c() {
    docker exec cisco-vpn "$@"
}

# Wait up to 90 seconds for the entrypoint's ready line from the container's current start.
# docker logs keeps the output of earlier starts, so only lines since State.StartedAt count.
wait_ready() {
    local started_at logs deadline=$((SECONDS + 90))
    started_at=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    while [ "$SECONDS" -lt "$deadline" ]; do
        logs=$(docker logs --since "$started_at" cisco-vpn 2>&1)
        if grep -qF '[start] all services started' <<<"$logs"; then
            return 0
        fi
        sleep 1
    done
    echo "no '[start] all services started' in the logs since $started_at after 90 seconds"
    return 1
}

# Print the result and exit: 0 when every check passed, 1 otherwise
finish() {
    if [ "$failures" -eq 0 ]; then
        echo "all checks passed"
        exit 0
    fi
    echo "$failures check(s) failed"
    exit 1
}
