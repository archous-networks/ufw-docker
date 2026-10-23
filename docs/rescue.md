# `ufw-docker rescue`

The break-glass path. Gets you back into a host whose firewall came up wrong, then
rebuilds ufw from its own configuration.

```bash
sudo ufw-docker rescue            # restore
sudo ufw-docker rescue --open     # last resort: firewall OFF
```

## The invariant

> **The rescue path may never leave a host more exposed than it found it — except where
> the alternative is no access at all, and then it must say so in terms someone reading a
> log will act on.**

Keep that if you change anything here.

## What it does to SSH

**It never opens a port you had not already opened.** That is the whole contract, and it
is worth stating plainly because an earlier version of this tool broke it.

1. **Finds the real sshd port(s)**, in order: systemd socket activation
   (`ssh.socket`/`sshd.socket` `ListenStream`), then `sshd -T`, then the listening
   sockets, then 22 — and it **says which source it used**:
   ```
   sshd port(s): 22  (from: sshd -T)
   ```
   Socket activation is checked first and is not a nicety: it has been the Ubuntu
   default since 22.10, and on such a host `sshd -T` reports 22 while the socket unit
   listens elsewhere. A confident wrong answer here opens the wrong port and leaves the
   real one shut. If every source fails, the fallback to 22 is announced as a **GUESS**,
   not presented as a finding.

2. **Replays your own rules** from `user.rules`, which nothing in this tool modifies:
   ```
   replayed your own rule(s) for port 22 (from your user.rules):
       -A ufw-user-input -p tcp --dport 22 -s 198.51.100.7 -j ACCEPT
   ```
   A host locked to one source stays locked to that source.

   "Your own rules" means **anything that permits the port**, not only `--dport` rules.
   `ufw allow in on wg0` writes `-A ufw-user-input -i wg0 -j ACCEPT`, with no port at
   all — see below.

3. **Falls back to the newest forensic snapshot.** Every previous rescue copied
   `user.rules` into `/var/backups/ufw-rescue-*`, so if ufw's own file has since been
   reset the real rules are still recoverable. Recovering beats inventing.

4. **Invents nothing** if neither has a rule permitting the port:
   ```
   no rule permitting port 22 found in user.rules or any snapshot
     NOT inventing one. If ufw never allowed 22, opening it now
     would grant access that never existed rather than restore it.
   ```
   `rescue --open` exists for the deliberate "get me in regardless" case, and is
   explicit about what it costs.

5. **Removes exactly what it added** once ufw has its own rules back — tracked, not
   guessed.

### Why it no longer inserts a blanket ACCEPT

It used to. If `user.rules` had no rule for the SSH port, it inserted
`-A INPUT -p tcp --dport 22 -j ACCEPT` so you could not be locked out.

Two things were wrong with that, and they compound:

- **It did not restore access, it granted it.** On a host whose SSH is deliberately
  restricted, "no rule in `user.rules`" means ufw was never permitting SSH. Opening it
  widens the host beyond anything the operator chose.
- **The detection was wrong, so it fired on hosts that *were* protected.** The matcher
  looked for `--dport <port>` only. An operator allowing SSH by interface has
  `-A ufw-user-input -i wg0 -j ACCEPT` — no `--dport` — and read as "no SSH rule". That
  host got port 22 opened to the world. Unattended, since the self-heal unit runs this
  at boot. (It also only searched the v4 chain, never `ufw6-user-input`.)

Both are fixed, and `tests/ssh-detect-selftest.sh` pins the matcher against every form
of permission — including a portless `DROP`, which must *not* count as permission, or
rescue would decide you were already covered and leave you locked out.

**The blanket rules an old version already left behind are still out there**, so
`status` now names any blanket SSH `ACCEPT` sitting in `INPUT` outside ufw's chains,
with the command to remove it.

## The steps

| | |
|---|---|
| 1 | restore SSH (above) — **before** any cleanup, so a later failure still leaves you in |
| 2 | strip the stanza from `after.rules` / `after6.rules` |
| 3 | reset `DOCKER-USER` to a single `RETURN` — releases the chain references that block ufw's rebuild. That was Docker's own stock content up to Docker 28; **29 creates the chain empty**, so on 29 this leaves one rule where there were none. Behaviourally identical, since an empty chain falls through |
| 3b | nft fallback, below |
| 4 | tear ufw's chains down |
| 5 | rebuild with `ufw enable`, which repopulates from `user.rules` |
| 6 | verify; remove the step-1 rules only if ufw has its own back |

A snapshot of the broken state (full `iptables-save` plus the three rule files) is kept in
`/var/backups/ufw-rescue-<timestamp>/`, pruned to the newest 3.

## Step 3b: the nft fallback

Occasionally ufw's chains end up expressed in **native nft syntax** (`tcp dport 22 accept`
rather than the `meta l4proto tcp` form iptables-nft emits). iptables then refuses to
touch them:

```
chain `ufw-user-input' in table `filter' is incompatible, use 'nft' tool.
```

Every `iptables -F`/`-X` silently does nothing and ufw cannot rebuild. Step 3b clears them
through `nft`, which also means deleting the base-chain jump rules by handle first.

> ⚠️ **The detection must be "present in nft AND unreadable by iptables".** Matching the
> error string alone is wrong: iptables-nft prints the *identical* message for a chain
> that simply does not exist, and an absent `ufw-user-input` is an ordinary state. An
> earlier version keyed on the string and would have run this destructive path on a
> healthy host.

The root cause of the syntax divergence is still unknown; it recurs reliably at the end of
a full test run. Contained, not explained.

## `--open`

Disables ufw and sets `INPUT`/`FORWARD`/`OUTPUT` to `ACCEPT`. The host is unfiltered.
Only when the normal restore cannot get you back in — and re-run plain `rescue` afterwards.
