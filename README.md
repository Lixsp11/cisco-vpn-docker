# cisco-vpn-docker

Run the official Cisco Secure Client (full VPN package with GUI) in a Docker container. You log in through the Cisco window shown in a browser via noVNC (SAML and any other interactive authentication work there), and the container exposes SOCKS5 and HTTP proxies that go through the VPN.

## How it works

| Component | Role |
|---|---|
| TigerVNC (`:1`) + flwm | X display for the Cisco GUI; VNC listens only inside the container (5901) |
| websockify / noVNC | Browser access to the VNC display on port 6080 |
| `vpnagentd` | Cisco VPN daemon, runs as root and is restarted if it exits |
| `vpnui` | Cisco GUI with the built-in login browser, runs as the unprivileged user `vpnuser` |
| microsocks | SOCKS5 proxy on port 1080 |
| tinyproxy | HTTP proxy on port 8888 |

Container-specific handling:

- `/etc/resolv.conf` and `/etc/hosts` are bind mounts in Docker and cannot be renamed, but `vpnagentd` renames `/etc/resolv.conf` to `/etc/resolv.conf.vpnbackup` when it sets up VPN DNS. The entrypoint copies their content, unmounts them and writes the content back, which requires `SYS_ADMIN` ([EyeSeeTea notes](https://github.com/EyeSeeTea/know-how/wiki/Cisco-Secure-Client-(secureclient)-v5.1-Docker-troubleshooting), [darrencocco/anyconnect-client](https://github.com/darrencocco/anyconnect-client)).
- `vpnagentd` verifies the gateway certificate as the logged-in user running the GUI, refuses to do so as root, and looks that user up in utmp. The GUI therefore runs as `vpnuser`, and the entrypoint writes a utmp login record for display `:1` with `utmpdump`.
- After connecting, the Cisco firewall chains block new connections from the local network, including the host. Enable **Allow local (LAN) access when using VPN** in the Cisco preferences (gear icon); the gateway must permit local LAN access ([Cisco docs](https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/221024-configure-local-lan-access-for-secure-cl.html)).

## Requirements

- Linux host (amd64) with Docker and Docker Compose
- `/dev/net/tun`
- The Cisco Secure Client VPN package for Linux, e.g. `cisco-secure-client-vpn_5.1.20.333_amd64.deb`

## Usage

1. Put the package in `packages/`:

   ```
   packages/cisco-secure-client-vpn_5.1.20.333_amd64.deb
   ```

   For another version, set the build argument `CSC_DEB` to its file name.

2. Build and start:

   ```bash
   VNC_PASSWORD='your-password' docker compose up -d --build
   docker logs -f cisco-vpn
   ```

   Without `VNC_PASSWORD` the password is `password`. Only the first 8 characters are used.

3. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password. On a remote host, forward the port first:

   ```bash
   ssh -N -L 6080:127.0.0.1:6080 user@host
   ```

4. In the Cisco window, enter the VPN address, click Connect and complete the login.

5. Use the proxies from the host:

   ```bash
   curl --socks5-hostname 127.0.0.1:1080 https://example.internal/
   curl -x http://127.0.0.1:8888 https://example.internal/
   ```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `VNC_PASSWORD` | `password` | VNC password (first 8 characters) |
| `VNC_SIZE` | `1280x800` | VNC resolution |
| `SOCKS_USER`, `SOCKS_PASSWD` | empty | When both are set, the SOCKS5 proxy requires this username and password |

### Ports

| Port | Service |
|---|---|
| 6080 | noVNC |
| 1080 | SOCKS5 |
| 8888 | HTTP proxy |

The example compose file binds them to `127.0.0.1` only.

### Diagnostics

```bash
docker exec cisco-vpn diag.sh
```

Prints the Cisco version and `vpn state`, interfaces, routes, policy routing, iptables/nftables rules, `/etc/resolv.conf`, related processes, memory, and files under `/opt/cisco/secureclient` modified after the container started.

### Stop and remove

```bash
docker compose down --rmi local
```
