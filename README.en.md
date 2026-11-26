[Русский](README.md)

# nginx-stream

A relay (TCP/UDP proxy) built on nginx: it accepts connections on this server and passes them to another server
as they are, without decrypting anything. One command to install; the installer asks the questions and sets
everything up.

```
  client  ──►  relay (this server)  ──►  destination server
               192.0.2.10:443            [2001:db8::10]:443
```

Clients connect to the relay, and the relay connects to the destination server. To the client it looks as if the
relay itself were the server.

## When you need it

- **The server is reachable over IPv6 only**, but clients use IPv4. The relay accepts on IPv4 and passes on over
  IPv6.
- **The server cannot be reached directly**, but the relay can.
- **Several servers behind one address:** port 443 goes to one server, 2222 to another, and so on.
- **Several sites on one port 443:** the relay looks at which name the client asks for (for example,
  `a.example.com` or `b.example.com`) and sends the connection to the right server.

The relay needs no certificates or keys: encrypted data passes through it without being decrypted. The installer
does not break anything already on the server: it does not remove packages, does not turn off IPv6 and does not
touch firewall rules that were there before it.

## What you need

- A server with **Debian 12 or newer** or **Ubuntu 22.04 or newer** and `root` access. 1 CPU core and 512 MB of
  memory are enough.
- **The destination server address** — where clients should really end up: IPv4 (`203.0.113.10`), IPv6
  (`2001:db8::10`) or a domain (`backend.example.com`).
- **Ports** — which ports to accept and which ports to send to. If you do not know, start with `tcp:443`.
- If the destination server is reachable over IPv6, the relay needs IPv6 too. To check:
  `ip -6 addr show scope global` — if it prints nothing, there is no IPv6, and the installer stops and explains.

## Installation

