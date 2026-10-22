# ufw-docker — development notes

Everything here was verified on a live Debian 12 host (ufw 0.36.2, Docker 28.x,
iptables 1.8.9 nftables backend). Where a claim came from reading rather than running,
it says so.

## The mechanism, and why this chain

`FORWARD` on a Docker host, in order:

```
-A FORWARD -j DOCKER-USER        <- runs FIRST; Docker's documented hook, left alone by Docker
-A FORWARD -j DOCKER-FORWARD
-A FORWARD -j ufw-before-forward
...
```

`DOCKER-USER` runs before Docker's own accept rules, which is why a `DROP` there wins.

`chaifeng/ufw-docker` jumps to **`ufw-user-forward`**, which is semantically tidier
(forwarded traffic judged by forward rules) but only reachable via `ufw route allow …`.
We jump to **`ufw-user-input`** instead, because the requirement was that operators keep
using the commands they already know. That is the only real difference between the two
projects; the hook and the stanza shape are the same.

## before.init is load-bearing, not a nicety

**Without it the firewall breaks on the second `ufw reload`.** Measured, not theorised:

| | reload #1 | reload #2 |
|---|---|---|
| ufw | active | **DOWN** |
| logging chains | 11 | **6** |
| SSH rule in `ufw-user-input` | present | **GONE** |

Mechanism: ufw deletes and recreates its own chains on every apply. Once our stanza has
run, `DOCKER-USER` references `ufw-user-input`, and iptables refuses to delete a chain
another chain references — `CHAIN_DEL failed (Device or resource busy)`. ufw aborts
part-way and leaves a half-built firewall. The host stays reachable only on existing
conntrack entries; every new SSH connection is refused.

`before.init` runs at `ufw-init-functions:125`, and `delete_chains` at `:145/:173` — so
emptying `DOCKER-USER` in the hook releases the references just in time. `after.rules`
repopulates it later in the same run, so there is no window where Docker traffic is
unfiltered while ufw is up.

## ufw's file order (the other thing that surprised us)

```
288:  before.rules    restored 1st
303:  after.rules     restored 2nd    <- our stanza; ufw-user-input does NOT exist yet
343:  user.rules      restored 3rd    <- the operator's rules, including SSH
```

Two consequences:

1. The stanza **must** declare `:ufw-user-input - [0:0]`, or the restore fails with
   `Chain 'ufw-user-input' does not exist`.
2. That declaration flushes the chain — which is **safe only because of this ordering**.
   `user.rules` repopulates it afterwards. If the order were reversed it would delete the
   operator's SSH rule.

⚠️ **Never apply the stanza with a manual `iptables-restore`.** Out of band, step 3 never
runs, the flush is permanent, and the SSH allow is gone. This is exactly how the firewall
got broken during development.

## Subnets are derived, never hardcoded

An early draft used `! -d 172.16.0.0/12`. Wrong: a user-defined network can sit on `10.x`
or `192.168.x` and would be silently dropped. `subnets()` reads them from
`docker network inspect` at install time.

Interface names are **not** usable as the handle — `br-<id>` is derived from the network
id and changes when a network is recreated. Source/destination subnet is stable.

## What survives what

| event | survives? | notes |
|---|---|---|
| `ufw reload` ×5 | ✅ | only with `before.init`; rule count stays constant |
| `ufw disable` → `enable` | ✅ | |
| `docker compose up --force-recreate` | ✅ | |
| `systemctl restart docker` | ✅ | Docker creates `DOCKER-USER` only if absent; it does not flush it |
| host reboot | ✅ | verified 2026-10-21; see *Reboot* below |

**Reboot is the remaining gap.** `ufw-docker-selfheal.service` was written as a net —
it waits 20s after boot, checks for an SSH rule in `ufw-user-input`, and runs `ufw-docker rescue`
if missing — but a real reboot has not been performed. Do it on a disposable VM before
claiming boot-ordering safety.

## Testing — and two ways to break your own host

Run it via `tests/run.sh`, never `bats` directly. Both guards in that wrapper exist
because the failure already happened here, and both failures were self-inflicted in ways
that looked like tool bugs:

**Concurrent access produces phantom bugs.** A manual `ufw-docker install` plus a
three-cycle `disable`/`enable` check was run while a suite was still going in the
background. The suite's `remove --force` stripped the stanza between the install and the
check, so `disable`/`enable` appeared to lose the wiring **3 times out of 3** — a
convincing, entirely fictitious reproducible bug. Run cleanly:

```
after install : markers=2  jumps=3
after disable : markers=2  jumps=0     (expected, ufw is off)
after enable  : markers=2  jumps=3     (restored)
```

A second suite was then started while the first ran. `tests/run.sh` now holds
`/var/lock/ufw-docker-tests`, so this is impossible rather than merely discouraged.

**Killing a run leaves a broken firewall.** bats' `teardown_file` does not fire on
SIGINT/SIGTERM; a `pkill` mid-test left ufw inactive with 6 of 11 logging chains and no
SSH rule. `tests/run.sh` traps `EXIT INT TERM` and runs `rescue` on any exit.

