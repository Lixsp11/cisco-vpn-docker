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
- [FAQ](#faq)

## Build

Put your Cisco Secure Client VPN package for Linux (the full package with the GUI) in `packages/`. The build argument `CSC_DEB` names the file, and its default is `cisco-secure-client-vpn_5.1.20.333_amd64.deb`. apt installs the package and its dependencies in a `debian:bookworm-slim` image.

With the default file name:

```bash
docker compose up -d --build
```

With another file name, pass the build argument each time you build:

```bash
docker compose build --build-arg CSC_DEB=cisco-secure-client-vpn_<version>_amd64.deb
docker compose up -d
```

The image is `cisco-vpn-docker:dev` and the container is `cisco-vpn`.

### Building in GitHub Actions

The workflow `.github/workflows/build.yml` builds the image and pushes it to the GitHub container registry (ghcr.io). It runs only when started by hand, from the Actions tab or with `gh workflow run build.yml`. Set the secret and the variable in the repository settings, under Secrets and variables > Actions:

| Name | Kind | Value |
|---|---|---|
| `CSC_DEB_URL` | Secret, required | Download URL of your own Cisco package, for example a pre-signed object storage link. The workflow checks that the file is the package `cisco-secure-client-vpn` for `amd64`, and names it after the version in the package. |
| `IMAGE_NAME` | Variable, optional | Full image name of the form `ghcr.io/<owner>/<name>`, with a single name part. The default is `ghcr.io/<owner>/<repository>`. The workflow lowercases the name. |

The image is tagged with the package version and `latest`. The package on ghcr.io must be private (see [Why is there no prebuilt image?](#why-is-there-no-prebuilt-image)). Before it downloads the Cisco package, the workflow stops with an error unless all of these hold:

- The repository is private. A package that a workflow creates gets the visibility of the repository.
- The image name has the form above.
- ghcr.io refuses anonymous pulls of the image (HTTP 401, 403 or 404), so the package is private or does not exist yet. A package that does not exist yet is created by the push. When anyone can pull the image without credentials, or when a request to ghcr.io fails or gets any other answer, the workflow stops.

## Configuration

Set the variables in a `.env` file next to `docker-compose.yml`, or in the environment of `docker compose up`. The compose file passes them to the container, and an empty value means the default. `docker compose up -d` recreates the container when a value changes.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `VPN_SERVER` | empty | Address of the VPN gateway, a host name or an IP address (letters, digits, `.`, `-` and `:` only). The container writes a Cisco client profile for it that turns on "Allow local (LAN) access", so that the host can still reach noVNC and the proxies once the VPN is connected. See the [FAQ](#how-is-allow-local-lan-access-turned-on-and-what-if-the-gateway-does-not-allow-it). When empty, a warning is logged; any other value logs an error. In both cases no profile is written. |
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
| 5901 | VNC (Xtigervnc) | Listens only inside the container and is not published |

The proxies accept any client that reaches their port. SOCKS5 can require a username and password, and the HTTP proxy has no authentication. The example compose file binds the ports to `127.0.0.1`, so other machines cannot reach them through the host. From another machine, forward the ports over SSH:

```bash
ssh -N -L 127.0.0.1:6080:127.0.0.1:6080 -L 127.0.0.1:1080:127.0.0.1:1080 -L 127.0.0.1:8888:127.0.0.1:8888 user@host
```

## Logging in

1. Open `http://127.0.0.1:6080/vnc.html` and enter the VNC password.
2. In the Cisco window, enter the VPN address exactly as in `VPN_SERVER` (for example `vpn.example.com`) and click Connect.
3. Complete the login in the window that opens. It is the Cisco client's built-in browser, so SAML single sign-on, MFA and any other step that the gateway asks for work there.

The Cisco window reopens about 1 second after it is closed. When the VPN session ends or expires, log in again in the Cisco window. `docker restart cisco-vpn` and `docker compose down` end the VPN session.

To see the state of the connection from the host:

```bash
docker exec cisco-vpn /opt/cisco/secureclient/bin/vpn state
```

## Proxies

```bash
curl --socks5-hostname 127.0.0.1:1080 https://example.internal/
curl -x http://127.0.0.1:8888 https://example.internal/
```

- Each connection leaves the container the way the container's routing table sends it: through the tunnel for the addresses that the VPN routes, and otherwise directly through the host's network. The same applies before the VPN is connected.
- The HTTP proxy resolves names inside the container. With SOCKS5, use `--socks5-hostname` (or `socks5h://`) so that names are resolved inside the container too. When the Cisco client connects, it replaces `/etc/resolv.conf` with the VPN's DNS settings, so names that only the VPN's DNS servers know resolve there.

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

danted does not start when one of its external interfaces is missing, and the Cisco client creates its tunnel interface `cscotun0` only when it connects. As in [docker-easyconnect](https://github.com/docker-easyconnect/docker-easyconnect)'s `start.sh`, a temporary tun interface named `cscotun0`, with the address `10.0.0.1/32`, stands in for it while danted starts. It is removed once danted listens, so that the Cisco client can create its own. For each connection, danted then uses the address of the interface that the kernel routes the destination through (`external.rotation: route`).

## Route mode

In route mode the host reaches addresses inside the VPN without a proxy, by routing them through the container. The container forwards packets from its network to the tunnel and the replies back. As in docker-easyconnect, it masquerades what leaves through the tunnel, so those packets carry the tunnel's address. The compose file turns on forwarding with the sysctl `net.ipv4.ip_forward=1`.

After the VPN is connected, run on the host:

```bash
# The container's IP address on the compose network
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cisco-vpn
# The MTU of the tunnel interface
docker exec cisco-vpn cat /sys/class/net/cscotun0/mtu
# Route a VPN subnet through the container
sudo ip route add <VPN subnet> via <container IP> mtu <tunnel MTU>
```

- `cscotun0` is the tunnel interface that the Cisco client creates (observed in testing). Its MTU, 1390 in testing, is smaller than the MTU of the Docker network, so the route's `mtu` makes the host send packets that fit into the tunnel.
- `docker exec cisco-vpn ip route show table all` lists the routes in the container, including those through `cscotun0`.
- Remove a route with `sudo ip route del <VPN subnet>`. Routes added this way are lost when the host reboots, and the container's IP address can change when the container is recreated.
- The container gives the host no DNS. In route mode the host resolves names with its own DNS servers, so for names that only the VPN's DNS servers know, use IP addresses or the proxies.
- The Cisco client's chains, which `FORWARD` jumps to, drop forwarded packets whose source is not the tunnel's address (observed in testing). The container's accept rules for route mode therefore come first in `FORWARD`, as in this [Docker forum thread](https://forums.docker.com/t/docker-desktop-windows-and-vpn-no-network-connection-inside-container/91234). See [Firewall](#firewall).

## Keepalive

The keepalive keeps the VPN connection from being dropped as idle. It starts when `PING_ADDR`, `PING_ADDR_URL` or both are set, and works like docker-easyconnect's keepalive:

- Every `PING_INTERVAL` seconds, it pings `PING_ADDR` once and requests `PING_ADDR_URL` without downloading it (`busybox wget --spider`), each only when set. The first check comes one interval after the start.
- A ping fails when no reply comes within 1 second. Either check fails when it takes more than 10 seconds in all, name resolution included.
- Only failures are logged, as `[keepalive] <address> unreachable`. The address or URL is logged as given, so do not put a password or a token in `PING_ADDR_URL`.
- `PING_INTERVAL` is a whole number of seconds above 0, and values such as `30m` or `1.5` are not accepted. With any other value, `[start] error: PING_INTERVAL is not a whole number of seconds above 0; the keepalive is not started` is logged once, and neither check runs.

## Persistence

The compose file mounts the host directory `CISCO_VPN_DATA` (default `$HOME/.cisco-vpn-data` of the user that runs `docker compose`) at `/home/vpnuser`, the home directory of the user that runs the Cisco window. `docker compose down` and a new `docker compose up` keep it. Docker creates the directory when it does not exist, and at each start the container gives the directory itself, but not its contents, to `vpnuser` (uid and gid 1000).

The directory holds:

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
- `.vnc/passwd`: the VNC password, owned by `vpnuser` with mode 600.
- Anything else that the Cisco client and its login window save in the home directory.

To start over, remove the container and delete the directory. The VNC password is then `password` again unless `PASSWORD` is set.

## Firewall

The rules are IPv4 iptables rules in the container's own network namespace. Each one carries the comment `cisco-vpn-docker`:

| Table and chain | Rules | Purpose |
|---|---|---|
| filter `INPUT` | accept packets of established and related connections, then drop new TCP connections from `cscotun0` | Machines on the VPN side cannot open TCP connections to the container's services. As in docker-easyconnect's `config_vpn_iptables`. |
| filter `FORWARD` | accept packets from `eth0` to `cscotun0`, and packets of established and related connections back | [Route mode](#route-mode) |
| nat `POSTROUTING` | masquerade what leaves through `cscotun0` | Route mode, as in docker-easyconnect's `config_vpn_iptables` |

- When the Cisco client connects, it adds chains of its own and jumps to them from `INPUT` and `FORWARD` (observed in testing). Its chain for `INPUT` returns packets from the tunnel interface to `INPUT`, which would then accept them (observed in testing). The drop rule above stops new TCP connections among them.
- The client may rebuild its chains when it connects. Every 5 seconds the container checks that its rules are the first rules of their chains, and puts them back when they are not. Each repair is logged, for example `[firewall] put the rules first in the INPUT chain of the filter table`. Only rules with the comment are ever deleted or moved.
- When the rules cannot be put in place at start, the container stops before any service starts and logs `[start] error: cannot put the firewall rules in place (the container needs the NET_ADMIN capability); stopping before any service starts`. When a later check fails, the error is logged once and the check is tried again every 5 seconds.

## Diagnostics

```bash
docker logs -f cisco-vpn
```

Each line starts with the name of the service that wrote it: `[start]`, `[firewall]`, `[vnc]`, `[flwm]`, `[novnc]`, `[vpnagentd]`, `[vpnui]`, `[socks5]`, `[http]` or `[keepalive]`. `[start] all services started` means that the entrypoint has finished its startup steps, not that every service runs. A service that was not started logs why, for example an error that ends with `the SOCKS5 proxy is not started`. A service that exits is logged as `exited (code <n>), restarting in 1 second`, and the next lines show whether it keeps failing. As in [Cisco's article on Secure Client in Docker](https://www.cisco.com/c/en/us/support/docs/security/secure-client-5/223124-configure-secure-client-vpn-for-use-in.html), `vpnagentd` runs in the foreground with `-execv_instance` and is restarted when it exits, and `CSC_LOGGING_OUTPUT=STDOUT` sends the logs of `vpnagentd` and `vpnui` to `docker logs`.

```bash
docker exec cisco-vpn diag.sh
```

`diag.sh` prints, in one go:

- the Cisco package version and `vpn state`;
- the interfaces, the routes of all routing tables except `local` and `broadcast` routes, and the policy routing rules;
- the firewall rules from `iptables-save`, and from `ip6tables-save`, `iptables-legacy-save` and `nft list ruleset` when those commands exist;
- `/etc/resolv.conf` and its mounts, and `/dev/net/tun`;
- the related processes with their memory use, and `free -m`;
- the files under `/opt/cisco/secureclient` that changed after the container was created or started.

The output contains the VPN's addresses, routes and DNS servers. Check it before you share it.

## FAQ

### Why does the container need `SYS_ADMIN`?

Docker bind-mounts `/etc/resolv.conf` and `/etc/hosts` into the container. When `vpnagentd` sets up the VPN's DNS, it renames `/etc/resolv.conf` to `/etc/resolv.conf.vpnbackup` and writes a new file. A mount point cannot be renamed, so the rename fails with `EBUSY` and the connection is aborted (observed in testing). At start, the container copies the content of both files, unmounts them and writes the content back, as in the [EyeSeeTea troubleshooting notes](https://github.com/EyeSeeTea/know-how/wiki/Cisco-Secure-Client-(secureclient)-v5.1-Docker-troubleshooting) and [darrencocco/anyconnect-client](https://github.com/darrencocco/anyconnect-client).

`umount` needs `SYS_ADMIN`, and that is why the container has it. Docker's default AppArmor profile allows `umount` and denies `mount` ([template](https://github.com/moby/profiles/blob/main/apparmor/template.go)). Without `SYS_ADMIN`, the log shows `[start] warning: cannot unmount /etc/resolv.conf; VPN DNS setup will fail (the container needs SYS_ADMIN)`.

`NET_ADMIN` and `/dev/net/tun` are for the tunnel interface, the routes and the firewall rules. Without `NET_ADMIN` the container stops at start (see [Firewall](#firewall)).

### Why does the Cisco window run as an unprivileged user, with a utmp login record?

This was observed in testing, and no public source for it was found:

- `vpnagentd` verifies the gateway's certificate as the logged-in user who runs the GUI, and refuses to do so as root. Its log then shows `Refusing to launch process as uid 0` and `PROCESS_API_ERROR_NO_USER_TOKEN`.
- It finds that user through a utmp login record whose PID is an ancestor of `vpnui`. Without such a record, it logs `Reached init/systemd process while trying to determine the logged in username`.

On a desktop, the display manager writes this record. The container has no display manager, so it runs `vpnui` as the user `vpnuser`, with `setpriv` in a `dbus-run-session`. It writes a login record for display `:1` with `utmpdump -r` from util-linux, using the PID of that session. The record is cleared when `vpnui` exits.

### Why are the WebKit sandbox and compositing turned off?

The login window uses WebKitGTK. The container cannot create user namespaces, so WebKit's sandbox cannot be created, and the VNC display has no GPU. `vpnui` therefore runs with `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` and `WEBKIT_DISABLE_COMPOSITING_MODE=1` (observed in testing). Pages in the login window run without WebKit's sandbox, so use the window only for the gateway's login.

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

### Why is there no prebuilt image?

The image contains the Cisco Secure Client, and [Cisco's software terms](https://www.cisco.com/c/en/us/about/legal/cloud-and-software/software-terms.html) do not allow providing the software to third parties. Build the image yourself from your own copy of the package.
