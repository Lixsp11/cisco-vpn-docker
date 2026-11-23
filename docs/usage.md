# Usage

- [Build](#build)
- [Configuration](#configuration)
- [Ports](#ports)
- [Logging in](#logging-in)
- [Proxies](#proxies)
- [Route mode](#route-mode)
- [Keepalive](#keepalive)
- [Persistence](#persistence)
- [Firewall](#firewall)
- [Diagnostics](#diagnostics)
- [Tests](#tests)
- [FAQ](#faq)

## Build

The build chooses the VPN client from the `.deb` files in `packages/` and writes `cisco` or `openconnect` to `/etc/vpn-type`. The build log shows the choice.

- **Cisco variant**: `packages/` holds your full Cisco Secure Client VPN package for Linux, `cisco-secure-client-vpn_<version>_amd64.deb`.
- **openconnect variant**: `packages/` holds no `.deb` file. The image has no Cisco software and no browser.

The build fails and says why when a `.deb` file in `packages/` has another name or sits in a subdirectory, or when `packages/` holds several Cisco packages. With several packages, name one with the build argument `CSC_DEB`:

```bash
docker compose build --build-arg CSC_DEB=cisco-secure-client-vpn_<version>_amd64.deb
```

`packages/` is only bind-mounted during the install step (BuildKit, Docker's default builder), so no file of it is left in the image. Both variants build the image `cisco-vpn-docker:dev` and run as the container `cisco-vpn`.

### Building and pushing by hand

The Cisco image contains the Cisco Secure Client, so push it only to a **private** repository. `<image>` is the full name with the registry host, such as `registry.example.com/<namespace>/cisco-vpn-docker` (lowercase), and `<registry>` is that host.

```bash
docker compose build
docker login <registry>
docker tag cisco-vpn-docker:dev <image>:<version>
docker tag cisco-vpn-docker:dev <image>:latest
docker push <image>:<version>
docker push <image>:latest
```

### Building in GitHub Actions

`.github/workflows/build.yml` does the same with the same Dockerfile, started by hand (Actions tab or `gh workflow run build.yml`). Set these repository secrets:

| Secret | Value |
|---|---|
| `CSC_DEB_URL` | Download URL of your Cisco package, such as a pre-signed object storage link |
| `IMAGE_NAME` | `<image>` |
| `ALIYUN_ACR_USERNAME` | Registry username |
| `ALIYUN_ACR_PASSWORD` | Registry password or access token |

Any registry that accepts `docker login` with a username and password works. The image is tagged with the package version and `latest`. The job log masks the secrets and the registry host, and the workflow turns off the build summary and build record artifact, which contain the image name.

### Deploying a prebuilt image

On a host with this repository but no Cisco package:

```bash
docker login <registry>
docker pull <image>:latest
docker tag <image>:latest cisco-vpn-docker:dev
docker compose up -d
```

Compose starts the existing image without building. `docker compose up --build` would build from `packages/` instead.

## Configuration

Set the variables in `.env` next to `docker-compose.yml`. An empty value means the default; `docker compose up -d` recreates the container when a value changes.

| Variable | Default | Meaning |
|---|---|---|
| `VPN_SERVER` | empty | VPN gateway, a host name or IP address. **Cisco**: optional; the container writes a client profile that turns on "Allow local (LAN) access" for it (see [FAQ](#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it)). **openconnect**: required; without it openconnect does not start |
| `CLI_OPTS` | empty | openconnect only: extra arguments, see below |
| `PASSWORD` | `password` | VNC password, first 8 characters. Saved in the data directory, so it can be removed from `.env` after the first start |
| `VNC_SIZE` | `1280x720` | VNC display size, `<width>x<height>` |
| `SOCKS_USER`, `SOCKS_PASSWD` | empty | When both are set, SOCKS5 requires them |
| `NODANTED` | empty | Non-empty: no SOCKS5 proxy |
| `PING_ADDR` | empty | Keepalive: address inside the VPN to ping |
| `PING_ADDR_URL` | empty | Keepalive: URL inside the VPN to request |
| `PING_INTERVAL` | `1800` | Keepalive interval in whole seconds |
| `CISCO_VPN_DATA` | `$HOME/.cisco-vpn-data` | Host directory mounted at `/home/vpnuser` |

The names match docker-easyconnect; its other variables are not supported.

### openconnect arguments (`CLI_OPTS`)

openconnect runs as:

```
openconnect --protocol=anyconnect --external-browser=/usr/local/bin/print-login-url.sh --interface=tun0 <CLI_OPTS> -- <VPN_SERVER>
```

- `CLI_OPTS` is split like a bash command line, as in docker-easyconnect, so quotes work. In `.env`, single-quote the whole value:

  ```
  CLI_OPTS='--useragent="AnyConnect Linux_64 5.1.20.333" --authgroup=Staff'
  ```

- bash evaluates it as shell code, so any command in it runs as root in the container. It is your own configuration, like the compose file.
- The firewall, NAT and SOCKS5 proxy expect the tunnel `tun0`, so `-i` and `--interface` are refused. The check is exact only when long options take their value with `=`. Do not set the interface in an openconnect `--config` file either.
- When `VPN_SERVER` is empty or `CLI_OPTS` is refused, the log and the terminal show why, and openconnect does not start until the container is recreated.

### Example compose file

`docker-compose.yml` adds `NET_ADMIN`, `SYS_ADMIN` and `/dev/net/tun`, sets `net.ipv4.ip_forward=1` for route mode, binds the ports to `127.0.0.1`, limits memory to 600 MB (1200 MB with swap), uses the network `192.168.213.0/24` (change it if it overlaps) and does not restart the container by itself (`restart: "no"`).

## Ports

| Port | Service | Notes |
|---|---|---|
| 6080 | noVNC | `/vnc.html` |
| 1080 | SOCKS5 (dante) | Optional username and password |
| 8888 | HTTP proxy (tinyproxy) | No authentication |
| 29786 | openconnect single sign-on callback | openconnect variant only |
| 20000 | socat, forward of 29786 | Not published |
| 5901 | VNC | Inside the container only |

The compose file publishes the ports on `127.0.0.1`. From another machine, forward them over SSH:

```bash
ssh -N -L 6080:127.0.0.1:6080 -L 1080:127.0.0.1:1080 -L 8888:127.0.0.1:8888 -L 29786:127.0.0.1:29786 user@host
```

Ports 6080, 1080 and 8888 can also be published on all of the host's addresses, such as `"1080:1080"`, and stay reachable from other machines while the VPN is connected (see [Firewall](#firewall)). The proxies accept any client that reaches them: set `SOCKS_USER` and `SOCKS_PASSWD`, and keep 8888 on `127.0.0.1` unless a firewall limits who reaches it, since the HTTP proxy has no authentication.

## Logging in

Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password. `docker restart` and `docker compose down` end the VPN connection.

**Cisco variant**

1. In the Cisco window, enter the address exactly as in `VPN_SERVER` and click Connect.
2. Finish the login in the window that opens: it is the client's built-in browser, so SAML, MFA and other steps work.

The window reopens 1 second after it is closed. `docker exec cisco-vpn /opt/cisco/secureclient/bin/vpn state` shows the connection state.

**openconnect variant**

1. Answer the prompts in the `openconnect` terminal: username, password, OTP or group.
2. For SAML single sign-on, the terminal prints the login URL, and `docker logs` shows it after `[openconnect] open this URL in your browser to log in:`. Open it in a browser on the host, or on the machine that forwards port 29786, and log in. The browser returns to `http://localhost:29786/`, and openconnect goes on.

When openconnect exits, the terminal restarts it after 10 seconds, or at once on Enter. Closing the terminal ends the connection without logging off, so the gateway may keep the session until it times out.

## Proxies

```bash
curl --socks5-hostname 127.0.0.1:1080 https://intranet.example.com/
curl -x http://127.0.0.1:8888 https://intranet.example.com/
curl -x socks5h://<SOCKS_USER>:<SOCKS_PASSWD>@127.0.0.1:1080 https://intranet.example.com/
```

- Traffic goes through the tunnel for the addresses that the VPN routes, and directly otherwise.
- Names are resolved in the container with the VPN's DNS, so use `--socks5-hostname` or `socks5h://`.
- `SOCKS_USER` can be any name that `useradd` accepts, uppercase letters included, as in docker-easyconnect, but not an existing account such as `root`; otherwise the SOCKS5 proxy does not start and the log says why.

## Route mode

The host routes VPN subnets through the container, which forwards them to the tunnel and masquerades them, as in docker-easyconnect. After the VPN is connected, run on the host:

```bash
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cisco-vpn)
MTU=$(docker exec cisco-vpn cat /sys/class/net/cscotun0/mtu)    # tun0 in the openconnect variant
sudo ip route add <VPN subnet> via $IP mtu $MTU
```

- Use the tunnel's MTU (`cscotun0` or `tun0`), which can be smaller than the Docker network's (1390 for the Cisco tunnel in testing).
- `docker exec cisco-vpn ip route show table all` lists the VPN's routes.
- Remove a route with `sudo ip route del <VPN subnet>`. The routes are lost when the host reboots, and the container's address can change when it is recreated.
- The container gives the host no DNS: use IP addresses, or the proxies for VPN-only names.

## Keepalive

Set `PING_ADDR`, `PING_ADDR_URL` or both. Every `PING_INTERVAL` seconds the container pings the address (1 second timeout) and requests the URL without downloading it (10 seconds). Only failures are logged, as `[keepalive] <address> unreachable`, so do not put secrets in the URL.

## Persistence

`CISCO_VPN_DATA` is mounted at `/home/vpnuser` and kept by `docker compose down`. It holds:

- `.vnc/passwd`: the VNC password (both variants);
- Cisco variant: `.vpn/.anyconnect` (the Cisco window's preferences, created with local LAN access on and never changed by the container), and the login window's cookies and cache under `.local/`.

To start over, remove the container and delete the directory.

## Firewall

IPv4 iptables rules in the container, each with the comment `cisco-vpn-docker`:

| Chain | Rules | Purpose |
|---|---|---|
| filter `INPUT` | accept established and related, accept new TCP from `eth0` to 6080, 1080 and 8888, drop new TCP from the tunnel | Clients outside the Docker host reach the services; VPN-side machines cannot connect to the container |
| filter `OUTPUT` | accept TCP from 6080, 1080 and 8888 out of `eth0` | Replies to those clients |
| filter `FORWARD` | accept `eth0` to tunnel and the replies | Route mode |
| nat `POSTROUTING` | masquerade out of the tunnel | Route mode |

- The Cisco client adds its own chains when it connects. Every 5 seconds the container puts its rules first again and logs each repair.
- Replies from 6080, 1080 and 8888 leave through `eth0`, not the tunnel: before the VPN client starts, the container copies its main routing table to table 2 and adds `ip rule add iif lo sport <port> table 2` for each port, as docker-easyconnect's `detect-route.sh` does. If that fails, the log shows `[start] error: cannot route the replies ...`, and once the VPN is connected only clients on the Docker network, such as the host, reach the ports.
- Without `NET_ADMIN` the rules cannot be set, and the container stops before any service starts.
- The openconnect variant also redirects port 29786 to socat on port 20000 (see [FAQ](#where-does-port-29786-come-from)).
- There are no IPv6 rules; the services listen only on IPv4 and `::1`.

## Diagnostics

```bash
docker logs -f cisco-vpn
docker exec cisco-vpn diag.sh
```

Each log line starts with its service, such as `[start]`, `[firewall]`, `[vnc]`, `[socks5]`, `[vpnagentd]` or `[openconnect]`. `[start] all services started` means startup has finished; a service that exits is restarted after 1 second.

`diag.sh` prints the client's version and state, processes and memory, interfaces, routes, firewall rules, `/etc/resolv.conf` and `/dev/net/tun`. Its output contains the VPN's addresses and, in the openconnect variant, any secrets in `CLI_OPTS`. Check it before sharing.

## Tests

Run as root on the Docker host:

- `tests/smoke.sh`: no VPN login needed. It restarts and recreates the container many times (ending any VPN session), needs internet access, and checks the variant in `/etc/vpn-type`. If interrupted, run `docker compose up -d --force-recreate`.
- `tests/connected.sh`: checks a real Cisco connection after you log in; it adds and removes one `/32` route through the container.

To test the openconnect variant from a checkout with a Cisco package, build from the committed files:

```bash
rm -rf tmp/oc-context && mkdir -p tmp/oc-context
git archive HEAD | tar -x -C tmp/oc-context
docker build -t cisco-vpn-docker:dev tmp/oc-context
docker compose up -d --force-recreate
tests/smoke.sh
```

The openconnect variant has not yet been tested with a real login on a real gateway.

## FAQ

### Why does the container need `SYS_ADMIN`?

Docker bind-mounts `/etc/resolv.conf`, and the Cisco client renames it when it sets up DNS, which fails on a mount point. The container copies the file, unmounts it and writes it back, as in [EyeSeeTea's notes](https://github.com/EyeSeeTea/know-how/wiki/Cisco-Secure-Client-(secureclient)-v5.1-Docker-troubleshooting); `umount` needs `SYS_ADMIN`. The openconnect variant unmounts nothing; the example compose file adds `SYS_ADMIN` for both variants.

### Why does the Cisco window run as an unprivileged user, with a utmp login record?

`vpnagentd` refuses to verify the gateway's certificate as root, and finds the logged-in user through a utmp record. The container runs the window as `vpnuser` and writes that record with `utmpdump`.

### Why are the WebKit sandbox and compositing turned off?

The container cannot create the namespaces of WebKit's sandbox and has no GPU. Use the login window only for the gateway's login.

### How is "Allow local (LAN) access" turned on, and what if the gateway does not allow it?

Once connected, the Cisco client drops connections from the local network, which includes the host. With `VPN_SERVER` set, the container writes a client profile that turns local LAN access on for that gateway, as [Cisco documents](https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/221024-configure-local-lan-access-for-secure-cl.html). Connect to the address exactly as in `VPN_SERVER`. The gateway must allow it too; if the host loses noVNC after connecting, look for `IPv4 Local LAN Wildcard` in `docker logs`, and use `docker restart cisco-vpn` to get noVNC back.

### The log shows that a module from the gateway failed to install with `pkcon`

The gateway pushed an extra module, such as Socket Filter. The container has no PackageKit, so it fails; the VPN works anyway.

### Which gateways does the openconnect variant support?

Gateways with username and password login, and SAML single sign-on only when the gateway allows the external browser. A gateway that offers only the embedded browser makes openconnect stop with `No SSO handler`; use the Cisco variant for it.

### Where does port 29786 come from?

After external-browser single sign-on, the browser opens `http://localhost:29786/api/sso/...`, where openconnect listens on `[::1]` only. The container publishes 29786 and forwards it to `[::1]:29786` with an iptables redirect and socat, like docker-easyconnect's `force_open_ports`. Only this port is forwarded, and new connections from the tunnel are still dropped.

### Why is there no prebuilt image?

The Cisco variant contains the Cisco Secure Client, and [Cisco's terms](https://www.cisco.com/c/en/us/about/legal/cloud-and-software/software-terms.html) do not allow providing it to others. Build your own and keep it in a private registry (see [Building and pushing by hand](#building-and-pushing-by-hand) and [Building in GitHub Actions](#building-in-github-actions)).
