# ufw-docker

Make plain `ufw allow` and `ufw deny` actually govern **Docker-published ports**.

```bash
curl -fsSL https://raw.githubusercontent.com/archous-networks/ufw-docker/main/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker

sudo ufw-docker install
sudo ufw deny 8089/tcp      # ...and this now genuinely closes it
```

One file. No new commands to learn — you keep using `ufw`.

---

## Not the same project as `chaifeng/ufw-docker`

There is an older, well-known project called
[`ufw-docker`](https://github.com/chaifeng/ufw-docker) by Chaiwat Suttipongsakul. **This is
not it, not a fork of it, and contains none of its code.** Everything here was derived
from reading ufw's own source on a running host and testing against a live firewall.

Both use `DOCKER-USER`, because Docker documents it as *the* hook for filtering container
traffic. Agreeing on that is not derivation.

| | `chaifeng/ufw-docker` | this |
|---|---|---|
| ufw chain | `ufw-user-forward` | `ufw-user-forward` **and** `ufw-user-input` |
| how you write rules | its own CLI: `ufw-docker allow httpd 80/tcp` | plain `ufw allow 80/tcp` |
| targets | a named container | a port, as ufw always has |

Theirs targets container IPs, which sidesteps the [remapped-port caveat](docs/caveats.md),
and is older and far more widely deployed. **Use theirs if your team will accept one new
verb.** This exists for when that is the sticking point.

---

## The problem

Docker publishes a port by DNAT, then **forwards** it. ufw filters `INPUT`. Forwarded
traffic never traverses `INPUT`:

```
$ sudo ufw deny 8089/tcp
Rule added
$ sudo ufw status
8089/tcp    DENY    Anywhere

$ curl http://your-host:8089/      # from outside
HTTP 400                            ← still wide open
```

The firewall reports a rule that does nothing. → [How it is fixed](docs/architecture.md)

---

## Documentation

| | |
|---|---|
| **[Architecture](docs/architecture.md)** | how the pieces fit, the packet path, why this chain. **Start here.** |
| [The `after.rules` stanza](docs/after-rules.md) | what `install` writes and why each line is load-bearing |
| [The `before.init` hook](docs/before-init.md) | why `ufw reload` breaks without it |
| [The self-heal service](docs/self-heal.md) | boot-time repair, what it checks, opting out |
| [`rescue`](docs/rescue.md) | break-glass: what it does to your SSH exposure |
| [Logging](docs/logging.md) | `[UFW DOCKER BLOCK]`, and what is recorded where |
| [Rule scoping](docs/scoping.md) | which rules reach the host, which reach containers |
| [Per-container rules](docs/per-container.md) | targeting one container rather than a port |
| [Caveats](docs/caveats.md) | things that are true and will surprise you |
| [Troubleshooting](docs/troubleshooting.md) | symptom → cause → fix |
| [Testing](docs/testing.md) | the suite, and two ways to break your own host |
| [Known gaps](TODO.md) | everything we know is missing, tagged and triaged |

---

## Commands

| | |
|---|---|
| `sudo ufw-docker install` | wire it up. Safe to re-run; that is how you pick up new subnets or a new version |
| `sudo ufw-docker install --no-selfheal` | …without the boot-repair unit |
| `sudo ufw-docker status` | what is wired and whether it is healthy. **Exit 1 = needs attention** |
| `sudo ufw-docker remove` | preview the undo — changes nothing |
| `sudo ufw-docker remove --force` | actually undo it |
| `sudo ufw-docker rescue` | get back in after a bad state |

Then use ufw exactly as you always have:

```bash
sudo ufw allow 443/tcp
sudo ufw deny 8089/tcp
sudo ufw allow from 10.0.0.0/8 to any port 8089 proto tcp
sudo ufw route allow to any port 8089 proto tcp    # also honoured
```

`status` is cron-friendly:

```
*/30 * * * * root /usr/local/sbin/ufw-docker status >/dev/null || logger -t ufw-docker "needs attention"
```

---

## Before you start

> **You are piping a script into `sudo`.** Convenient, and exactly the pattern to be
> suspicious of for something that rewrites your firewall. Read it first — plain shell,
> no dependencies:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/archous-networks/ufw-docker/main/ufw-docker | less
> ```

If anything goes wrong, from the console:

```bash
sudo ufw-docker rescue            # restore
sudo ufw-docker rescue --open     # last resort: firewall OFF, you are definitely back in
```

It restores SSH **first**, replaying your own restricted rule rather than opening the
port. → [rescue.md](docs/rescue.md)

---

## Requirements

Debian/Ubuntu with `ufw`, Docker, `iptables`, and root. Tested on Debian 12 with
ufw 0.36.2, Docker 28.x, nftables-backed iptables 1.8.9 — including across a real reboot,
where ufw starts before Docker and the wiring survives intact.

## License

MIT — see [LICENSE](LICENSE).
