# Supported platforms

This tool **refuses to install** on a platform nothing has proven it works on. That is
not caution for its own sake: the failure it prevents is silent. `install` would succeed,
`status` would report everything wired, and nothing would be filtered.

The authoritative copy of this table is a heredoc inside `ufw-docker` itself, because the
preflight has to read it on a host that has only ever downloaded that one file. This page
is the human-readable copy, and `tests/lint-supported.sh` fails the build if the two
disagree.

```
ufw-docker platforms      # the matrix, plus where this host sits in it
```

## The matrix

| label | distro | ver | ufw | backend | docker | verified by | status |
|---|---|---|---|---|---|---|---|
| `deb10-nft` | debian | 10 | 0.36 | nf_tables | 26.1.4 | CI leg `distro (debian:10, nft)` | **supported** |
| `deb10-legacy` | debian | 10 | 0.36 | legacy | 26.1.4 | CI leg `distro (debian:10, legacy)` | **supported** |
| `deb11-nft` | debian | 11 | 0.36 | nf_tables | 20.10.5 | CI leg `distro (debian:11, nft)` | **supported** |
| `deb11-legacy` | debian | 11 | 0.36 | legacy | 20.10.5 | CI leg `distro (debian:11, legacy)` | **supported** |
| `deb12-nft` | debian | 12 | 0.36.2 | nf_tables | 20.10.24 | CI leg, plus full suite on a 29.7.1 host | **supported** |
| `deb12-legacy` | debian | 12 | 0.36.2 | legacy | 20.10.24 | CI leg `distro (debian:12, legacy)` | **supported** |
| `ubu22-nft` | ubuntu | 22 | 0.36.1 | nf_tables | 29.1.3 | CI leg `distro (ubuntu:22.04, nft)` | **supported** |
| `ubu22-legacy` | ubuntu | 22 | 0.36.1 | legacy | 29.1.3 | CI leg `distro (ubuntu:22.04, legacy)` | **supported** |
| `ubu24-nft` | ubuntu | 24 | 0.36.2 | nf_tables | 29.1.3 | CI legs `bats` nft ×2, and `distro` nft | **supported** |
| `ubu24-legacy` | ubuntu | 24 | 0.36.2 | legacy | 29.1.3 | CI legs `bats` legacy, and `distro` legacy | **supported** |

Matching is on **distro + major version + iptables backend**. ufw and Docker versions are
recorded but deliberately *not* matched on — they move constantly, and gating on them
would turn every routine upgrade into a refusal.

**Every one of those rows is re-proven on every push.** A leg runs the whole
suite inside that actual distribution, with its own systemd and its own Docker daemon —
see [testing.md](testing.md#the-distro-matrix--real-distributions-in-containers). The
range covered is iptables **1.8.2 → 1.8.10**, ufw **0.36 → 0.36.2**, Docker **20.10 →
29.1**, on both backends.

## What the legs cannot prove

Stated here rather than buried, because a matrix that overstates its reach is worse than
a small one.

| not covered | why |
|---|---|
| **each distro's own kernel** | a leg is that distro's *userspace* on the runner's kernel — a container image carries no kernel at all (`docker run --rm debian:10 uname -r` prints the host's, and `/boot` is empty). `deb10-*` is Debian 10 tooling on a 6.x kernel, not the 4.19 a real Debian 10 box runs. **Now closed by the VM legs.** `tests/vm-leg.sh` boots each release's own kernel under KVM on a free runner and runs the whole suite inside it, so `debian-10` is tested on **4.19**, `debian-11` on **5.10** and `debian-12` on **6.1** — alongside, not instead of, the container legs on the runner's pinned 6.8 and 6.17. The VM legs also reach a pairing containers cannot build at all: Debian 10's own `docker.io` 18.09.1, which predates cgroup v2 and cannot start on a modern kernel |
| **a real machine starting** | the *boot ordering race* is covered per push — a leg runs systemd as pid 1, so restarting it re-runs every unit (`tests/leg-coldboot.sh`). What is not covered is an initramfs, module loading and a real NIC coming up. `tests/cold-boot-check.sh` on hardware, still manual |
| **capacity under load** | *correctness* under concurrency is covered per push — 200 simultaneous connections against a DENY all refused, against an ALLOW all served, rule set unchanged (`tests/leg-load.sh`). What that does not say is what it costs on a box running dozens of containers |

