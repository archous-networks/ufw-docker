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

It does **not** simply open port 22.

1. **Finds the real sshd port(s)**: `sshd -T`, falling back to listening sockets, then 22.
   A host running sshd on 2222 is handled — the first version hardcoded 22 and would have
   protected nothing there.
2. **Replays your own rules** from `user.rules`, which nothing in this tool modifies:
   ```
   replayed your own rule(s) for port 22:
       -A ufw-user-input -p tcp --dport 22 -s 198.51.100.7 -j ACCEPT
   ```
   A host locked to one source stays locked to that source.
3. **Removes exactly what it added** once ufw has its own rules back — tracked, not
   guessed.

The one case where it opens a port: `user.rules` has no rule for an SSH port, so there is
nothing to replay. It inserts a blanket `ACCEPT` rather than leave you with no way in,
reports it loudly, and if ufw still has no SSH rule at the end it **leaves it** with the
commands to close it.

## The steps

| | |
|---|---|
| 1 | restore SSH (above) — **before** any cleanup, so a later failure still leaves you in |
| 2 | strip the stanza from `after.rules` / `after6.rules` |
| 3 | reset `DOCKER-USER` to a single `RETURN` — releases the chain references that block ufw's rebuild |
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
