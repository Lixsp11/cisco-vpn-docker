#!/bin/bash
# openconnect steps of the entrypoint. start.sh sources this file and uses only:
#   VPN_TUN      the tunnel interface of the client
#   vpn_prepare  preparation before any service starts
#   vpn_start    starts the client processes with start.sh's run_service
# Uses log from start.sh. The login is not implemented yet: the client is not started.

# Tunnel interface that openconnect creates when it connects; start.sh uses it
# shellcheck disable=SC2034
VPN_TUN=tun0

vpn_prepare() {
    :
}

vpn_start() {
    log "the openconnect login is not implemented yet; openconnect is not started"
}
