"""Test stand helper: run commands and upload files on a clean VM over SSH.

Access: SERVER_ACCESS.local.md (not in git), blocks `## name` with `host:`, `user:`, `password:` lines;
STAND=name picks a block (default: the first). The host key is pinned in .work/known_hosts; a changed key stops.

  python tools/stand.py run 'uname -a'          run a command
  python tools/stand.py sh < script.sh          run a script with bash -s
  python tools/stand.py put install.sh /root/install.sh
  python tools/stand.py get /etc/nginx/nginx.conf out.conf

One SSH connection per call: the installer's SSH protection allows 10 new connections a minute.
"""
import os
import pathlib
import re
import sys

import paramiko

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACCESS = ROOT / "SERVER_ACCESS.local.md"
KNOWN = ROOT / ".work" / "known_hosts"


def access():
    text = ACCESS.read_text(encoding="utf-8")
    blocks = {m.group(1): m.group(2) for m in re.finditer(r"^## (\S+)\s*\n(.*?)(?=^## |\Z)", text, re.M | re.S)}
    name = os.environ.get("STAND") or next(iter(blocks))
    block = blocks[name]
    get = lambda k: re.search(rf"^{k}:\s*(\S+)\s*$", block, re.M).group(1)
    return get("host"), get("user"), get("password")


def connect():
    host, user, pw = access()
    KNOWN.parent.mkdir(exist_ok=True)
    c = paramiko.SSHClient()
    if KNOWN.exists():
        c.load_host_keys(str(KNOWN))
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username=user, password=pw, timeout=20, look_for_keys=False, allow_agent=False)
    c.save_host_keys(str(KNOWN))
    return c


def run(c, cmd, stdin_data=None, timeout=900):
    chan = c.get_transport().open_session()
    chan.settimeout(timeout)
    chan.set_combine_stderr(True)
    chan.exec_command(cmd)
    if stdin_data is not None:
        chan.sendall(stdin_data)
        chan.shutdown_write()
    out = sys.stdout.buffer
    while True:
        data = chan.recv(65536)
        if not data:
            break
        out.write(data)
        out.flush()
    return chan.recv_exit_status()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    op, args = sys.argv[1], sys.argv[2:]
    c = connect()
    try:
        if op == "run":
            rc = run(c, " ".join(args))
        elif op == "sh":
            rc = run(c, "bash -s", sys.stdin.buffer.read())
        elif op == "put":
            sftp = c.open_sftp()
            sftp.put(str(ROOT / args[0]) if not pathlib.Path(args[0]).is_absolute() else args[0], args[1])
            rc = 0
        elif op == "get":
            c.open_sftp().get(args[0], args[1])
            rc = 0
        else:
            sys.exit(__doc__)
    finally:
        c.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
