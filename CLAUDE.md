# ufw-docker — working notes

Makes plain `ufw allow` / `ufw deny` govern Docker-published ports, by wiring ufw's own
rule chains into Docker's `DOCKER-USER` hook.

**Everything ships in one file: `ufw-docker`.** Tests, docs and CI are repo-only.

## Where to look, and when

`docs/` holds the detail. Read the one you need — do not read them all.

| Working on | Read |
|---|---|
| anything, first time | [docs/architecture.md](docs/architecture.md) |
| the stanza, subnets, chain order | [docs/after-rules.md](docs/after-rules.md) |
| `ufw reload` breaking, chain-deletion errors | [docs/before-init.md](docs/before-init.md) |
| boot behaviour, the systemd unit | [docs/self-heal.md](docs/self-heal.md) |
| `rescue`, SSH handling, nft fallback | [docs/rescue.md](docs/rescue.md) |
| log output, `[UFW DOCKER BLOCK]` | [docs/logging.md](docs/logging.md) |
| "why doesn't rule X work" | [docs/caveats.md](docs/caveats.md) |
| running or writing tests | [docs/testing.md](docs/testing.md) ← **read before running the suite** |
| what is still missing | [TODO.md](TODO.md) |

## Invariants — do not break these

1. **`before.init` is load-bearing.** Without it the *second* `ufw reload` leaves ufw
   half-built with no SSH rule. Not a nicety. → `docs/before-init.md`
2. **Never apply the stanza with a manual `iptables-restore`.** Out of band, ufw's
   `user.rules` pass never runs, the chain flush is permanent, and the SSH allow is gone.
   This broke the dev host. → `docs/after-rules.md`
3. **`rescue` may never leave a host more exposed than it found it** — except where the
   alternative is no access at all, and then it must say so. → `docs/rescue.md`
4. **Subnets are derived from `docker network inspect`, never hardcoded.** An early draft
   assumed `172.16/12` and would have silently dropped `10.x` networks.
5. **One file ships**, so anything the tool writes is generated from inside it. Two
   committed duplicates of generated content (`stanza.sh`, a `systemd/*.service`) both
   drifted within the hour and were deleted.

## Working on a live host

This mutates a real firewall on a machine you are probably SSH'd into.

- `sudo ufw-docker rescue` is the way back. `rescue --open` if that fails.
- **Never run firewall commands while the test suite is running.** This produced a
  convincing fictitious bug — a "reproducible 3/3" failure that was the suite's teardown
  stripping config mid-check. `tests/run.sh` takes a lock; respect it.
- **After a suite run the tool is uninstalled** (teardown removes it). Re-run `install`
  before testing anything by hand, or you will measure an unfiltered host and think the
  feature is broken. This has happened twice.
- Sample state **after** an operation completes, not during. A rescue takes ~20s;
  snapshots taken mid-run look like a broken firewall.

## A flaky result here is usually contention

Two apparent flakes were investigated as real bugs; both were measurement artifacts —
one single-point sampling after an async operation, one the concurrency above. Before
believing an intermittent failure: `pgrep -f bats`, check the lock, confirm the tool is
installed.

## Verified behaviour worth not re-deriving

| | |
|---|---|
| ufw file order | `before.rules` → `after.rules` → `user.rules` (`ufw-init-functions:288/303/343`) |
| boot order | ufw at ~3.7s, docker at ~8.1s — ufw first; Docker adopts a populated `DOCKER-USER` |
| Docker daemon restart | `DOCKER-USER` preserved; 100 samples at 0.5s across a restart, never empty |
| `iptables -S <absent chain>` | prints `... is incompatible, use 'nft' tool` — the **same** message as a genuinely incompatible chain. Never key on that string alone. |
| bats + a helper that exits non-zero | a bare `helper args` statement fails the test under errexit. `netns-probe.sh get` always exits 0 for this reason |
| IPv6 without daemon `ip6tables` | Docker adds its own `raw`/PREROUTING DROP ahead of FORWARD, so our v6 stanza is correct but never consulted |
