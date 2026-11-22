# cisco-vpn-docker

Runs the official Cisco Secure Client (AnyConnect VPN) in a Docker container. You log in through the Cisco window in a browser (noVNC), and the host reaches the VPN through SOCKS5 and HTTP proxies, or by routing through the container. The VPN stays inside the container's network namespace, so the host's own routes, DNS and firewall are not changed. The environment variables, the proxies and route mode follow [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect).

## How it works

| Component | Role |
|---|---|
| TigerVNC (display `:1`) and flwm | X display for the Cisco window; VNC listens only inside the container (port 5901) |
| websockify and noVNC | The VNC display in a browser, on port 6080 |
| `vpnagentd` | Cisco VPN daemon, runs as root |
| `vpnui` | Cisco window with its built-in login browser, runs as the unprivileged user `vpnuser` |
| dante (`danted`) | SOCKS5 proxy on port 1080 |
| tinyproxy | HTTP proxy on port 8888 |
| `firewall.sh` | Drops new TCP connections from the VPN side; forwarding and NAT for route mode |
| keepalive | Optional ping or URL request every `PING_INTERVAL` seconds |

The entrypoint `start.sh` starts these services and restarts each one 1 second after it exits. Every login step that the gateway asks for, such as SAML single sign-on or MFA, happens in the Cisco window. The Cisco user preferences and the VNC password are kept in a host directory that is mounted as the home directory of `vpnuser`.

The container needs the `NET_ADMIN` and `SYS_ADMIN` capabilities and `/dev/net/tun`. It does not use `--privileged` or the host network. [doc/usage.md](doc/usage.md#faq) explains each step that the Cisco client needs inside a container.

## Requirements

- A Linux host (amd64) with Docker and Docker Compose (`docker compose`)
- `/dev/net/tun` on the host
- Your own Cisco Secure Client VPN package for Linux: the full package with the GUI, `cisco-secure-client-vpn_<version>_amd64.deb`

## Quick start

1. Put the package in `packages/`. The Dockerfile expects `cisco-secure-client-vpn_5.1.20.333_amd64.deb`; for another file name, see [Build](doc/usage.md#build).

2. Set the VNC password and the address of your VPN gateway in a `.env` file next to `docker-compose.yml`. Only the first 8 characters of the password count. With `VPN_SERVER` set, the container turns on Cisco's "Allow local (LAN) access" for that gateway, so that the host can still reach noVNC and the proxies once the VPN is connected (see the [FAQ](doc/usage.md#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it)):

   ```
   PASSWORD=changeme
   VPN_SERVER=vpn.example.com
   ```

3. Build and start. `[start] all services started` in the log means that startup has finished; the lines of each service show whether it runs or failed:

   ```bash
   docker compose up -d --build
   docker logs -f cisco-vpn
   ```

4. The ports are bound to `127.0.0.1` on the Docker host. From another machine, forward them over SSH:

   ```bash
   ssh -N -L 127.0.0.1:6080:127.0.0.1:6080 -L 127.0.0.1:1080:127.0.0.1:1080 -L 127.0.0.1:8888:127.0.0.1:8888 user@host
   ```

5. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password.

6. In the Cisco window, enter the VPN address exactly as in `VPN_SERVER`, click Connect and complete the login.

7. Use the proxies:

   ```bash
   curl --socks5-hostname 127.0.0.1:1080 https://example.internal/
   curl -x http://127.0.0.1:8888 https://example.internal/
   ```

8. Stop and remove the container. The data directory is kept:

   ```bash
   docker compose down
   ```

## Documentation

[doc/usage.md](doc/usage.md) covers the environment variables, ports, proxies, route mode, keepalive, persistence, firewall and diagnostics, and has an FAQ.