> Two of these three used to be flat "not covered". They were assumptions about what a
> container can do, not measurements — and they cost a year of "still manual" on a check
> that takes a minute per leg. The kernel one is real.

## Hosts this has actually run on

An **inventory, not evidence** — these are machines we have seen, and they are listed
separately so they are never mistaken for a reason a platform is supported. The matrix
above is the evidence.

| host | distro | ufw | backend | docker | how we know |
|---|---|---|---|---|---|
| dev-00 | Debian 12 | 0.36.2 | nf_tables | 29.7.1 | full suite on demand — 52/52, host state restored exactly — plus a verified cold boot, which is the one thing CI cannot do |
| site-00 | Debian 12 | 0.36.2 | nf_tables | 29.9.2 | `tools/ufw-docker-survey` only |

> An earlier version of this page had both of those **in the matrix**, as two rows with
> one key, and justified the second with *"same class as `dev-00`"*. That is precisely the
> family-resemblance argument the rule below forbids, written into the table the rule
> governs. A third row claimed "full suite, every run" for something run by hand.
> Customer names are still kept out of this repo; the `site-NN` mapping lives outside it.

## The rule for adding a row

> A row may say `supported` only where the **verified by** column names real evidence.

Not "it ought to work". Not "it is the same family as one that does". The whole point of
the matrix is to make the difference between *proven* and *assumed* impossible to blur,
because this project has twice been wrong about which was which.

To add one:

1. Run `sudo tools/ufw-docker-survey` on the host and keep the output.
2. **Add a CI leg for it** — a `base` and `backend` pair in the `distro` job of
   `.github/workflows/test.yml` — and get it green. Try it locally first with
   `tests/container-leg.sh <base-image> <nft|legacy>`, which is the same script.
3. Add the row, naming that leg as the evidence.

Step 2 used to read "or run the full suite on a host of that class", which is how a row
ended up justified by a family resemblance. A one-off run proves the day it ran; a leg
proves every push. Take the manual route only where a leg genuinely cannot reach — a
distro-specific kernel is the real example — and then say so in the **verified by**
column instead of implying CI covers it.

A row is a **platform**, not a machine. Hosts you have surveyed go in *Hosts this has
actually run on* above, which is an inventory. **Customer names do not belong in a
public repo**; the `site-NN` mapping is kept outside it.

## What is deliberately not in the matrix

Some things are refused by the preflight regardless of platform, because they are
properties of the *mechanism* rather than of the OS:

| check | why |
|---|---|
| mixed iptables backends | the kernel evaluates both, and a `DROP` in either wins — so our rules can be perfectly correct and still be overridden |
| Docker Swarm | publishes through its own ingress mesh, a path this tool does not govern |
| rootless Docker | publishes via a userspace proxy, so traffic never traverses `DOCKER-USER` |
| ufw's files not where ufw says | we would write a stanza nothing reads, and report success |
| `FORWARD` not jumping to `DOCKER-USER` | the stanza would sit in a chain no packet reaches. Everything would look wired and nothing would filter — `"iptables": false` in daemon.json produces exactly this |

And one thing that is explicitly **not** a failure: `--network host` containers. They are
understood, correctly unaffected, and governed by ordinary ufw `INPUT` rules. Spending
the word "unsupported" on something harmless is how it stops being read when it matters.

## Overriding it

```
sudo ufw-docker install --unsupported --force
```

Both flags are required — one flag is something you can paste from a forum post without
reading it. The fact is recorded in the installed stanza and reported by **every**
`status` run afterwards, because the person reading `status` is rarely the person who
typed `--force`.

An accepted override **warns** and leaves `status` exiting 0. An environment that became
unsupported *after* install — somebody switched the backend — **goes red**, because that
is a change nobody agreed to.
