FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
# Full Cisco Secure Client VPN package; place it in packages/ before building
ARG CSC_DEB=cisco-secure-client-vpn_5.1.20.333_amd64.deb

COPY packages/${CSC_DEB} /tmp/${CSC_DEB}

# Install VNC, noVNC, WebKit for the login window, diagnostic tools and proxies first,
# then the Cisco package (apt resolves its Depends).
# Versions are not pinned: the Debian archive keeps only the current version of each package,
# so pins would break the build after the next point release or security update.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-tools flwm \
      novnc python3-websockify \
      libwebkit2gtk-4.1-0 dbus-x11 xdg-utils fonts-wqy-microhei ca-certificates \
      iproute2 iptables procps psmisc \
      microsocks tinyproxy-bin \
 && apt-get install -y --no-install-recommends /tmp/${CSC_DEB} \
 && rm -f /tmp/${CSC_DEB} \
 && rm -rf /var/lib/apt/lists/*

# Unprivileged user that runs the Cisco GUI (vpnagentd refuses to verify server certificates as root)
RUN useradd -m -s /bin/bash vpnuser

COPY docker-root/ /
# The executable bit may be lost when copying files around; set it explicitly
RUN chmod 755 /usr/local/bin/start.sh /usr/local/bin/vpn-cisco.sh /usr/local/bin/diag.sh

# Send vpnagentd and vpnui logs to stdout so they show up in docker logs
ENV CSC_LOGGING_OUTPUT=STDOUT

CMD ["start.sh"]
