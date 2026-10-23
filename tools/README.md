# tools/

## `ufw-docker-survey`

Reports what a host **is**. Changes nothing.

```bash
curl -fsSL https://raw.githubusercontent.com/archous-networks/ufw-docker/main/tools/ufw-docker-survey \
  -o /tmp/ufw-docker-survey && chmod +x /tmp/ufw-docker-survey
sudo /tmp/ufw-docker-survey
```

**Safe on production.** Every command in it reads; none writes. There is no install path, no
rule is added or removed, no service is restarted, nothing outside stdout is touched. It is a
separate file from `ufw-docker` deliberately — handing someone the real tool means trusting
them to type the right subcommand, and this one cannot do damage even if they do not. It is
short enough to read end to end before running, which is the point.

**It requires root, and refuses rather than guess.** Not for safety — it only reads. It is
because `/etc/ufw/*.rules`, `before.init`, the iptables tables and the Docker socket are
all root-only, and a survey that cannot read them does not report "unknown".

It used to carry on with a one-line caveat. What it actually produced, run as a normal
user on a completely healthy host, was four confident falsehoods:

```
version      NOT INSTALLED                                   (ufw 0.36.2, active)
iptables     NOT FOUND                                       (v1.8.9, nf_tables)
stanza       (none)                                          (installed, 0.9.0)
before.init  CUSTOMISED BY OPERATOR — install would refuse    (it is ours)
```

Incomplete would have been fine. Wrong is not: this output is pasted into the
[platform matrix](../docs/supported.md), where it becomes a row nobody re-checks. Two of
those four were the `/usr/sbin` PATH trap — `ufw` and `iptables` are not on a plain
user's `PATH` — which has now caught this project three times, so the survey sets `PATH`
defensively as well.

### The quick fleet sweep

Before running the full survey everywhere, this one paste emits a single pipe-delimited
line per host — easy to collect across many boxes and sort:

```bash
sudo bash -c '
. /etc/os-release 2>/dev/null
L=$(iptables-legacy -S 2>/dev/null | grep -c "^-A"); N=$(iptables-nft -S 2>/dev/null | grep -c "^-A")
printf "%s|kernel=%s|ufw=%s|iptables=%s|alt=%s|nft=%s|docker=%s|swarm=%s|rootless=%s|legacyrules=%s|nftrules=%s|sshport=%s\n" \
 "${PRETTY_NAME:-unknown}" "$(uname -r)" \
 "$(ufw --version 2>/dev/null | head -1 | awk "{print \$2}")" \
 "$(iptables --version 2>/dev/null | awk "{print \$2, \$3}")" \
 "$(update-alternatives --query iptables 2>/dev/null | awk "/^Value:/{print \$2}")" \
 "$(nft --version 2>/dev/null | awk "{print \$2}")" \
 "$(docker version --format "{{.Server.Version}}" 2>/dev/null)" \
 "$(docker info --format "{{.Swarm.LocalNodeState}}" 2>/dev/null)" \
 "$(docker info --format "{{range .SecurityOptions}}{{.}} {{end}}" 2>/dev/null | grep -o rootless || echo no)" \
 "${L:-0}" "${N:-0}" \
 "$(sshd -T 2>/dev/null | awk "/^port /{printf \"%s,\", \$2}")"
'
```

```
Debian GNU/Linux 12 (bookworm)|kernel=6.1.0-52-amd64|ufw=0.36.2|iptables=v1.8.9 (nf_tables)|alt=/usr/sbin/iptables-nft|nft=v1.0.6|docker=29.7.1|swarm=inactive|rootless=no|legacyrules=0|nftrules=104|sshport=22,
```

Then run the **full survey** on anything that looks unusual: a non-nft backend, both rule
counts non-zero, a non-22 SSH port, Swarm or rootless, or an unexpected distro.

> An empty `sshport=` means *could not ask*, not *no SSH* — the one-liner calls `sshd` on
> `PATH`, which root does not always have. The full survey falls back to `/usr/sbin/sshd`.

### What it is for

Building the supported-platform matrix from **real hosts** rather than from assumptions. The
answers that matter most:

| section | why |
|---|---|
| **iptables backend** | `nf_tables` vs `legacy`. Both are now verified and both are matched on, so this decides WHICH matrix row a host lands in rather than whether it is refused outright |
| **mixed backends** | rules present in *both* subsystems. Both are evaluated by the kernel and a `DROP` in either wins, so filtering breaks in ways neither ruleset explains |
| **Swarm / rootless** | both take packet paths this tool does not hook. `install` would appear to succeed and filter nothing |
| **ufw version + default policy** | `deny (incoming)` is assumed throughout |
| **before.init** | a customised one means `install` will refuse, by design |
| **SSH port** | `sshd -T`, listening sockets and `ssh.socket` can disagree; the recovery path depends on getting this right |

### Reading the output

Paste it back **whole, untidied**. Surprising answers are the valuable ones — a host that
looks wrong is exactly the host the matrix needs to account for. A `!!` line marks something
already known to be dangerous.
