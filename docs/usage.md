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

The image is built on `debian:bookworm-slim`. Before anything is installed, the build chooses the VPN client from the `.deb` files in `packages/` and writes it, `cisco` or `openconnect`, to `/etc/vpn-type`, which the entrypoint and `diag.sh` read. The build log shows the choice, as `VPN client: cisco, from packages/<file>` or `VPN client: openconnect, since packages/ holds no .deb file`.

- **Cisco variant.** Put your Cisco Secure Client VPN package for Linux (the full package with the GUI) in `packages/`, named `cisco-secure-client-vpn_<version>_amd64.deb`. apt installs it with its dependencies and WebKitGTK for its login window.
- **openconnect variant.** When `packages/` holds no `.deb` file and the build argument `CSC_DEB` is empty, apt installs openconnect, xterm and socat instead. The image contains no Cisco software and no browser.

The build mounts `packages/` only while its install step runs, as a BuildKit bind mount, so no file of `packages/`, not even the `.deb` file of the installed Cisco package, is in the image. BuildKit is the default builder of `docker build` and `docker compose build` since Docker Engine 23.0.

The build argument `CSC_DEB` names the Cisco package to install, as the name of a file in `packages/` without a directory. It is empty by default, and then the build installs the only package in `packages/`. The build fails, and says why, when:

- a `.deb` file in `packages/` is not named `cisco-secure-client-vpn_<version>_amd64.deb` or is not directly in `packages/`, also when `CSC_DEB` is set. Hidden files, files in subdirectories and names that end in `.DEB` or another letter case count as `.deb` files;
- `packages/` holds several Cisco packages and `CSC_DEB` is empty;
- `CSC_DEB` contains a `/` or names no `.deb` file in `packages/`.

With one Cisco package in `packages/`, or none for the openconnect variant:

```bash
docker compose up -d --build
```

With several Cisco packages, pass the build argument each time you build:

```bash
docker compose build --build-arg CSC_DEB=cisco-secure-client-vpn_<version>_amd64.deb
docker compose up -d
```

Both variants build the image `cisco-vpn-docker:dev` and run as the container `cisco-vpn`. To change the variant, add or remove the package and build again.

### Building and pushing by hand

