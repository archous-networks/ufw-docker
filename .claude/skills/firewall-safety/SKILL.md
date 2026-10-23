---
name: firewall-safety
description: Safety protocol for changing or testing firewall rules on a live host over SSH. Use when editing ufw/iptables/nftables rules, running the ufw-docker test suite, or doing anything that could sever the connection you are working over.
---

# Changing a firewall on the host you are connected to

The failure mode is losing access to the machine, with no way back except a console.
Everything below came from doing it wrong on a real host.

## Before you touch anything

1. **Confirm the break-glass path exists and works.**
   ```bash
   command -v ufw-docker && sudo ufw-docker rescue --help 2>/dev/null | head -1
   ```
   If there is no rescue path, create one *first*.
2. **Know how the current SSH rule is expressed**, so you can tell "restored" from
   "replaced with something more permissive":
   ```bash
   sudo iptables -S ufw-user-input | grep -- '--dport 22'
   grep -- 'dport 22' /etc/ufw/user.rules
   ```
3. **Your existing session survives on conntrack.** It is not evidence that new
   connections work. Test a *new* connection, or you will discover the lockout later.

## While working

- **One mutator at a time.** Never run manual firewall commands while a test suite or
  another script is running. Concurrency here produces failures that look perfectly
  reproducible and are entirely fictitious.
- **Sample state after an operation finishes, not during.** A multi-step repair passes
  through states that look like a broken firewall.
- **Re-check preconditions after any suite run** — but know which way round it is now.
  `tests/run.sh` snapshots `/etc/ufw`, ufw's enabled state *and* the self-heal unit before
  the run and restores them after, printing a diff if anything does not match. So the trap
  has inverted: it used to be measuring an uninstalled tool, and it is now **re-installing
  over a host the restore already put back correctly**. Read what `run.sh` printed at the
  end before you change anything.
- **A restore that reports success is only as good as its fingerprint.** This one silently
  omitted the self-heal systemd unit and reported "host state matches the pre-suite
  snapshot" five times while the unit was gone. If you add state the suite can touch, add
  it to `fingerprint()` in the same change.

## Do not test on a host you care about when you do not have to

`tests/container-leg.sh <base-image> <nft|legacy>` runs the whole suite inside a
privileged container with its own systemd, its own Docker daemon and **its own network
namespace** — so nothing it does reaches the host's firewall. No marker file, no risk.
Reach for that before `tests/run.sh` on a live box.

Two things there are still host-wide, because they are not namespaced:

- `net.netfilter.nf_log_all_netns`, which the leg script sets to 1 and restores. Without
  it, netfilter `LOG` from a non-initial namespace is silently discarded.
- the kernel ring buffer, which a leg reads. Two legs on one machine can pass on each
  other's log lines, which is why the script takes `/var/lock/ufw-docker-leg`.

What a container cannot give you is a **cold boot** or the distro's **own kernel**. For
those, a real host and `tests/cold-boot-check.sh`.

## Verifying a filter actually filters

Rules existing is not the same as traffic being filtered.

- **Do not probe from the host itself.** Host → own-IP never traverses `FORWARD`, so it
  proves nothing about forwarded traffic.
- **Do not probe from a Docker container** if the thing under test exempts container
  subnets — the probe is exempted and the test passes regardless.
- **Use a network namespace on a veth pair.** It is not a Docker subnet and its traffic
  takes the same path an external client's does.

## Interpreting iptables output

- `iptables -S <chain>` prints `chain ... is incompatible, use 'nft' tool` both for a
  genuinely nft-native chain **and for a chain that does not exist**. Never branch on that
  string alone; require "present in `nft` AND unreadable by `iptables`".
- A rate-limited `LOG` rule will legitimately produce no line. Poll, do not assert once.

## If you lose access

From a console:
```bash
sudo ufw-docker rescue          # restores SSH first, then rebuilds
sudo ufw-docker rescue --open   # last resort: firewall off
```
Then re-wire deliberately; a recovered host is usually left unfiltered on purpose.
