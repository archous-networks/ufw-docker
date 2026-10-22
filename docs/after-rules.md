# The stanza in `after.rules`

What `install` writes, and why each line is there.

## Where and why

`/etc/ufw/after.rules` (and `after6.rules` for IPv6), between markers:

```
# BEGIN DOCKER-UFW
...
# END DOCKER-UFW
```

**`docker-compose.yml`-style files are never edited, and neither is `before.rules` or
`user.rules`.** `after.rules` is hand-maintained by the operator, survives ufw upgrades,
and is applied on every `ufw reload`.

## The chain declarations

```
:ufw-user-input - [0:0]
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
```

These are **required, not decorative.** ufw applies its rule files in this order:

```
before.rules   (ufw-init-functions:288)
after.rules    (:303)   ← our stanza. ufw-user-input does NOT exist yet
user.rules     (:343)   ← the operator's rules, including SSH
```

Without the declaration the restore fails outright:

```
iptables-restore: Chain 'ufw-user-input' does not exist
```

The `[0:0]` flushes the chain, which is **safe only because of that ordering** —
`user.rules` repopulates it afterwards. If the order were reversed, this would delete the
operator's SSH rule.

> ⚠️ **Never apply this stanza by hand with `iptables-restore`.** Out of band, the
> `user.rules` pass never happens, the flush is permanent, and the SSH allow is gone.
> This is precisely how the firewall was broken during development.

## Subnets are derived, never hardcoded

`install` reads them from `docker network inspect`. An early draft assumed `172.16.0.0/12`
and would have silently dropped traffic for any network on `10.x` or `192.168.x`.

Interface names are **not** usable as the handle: `br-<id>` is derived from the network id
and changes when a network is recreated. Subnets are stable.

Because they are captured at install time, a network created **afterwards** is covered by
nothing. `ufw-docker status` detects that and says so — see
[troubleshooting.md](troubleshooting.md#subnet-drift).

## Idempotence

`install` strips any existing block before writing a new one, so re-running it is safe and
is the supported way to pick up new subnets or a new version.