1. Connect to the server over SSH as `root`.
2. Run this command:

   ```bash
   bash <(wget -qO- --inet4-only https://raw.githubusercontent.com/drno88/nginx-stream/main/install.sh)
   ```

   If there is no `wget`, do the same with `curl`:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/drno88/nginx-stream/main/install.sh -o install.sh
   bash install.sh
   ```

3. Answer the questions (below: what each one means). If you are not sure, press Enter: the default value is
   used, and it suits most people.
4. Check the summary and confirm. A minute later the relay works, and the installer prints which ports it listens
   on.

After the installation the server has a `nginx-stream` command: use it to change settings, see the state and
remove the relay (see "Management").

## Installer questions

Every question can be answered in advance with a flag — then the installer does not ask it (see "All
parameters").

**Language** — Russian or English. Russian by default.

**Destination address** — where to send connections. This is the server that really serves
the clients. Required. If you give a domain, nginx looks up its IP once, at start; if the domain's IP changes,
restart nginx: `systemctl restart nginx`.

**Port rules** — what to accept and where to send it. The default is `tcp:443`: accept TCP on port 443 and send
it to the same port of the destination server. How to write your own is in "Port rules" below.

**Listen on which addresses?** — on which relay addresses to accept connections: IPv4 only, or IPv4 and IPv6. By default both, if
the server has IPv6. If you do not know, leave it as it is.

**Send PROXY protocol to the destination?** — whether to pass the real client address to the destination server.
Without it the destination server sees the relay's address. The default is **no**. Turn it on only if the
destination server is set up to accept it, otherwise no connection will get through. Works for TCP only.

**nginx log** — `none` (default) or `errors only`. Errors help when something does not work; the log is in
`/var/log/nginx/error.log`.

**Tune kernel parameters?** — set up the network for a proxy: more simultaneous connections,
buffers, the BBR algorithm. The default is **yes**. Settings that cannot be changed on this server are simply
skipped.

**Protect SSH from brute force?** — at most 10 new SSH connections per minute from one network (/24, for IPv6 — /64);
the extras are dropped. Guessing a password becomes pointless. The default is **yes**. It does not get in the way of normal SSH
work.

**Scan protection?** — the server stops answering ping and closed ports, so it is harder to tell from outside what
runs on it. The default is **no**. If you later start a new service on a port below 10000, run `nginx-stream` and
reconfigure with the same answers, otherwise that service's clients will wait on errors.

**Enable unattended security updates?** — the server installs security updates by itself (without a reboot). The
default is **yes**.

**Continue?** — the installer shows a summary of your answers. `y` — install, `n` — quit without changing
anything.

## Port rules

A rule is one entry "what to accept → where to send it". Several rules are written with commas, no spaces.

### Let us start with the simple ones

| Entry | What it does |
|---|---|
| `tcp:443` | accept TCP on port 443 → send to port 443 of the destination server |
| `udp:443` | the same for UDP |
| `both:443` | both TCP and UDP on port 443 |
| `tcp:8443>443` | accept on 8443 → send to 443 |
| `tcp:2222>203.0.113.20:22` | accept on 2222 → send to **another** server, `203.0.113.20`, port 22 |
| `udp:51820>[2001:db8::20]:51820` | send to a server with an IPv6 address — write the address **in square brackets** |
| `tcp:443,udp:443,tcp:2222>203.0.113.20:22` | three rules at once |

Parts of an entry:

- **`tcp`, `udp` or `both`** — the protocol. Which one you need is written in the settings of the program the
  relay is for. If you do not know, it is most often `tcp`; `both` if you need both.
- **the port after the colon** — the port the relay accepts on. From 1 to 65535.
- **`>` and what follows** — where to send. A port alone (`>443`) — to the destination server from the
  "Destination address" question. An address and a port (`>203.0.113.20:22`) — to that server. No `>` — to the
  destination server, the same port.

### When you need more

These parts are rarely needed. If you do not understand why you would want them, do not use them.

| I want | Entry |
|---|---|
| The relay has two external addresses, and each should lead to its own server | `udp:192.0.2.20:443>[2001:db8::20]:443,udp:192.0.2.21:443>[2001:db8::21]:443` |
| Listen on only one relay address | `tcp:[2001:db8::1]:443>203.0.113.10:443` |
| The destination server accepts only from a certain relay address | `udp:443>[2001:db8::21]:443@[2001:db8::5]` |
| One port 443, the server is chosen by the site name | `tcp:443/a.example.com>203.0.113.5:443,tcp:443/*.b.example.com>203.0.113.6:443,tcp:443>203.0.113.9:443` |

- **Listen address** (`192.0.2.20:` before the port) — on which relay address this rule accepts. Needed only if
  the server has several external addresses. The address must be on the server (`ip addr`).
- **Outgoing address** (`@address` at the end) — which relay address to use to reach the destination server.
  Needed when the relay has several addresses and the destination server accepts from only one. The address must
  be on the server and of the same type as the destination address: IPv4 with IPv4, IPv6 with IPv6.
- **Name** (`/a.example.com` after the port) — TCP only. The relay looks at which name the client asks for over
  TLS (HTTPS and other encrypted protocols) and sends it to the server of that rule. The name is written exactly
  (`a.example.com`) or for all subdomains (`*.b.example.com` — matches `x.b.example.com` but not `b.example.com`
  itself). A rule on the same port without a name is the "default": everyone else goes there, including
  non-TLS traffic. The names must point to the relay's address in DNS. For UDP on the same port, add a separate
  rule `udp:443`.

The full format of one rule:

```
protocol:[listen_address:]port[/name][>[host:]target_port][@outgoing_address]
```

### When the installer refuses

The installer checks the rules before installing and explains what is wrong. Common reasons:

- an IPv6 address without square brackets: it must be `[2001:db8::20]:443`, not `2001:db8::20:443`;
- a port below 1 or above 65535;
- the same rule twice (the same protocol and port);
- the port is already taken by another program on the server — free it or pick another;
- the listen address or the outgoing address is not on the server;
- the outgoing address is of a different type than the destination address (IPv4 and IPv6);
- a name on a `udp` or `both` rule, a name in the wrong form (an IP address, `.example.com`, `example.*`), the
  same name twice on a port, two rules without a name on one port.

## After installation

1. **Give clients the relay's address** instead of the destination server's address. The ports are the ones the
   relay listens on; the installer prints them at the end.
2. **If the destination server does not accept everyone**, allow the relay's addresses on it. The installer
   prints those at the end too.
3. **If you turned on PROXY protocol**, make sure the destination server accepts it.
4. **Check** from another computer: `nc -vz 192.0.2.10 443` (the relay's address and port). For UDP this check
   shows nothing — test with a real client.

## Management

The `nginx-stream` command without parameters shows a menu: reconfigure, status, uninstall, quit.
When you reconfigure, the previous answers are filled in for you — just change what you need.

```bash
nginx-stream               # menu
nginx-stream --status      # state: is nginx running, which ports, how many connections
nginx-stream --uninstall   # remove the relay
```

An example of `--status`:

```
nginx: active
Ports:
  tcp 443 -> [2001:db8::10]:443  [up, 12 conn]
  udp 8443 -> [2001:db8::10]:443  [up]
nginx UDP sockets: 2
Protection nft table: present
Ports service: active, rules open: 2
```

**Uninstall** returns the server to how it was: removes the firewall rules the installer added, restores the
previous nginx and kernel settings (the kernel ones after a reboot). The nginx package is removed only if you
agree; if nginx also serves sites, it stays. Details are in [docs/details.en.md](docs/details.en.md#uninstall).

## All parameters

Any answer can be given as a flag. With `--yes` the installer asks nothing and takes the defaults for everything
not set. This is handy for installing from a script or on many servers.

```bash
bash install.sh --yes --target 2001:db8::10 --ports 'tcp:443,udp:443'
```

**Put the `--ports` value in single quotes**: without them the shell takes `>` for output redirection.

| Flag | What it sets | Values | Default |
|---|---|---|---|
| `--lang` | language | `ru`, `en` | asks; with `--yes` — `ru` |
| `--target` | destination server address | IPv4, IPv6 (brackets optional), domain | — |
| `--ports` | port rules | see "Port rules" | `tcp:443` |
| `--listen` | which addresses to listen on | `v4` — IPv4 only, `v4v6` — IPv4 and IPv6 | `v4v6` if there is IPv6 |
| `--proxy-protocol` | pass the client address | `y` / `n` | `n` |
| `--logs` | nginx log | `off` — none, `error` — errors only | `off` |
| `--tcp-timeout` | after how long to close a TCP connection with no traffic | `90s` (seconds), `10m` (minutes), `1h` (hours), `1d` (days) | `10m` |
| `--udp-timeout` | the same for UDP | the same | `10m` |
| `--tune` | kernel parameters | `y` / `n` | `y` |
| `--ssh-protect` | SSH brute-force protection | `y` / `n` | `y` |
| `--scan-protect` | scan protection | `y` / `n` | `n` |
| `--auto-updates` | unattended security updates | `y` / `n` | `y` |
| `--yes` | ask no questions | | |
| `--status` | show the state | | |
| `--uninstall` | remove the relay | | |
| `--dry-run` | only build the config files into a folder, install nothing; no root needed | | |
| `--out` | folder for `--dry-run` | a path | `./out` |
| `--ram-mb` | memory size used to calculate kernel parameters, only with `--dry-run` | a number of MB | `1024` |
| `--help` | short help | | |

`--target` may be left out only if every rule has its own destination address (this works with flags only; in
the questions the address is required).

Colored output is turned off with the `NO_COLOR=1` variable.

Examples:

```bash
# The simplest case: TCP 443 to a server reachable over IPv6
bash install.sh --yes --target 2001:db8::10

# TCP and UDP 443, plus UDP 8443 to 443
bash install.sh --yes --target 203.0.113.10 --ports 'both:443,udp:8443>443'

# Several servers; the default server is given as a domain; listen on IPv4 only
bash install.sh --yes --target backend.example.com \
  --ports 'tcp:443,tcp:2222>203.0.113.20:22,udp:51820>[2001:db8::20]:51820' --listen v4

# Two external relay addresses — two destination servers
bash install.sh --yes --ports 'udp:192.0.2.20:443>[2001:db8::20]:443,udp:192.0.2.21:443>[2001:db8::21]:443'

# Port 443 by site name, everything else and UDP go to the default server
bash install.sh --yes --target 203.0.113.9 \
  --ports 'tcp:443/a.example.com>[2001:db8::10]:443,tcp:443/*.b.example.com>203.0.113.5:443,tcp:443>203.0.113.9:443,udp:443'
```

See which files would be written, installing nothing (you can do this on your own computer too):

```bash
bash install.sh --dry-run --yes --target 2001:db8::10 --out ./out
```

Ready-made results for different cases are in [examples/](examples/).

## A relay to AntiZapret-VPN

A common case: an [AntiZapret-VPN](https://github.com/GubernievS/AntiZapret-VPN) server is closed to clients over
IPv4 but reachable over IPv6. The relay accepts clients over IPv4 and takes them to the server over IPv6. Three steps.

**1. On the AntiZapret server — let OpenVPN accept IPv6.** AntiZapret sets OpenVPN up for IPv4 only
(`proto udp4`, `proto tcp4`), so it will not accept connections from the relay over IPv6. Change the `proto`
line and restart the running OpenVPN servers:

```bash
cd /etc/openvpn/server
sed -i 's/^proto udp4$/proto udp6/' antizapret-udp.conf vpn-udp.conf
sed -i 's/^proto tcp4$/proto tcp6/' antizapret-tcp.conf vpn-tcp.conf
systemctl try-restart openvpn-server@antizapret-udp openvpn-server@vpn-udp \
  openvpn-server@antizapret-tcp openvpn-server@vpn-tcp
```

`udp6` and `tcp6` accept both IPv6 and IPv4, so clients that connect directly keep working. WireGuard and
AmneziaWG accept IPv6 without changes. **Repeat this after reinstalling or updating AntiZapret** — it puts
`udp4` back. Tested on UDP; TCP is set up the same way.

**2. On the relay — install with the AntiZapret ports.** AntiZapret maps its backup ports (80, 443, 504, 508,
540, 580, 52080, 52443) to the real ones for IPv4 only, so for IPv6 the relay does it:

```bash
bash install.sh --target 2001:db8::10 --ports 'both:80>50080,both:443>50443,both:504>50443,both:508>50080,both:50080,both:50443,udp:540>51443,udp:580>51080,udp:52080>51080,udp:52443>51443,udp:51080,udp:51443'
```

Put the AntiZapret server's IPv6 address instead of `2001:db8::10` (`ip -6 addr show scope global` on it).
The installer asks the rest.

| Ports on the relay | Port on the AntiZapret server | What |
|---|---|---|
| 80, 508, 50080 | 50080 | OpenVPN |
| 443, 504, 50443 | 50443 | OpenVPN |
| 580, 52080, 51080 | 51080 | WireGuard / AmneziaWG |
| 540, 52443, 51443 | 51443 | WireGuard / AmneziaWG |

If you do not need OpenVPN over TCP, replace `both:` with `udp:`. The relay can take port 80 only if no site
uses it; otherwise drop the `both:80>50080` rule.

**3. Clients — the relay address.** In the profiles replace the AntiZapret server address with the relay address:
the `remote` line in OpenVPN, `Endpoint` in WireGuard and AmneziaWG. The ports stay the same.

If attack protection is on in AntiZapret: all clients reach it from the one relay address. Its limit is 100,000
new connections an hour per address, which is usually enough. AntiZapret has no exceptions file for IPv6; under
heavy load the relay address can be excluded with `ipset add antizapret-allow6 <relay IPv6>` (until AntiZapret
restarts).

## Common problems

**Clients cannot connect.** Check in order:
1. `nginx-stream --status` — nginx is `active`, the needed port is `up`;
2. the port is open at the hosting provider: many providers have their own firewall in the control panel — open
   the relay's ports there;
3. the destination server is reachable from the relay: `nc -vz 2001:db8::10 443` (on the relay itself);
4. the destination server accepts the relay's addresses (see "After installation").

**"Port already in use".** Another program on the server listens on this port. To see which:
`ss -lntup | grep :443`. Stop it or pick another port.

**"No IPv6".** The destination server is reachable over IPv6, but the relay has no IPv6. Turn IPv6 on in the
hosting panel or take another server.

**The IP of the destination domain changed.** nginx looks up the domain's IP only at start: `systemctl restart nginx`.

**You turned on ufw after the installation.** Run `nginx-stream`, choose "Reconfigure" and keep the same answers —
the ports will be opened in ufw too.

**firewalld is installed.** The installer adds nothing to it and prints the ports — open them in firewalld
yourself.

**The server already has sites on nginx.** Nothing will break: the installer adds the relay to them with one line
and does not rewrite their settings. A port taken by a site cannot be given to the relay — pick another.

## Details

How it all works inside — which files change, how the firewall works, why these settings were chosen, how this
differs from iptables DNAT — is in [docs/details.en.md](docs/details.en.md).

## License

Apache-2.0, see [LICENSE](LICENSE).
