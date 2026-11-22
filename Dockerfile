FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
# Full Cisco Secure Client VPN package in packages/ to install. When empty, the build installs the only
# cisco-secure-client-vpn_<version>_amd64.deb in packages/, and openconnect when packages/ holds no .deb file;
# build-scripts/select-vpn-client.sh has the rules.
ARG CSC_DEB=

# packages/ and build-scripts/ of the build context are BuildKit bind mounts, read-only and only while this step
# runs, so no file of them, not even the installed Cisco package, is in a layer of the image.
# First choose the VPN client, so that a packages/ directory it refuses fails the build before apt runs.
# select-vpn-client.sh writes cisco or openconnect to /etc/vpn-type.
# Then install VNC, noVNC, diagnostic tools, proxies and busybox (ping and wget for the keepalive), and the packages
# of the chosen client: for the Cisco client, WebKit for its login window, then the Cisco package (apt resolves its
# Depends); for openconnect, openconnect, xterm and socat.
# Versions are not pinned: the Debian archive keeps only the current version of each package,
# so pins would break the build after the next point release or security update.
# client_packages is a list of package names, split on purpose.
# hadolint ignore=DL3008,SC2086
RUN --mount=type=bind,source=packages,target=/tmp/packages \
    --mount=type=bind,source=build-scripts,target=/tmp/build-scripts \
    bash /tmp/build-scripts/select-vpn-client.sh \
 && if [ "$(cat /etc/vpn-type)" = cisco ]; then \
        client_packages="libwebkit2gtk-4.1-0 dbus-x11 xdg-utils"; \
    else \
        client_packages="openconnect xterm socat"; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-tools flwm \
      novnc python3-websockify \
      fonts-wqy-microhei ca-certificates \
      iproute2 iptables procps psmisc \
      dante-server tinyproxy-bin \
      busybox \
      $client_packages \
 && if [ "$(cat /etc/vpn-type)" = cisco ]; then \
        apt-get install -y --no-install-recommends /tmp/cisco-secure-client-vpn.deb; \
    fi \
 && rm -rf /tmp/cisco-secure-client-vpn.deb /var/lib/apt/lists/*

# Unprivileged user that runs the VPN client's GUI and owns the data directory (the Cisco client's vpnagentd
# refuses to verify server certificates as root), and the system user of danted's unprivileged operations
# (user.notprivileged in /etc/danted.conf.sample)
RUN useradd -m -s /bin/bash vpnuser \
 && useradd -r -s /usr/sbin/nologin socks

COPY docker-root/ /
# The executable bit may be lost when copying files around; set it explicitly
RUN chmod 755 /usr/local/bin/start.sh /usr/local/bin/vpn-cisco.sh /usr/local/bin/vpn-openconnect.sh \
      /usr/local/bin/openconnect-login.sh /usr/local/bin/print-login-url.sh \
      /usr/local/bin/diag.sh /usr/local/bin/firewall.sh

# Send vpnagentd and vpnui logs to stdout so they show up in docker logs
ENV CSC_LOGGING_OUTPUT=STDOUT

CMD ["start.sh"]
