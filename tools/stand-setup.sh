#!/bin/bash
# Stand backends: persistent TCP/UDP echo servers on the VM's global IPv6 (9443/tcp, 9444/udp).
#   python tools/stand.py sh < tools/stand-setup.sh
set -euo pipefail
V6=$(ip -6 -o addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')
[[ -n $V6 ]] || { echo "no global IPv6" >&2; exit 1; }
mkdir -p /root/stand
cat >/root/stand/echo.py <<'PY'
import socket, sys, threading
proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
fam = socket.AF_INET6 if ":" in host else socket.AF_INET
if proto == "udp":
    s = socket.socket(fam, socket.SOCK_DGRAM); s.bind((host, port))
    while True:
        d, a = s.recvfrom(65535); s.sendto(b"echo:" + d, a)
s = socket.socket(fam, socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, port)); s.listen(128)
def h(c):
    with c:
        while True:
            d = c.recv(65536)
            if not d: break
            c.sendall(d)
while True:
    c, _ = s.accept(); threading.Thread(target=h, args=(c,), daemon=True).start()
PY
for p in tcp:9443 udp:9444; do
	printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n[Service]\nExecStart=/usr/bin/python3 /root/stand/echo.py %s %s %s\nRestart=always\nRestartSec=2\n[Install]\nWantedBy=multi-user.target\n' \
		"${p%%:*}" "$V6" "${p##*:}" >"/etc/systemd/system/stand-echo-${p%%:*}.service"
done
systemctl daemon-reload
systemctl enable --now stand-echo-tcp stand-echo-udp >/dev/null 2>&1
sleep 2
echo "backends on [$V6]: $(ss -Hlntu | grep -cE ':944[34] ') sockets"
