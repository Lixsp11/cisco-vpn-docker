# cisco-vpn-docker

Connects to a Cisco AnyConnect VPN gateway from a Docker container, with the official Cisco Secure Client or with openconnect, chosen when the image is built. You log in on a VNC desktop in a browser (noVNC), and the host reaches the VPN through SOCKS5 and HTTP proxies, or by routing through the container. The VPN stays inside the container's network namespace, so the host's own routes, DNS and firewall are not changed. The environment variables, the proxies and route mode follow [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect).

## Variants

The build chooses the VPN client from the `.deb` files in `packages/` and writes it, `cisco` or `openconnect`, to `/etc/vpn-type` in the image:

| | Cisco variant | openconnect variant |
|---|---|---|
| Built when | `packages/` holds your Cisco Secure Client package | `packages/` holds no `.deb` file |
| VPN client | Cisco Secure Client | [openconnect](https://www.infradead.org/openconnect/) with `--protocol=anyconnect` |
| Login | In the Cisco window with its built-in login browser, for SAML single sign-on, MFA and any other step that the gateway asks for | In a terminal window that runs openconnect, for username, password, one-time password and group. SAML single sign-on runs in your own browser, and only on gateways that allow the external browser mode. |
| `VPN_SERVER` | Optional: turns on local LAN access for this gateway | Required: the gateway that openconnect connects to |
| `CLI_OPTS` | Not used | Extra arguments of openconnect |
| Tunnel interface | `cscotun0` | `tun0` |

[docs/usage.md](docs/usage.md#build) has the rules for `packages/`.

## How it works

| Component | Role |
|---|---|
| TigerVNC (display `:1`) and flwm | X display for the VPN client's window; VNC listens only inside the container (port 5901) |
| websockify and noVNC | The VNC display in a browser, on port 6080 |
| `vpnagentd` (Cisco variant) | Cisco VPN daemon, runs as root |
| `vpnui` (Cisco variant) | Cisco window with its built-in login browser, runs as the unprivileged user `vpnuser` |
| xterm and openconnect (openconnect variant) | Terminal window titled `openconnect` that runs openconnect as root |
| socat (openconnect variant) | Forwards port 29786 to openconnect, for the browser's return after single sign-on |
| dante (`danted`) | SOCKS5 proxy on port 1080 |
| tinyproxy | HTTP proxy on port 8888 |
| `firewall.sh` | Drops new TCP connections from the VPN side; forwarding and NAT for route mode |
| keepalive | Optional ping or URL request every `PING_INTERVAL` seconds |

The entrypoint `start.sh` loads the steps of the client that `/etc/vpn-type` names, starts these services and restarts each one 1 second after it exits. The terminal window and the Cisco window reopen the same way when they are closed. Closing the terminal window ends openconnect and with it the VPN connection. The VNC password, and in the Cisco variant the Cisco user preferences, are kept in a host directory that is mounted as the home directory of `vpnuser`.

In the openconnect variant, openconnect runs with `--external-browser` set to a script that prints the login URL in the terminal and in `docker logs`; the image has no browser. After the login, your browser opens `http://localhost:29786/...`. openconnect listens for that request only on the container's IPv6 loopback address, so the container publishes port 29786 and forwards it there with an iptables redirect and socat, as docker-easyconnect does for the ports where its clients wait for the browser.

The container runs with the `NET_ADMIN` and `SYS_ADMIN` capabilities and `/dev/net/tun`, without `--privileged` or the host network. [docs/usage.md](docs/usage.md#faq) explains each step that the Cisco client needs inside a container.

## Requirements

- A Linux host (amd64) with Docker and Docker Compose (`docker compose`). The build needs BuildKit, Docker's default builder since Docker Engine 23.0.
- `/dev/net/tun` on the host
- For the Cisco variant, your own Cisco Secure Client VPN package for Linux: the full package with the GUI, `cisco-secure-client-vpn_<version>_amd64.deb`

## Quick start

1. Choose the variant. For the Cisco variant, put your package in `packages/` as its only `.deb` file. For the openconnect variant, leave `packages/` without `.deb` files.

2. Set the VNC password and the address of your VPN gateway in a `.env` file next to `docker-compose.yml`. Only the first 8 characters of the password count:

   ```
   PASSWORD=changeme
   VPN_SERVER=vpn.example.com
   ```

   In the Cisco variant, `VPN_SERVER` turns on Cisco's "Allow local (LAN) access" for that gateway, so that the host can still reach noVNC and the proxies once the VPN is connected (see the [FAQ](docs/usage.md#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it)). In the openconnect variant, `VPN_SERVER` is required, and `CLI_OPTS` can add arguments of openconnect (see [openconnect arguments](docs/usage.md#openconnect-arguments-cli_opts)).

3. Build and start. `[start] all services started` in the log means that startup has finished; the lines of each service show whether it runs or failed:

   ```bash
   docker compose up -d --build
   docker logs -f cisco-vpn
   ```

4. The ports are bound to `127.0.0.1` on the Docker host. From another machine, forward them over SSH. Port 29786 is for single sign-on in the openconnect variant:

   ```bash
   ssh -N -L 127.0.0.1:6080:127.0.0.1:6080 -L 127.0.0.1:1080:127.0.0.1:1080 -L 127.0.0.1:8888:127.0.0.1:8888 -L 127.0.0.1:29786:127.0.0.1:29786 user@host
   ```

5. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password.

6. Log in:

   - Cisco variant: in the Cisco window, enter the VPN address exactly as in `VPN_SERVER`, click Connect and complete the login.
   - openconnect variant: the terminal window runs openconnect for `VPN_SERVER`. Answer its prompts there. When the gateway asks for single sign-on, the terminal shows the login URL, and `docker logs` shows it in a line that starts with `[openconnect] open this URL in your browser to log in:`. Open the URL in a browser on the Docker host or on the machine that forwards port 29786, and log in. The browser then returns to `http://localhost:29786/...`, and openconnect goes on in the terminal.

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

[docs/usage.md](docs/usage.md) covers the build, the environment variables, ports, logging in, proxies, route mode, keepalive, persistence, firewall and diagnostics, and has an FAQ.
