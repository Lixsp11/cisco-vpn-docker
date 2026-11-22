#!/bin/bash
# Chooses the image's VPN client at build time, before anything is installed, and writes its name to
# /etc/vpn-type, which the rest of the Dockerfile's install step and start.sh read:
#   cisco        the Cisco Secure Client package in /tmp/packages, where that step mounts packages/ of the build
#                context: the file that the build argument CSC_DEB names, or else the only .deb file there.
#                /tmp/cisco-secure-client-vpn.deb then links to it.
#   openconnect  when CSC_DEB is empty and /tmp/packages holds no .deb file
# Every .deb file in packages/, hidden ones and those in subdirectories included, must be a Cisco package named
# cisco-secure-client-vpn_<version>_amd64.deb directly in packages/, and CSC_DEB must be the name of one of them,
# without a directory. Fails, and says why, when one is not, or when CSC_DEB is empty and packages/ holds several:
# it never picks one of several packages, and never builds the openconnect image from a context that holds a package.
set -euo pipefail

packages=/tmp/packages
link=/tmp/cisco-secure-client-vpn.deb

fail() {
    echo "error: $*" >&2
    exit 1
}

use_cisco() {
    ln -s "$packages/$1" "$link"
    echo cisco >/etc/vpn-type
    echo "VPN client: cisco, from packages/$1"
}

# The .deb files under packages/, as paths relative to it, whatever the case of the extension
mapfile -t debs < <(find "$packages" -iname '*.deb' -printf '%P\n' | sort)
for deb in "${debs[@]}"; do
    if [[ $deb != cisco-secure-client-vpn_*_amd64.deb || $deb == */* ]]; then
        fail "packages/ holds $deb; every .deb file in packages/ must be a Cisco package named" \
            "cisco-secure-client-vpn_<version>_amd64.deb directly in packages/, so remove or rename it"
    fi
done

if [ -n "${CSC_DEB:-}" ]; then
    [[ $CSC_DEB != */* ]] ||
        fail "the build argument CSC_DEB is $CSC_DEB; it must be the name of a file in packages/, without a directory"
    for deb in "${debs[@]}"; do
        if [ "$deb" = "$CSC_DEB" ]; then
            use_cisco "$deb"
            exit 0
        fi
    done
    fail "the build argument CSC_DEB names $CSC_DEB, which is not a .deb file in packages/"
fi

case ${#debs[@]} in
    0)
        echo openconnect >/etc/vpn-type
        echo "VPN client: openconnect, since packages/ holds no .deb file"
        ;;
    1)
        use_cisco "${debs[0]}"
        ;;
    *)
        fail "packages/ holds several Cisco packages (${debs[*]}); name the one to install with the build" \
            "argument CSC_DEB, or remove the others"
        ;;
esac
