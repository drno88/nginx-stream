[Русский](details.md) · [← README](../README.en.md)

# nginx-stream: how it works

A reference for those who want to know exactly what the installer does to the server. How to install and fill in
the parameters is in the [README](../README.en.md).

## How it differs from iptables DNAT

DNAT does the same job in the kernel and is the better fit for many tasks. nginx-stream is for what DNAT cannot do:

| | iptables DNAT | nginx-stream |
|---|---|---|
| IPv4 in, IPv6 out | no | yes |
| Encrypted stream | passes through | passes through, no certificates or keys on the relay |
| Choosing the server by the TLS name | no | yes |
| Other rules and IPv6 on the server | depends on how it is set up | left alone |
| Overhead | minimal, all in the kernel | higher: data goes through the nginx process |
| IPv4 to IPv4 | simpler and faster | works, but DNAT is enough for this |

If both the entry and the destination server are IPv4 and you need maximum speed on a weak server, DNAT is
better. If you need IPv4 → IPv6, different hosts per rule, or you do not want to touch iptables rules,
use nginx-stream.

## Port rules: exact semantics

```
proto:[listen_ip:]listen[/name][>[host:]port][@src]
```

- `proto` — `tcp`, `udp` or `both` (the same as two rules: tcp and udp).
- `listen_ip` — the relay address to listen on, IPv4 or IPv6 in square brackets. The address must be on the
  server (`ip addr`); write IPv6 the way `ip addr` shows it. Without it the rule listens on all addresses (the
  "Listen on which addresses?" question).
- `listen` — the port on the relay, 1–65535; leading zeros are dropped.
- `/name` — `tcp` only: the name from the TLS ClientHello (SNI). An exact name or `*.zone` (all subdomains, the
  zone itself is not included); case does not matter, punycode is allowed, up to 253 characters. Rules with the
  same listen address and port form a group: any number of rules with names and at most one without a name. No
  name, another name and non-TLS go to the rule without a name; if there is none — to the target of the first
  rule with a name (with its `@src`). The name is checked for syntax only, the installer does no DNS lookups. A
  rule without a listen address overlaps any rule on the same protocol and port, so a named group on `*:443` and
  `tcp:192.0.2.1:443` are not allowed together.
- after `>` — the port on the destination server, the same by default; before the port you can give a host of its
  own: IPv4, IPv6 in square brackets or a domain. By default `--target` is used.
- `@src` — the relay address it connects to the destination server from (`proxy_bind`), IPv4 or IPv6 in brackets.
  It must be on the server and of the same family as the destination address; if the destination is a domain, it
  must resolve to addresses of the same family. Without `@src` the kernel picks the address by route.

## What changes on the server

| File | Purpose |
|---|---|
| `/etc/nginx/nginx.conf` | main config (own-nginx mode only); the previous one is kept as `nginx.conf.before-nginx-stream`; during the install every replaced file is copied next to it as `<file>.nginx-stream-bak` (the copies are deleted on success) |
| `/etc/nginx/nginx-stream.conf` | the `stream` block: an upstream and a server for each pair (protocol, target host, target port); a port with names gets one server and a map by TLS name |
| `/etc/systemd/system/nginx.service.d/nginx-stream.conf` | `LimitNOFILE=262144`, `Restart=on-failure`, `RestartSec=2s` |
| `/etc/sysctl.d/90-nginx-stream.conf` | kernel parameters (when tuning); values depend on memory size |
| `/etc/modules-load.d/nginx-stream.conf` | loads `tcp_bbr` (if BBR is available) |
| `/etc/default/grub.d/99-nginx-stream-nr-cpus.cfg` | `nr_cpus=N` on the kernel boot line (when tuning, and only if the hoster announces extra CPUs); takes effect after a reboot |
| `/etc/nginx-stream/firewall.nft` and the `nginx-stream-firewall.service` unit | SSH and/or scan protection, in its own `inet nginx_stream` table |
| `/etc/nginx-stream/ports.sh` and the `nginx-stream-ports.service` unit | opens the relay ports in the server firewall (see "Firewall"): an `up`/`down` script with the port list and a unit that runs it at boot and together with the other firewall |
| `/etc/systemd/system/nftables.service.d/nginx-stream.conf` | after every start of `nftables.service` (its `flush ruleset` wipes our rules) restarts the protection and ports services |
| `/etc/nginx-stream/settings.env` | all installer answers, the nginx mode, the list of ufw rules |
| `/usr/local/sbin/nginx-stream` | a copy of the installer for rerunning |
| ufw rules | `ufw allow <port>/<proto> comment nginx-stream` if ufw is active (while ufw is off the rules are not changed; the ones recorded earlier stay in `settings.env`); with firewalld the ports are only printed |
| iptables and nftables rules | `ACCEPT` for the relay ports marked `nginx-stream` when incoming traffic is filtered; added and removed by the `nginx-stream-ports` service |

