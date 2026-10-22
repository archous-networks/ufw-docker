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

Root is needed only because `iptables -S` and the Docker socket require it. Without root it
still runs and says which sections are incomplete.

### What it is for

Building the supported-platform matrix from **real hosts** rather than from assumptions. The
answers that matter most:

| section | why |
|---|---|
| **iptables backend** | `nf_tables` vs `legacy`. Only nf_tables has ever been verified, and Debian 10/11 default to legacy |
| **mixed backends** | rules present in *both* subsystems. Both are evaluated by the kernel and a `DROP` in either wins, so filtering breaks in ways neither ruleset explains |
| **Swarm / rootless** | both take packet paths this tool does not hook. `install` would appear to succeed and filter nothing |
| **ufw version + default policy** | `deny (incoming)` is assumed throughout |
| **before.init** | a customised one means `install` will refuse, by design |
| **SSH port** | `sshd -T`, listening sockets and `ssh.socket` can disagree; the recovery path depends on getting this right |

### Reading the output

Paste it back **whole, untidied**. Surprising answers are the valuable ones — a host that
looks wrong is exactly the host the matrix needs to account for. A `!!` line marks something
already known to be dangerous.