The general lesson for future work here: **a flaky-looking result in this project is more
often contention than a real intermittent bug.** Before believing an intermittent failure,
confirm nothing else is touching the firewall — `pgrep -f bats`, and check for the lock.
Two "flakes" in this suite were investigated as real; one (Docker restart) turned out to
be single-point sampling, the other was this.

Bats (`apt-get install bats`, 1.8.2 on Debian 12 — no vendoring needed).

**The probe must not be a Docker container.** The tool exempts every Docker subnet as
container-originated, so a container probe `RETURN`s before it is judged and the test
passes regardless. `tests/netns-probe.sh` uses a network namespace on a veth pair, which
is not a Docker subnet, so its traffic takes the same path an internet client's does.

`teardown_file` always calls `ufw-docker rescue`. Non-negotiable: a failing test must never leave
the host unreachable.

Gotcha hit while writing the suite: an apostrophe inside `${VAR:?...}` ("this host's")
breaks bats' preprocessing with `unexpected EOF while looking for matching '`.

## The nft-incompatible chain failure

Hit for real at the end of a full test run. `iptables` started refusing to touch ufw's
chains:

```
iptables v1.8.9 (nf_tables): chain `ufw-user-input' in table `filter' is incompatible, use 'nft' tool.
```

The rules were all still there — visible via `nft` — but expressed in **native nft
syntax** (`tcp dport 22 accept`) rather than the form iptables-nft emits
(`meta l4proto tcp tcp dport 22`). The compat layer will not read a chain it did not
write, so every `iptables -F` / `-X` in the rescue path silently did nothing and ufw
could not rebuild.

Recovery requires clearing the chains through `nft`, which also means deleting the
base-chain jump rules by handle first — a referenced chain cannot be removed.
`rescue` step 3b does this, and it runs **before** the iptables teardown so the
teardown has something it can actually act on.

Two details worth keeping:

- **Detect the specific error string.** An absent chain also makes `iptables -S` fail,
  and a first version treated that as incompatibility — sending a perfectly healthy host
  down the nft-destruction path. A rescue script must never take drastic action on a
  false positive.
- The root cause of the syntax divergence is **not established**, but it is not a one-off:
  it recurs reliably at the end of a full suite run, where the teardown's `rescue`
  interleaves `iptables -F/-X` with ufw's own rebuild. Step 3b handles it every time, so
  it is a known-and-contained condition rather than an open hazard — but if you can
  pin the mechanism down, write it here.

## CI caught a blind spot in the test design

First CI run: tests 5 and 7 failed (`ufw allow` should open a port), while 4 and 6
(`blocked`) passed. The workflow published `-p 8089:80` — a **remapped** port. After DNAT
the rule must name the *container* port, so `ufw allow 8089` could never match. The
"blocked" tests were therefore passing **vacuously**: the port was shut, but for the wrong
reason, and they would have kept passing even if the tool did nothing at all.

Two changes came out of it:

- CI publishes **1:1** (`8089:8089`), so the port an operator writes is the port matched.
- A dedicated test now pins the remap behaviour: with `18443:18080` published,
  `ufw allow 18443` must **not** open it and `ufw allow 18080` must. The footgun is now a
  verified property instead of a comment.

Worth noting the shape of the mistake: a test that asserts "blocked" is only meaningful if
something could have unblocked it. Both vacuous tests looked green on the host where the
ports happen to be 1:1.

## One file, one name

`ufw-rescue` was a separate script. It is now `cmd_rescue()` inside `ufw-docker`, reached
as `ufw-docker rescue`.

An intermediate version also had `install` drop a `ufw-rescue` symlink, dispatched via
`argv[0]`. Dropped: the case for it was "one short word at a console", which `ufw-docker
rescue` already satisfies, and it cost a second code path, a second name for one thing,
and a bug — `remove` did not delete the symlink, so removing the tool later left a
dangling link in `sbin`.

The argument for keeping them apart was **shared fate** — a rescue tool that can break
along with what it rescues is worth less. The argument that won: with two files the
realistic failure is an operator installing the tool and skipping the rescue, which is far
likelier than a syntax error surviving `bash -n` and CI. One file cannot be half-installed.

`cmd_rescue()` keeps a different discipline from the rest of the file on purpose — it
relies on no `set -e` behaviour, every step is independent, and SSH is restored before any
cleanup. Keep it that way: a rescue path must push through failures, not abort on the
first one.

## What `remove` cleans, and what it deliberately does not

Audited rather than assumed. `remove` strips both stanzas, restores `before.init`, deletes
the self-heal unit, and resets `DOCKER-USER`. It does **not** touch the operator's ufw
rules — those are theirs, and deleting them would be a far worse surprise than leaving
them.

Three defects the audit turned up, all fixed:

- **Backups accumulated forever.** Twelve `after.rules.ufw-docker-bak-*` files on the dev
  box before anyone looked. `prune_backups` keeps the newest 3, and `rescue` prunes its own
  `/var/backups/ufw-rescue-*` snapshots the same way.
- **`before.init` could survive `remove`.** The restore was guarded on a backup existing;
  on a host with no original file, no backup is taken and our hook stayed behind — still
  flushing `DOCKER-USER` on every ufw start. It now removes our hook whether or not there
  is an original to put back.
- **The self-heal unit was an orphan by construction** — installed by hand, unknown to both
  subcommands. Now `install --with-selfheal` deploys it and `remove` always deletes it.

**`remove` is a dry run without `--force`.** It prints WOULD REMOVE / WOULD LEAVE and
exits. Deliberately not a y/N prompt: a prompt is skippable by habit, needs a tty, and is
awkward to automate — a dry-run default behaves identically everywhere and makes the
preview worth reading on its own. The WOULD LEAVE list names the backups and snapshots that
stay, so "what is still on my disk" is answerable without hunting.

**It also warns.** The operator's rules keep working for host services and silently
stop reaching containers, while `ufw status` prints exactly the same thing either way. It
names the specific DENY rules that just became container-ineffective. Silence there would
hand someone a firewall they will misread.

## Why self-heal is ON by default

It shipped opt-in for one commit, argued as "a systemd unit that runs a destructive repair
unattended at boot — the operator's trade to make". That reasoning was wrong, and the word
doing the damage was *destructive*.

The unit fires only when this is false:

```sh
iptables -S ufw-user-input | grep -q "dport 22"
```

That is a host with **no SSH rule at all** — already unreachable. There is no healthy
state it can damage, and the alternative is somebody driving to a console. A default
should be the safe one, and safe here means "you can still log in". The operators most
exposed to a bad boot are also the least likely to find an opt-in flag.

`--no-selfheal` exists for hosts whose boot-time state is owned by config management or an
immutable image.

The check stays deliberately narrow — one symptom, the one that locks people out. Anything
broader risks running a rebuild over a merely unusual state.

## Docker daemon restart: measured, not assumed

The suite's restart test failed once and passed otherwise, which is exactly the shape of a
bad test rather than a bad tool. Sampling `DOCKER-USER` every 0.5s across a full
`systemctl restart docker` — **100 samples over 52.5s, always 3 jumps, never 0** — showed
no unfiltered window at all. The test was polling-free and sampling a single point after a
fixed sleep; it now polls with a timeout.

## A blanket rename renamed a path, not just prose

`ufw-rescue` became `ufw-docker rescue` via a repo-wide `sed`. It also rewrote this:

```sh
BACKUP="/var/backups/ufw-rescue-${STAMP}"   ->   "/var/backups/ufw-docker rescue-${STAMP}"
```

Snapshots then landed in a directory with a space in the name, which `prune_backups`
could never match again — so they would accumulate forever while the tool reported
success. Caught only because `rescue` prints the path and someone read it.

When renaming across a file that holds both prose and filesystem paths, check the paths
individually. `grep -n 'var/\|/etc/\|/usr/'` after the rename is enough.

## Rescue must not quietly widen SSH exposure

The first version of step 1 was `iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT`. Two
defects, both only dangerous once self-heal runs unattended at boot:

- On a host deliberately locked to one source it **silently opened SSH to the internet** —
  and if ufw then came back with no SSH rule of its own, the blanket was left there
  permanently, with only a warning nobody was present to read.
- It **hardcoded port 22**. A host running sshd on 2222 got nothing useful from the step
  whose whole job is keeping you logged in.

It now derives the real port(s) (`sshd -T`, then listening sockets, then 22) and replays
the operator's own rules out of `user.rules`, which nothing in this tool modifies. The
blanket is a last resort for when there is genuinely nothing to replay, it is reported as
such, and step 6 removes exactly what step 1 added — tracked in `$INSERTED`/`$BLANKET`,
not guessed at.

Keep that property if you touch this: **the rescue path may never leave a host more
exposed than it found it, except where the alternative is no access at all** — and then it
must say so in terms someone reading a log will act on.

## The systemd unit is embedded, not shipped as a file

`install_selfheal()` writes the unit from a heredoc. There is deliberately **no**
`systemd/ufw-docker-selfheal.service` in the repo.

There was one briefly, and it had already drifted from the embedded copy within the hour —
unreferenced by anything, undownloadable by the one-liner install (which fetches only
`ufw-docker`), and therefore guaranteed to be the version that never runs. Same mistake as
an early `stanza.sh`: a second copy of generated content, which exists only to be wrong
later.

The rule for this repo: **one file ships, so anything the tool writes is generated from
inside it.** If you want to read the unit, read `install_selfheal()`.

## Still open

- **The self-heal unit has never actually repaired anything at boot.** Its detection ran
  and reported `ufw healthy at boot`, and `rescue` itself is well exercised by hand — but
  the two have never been joined up in anger, because the boot has not yet gone wrong.
- **Functional IPv6.** The v6 stanza is verified to generate and apply (`IPv6 wired (1
  jumps into ufw6-user-input)`), but the dev host has no global IPv6, so no v6 packet has
  ever been filtered by it. Needs a v6-capable host.
- **Port remapping.** `8443:443` requires the operator to write `443`. Fixable only by
  translating ufw's rules into `DOCKER-USER` with `--ctorigdstport` — a tool, not a
  stanza. Not attempted.