Packages (only the missing ones are installed; `libnginx-mod-stream` is not needed if nginx is already there with
stream built in, as in the nginx.org build): `nginx`, `libnginx-mod-stream`, `nftables` when protections are on,
`unattended-upgrades` when automatic updates are on. `dist-upgrade` is not run. If all packages are already
installed (reconfiguration), apt is not called. On a fresh VM cloud-init may still be running first, then the
first automatic update: the installer waits for cloud-init (up to 10 minutes), then for apt to be released (also
up to 10 minutes, saying once a minute what it is still waiting for). A fresh nginx is not started with the stock
site while the package installs — only with the relay configuration.

If nginx fails to start with the new configuration, the installer restores the previous files and restarts nginx
with them. An interruption during the install (Ctrl+C, a dropped SSH connection) also rolls the changes back.

## Firewall

- The installer does not install ufw. If ufw is active, the relay ports are opened in it (`ufw allow ... comment
  nginx-stream`). Turned ufw on after the install — run `nginx-stream` and reconfigure with the same answers.
- The other firewalls are handled by the `nginx-stream-ports` service. It is always installed and at every start
  decides anew where to open the `listen` ports:
  - iptables/ip6tables — if ufw is not active (otherwise our `ACCEPT` would bypass the denies in ufw): an `ACCEPT`
    with the comment `nginx-stream` is inserted before the last bare `-j DROP`/`-j REJECT` of the `INPUT` chain
    (a comment and `-i interface` allowed), or, if there is none and the policy is DROP, at the end; `iptables`
    for IPv4, `ip6tables` for IPv6 listens. Not as the first rule: it would bypass the owner's bans like
    `-s X -j DROP` and block sets;
  - nftables — in every foreign base chain of `type filter hook input` (other than our `inet nginx_stream` and the
    `INPUT` chain of the iptables-nft tables): an `accept` with `comment "nginx-stream"` is inserted before the
    last rule that is a bare `drop`/`reject` (`counter`, `log`, `comment` and `iifname` allowed), or, if there is
    none and the chain has `policy drop`, at the end: into an `ip` table the IPv4 ports, into `ip6` the IPv6 ones,
    into `inet` all. A `policy accept` chain with a final `reject` is opened too.

  If the chain accepts by default and has no bare drop at its end (partial bans are the owner's business), the
  ports are open there anyway and nothing is inserted; if the input filters still have DROP/REJECT rules, the
  installer warns — check the ports. Before inserting, the service removes its own marked rules, so there are no
  duplicates. Policies and other rules are not changed. All `iptables` calls use `-w 5` (they wait for the
  xtables lock at boot together with docker and fail2ban). `netfilter-persistent save` is not used: it would save
  the whole current ruleset, docker's dynamic chains included.
- Both services — the protection (`nginx-stream-firewall`) and the ports one — start after `nftables.service` and
  `netfilter-persistent` and follow them: after restart, reload and stop+start our table and rules come back.
  The first `systemctl start nftables` (the firewall turned on after the install) does not restart services that
  are already running by itself — the drop-in `/etc/systemd/system/nftables.service.d/nginx-stream.conf`
  (`ExecStartPost`) does that. A manual `nft -f /etc/nftables.conf` (bypassing systemctl) wipes our table and
  rules until `systemctl restart nginx-stream-firewall nginx-stream-ports`; `--status` shows whether the table is
  there and how many rules are open.
- On reconfiguration the script is rewritten. `--uninstall` removes our rules, deletes the services and the
  drop-in and removes the lines marked `nginx-stream` from `/etc/iptables/rules.v4|v6` and `/etc/nftables.conf`,
  if they are there.
- firewalld: if it is active, the service inserts nothing (its reload would wipe our rules); the ports are only
  printed — open them yourself.

## Two nginx modes

- **Own.** Nothing else runs on nginx: `nginx.conf` and the `default` site match the packaged ones (by dpkg
  checksums), there are no other sites, `conf.d` is empty, and `/var/www/html` holds nothing but the package page
  (the stock `default` site serves exactly that directory). The installer writes its own `nginx.conf` and
  removes the `default` site to free port 80 for a rule. In any doubtful case the shared mode is chosen.
- **Shared.** nginx already serves sites. `nginx.conf` is not rewritten: one line,
  `include /etc/nginx/nginx-stream.conf;`, is added after `include /etc/nginx/modules-enabled/*.conf;`
  (or at the end of the file if that line is absent: before `load_module` lines the include would break
  `nginx -t`). A commented-out `#include ...` does not count as the include. If the configuration already has a
  `stream {` block, the installer stops: nginx does not accept a second `stream` block. If the mode was "own" but
  `nginx.conf` was changed after the install, reconfiguring picks "shared". Worker limits are not changed in this
  mode; if there are many connections, raise `worker_rlimit_nofile` and `worker_connections` yourself.

## Uninstall

`--uninstall`:

- stops and removes the protection service and the `inet nginx_stream` table, the `nginx-stream-ports` service and
  the drop-in for `nftables.service`;
- removes the sysctl and modules-load files; **kernel values stay until reboot**;
- removes the `nr_cpus` file from `/etc/default/grub.d` and runs `update-grub`; the CPU limit is lifted after a reboot;
- removes the systemd override and `/etc/nginx/nginx-stream.conf`;
- in own mode restores the previous `nginx.conf` and the `default` site; in shared mode removes the include line;
- removes the ufw, iptables and nftables rules the installer added (rules that existed before are left alone); the
  ufw rules are removed if ufw is installed, even while it is off;
- in "own" mode asks whether to remove the nginx package (no by default); in "shared" mode does not ask and
  keeps nginx — it serves other sites too, and removing the package would wipe `/etc/nginx` with them; if nginx
  stays, checks the configuration and restarts it, or, if the installer itself installed it (nginx was not there
  before), stops and disables it (`systemctl disable --now nginx`). Without a terminal and without `--yes` the
  package question is answered "no";
- removes `/etc/nginx-stream` and `/usr/local/sbin/nginx-stream`.

The `nftables` and `unattended-upgrades` packages stay, and so do the automatic updates
(`/etc/apt/apt.conf.d/20auto-upgrades`). If you agree to remove nginx, `nginx`, `nginx-core`, `nginx-common` and
`libnginx-mod-stream` are purged (purge deletes the whole `/etc/nginx`); dependencies that are no longer needed
are not touched — remove them by hand with `apt autoremove`.

## Fine points

Briefly, why it is done this way.

- `worker_shutdown_timeout 10s` — only when there is a UDP rule. UDP clients send keepalives, and after a reload
  old workers would hold their sessions forever. With mixed rules (TCP and UDP) the TCP connections of old workers
  are cut 10 s after a reload; the installer applies the config with a restart, so this concerns only a manual
  reload. A TCP-only rule set has no such setting.
- A port with names. The name is read from the TLS ClientHello (`ssl_preread`), nothing is decrypted. No name,
  another name and non-TLS go to the default destination. If the name is hidden (ECH), only the outer SNI is
  visible. Only protocols where the client speaks first work; if the client stays silent, nginx closes the
  connection after 30 s (`preread_timeout`) — keep such services on a separate port. The `stream_ssl_preread`
  module is needed (Debian and Ubuntu packages have it); without it the installer stops.
- A site of the same nginx on 443 cannot live next to matching by name: move the site to another port and add the
  rule `tcp:443/site.example.com>127.0.0.1:8443`.
- Map values are upstream names, not `host:port`: a domain in a variable would need a `resolver`. The outgoing
  address for names is a separate map; an empty value means "no binding". `map_hash_bucket_size` is 128, 512 for
  names longer than about 110 characters.
- `reuseport` on UDP. Without it, datagrams from one client are picked up by different workers, each with its
  own outgoing socket, and the server sees fragments of different sessions.
- `max_fails=0`. If a domain gives both IPv4 and IPv6, after a one-second failure of one address nginx would
  disable it for `fail_timeout` and send everyone to the other. The client retries a dropped connection itself.
- `restart`, not `reload`. New limits and `reuseport` sockets are applied only on restart.
- `sysctl -e -p <file>`, not `sysctl --system`. On someone else's server `/etc/sysctl.d/` may contain, say,
  `disable_ipv6=1`; only our file is applied. Outgoing ports are 10000–65535; `ip_local_reserved_ports` gets the
  relay ports from 10000 and the TCP ports from 10000 that were listening at install time, so that nginx's
  outgoing connections do not take them.
- `nftables.service` is not enabled. Its `/etc/nftables.conf` starts with `flush ruleset` and would wipe the
  docker and ufw rules. Instead, our own service loads only the `inet nginx_stream` table; if the server firewall
  is on through `nftables.service` (before the install or after), our table comes back after its every start.
- nginx resolves the destination domain only at start. If a domain gives both A and AAAA, both addresses go into
  the upstream.
- `proxy_buffer_size 64k`. The default (16k) causes extra system calls on a heavy stream.
- Scan protection does not touch RST from nginx (from `listen` ports and ephemeral 10000–65535), SSH, and all
  TCP ports that were listening at install time. Otherwise connections dropped by nginx or another service
  would hang on the peer until timeout.
- SSH protection counts SYN packets on all sshd ports, not connection state: a rule with `ct state` would turn on
  conntrack for all relay traffic, and on a low-memory server the table would overflow under load. The network is
  /24 for IPv4 and /64 for IPv6, the counters live for 2 minutes.
- `proxy_bind`, not SNAT. SNAT needs conntrack and rules in the nat table and clashes with ufw and docker;
  `proxy_bind` is done by nginx itself, per rule, and adds nothing to the kernel.
- `nr_cpus`. Some hosters announce up to 240 possible CPUs on a one-CPU machine, and the kernel keeps memory for
  each (`Percpu:` in `/proc/meminfo`; over 100 MB on a 1 GB server). It fires when the possible CPUs are at least
  four times the real ones and at least 16 MB would be freed; N is the real count but not less than 2. The file is
  written after the install is verified (the rollback does not restore the bootloader), applied with `update-grub`
  and effective after a reboot. If the final `/boot/grub/grub.cfg` lacks it (another file in `/etc/default/grub.d`
  overrides it), the file is removed and no reboot follows; if the server rebooted and the parameter still did not
  apply, `--status` warns. Skipped in a container, without GRUB and when `nr_cpus`/`possible_cpus` is already
  set. The cap gets in the way of moving to a plan with more CPUs — see "Common problems" in the README.
- BBR is enabled only if the `tcp_bbr` module loads and `bbr` is among the available algorithms.
- The output is in color only when it goes to a terminal; `NO_COLOR` (any non-empty value) and `TERM=dumb` turn
  the color off.

## Examples

[examples/](../examples/) is the result of `--dry-run` for typical cases; the parameters of each are in its
`settings.env`.

- `tcp-443` — a single port: TCP 443 to a destination server over IPv6;
- `tcp-udp` — TCP and UDP 443 plus UDP 8443 → 443 to one destination server;
- `multi-target` — three rules to three different destination servers, with SSH and scan protection;
- `multi-ip` — rules on different relay listen addresses (IPv4 and IPv6) to different destination servers, with
  outgoing relay addresses (`@src`) on two of the rules;
- `sni` — matching by name on TCP 443 (three destinations including the default, `@src` on one of them) plus UDP
  443 to the default server.
