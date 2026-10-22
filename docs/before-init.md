# The `before.init` hook

The least obvious part of this tool, and the one most likely to be "tidied away" by
someone who does not know what it is for. **Without it, the second `ufw reload` breaks the
firewall and drops your SSH rule.**

## What it does

`/etc/ufw/before.init` runs before ufw applies or tears down its rules. Ours empties
`DOCKER-USER`:

```sh
case "$1" in
    start|stop|flush-all) flush_docker_user ;;
esac
```

## Why that is necessary

ufw **deletes and recreates its own chains on every apply**. iptables refuses to delete a
chain that another chain still references — and after our stanza has run once,
`DOCKER-USER` references `ufw-user-input`:

```
iptables: CHAIN_DEL failed (Device or resource busy): chain ufw-before-input
```

ufw aborts part-way through and leaves a half-built firewall. Measured without the hook:

| | reload #1 | reload #2 |
|---|---|---|
| ufw | active | **DOWN** |
| logging chains | 11 | **6** |
| SSH rule in `ufw-user-input` | present | **GONE** |

The host stays reachable only on existing conntrack entries; every new SSH connection is
refused. That is the whole reason this file exists.

`before.init` runs at `ufw-init-functions:125`, before `delete_chains` at `:145`/`:173`,
so emptying `DOCKER-USER` there releases the references in time. `after.rules` repopulates
it later in the same run, so there is no window where ufw is up and Docker traffic is
unfiltered.

## If you already have a `before.init`

`install` **refuses** rather than overwriting it. It used to `cat >` unconditionally —
a backup was taken, but the operator's hook was silently replaced and simply stopped
running, which is the worst way to lose a firewall customisation.

It compares against ufw's pristine template at `/usr/share/ufw/before.init`; an untouched
copy is safe to replace, anything else is yours. When it refuses it prints the snippet to
add to your own file:

```sh
for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    "$ipt" -S DOCKER-USER >/dev/null 2>&1 || continue
    "$ipt" -F DOCKER-USER 2>/dev/null || true
    "$ipt" -A DOCKER-USER -j RETURN 2>/dev/null || true
done
```

`install` then **aborts**, because proceeding without the hook would arm the reload
failure above.

## Removal

`remove` restores the original from `/etc/ufw/before.init.ufw-docker-backup`. If there was
no original — the file did not exist before — it deletes ours rather than leaving it
behind.
