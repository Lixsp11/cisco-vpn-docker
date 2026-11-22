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

# Wait up to 90 seconds for a log line that matches the extended regular expression $1 and was logged
# since the time $2 (RFC 3339). Without $2, only lines from the container's current start count:
# docker logs keeps the output of earlier starts, so the time is then State.StartedAt.
wait_log() {
    local pattern=$1 since=${2:-} logs deadline=$((SECONDS + 90))
    if [ -z "$since" ]; then
        since=$(docker inspect -f '{{.State.StartedAt}}' cisco-vpn) || return 1
    fi
    while [ "$SECONDS" -lt "$deadline" ]; do
        logs=$(docker logs --since "$since" cisco-vpn 2>&1)
        if grep -qE "$pattern" <<<"$logs"; then
            return 0
        fi
        sleep 1
    done
    echo "no line matching '$pattern' in the logs since $since after 90 seconds"
    return 1
}

# Wait for the entrypoint's ready line from the container's current start
wait_ready() {
    wait_log '^\[start\] all services started$'
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
