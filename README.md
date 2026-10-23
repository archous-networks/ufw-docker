# ufw-docker

[![test](https://github.com/archous-networks/ufw-docker/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/archous-networks/ufw-docker/actions/workflows/test.yml)

<!-- The badge above is a GitHub-native URL, so it needs no third party. It
     renders as a broken image while this repository is PRIVATE -- GitHub
     proxies README images through camo, which fetches anonymously -- and
     starts working by itself the moment the repo goes public. Nothing to
     change at that point. The per-combination results below are text on
     purpose; see docs/testing.md. -->

Make plain `ufw allow` and `ufw deny` actually govern **Docker-published ports**.

```bash
curl -fsSL https://github.com/archous-networks/ufw-docker/releases/latest/download/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker

sudo ufw-docker install
sudo ufw deny 8089/tcp      # ...and this now genuinely closes it
```

That URL is a **release**, not the tip of `main`. Installing from `main` means whatever
commit happened to be there when you ran it — possibly one mid-push — on a tool that
rewrites your firewall. Pin a version with
`releases/download/v1.0.0/ufw-docker`. → [releases.md](docs/releases.md)

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
| [Day-to-day operation](docs/operations.md) | `--dry-run`, `status --rules`, versions, backups, when to re-run `install` |
| [Logging](docs/logging.md) | `[UFW DOCKER BLOCK]`, the audit trail, and what is recorded where |
| [Rule scoping](docs/scoping.md) | which rules reach the host, which reach containers |
| [Per-container rules](docs/per-container.md) | targeting one container rather than a port |
| [Where a WAF fits](docs/waf.md) | why an edge WAF is not a substitute, and why this tool is what makes one worth having |
| [Releases and verifying a download](docs/releases.md) | why not to install from `main`, pinning a version, checksums |
| **[Supported platforms](docs/supported.md)** | what this is proven on, how a row earns `supported`, and the override |
| [Caveats](docs/caveats.md) | things that are true and will surprise you |
| [Troubleshooting](docs/troubleshooting.md) | symptom → cause → fix |
| [Testing](docs/testing.md) | the suite, the distro and IPv6 matrices, and two ways to break your own host |
| [Known gaps](TODO.md) | approved for immediate work, tagged and triaged |
| [Deferred](FUTURE.md) | reviewed and put off, each with what would bring it forward |

---

## Commands

| | |
|---|---|
| `sudo ufw-docker install` | wire it up. Safe to re-run; that is how you pick up new subnets or a new version |
| `sudo ufw-docker install --dry-run` | print the exact stanza it would write — changes nothing |
| `sudo ufw-docker install --no-selfheal` | …without the boot-repair unit |
| `sudo ufw-docker status` | what is wired and whether it is healthy. **Exit 1 = needs attention** |
| `sudo ufw-docker status --rules` | …and the rules containers are actually judged by |
| `sudo ufw-docker status --json` | the same report, machine-readable, for monitoring |
| `sudo ufw-docker status --counters` | …and `DOCKER-USER` packet counts — the cheapest signal of *wired but filtering nothing* |
| `sudo ufw-docker install --unsupported --force` | install anyway on an environment we have **not** proven |
| `sudo ufw-docker containers` | container addresses, for per-container rules |
| `sudo ufw-docker platforms` | the platforms this is proven on, and whether this host is one |
| `sudo ufw-docker remove` | preview the undo — changes nothing |
| `sudo ufw-docker remove --force` | actually undo it |
| `sudo ufw-docker remove --force --include-backups` | …and delete the backups too |
| `sudo ufw-docker remove --force --purge` | …and delete the binary too (it is kept by default, so `rescue` stays available) |
| `sudo ufw-docker rescue` | get back in after a bad state |
| `ufw-docker --version` | the version; the installed stanza records the one that wired the host |
| `ufw-docker <cmd> --help` | flags and caveats for that subcommand — works without `sudo` |

Both `install` and `remove` preview before they change anything, and `install` parses the
stanza it generated before writing a byte of it.

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

…and `--json` gives monitoring something better than an exit code:

```bash
ufw-docker status --json | jq -r 'select(.healthy|not) | .checks[] | select(.level=="bad") | .message'
```

## It refuses environments it has not been proven on

`install` runs a preflight and **refuses** rather than installing where this tool has
never been verified. Two kinds of check:

- **the platform matrix** — distro, major version and iptables backend must match a row
  that something actually proved. See [supported.md](docs/supported.md), or run
  `ufw-docker platforms`.
- **mechanism checks**, regardless of platform — rules present in *both* iptables
  backends, Docker Swarm, a rootless-only daemon, a `DOCKER-USER` that `FORWARD` does
  not reach, ufw's files not where ufw says they are, or **Docker's nftables firewall
  backend**, in which there is no `DOCKER-USER` chain at all and nothing this tool
  writes would ever be consulted.

  A rootless daemon running *alongside* a rootful one is not a refusal: the rootful
  daemon is wired normally, and `status` names the rootless one so nobody reads an
  empty container table as an empty host.

The refusal exists because the failure it prevents is **silent** — `install` would
succeed, `status` would report everything wired, and nothing would be filtered.

To proceed anyway you must pass **both** `--unsupported` and `--force`; one flag is
something you can paste from a forum post without reading it. Doing so is recorded in
the installed stanza and reported by every `status` run afterwards, because the person
reading `status` is rarely the person who typed `--force`.

The preflight also runs on **every `status`**, not just at install — a host that is
supported today can have its backend switched tomorrow. If that happens *without*
anyone having accepted it, `status` goes red; if it was accepted at install time, it
warns but stays green, so the exit code remains worth reading.

---

## Before you start

> **You are piping a script into `sudo`.** Convenient, and exactly the pattern to be
> suspicious of for something that rewrites your firewall. Read it first, and check you
> got the bytes we published — plain shell, no dependencies:
> ```bash
> cd "$(mktemp -d)"
> base=https://github.com/archous-networks/ufw-docker/releases/latest/download
> curl -fsSLO $base/ufw-docker
> curl -fsSLO $base/SHA256SUMS
> sha256sum -c SHA256SUMS      # must say: ufw-docker: OK
> less ufw-docker
> ```
> A checksum proves you got what we published. It does **not** prove who published it —
> only a signature would, and there is not one yet.

If anything goes wrong, from the console:

```bash
sudo ufw-docker rescue            # restore
sudo ufw-docker rescue --open     # last resort: firewall OFF, you are definitely back in
```

It restores SSH **first**, replaying your own restricted rule rather than opening the
port. → [rescue.md](docs/rescue.md)

---

## What this is tested against

<!-- BEGIN TEST MATRIX -->

<!-- GENERATED by tests/render-matrix.sh from CI results. Do not edit by hand. -->
<!-- matrix-signature: 404bc429d0879b405664230c918209860c5cad5d9e1a83fa15d6b5ceadc3d19e -->

Every combination below runs on **every push**. Last updated 2026-10-23 15:19 UTC · [run 49](https://github.com/archous-networks/ufw-docker/actions/runs/39975654830), commit `284b8c1`.

#### Distribution legs — each distro's real userspace, in a systemd container

| base | iptables | runner | kernel | result | suite and phases |
|---|---|---|---|---|---|
| `debian:10` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |
| `debian:10` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |
| `debian:11` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63; load=4; rootless=7; coldboot=7 |
| `debian:11` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63; load=4; rootless=7; coldboot=7 |
| `debian:12` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63; load=4; rootless=7; coldboot=7 |
| `debian:12` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63; load=4; rootless=7; coldboot=7 |
| `ubuntu:22.04` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |
| `ubuntu:22.04` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |
| `ubuntu:24.04` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |
| `ubuntu:24.04` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63; load=4; rootless=SKIPPED; coldboot=7 |

#### Native runner — the same suite, plus the IPv6 legs

| Docker IPv6 | iptables | runner | kernel | result | detail |
|---|---|---|---|---|---|
| `false` | legacy | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63 |
| `false` | nft | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63 |
| `false` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63 |
| `true` | legacy | `ubuntu-22.04` | `6.8.0-1064-azure` | ✅ pass | suite=63/63 |
| `true` | nft | `ubuntu-24.04` | `6.17.0-1022-azure` | ✅ pass | suite=63/63 |

#### Static analysis and coverage

| check | result | detail |
|---|---|---|
| shellcheck, syntax and 8 pure-logic gates | ✅ pass | invariant, functions, version, SSH matcher, firewall backend, ufw IPv6 switch, nothing identifying, platform matrix |
| line coverage of ufw-docker | ⏭️ skip | kcov attributed 0 executable lines -- it could not trace the tool |

> **The kernel column is the honest part of this table.** A container shares the
> host's kernel — `debian:10` above is buster's userspace (iptables 1.8.2, its own
> Docker and systemd) on the runner's kernel, not on buster's 4.19. The legs are
> split deliberately across two runner images so more than one kernel is
> represented, but every kernel here is a modern one.
> → [testing.md](docs/testing.md#what-a-leg-does-not-cover)
<!-- END TEST MATRIX -->

---

## Requirements

Debian/Ubuntu with `ufw`, Docker, `iptables`, and root.

Every push runs the full suite against **ten distro/backend combinations** —
iptables 1.8.2 through 1.8.10, Docker 18.09 through 29.1 — plus the IPv6 legs on
the native runner. The live results are in [the table above](#what-this-is-tested-against).
On top of that, Debian 12 with ufw 0.36.2, Docker 29.7.1 and nftables-backed
iptables 1.8.9 is exercised on real hardware, including across a real reboot, where
ufw starts before Docker and the wiring survives intact.

`install` refuses anything outside that set rather than filtering silently — see
[supported.md](docs/supported.md). The one thing CI cannot give you is each distro's
**own kernel**: a leg is that distro's userspace on the runner's kernel.
→ [testing.md](docs/testing.md)

**IPv4 and IPv6.** v6 filtering is real but needs the Docker daemon to be doing v6
itself — `"ipv6": true, "ip6tables": true` in `daemon.json`. Without that, Docker drops
inbound v6 to containers in its own `raw` chain, ahead of where we sit, so the v6 stanza
is written and never consulted. CI runs the whole suite both ways.
→ [caveats.md](docs/caveats.md), [testing.md](docs/testing.md)

## License

MIT — see [LICENSE](LICENSE).