To run the Cisco variant on hosts without the Cisco package, push the image to a repository in a container registry and pull it from there (see [Deploying a prebuilt image](#deploying-a-prebuilt-image)). The repository must be private: the image contains the Cisco Secure Client (see [Why is there no prebuilt image?](#why-is-there-no-prebuilt-image)). In the commands below, `<image>` is the full image name including the registry host, for example `registry.example.com/<namespace>/cisco-vpn-docker`, `<registry>` is that host, and `<version>` is the version of the Cisco package. Image names must be lowercase.

With the package in `packages/`, build the image as above, log in to the registry, and tag and push the image:

```bash
docker compose build
docker login <registry>
docker tag cisco-vpn-docker:dev <image>:<version>
docker tag cisco-vpn-docker:dev <image>:latest
docker push <image>:<version>
docker push <image>:latest
```

`docker build -t cisco-vpn-docker:dev .` builds the same image as `docker compose build`.

### Building in GitHub Actions

The workflow `.github/workflows/build.yml` does the same steps with the same Dockerfile and the package from `CSC_DEB_URL`: it downloads the package, builds the Cisco variant with its file name as `CSC_DEB`, logs in to the registry and pushes the image. It runs only when started by hand, from the Actions tab or with `gh workflow run build.yml`. The workflow reads the registry, the image name and the login only from these secrets; set all four in the repository settings, under Secrets and variables > Actions:

| Secret | Value |
|---|---|
| `CSC_DEB_URL` | Download URL of your own Cisco package, for example a pre-signed object storage link. The workflow checks that the file is the package `cisco-secure-client-vpn` for `amd64`, and names it after the version in the package. |
| `IMAGE_NAME` | Full image name including the registry host, for example `registry.example.com/<namespace>/cisco-vpn-docker`. It must be lowercase. The workflow logs in to the part before the first `/`. |
| `ALIYUN_ACR_USERNAME` | Username for `docker login` to that registry |
| `ALIYUN_ACR_PASSWORD` | Password or access token for that username |

Any registry that accepts `docker login` with a username and password works; the names of the two login secrets are only names. The image is tagged with the package version and `latest`. The repository in the registry must be private (see [Why is there no prebuilt image?](#why-is-there-no-prebuilt-image)). GitHub masks the values of the secrets in the job log, and the workflow also masks the registry host that it takes from `IMAGE_NAME`. The workflow turns off the build summary and the build record artifact of `docker/build-push-action`, since both contain the image name and the artifact is not masked.

### Deploying a prebuilt image

On a host with this repository but without the Cisco package, log in to the registry, pull the image, give it the image name of `docker-compose.yml`, `cisco-vpn-docker:dev`, and start it. `<tag>` is a package version or `latest`:

```bash
docker login <registry>
docker pull <image>:<tag>
docker tag <image>:<tag> cisco-vpn-docker:dev
docker compose up -d
```

Compose pulls or builds the image only when no image of that name is present, so `docker compose up -d` starts the pulled image: the host needs no Cisco package, and `docker-compose.yml` needs no change. `docker compose up --build` and `docker compose build` build from `packages/` instead and give the result the same name, which is the openconnect variant when `packages/` holds no `.deb` file. Tag the pulled image again to go back to it.

## Configuration

Set the variables in a `.env` file next to `docker-compose.yml`, or in the environment of `docker compose up`. The compose file passes them to the container, and an empty value means the default. `docker compose up -d` recreates the container when a value changes.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `VPN_SERVER` | empty | Address of the VPN gateway.<br>**Cisco variant:** optional. A host name (labels of up to 63 letters, digits and hyphens, at most 253 characters) or an IPv4 or IPv6 address. The container writes a Cisco client profile for it that turns on "Allow local (LAN) access", so that the host can still reach noVNC and the proxies once the VPN is connected. See the [FAQ](#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it). When `VPN_SERVER` is empty, a warning is logged. A value that is neither a host name nor an IP address is refused, and an error is logged. In both cases the container writes no profile.<br>**openconnect variant:** required. openconnect connects to it: it is the last argument of openconnect's command line (see [openconnect arguments](#openconnect-arguments-cli_opts)). When it is empty, an error is logged and openconnect is not started. |
| `CLI_OPTS` | empty | openconnect variant: extra arguments of openconnect, such as `--user=<name>` or `--authgroup=<group>`. See [openconnect arguments](#openconnect-arguments-cli_opts). The Cisco variant does not use it. |
| `PASSWORD` | `password` when no password is saved | VNC password. Only the first 8 characters of its first line count. When empty, the saved password is kept. When empty and no password is saved, the password is `password` and a warning is logged. |
| `VNC_SIZE` | `1280x720` | Size of the VNC display, as `<width>x<height>` |
| `SOCKS_USER`, `SOCKS_PASSWD` | empty | When both are set, the SOCKS5 proxy requires this username and password. See [SOCKS5 username and password](#socks5-username-and-password). |
| `NODANTED` | empty | When not empty, the SOCKS5 proxy is not started |
| `PING_ADDR` | empty | Address inside the VPN that the [keepalive](#keepalive) pings |
| `PING_ADDR_URL` | empty | URL inside the VPN that the keepalive requests, for targets that do not answer pings |
| `PING_INTERVAL` | `1800` | Seconds between two keepalive checks, as a whole number above 0 |
| `CISCO_VPN_DATA` | `$HOME/.cisco-vpn-data` | Host directory that keeps the user data (see [Persistence](#persistence)). Used by the compose file, not by the container. |

A saved VNC password stays in the data directory, so `PASSWORD` can be removed from `.env` after the first start.

The names and meanings match docker-easyconnect. Its other variables, such as `EXIT`, `MAX_RETRY`, `URLWIN`, `CLIP_TEXT`, `TYPE` and `FORWARD`, are not supported.

### openconnect arguments (`CLI_OPTS`)

The openconnect variant runs openconnect with these arguments:

```
openconnect --protocol=anyconnect --external-browser=/usr/local/bin/print-login-url.sh --interface=tun0 <arguments of CLI_OPTS> -- <VPN_SERVER>
```

- The container splits `CLI_OPTS` into arguments as bash splits a command line, as docker-easyconnect does: quotes and backslashes keep spaces in an argument, `$` expansions are made, and `#` starts a comment. Patterns such as `*` are not expanded. For example, `--useragent="AnyConnect Linux_64 5.1.20.333" --authgroup=Staff` gives the two arguments `--useragent=AnyConnect Linux_64 5.1.20.333` and `--authgroup=Staff`.
- In `.env`, Compose reads the value first, by its [`.env` syntax](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax). It uses a single-quoted value literally:

  ```
  CLI_OPTS='--useragent="AnyConnect Linux_64 5.1.20.333" --authgroup=Staff'
  ```

- As in docker-easyconnect, bash evaluates the value as shell code, so any command in it, not only a command substitution, runs as root in the container. `CLI_OPTS` is your own configuration, like the compose file. A bash of its own parses it and passes back only the arguments, so it cannot change openconnect's other arguments.
- The fixed options come first, so an option at the end of `CLI_OPTS` that takes a value cannot take one of them as its value. `--` ends the options before `VPN_SERVER`, so `CLI_OPTS` holds options only. An option at the end of `CLI_OPTS` that takes a value but is given none, such as `-u`, takes that `--` as its value instead.
- openconnect must use the tunnel interface `tun0`, which the firewall, the NAT of route mode and the SOCKS5 proxy expect. The container refuses a `CLI_OPTS` that sets the interface with `-i` or `--interface`, also abbreviated as in `--inter=tun1`. The check does not know which long options take a value, so it is exact only when long options get their value with `=`, as in the examples above. It reads a value given as the next argument as an argument of its own: `--useragent -iX` is refused, and in `--useragent -- -i tun1` and `--useragent -u -i tun1` it misses the `-i tun1` that openconnect reads as an option. Do not set the interface in an openconnect configuration file (`--config`) either: the container does not check such a file, and its setting comes after `--interface=tun0` and replaces it.
- When `VPN_SERVER` is empty, or `CLI_OPTS` is refused as above or cannot be split (for example because of an unmatched quote), the log shows `[start] error: <reason>; openconnect is not started until that is changed and the container is recreated`. The terminal window shows the reason and waits, and port 29786 is not forwarded.

### Example compose file

`docker-compose.yml` sets:

- the capabilities `NET_ADMIN` and `SYS_ADMIN` and the device `/dev/net/tun` (see the [FAQ](#why-does-the-container-need-sys_admin));
- the sysctl `net.ipv4.ip_forward=1` for [route mode](#route-mode);
- the ports, bound to `127.0.0.1`;
- the volume `CISCO_VPN_DATA` at `/home/vpnuser`;
- a memory limit of 600 MB (1200 MB with swap);
- the bridge network `vpn-net` with the subnet `192.168.213.0/24`. Change the subnet if it overlaps a network that the host or the VPN uses;
- `restart: "no"`, so the container does not start again by itself.

## Ports

| Port | Service | Notes |
|---|---|---|
| 6080 | noVNC (websockify) | `/` and `/vnc.html` open the VNC client |
| 1080 | SOCKS5 (dante) | |
| 8888 | HTTP proxy (tinyproxy) | |
| 29786 | The browser's return to openconnect after single sign-on (openconnect variant) | Forwarded to openconnect, which listens on `[::1]:29786` in the container while it waits for the browser. See the [FAQ](#where-does-port-29786-come-from). The Cisco variant does not use it. |
| 20000 | socat, the forward of port 29786 to openconnect (openconnect variant) | Not published. socat listens on all the container's IPv4 addresses, so the container's network reaches it as well, and it leads only to openconnect's callback listener. The firewall drops new connections to it from the tunnel. |
| 5901 | VNC (Xtigervnc) | Listens only inside the container and is not published |

The proxies accept any client that reaches their port. SOCKS5 can require a username and password, and the HTTP proxy has no authentication. The example compose file binds the ports to `127.0.0.1`, so other machines cannot reach them through the host. From another machine, forward the ports over SSH. For single sign-on in the openconnect variant, forward port 29786 to the machine whose browser you log in with:

```bash
ssh -N -L 127.0.0.1:6080:127.0.0.1:6080 -L 127.0.0.1:1080:127.0.0.1:1080 -L 127.0.0.1:8888:127.0.0.1:8888 -L 127.0.0.1:29786:127.0.0.1:29786 user@host
```

## Logging in

In both variants, `docker restart cisco-vpn` and `docker compose down` end the VPN connection. In the openconnect variant, openconnect does not log the session off then, so the gateway may keep the session until it times out.

### Cisco variant

1. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password.
2. In the Cisco window, enter the VPN address exactly as in `VPN_SERVER` (for example `vpn.example.com`) and click Connect.
3. Complete the login in the window that opens. It is the Cisco client's built-in browser, so SAML single sign-on, MFA and any other step that the gateway asks for work there.

The Cisco window reopens about 1 second after it is closed. When the VPN session ends or expires, log in again in the Cisco window.

To see the state of the connection from the host:

```bash
docker exec cisco-vpn /opt/cisco/secureclient/bin/vpn state
```

### openconnect variant

1. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password. The terminal window titled `openconnect` runs openconnect for `VPN_SERVER`.
2. Answer openconnect's prompts in the terminal, such as the username, password, one-time password or group.
3. When the gateway asks for SAML single sign-on in an external browser, the terminal shows the login URL:

   ```
   Open this URL in your browser to log in:

   https://vpn.example.com/...
   ```

   `docker logs cisco-vpn` shows it as well, in a line that starts with `[openconnect] open this URL in your browser to log in: `. Open the URL in a browser on the Docker host, or on the machine that forwards port 29786 over SSH (see [Ports](#ports)), and log in. The browser then opens `http://localhost:29786/api/sso/...`, which reaches openconnect in the container, and openconnect goes on in the terminal.

- openconnect's messages appear only in the terminal. When openconnect exits, the terminal shows its exit code and starts it again after 10 seconds, or at once when you press Enter. When the VPN session ends, log in again in the terminal.
- Closing the terminal ends openconnect and with it the VPN connection, without logging the session off, so the gateway may keep the session until it times out. The terminal reopens about 1 second later and starts a new login.
- The openconnect variant supports username and password logins, and SAML single sign-on only on gateways that allow the external browser mode. See [Which gateways does the openconnect variant support?](#which-gateways-does-the-openconnect-variant-support)

## Proxies

```bash
curl --socks5-hostname 127.0.0.1:1080 https://example.internal/
curl -x http://127.0.0.1:8888 https://example.internal/
```

- Each connection leaves the container the way the container's routing table sends it: through the tunnel for the addresses that the VPN routes, and otherwise directly through the host's network. The same applies before the VPN is connected.
- The HTTP proxy resolves names inside the container. With SOCKS5, use `--socks5-hostname` (or `socks5h://`) so that names are resolved inside the container too. When the VPN connects, the client writes the VPN's DNS settings to `/etc/resolv.conf`, so names that only the VPN's DNS servers know resolve there. The Cisco client replaces the file, and openconnect's vpnc-script rewrites it in place and restores it when the VPN disconnects.

### SOCKS5 username and password

When `SOCKS_USER` and `SOCKS_PASSWD` are both set, the proxy requires them:

```bash
curl -x socks5h://<SOCKS_USER>:<SOCKS_PASSWD>@127.0.0.1:1080 https://example.internal/
```

- dante's `username` method checks them against a system account in the container. At start, the container creates the account `SOCKS_USER` without a home directory or login shell, marks it with the comment `SOCKS5 proxy account`, and sets its password. A later start of the same container, such as `docker restart`, reuses that account and sets its password again.
- The password is not written to the logs or to a command line.
- When only `SOCKS_USER` is set, a warning is logged and the proxy requires no username. When only `SOCKS_PASSWD` is set, the proxy requires no username either.
- The SOCKS5 proxy stays off in the following cases. Each one logs an error that ends with `the SOCKS5 proxy is not started`. Fix the variable and recreate the container.
  - `SOCKS_USER` is not a plain user name: lowercase letters, digits, `_` and `-`, not starting with a digit or `-`, at most 32 characters.
  - `SOCKS_USER` names an existing account that the container did not create for the proxy, such as `root` or `vpnuser`.
  - `SOCKS_PASSWD` contains a newline.
  - Creating the account or setting its password fails.

### SOCKS5 off

A non-empty `NODANTED` leaves the SOCKS5 proxy off. The HTTP proxy is not affected.

### dante and the tunnel interface

danted does not start when one of its external interfaces is missing, and the VPN client creates its tunnel interface only when it connects: `cscotun0` for the Cisco client, and `tun0` for openconnect, which the container tells to use that name. As in [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect)'s `start.sh`, a temporary tun interface with the tunnel interface's name and the address `10.0.0.1/32` stands in for it while danted starts. It is removed once danted listens, so that the VPN client can create its own. For each connection, danted then uses the address of the interface that the kernel routes the destination through (`external.rotation: route`).

## Route mode

In route mode the host reaches addresses inside the VPN without a proxy, by routing them through the container. The container forwards packets from its network to the tunnel and the replies back. As in docker-easyconnect, it masquerades what leaves through the tunnel, so those packets carry the tunnel's address. The compose file turns on forwarding with the sysctl `net.ipv4.ip_forward=1`.

After the VPN is connected, run on the host:

```bash
# The container's IP address on the compose network
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cisco-vpn
# The MTU of the tunnel interface: cscotun0 in the Cisco variant
docker exec cisco-vpn cat /sys/class/net/cscotun0/mtu
# The MTU of the tunnel interface: tun0 in the openconnect variant
docker exec cisco-vpn cat /sys/class/net/tun0/mtu
# Route a VPN subnet through the container
sudo ip route add <VPN subnet> via <container IP> mtu <tunnel MTU>
```

- The tunnel interface is `cscotun0`, which the Cisco client creates (observed in testing), or `tun0`, which the container tells openconnect to create. The tunnel's MTU can be smaller than the MTU of the Docker network (1390 for the Cisco client's tunnel in testing), so the route's `mtu` makes the host send packets that fit into the tunnel.
- `docker exec cisco-vpn ip route show table all` lists the routes in the container, including those through the tunnel interface.
- Remove a route with `sudo ip route del <VPN subnet>`. Routes added this way are lost when the host reboots, and the container's IP address can change when the container is recreated.
- The container gives the host no DNS. In route mode the host resolves names with its own DNS servers, so for names that only the VPN's DNS servers know, use IP addresses or the proxies.
- In the Cisco variant, the Cisco client's chains, which `FORWARD` jumps to, drop forwarded packets whose source is not the tunnel's address (observed in testing). The container's accept rules for route mode therefore come first in `FORWARD`, as in this [Docker forum thread](https://forums.docker.com/t/docker-desktop-windows-and-vpn-no-network-connection-inside-container/91234). See [Firewall](#firewall).

## Keepalive

The keepalive keeps the VPN connection from being dropped as idle. It starts when `PING_ADDR`, `PING_ADDR_URL` or both are set, and works like docker-easyconnect's keepalive:

- Every `PING_INTERVAL` seconds, it pings `PING_ADDR` once and requests `PING_ADDR_URL` without downloading it (`busybox wget --spider`), each only when set. The first check comes one interval after the start.
- A ping fails when no reply comes within 1 second. Either check fails when it takes more than 10 seconds in all, name resolution included.
- Only failures are logged, as `[keepalive] <address> unreachable`. The address or URL is logged as given, so do not put a password or a token in `PING_ADDR_URL`.
- `PING_INTERVAL` is a whole number of seconds above 0, and values such as `30m` or `1.5` are not accepted. With any other value, `[start] error: PING_INTERVAL is not a whole number of seconds above 0; the keepalive is not started` is logged once, and neither check runs.

## Persistence

The compose file mounts the host directory `CISCO_VPN_DATA` (default `$HOME/.cisco-vpn-data` of the user that runs `docker compose`) at `/home/vpnuser`, the home directory of the user `vpnuser`, which runs the Cisco window in the Cisco variant. `docker compose down` and a new `docker compose up` keep it. Docker creates the directory when it does not exist, and at each start the container gives the directory itself, but not its contents, to `vpnuser` (uid and gid 1000).

In both variants, the directory holds `.vnc/passwd`, the VNC password, owned by `vpnuser` with mode 600. In the openconnect variant, the container writes nothing else there: openconnect runs as root, and root's home directory `/root` is not in the mounted directory.

In the Cisco variant, it also holds:

- `.vpn/.anyconnect`: the Cisco window's user preference file. The window reads it at start (found with strace in testing) and logs the values it read as `Current Preference Settings`. The client saves the last gateway address (`DefaultHostName`) there when it connects, and the preferences that the user changes in the window (observed in testing). When the file does not exist, the container creates it with "Allow local (LAN) access" turned on, so that the window shows the setting that the [client profile](#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it) turns on. The client uses its defaults for every other preference:

  ```xml
  <?xml version="1.0" encoding="UTF-8"?>
  <AnyConnectPreferences>
  <ControllablePreferences>
  <LocalLanAccess>true</LocalLanAccess>
  </ControllablePreferences>
  </AnyConnectPreferences>
  ```

  The container never changes or replaces an existing file. To go back to this default, delete the file while the container is stopped.
- `.local/shareacwebhelper.cookies.sqlite` and `.local/shareacwebhelper/`: the cookies and the cache of the login window (observed in testing; the client names them without a `/` after `share`).
- Anything else that the Cisco client and its login window save in the home directory.

To start over, remove the container and delete the directory. The VNC password is then `password` again unless `PASSWORD` is set.

## Firewall

The rules are IPv4 iptables rules in the container's own network namespace. Each one carries the comment `cisco-vpn-docker`. They name the tunnel interface of the variant, `cscotun0` or `tun0`:

| Table and chain | Rules | Purpose |
|---|---|---|
| filter `INPUT` | accept packets of established and related connections, then drop new TCP connections from the tunnel interface | Machines on the VPN side cannot open TCP connections to the container's services. As in docker-easyconnect's `config_vpn_iptables`. |
| filter `FORWARD` | accept packets from `eth0` to the tunnel interface, and packets of established and related connections back | [Route mode](#route-mode) |
| nat `POSTROUTING` | masquerade what leaves through the tunnel interface | Route mode, as in docker-easyconnect's `config_vpn_iptables` |

- In the Cisco variant, when the Cisco client connects, it adds chains of its own and jumps to them from `INPUT` and `FORWARD` (observed in testing). Its chain for `INPUT` returns packets from the tunnel interface to `INPUT`, which would then accept them (observed in testing). The drop rule above stops new TCP connections among them.
- The Cisco client may rebuild its chains when it connects. Every 5 seconds the container checks that its rules are the first rules of their chains, and puts them back when they are not. Each repair is logged, for example `[firewall] put the rules first in the INPUT chain of the filter table`. Only rules with the comment are ever deleted or moved.
- When the rules cannot be put in place at start, the container stops before any service starts and logs `[start] error: cannot put the firewall rules in place (the container needs the NET_ADMIN capability); stopping before any service starts`. When a later check fails, the error is logged once and the check is tried again every 5 seconds.
- The openconnect variant adds one more rule when it starts openconnect, in nat `PREROUTING`: it redirects TCP connections to port 29786 of the container's own addresses to port 20000, where socat forwards them to openconnect (see the [FAQ](#where-does-port-29786-come-from)). This rule has no comment, and the 5-second check does not cover it.
- There are no IPv6 rules. The container's services listen only on IPv4 and on the IPv6 loopback address `::1`, so the VPN side cannot reach them over IPv6.

## Diagnostics

```bash
docker logs -f cisco-vpn
```

Each line starts with the name of the service that wrote it: `[start]`, `[firewall]`, `[vnc]`, `[flwm]`, `[novnc]`, `[socks5]`, `[http]` or `[keepalive]`, and also `[vpnagentd]` and `[vpnui]` in the Cisco variant, or `[openconnect]` (the terminal window and the login URL) and `[sso-callback]` (socat's forward of port 29786) in the openconnect variant. `[start] all services started` means that the entrypoint has finished its startup steps, not that every service runs. A service that was not started logs why, for example an error that ends with `the SOCKS5 proxy is not started`. A service that exits is logged as `exited (code <n>), restarting in 1 second`, and the next lines show whether it keeps failing.

- In the Cisco variant, as in [Cisco's article on Secure Client in Docker](https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/223124-configure-secure-client-vpn-for-use-in.html), `vpnagentd` runs in the foreground with `-execv_instance` and is restarted when it exits, and `CSC_LOGGING_OUTPUT=STDOUT` sends the logs of `vpnagentd` and `vpnui` to `docker logs`.
- In the openconnect variant, openconnect's messages appear only in the terminal window. The login URL also goes to `docker logs`.

```bash
docker exec cisco-vpn diag.sh
```

`diag.sh` prints, in one go:

- in the Cisco variant, the Cisco package version, `vpn state`, the Cisco processes with their memory use, and the files under `/opt/cisco/secureclient` that changed after the container was created or started;
- in the openconnect variant, the openconnect version, the processes of openconnect, xterm and socat with their memory use, and the listeners on port 29786 and on socat's port 20000;
- the interfaces, the routes of all routing tables except `local` and `broadcast` routes, and the policy routing rules;
- the firewall rules from `iptables-save`, and from `ip6tables-save`, `iptables-legacy-save` and `nft list ruleset` when those commands exist;
- `/etc/resolv.conf` and its mounts, and `/dev/net/tun`;
- the other related processes (Xtigervnc, websockify, danted, tinyproxy and flwm) with their memory use, and `free -m`.

The output contains the VPN's addresses, routes and DNS servers. In the openconnect variant, it also shows the full command lines of openconnect and its terminal, with any secrets passed in `CLI_OPTS`, such as `--cookie`, `--token-secret` or `--key-password`. Check it before you share it.

## Tests

The scripts in `tests/` run as root on the Docker host, from any working directory, against the container `cisco-vpn` of the repository's compose file.

`tests/smoke.sh` needs no VPN login. Run it after `docker compose up -d --build`. It reads `/etc/vpn-type` in the container and runs the checks of that variant:

- It restarts and recreates the container many times, which ends any VPN session. Its recreates use the repository's compose file and the image `cisco-vpn-docker:dev`. At the end it recreates the container with the configured settings.
- It needs internet access: the proxy checks request `https://deb.debian.org/`.
- The first checks run on the configured container and data directory. `.env` must set none of `VNC_SIZE`, `NODANTED`, `SOCKS_USER` and `SOCKS_PASSWD`. In the Cisco variant, the saved preferences must keep "Allow local (LAN) access" turned on (`LocalLanAccess` true in `.vpn/.anyconnect`).
- The cases that change the data directory use `tmp/smoke-data` in the repository, not the configured data directory.
- In the openconnect variant, the configured container runs openconnect for the configured `VPN_SERVER`, so the tests connect to that gateway without logging in: at the first checks, at two restarts and at the final recreate. Every other recreate leaves `VPN_SERVER` empty or sets it to a test gateway that the checks start in the container. That test gateway asks for single sign-on in an external browser, and the checks of the login URL and of the forward of port 29786 use it.
- An interrupted run can leave the container with test settings or test commands. To recreate it with the configured settings, run `docker compose up -d --force-recreate`.

To test the openconnect variant from a checkout whose `packages/` holds a Cisco package, build it from a copy of the committed files, which hold no package, under the image name that the compose file uses. This replaces the image of the Cisco variant under that name until `docker compose build` builds it again:

```bash
rm -rf tmp/oc-context && mkdir -p tmp/oc-context
git archive HEAD | tar -x -C tmp/oc-context
docker build -t cisco-vpn-docker:dev tmp/oc-context
docker compose up -d --force-recreate
tests/smoke.sh
```

The openconnect variant has not yet been accepted with a real login on a real gateway: its tests use the test gateway in the container, and `tests/connected.sh` checks only the Cisco variant.

`tests/connected.sh` checks a real connection of the Cisco variant. Log in to the VPN in the Cisco window first. It needs root, and for the route mode check it adds one `/32` host route through the container and removes it again. The script's header lists its checks and environment variables.

## FAQ

### Why does the container need `SYS_ADMIN`?

Docker bind-mounts `/etc/resolv.conf` and `/etc/hosts` into the container. When `vpnagentd` sets up the VPN's DNS, it renames `/etc/resolv.conf` to `/etc/resolv.conf.vpnbackup` and writes a new file. A mount point cannot be renamed, so the rename fails with `EBUSY` and the connection is aborted (observed in testing). At start, the container copies the content of both files, unmounts them and writes the content back, as in the [EyeSeeTea troubleshooting notes](https://github.com/EyeSeeTea/know-how/wiki/Cisco-Secure-Client-(secureclient)-v5.1-Docker-troubleshooting) and [darrencocco/anyconnect-client](https://github.com/darrencocco/anyconnect-client).

`umount` needs `SYS_ADMIN`, and that is why the container has it. Docker's default AppArmor profile allows `umount` and denies `mount` ([template](https://github.com/moby/profiles/blob/main/apparmor/template.go)). Without `SYS_ADMIN`, the log shows `[start] warning: cannot unmount /etc/resolv.conf; VPN DNS setup will fail (the container needs SYS_ADMIN)`.

This step belongs to the Cisco variant. The openconnect variant unmounts nothing: openconnect's vpnc-script writes `/etc/resolv.conf` in place, which works on the mounted file. The example compose file adds `SYS_ADMIN` for both variants.

`NET_ADMIN` and `/dev/net/tun` are for the tunnel interface, the routes and the firewall rules. Without `NET_ADMIN` the container stops at start (see [Firewall](#firewall)).

### Why does the Cisco window run as an unprivileged user, with a utmp login record?

This was observed in testing, and no public source for it was found:

- `vpnagentd` verifies the gateway's certificate as the logged-in user who runs the GUI, and refuses to do so as root. Its log then shows `Refusing to launch process as uid 0` and `PROCESS_API_ERROR_NO_USER_TOKEN`.
- It finds that user through a utmp login record whose PID is an ancestor of `vpnui`. Without such a record, it logs `Reached init/systemd process while trying to determine the logged in username`.

On a desktop, the display manager writes this record. The container has no display manager, so it runs `vpnui` as the user `vpnuser`, with `setpriv` in a `dbus-run-session`. It writes a login record for display `:1` with `utmpdump -r` from util-linux, using the PID of that session. The record is cleared when `vpnui` exits.

### Why are the WebKit sandbox and compositing turned off?

The Cisco client's login window uses WebKitGTK. The container cannot create user namespaces, so WebKit's sandbox cannot be created, and the VNC display has no GPU. `vpnui` therefore runs with `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` and `WEBKIT_DISABLE_COMPOSITING_MODE=1` (observed in testing). Pages in the login window run without WebKit's sandbox, so use the window only for the gateway's login.

### How is "Allow local (LAN) access" turned on, and what if the gateway does not allow it?

Once the VPN is connected, the Cisco client's firewall chains drop new connections from the local network (observed in testing). For the container, the local network is the Docker network that the host connects from. Without local LAN access, the host can no longer reach noVNC or the proxies.

Cisco's "Allow local (LAN) access when using VPN" setting lets the local network through when the gateway allows local LAN access as well. [Cisco's documentation](https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/221024-configure-local-lan-access-for-secure-cl.html) turns it on in the client profile. When `VPN_SERVER` is set, the container writes such a profile at each start, as `/opt/cisco/secureclient/vpn/profile/cisco-vpn-docker.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile xmlns="http://schemas.xmlsoap.org/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://schemas.xmlsoap.org/encoding/ AnyConnectProfile.xsd">
  <ClientInitialization>
    <LocalLanAccess UserControllable="true">true</LocalLanAccess>
  </ClientInitialization>
  <ServerList>
    <HostEntry>
      <HostName>vpn.example.com</HostName>
      <HostAddress>vpn.example.com</HostAddress>
    </HostEntry>
  </ServerList>
</AnyConnectProfile>
```

- The VPN daemon `vpnagentd` takes the setting at connect time from the profile whose server list holds the gateway. Its log then shows `loading preferences for profile 'cisco-vpn-docker.xml'`, and the connection log shows `IPv4 Local LAN Wildcard: received` when the gateway allows local LAN access. With the profile, the host reached noVNC, the proxies and the routed addresses while the VPN was connected (observed in testing). Connect to the address exactly as given in `VPN_SERVER`, so that the profile applies.
- The user preference file `~/.vpn/.anyconnect`, which the container creates with the setting turned on (see [Persistence](#persistence)), is not enough by itself. The Cisco window reads it, but `vpnagentd` does not, and the connection log showed `IPv4 Local LAN Wildcard: local LAN access preference is disabled` (observed in testing). The file is still created, because before a connection the window does not take the setting from the profile: with the profile and no preference file, the window read `LocalLanAccess: false` (observed in testing). Local LAN access worked in testing with both the profile and that file.
- `UserControllable="true"` keeps the checkbox in the Cisco window's preferences (the gear icon). A value that the user saves there goes to `~/.vpn/.anyconnect`.
- Without `VPN_SERVER` the container writes no profile and logs a warning. Turning the checkbox on in the Cisco window also turned local LAN access on in testing.
- The profile is in the image's file system, not in the data directory, so each new container writes it again from `VPN_SERVER`.

A gateway that does not allow local LAN access was not tested, and what happens then depends on the gateway's policy. If the host cannot reach noVNC or the proxies after the VPN connects, look for `IPv4 Local LAN Wildcard` in `docker logs cisco-vpn`. `received` was logged in testing when local LAN access worked. `local LAN access preference is disabled` means that the client did not ask for it, for example because `VPN_SERVER` is not set or differs from the address that was entered. `docker exec` does not go through the network, so it still works:

```bash
docker exec cisco-vpn /opt/cisco/secureclient/bin/vpn state
docker restart cisco-vpn    # ends the VPN session; noVNC is reachable again
```

Local LAN access is configured on the gateway, by its administrator (see the Cisco documentation above).

### The log shows that a module from the gateway failed to install with `pkcon`

A gateway can push additional Cisco modules to the client, such as the Socket Filter module in testing. The client downloads the module and installs it with `pkcon` from PackageKit, which the container does not have, so the installation fails. The VPN connection is not affected (observed in testing).

### Which gateways does the openconnect variant support?

openconnect asks for what the gateway's login form needs, such as the username, password, one-time password or group, in the terminal window, so the openconnect variant supports gateways that log in that way.

For SAML single sign-on, the gateway tells the client in its login form whether to open the login page in a browser of the client's own (embedded) or in an external browser. openconnect runs its `--external-browser` program only when the gateway asks for the external browser (`process_auth_form` in openconnect's `library.c`), and the openconnect command line has no embedded browser. A gateway that offers single sign-on only in the embedded mode therefore makes openconnect stop with `No SSO handler` and `Failed to complete authentication`. Use the Cisco variant for such a gateway: its login window is an embedded browser.

### Why does the openconnect variant have no browser?

openconnect has no login window of its own. For single sign-on in the external browser mode, it starts the program that `--external-browser` names with the login URL, and waits for the browser to return to `http://localhost:29786/`. In this image that program, `print-login-url.sh`, only prints the URL, in the terminal window and in `docker logs`, so the login runs in a browser on your own machine. The image therefore needs no browser, and none is installed.

### Where does port 29786 come from?

After a single sign-on in the external browser mode, the browser is sent to `http://localhost:29786/api/sso/...`. openconnect listens for that request on port 29786 of the IPv6 loopback address `[::1]` only, and only while it waits for the browser (`handle_external_browser` in openconnect's `hpke.c`). The port must therefore be reachable as `localhost:29786` from the browser: the compose file publishes it on the Docker host's `127.0.0.1`, and on another machine an SSH forward of the same port reaches it (see [Ports](#ports)).

A published port reaches the container's own network address, not its loopback address. As docker-easyconnect's `force_open_ports` in its `start.sh` does for the ports where its clients wait for the browser, a nat `PREROUTING` rule redirects TCP connections to port 29786 of the container's own addresses to port 20000, where socat accepts them and connects to `[::1]:29786`.

- The rule matches only the container's own addresses, so route mode is not affected.
- Only this port is forwarded, so VNC on port 5901 and the other services on the loopback address stay unreachable from outside. socat listens on port 20000 of all the container's IPv4 addresses, so the container's network reaches that port as well, and it leads only to the callback.
- The firewall's `INPUT` rules still drop new TCP connections from the tunnel, also after the redirect and to port 20000.
- The rule and socat are set up only when openconnect is started, that is when `VPN_SERVER` is set and `CLI_OPTS` is accepted.

### Why is there no prebuilt image?

This project publishes no image of the Cisco variant: the image contains the Cisco Secure Client, and [Cisco's software terms](https://www.cisco.com/c/en/us/about/legal/cloud-and-software/software-terms.html) do not allow providing the software to third parties. Build the image yourself from your own copy of the package. To run it on other hosts, push it to a private repository in a container registry, by hand or with the workflow, and pull it from there (see [Building and pushing by hand](#building-and-pushing-by-hand), [Building in GitHub Actions](#building-in-github-actions) and [Deploying a prebuilt image](#deploying-a-prebuilt-image)).
