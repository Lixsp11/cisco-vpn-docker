#!/bin/bash
# Chooses the image's VPN client at build time, before anything is installed, and writes its name to
# /etc/vpn-type, which the next build step and start.sh read:
#   cisco        the Cisco Secure Client package in /tmp/packages (packages/ of the build context): the file that
#                the build argument CSC_DEB names, or else the only .deb file there, which must then be named
#                cisco-secure-client-vpn_<version>_amd64.deb. /tmp/cisco-secure-client-vpn.deb then links to it.
#   openconnect  when CSC_DEB is empty and /tmp/packages holds no .deb file
# Fails, and says why, when CSC_DEB names no file in packages/, or when CSC_DEB is empty and packages/ holds several
# .deb files or one with another name: it never picks one of several packages, and never builds the openconnect
# image from a context that holds a package.
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

if [ -n "${CSC_DEB:-}" ]; then
    [ -f "$packages/$CSC_DEB" ] || fail "the build argument CSC_DEB names $CSC_DEB, which is not a file in packages/"
    use_cisco "$CSC_DEB"
    exit 0
fi

shopt -s nullglob
debs=("$packages"/*.deb)
case ${#debs[@]} in
    0)
        echo openconnect >/etc/vpn-type
        echo "VPN client: openconnect, since packages/ holds no .deb file"
        ;;
    1)
        name=${debs[0]##*/}
        [[ $name == cisco-secure-client-vpn_*_amd64.deb ]] ||
            fail "packages/ holds $name, which is not named cisco-secure-client-vpn_<version>_amd64.deb;" \
                "rename it, or name it with the build argument CSC_DEB"
        use_cisco "$name"
        ;;
    *)
        fail "packages/ holds several .deb files (${debs[*]##*/}); name the one to install with the build" \
            "argument CSC_DEB, or remove the others"
        ;;
esac
