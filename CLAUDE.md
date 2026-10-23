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
| log output, `[UFW DOCKER BLOCK]`, the syslog audit trail | [docs/logging.md](docs/logging.md) |
| `--dry-run`, `status --rules`, versioning, backups | [docs/operations.md](docs/operations.md) |
| host vs container rule scope | [docs/scoping.md](docs/scoping.md) |
| targeting a single container | [docs/per-container.md](docs/per-container.md) |
| "why doesn't rule X work" | [docs/caveats.md](docs/caveats.md) |
| WAF / Cloudflare / reverse-proxy questions | [docs/waf.md](docs/waf.md) |
| which platforms are proven, and how a row earns it | [docs/supported.md](docs/supported.md) |
| cutting a release, verifying a download | [docs/releases.md](docs/releases.md) |
| surveying a host you do not control | [tools/README.md](tools/README.md) |
| running or writing tests | [docs/testing.md](docs/testing.md) ← **read before running the suite** |
| what is still missing, approved to build | [TODO.md](TODO.md) |
| what was deferred, and what would un-defer it | [FUTURE.md](FUTURE.md) |

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
6. **One source of truth per question.** Three times in one day a second copy of a rule
   was added and the two disagreed within hours: a hardcoded "backend must be nf_tables"
   check beside the matrix's backend column; the suite's `host_supported()`
   re-implementing the preflight instead of asking the tool; and `rescue` matching SSH
   rules one way while its own verification step matched them another. If two places
   answer the same question, one of them is already wrong.
7. **A check that cannot fail is not a check.** Every gate here has been run against a
   deliberately broken input to prove it fires — `invariant-selftest.sh`,
   `ssh-detect-selftest.sh`, `lint-supported.sh`, `lint-functions.sh`,
   `cold-boot-check.sh`. Two of them were found vacuous exactly this way.

## Working on a live host

This mutates a real firewall on a machine you are probably SSH'd into.

- `sudo ufw-docker rescue` is the way back. `rescue --open` if that fails.
- **Never run firewall commands while the test suite is running.** This produced a
  convincing fictitious bug — a "reproducible 3/3" failure that was the suite's teardown
  stripping config mid-check. `tests/run.sh` takes a lock; respect it.
- **A suite run now RESTORES the host** — `/etc/ufw`, ufw's enabled state, and the
  self-heal unit are snapshotted before and put back after, with a fingerprint diff
  printed if anything does not match. This used to say "after a suite run the tool is
  uninstalled, re-run install" and that is no longer true; following it would now
  re-install over a correctly restored host. Trust the `host state matches the
  pre-suite snapshot` line, and read the diff if it is absent.
- Sample state **after** an operation completes, not during. A rescue takes ~20s;
  snapshots taken mid-run look like a broken firewall.

## Negative assertions are the weak spot

Most of this suite asserts "blocked". A blocked port and a port with no listener both look
like `000`, so environmental breakage turns those tests green instead of red. Twice now,
only CI caught it — a remapped port, and a container killed by the daemon-restart test.
`ensure_service` guards it. When adding a negative assertion, ask what else produces the
same observation.

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
| bats + a background process | it inherits **fd 3** and bats blocks on exit until it dies. `>/dev/null 2>&1` is NOT enough — add `3>&-`. Measured: 25s vs 0s. Hung two CI jobs to their timeout |
| bats + diagnostics on failure | a test's stdout/stderr is captured and `--tap` never replays it. Print to `>&3` or you see nothing |
| GitHub's run-level CI status | **unreliable in BOTH directions.** Seen reporting `completed/success` with both bats jobs still `queued`, and `in_progress/null` with all three jobs `completed/success`. The false-green is the dangerous one. Gate on `/actions/runs/<id>/jobs`, never the run |
| destination IP is the only discriminator | no dst → rule hits host AND containers; dst=host-ip → host only; dst=container-ip → that container only. Measured. |
| IPv6 without daemon `ip6tables` | Docker adds its own `raw`/PREROUTING DROP ahead of FORWARD, so our v6 stanza is correct but never consulted |
| IPv6 WITH daemon `ip6tables` | that DROP disappears and the v6 stanza governs. allow/deny/source/destination all behave exactly as v4. Measured; CI runs both legs |
| a v6 probe of a v4-only listener | TCP RST → `000`, identical to "correctly blocked". `python -m http.server` needs `--bind ::` |
| `iptables-restore --test` | catches **syntax** (`--bogus` → rc=2) on both backends; a jump to a nonexistent chain is **accepted** (rc=0) under nf_tables and **rejected** under legacy. Backend-dependent, asserted per backend by a test |
| `iptables-restore` is in `/usr/sbin` | not on a plain user's `PATH`. A `command -v` guard that looks fine interactively passes vacuously; the tool only ever runs this as root |
| `ufw logging off` | does not reach our own `LOG` rule. `install` reads the setting and bakes it in; `status` reports the drift |
| **mixed iptables backends** | the kernel evaluates **both**, and a `DROP` in either wins. Switching the alternative does NOT move existing rules. This is what made the legacy CI leg fail for days while the stanza it wrote was correct; `nft flush ruleset` after the switch fixed it. Hardest failure here to see from outside — everything looks wired and nothing flows |
| **iptables-legacy itself** | works. 51/51 green on Ubuntu 24.04 / iptables 1.8.10. The earlier failure was the mixed-backend runner above, not legacy |
| `ufw allow in on <iface>` | writes `-A ufw-user-input -i wg0 -j ACCEPT` — **no `--dport` at all**. Matching SSH rules on `--dport` alone reads such a host as "no SSH rule"; `rescue` then opened port 22 to the world. Measured |
| self-heal's syslog tag | `ufw-docker-selfheal`, **not** `ufw-docker`. Grepping the latter returns "No entries" and hides the evidence |
| `SELFHEAL_DELAY` (20s) | load-bearing, and now validated: a chain emptied at boot was caught exactly 20s later. Checking immediately would find everything fine every time, and the unit would be useless without ever looking broken |
| cold boot | verified by observation, not declaration: wiring survives, the unit runs in the boot environment, leaves a healthy firewall alone, **and repairs a broken one**. `tests/cold-boot-check.sh` |
| `ufw`'s shebang | `#! /usr/bin/python3` — so the interpreter that can import `ufw.common` is guaranteed wherever ufw runs. That is what makes deriving ufw's paths safe (D5) |
| Debian iptables/ufw by release | 10 → 1.8.2 / 0.36 · 11 → 1.8.7 / 0.36 · 12 → 1.8.9 / 0.36.2 · Ubuntu 24.04 (CI) → 1.8.10. **CI tests only the last of these**, so a Debian-only regression reaches `main` green |
| systemd inside a privileged container | **works**, and is the route to a real CI matrix. `debian:12` + `systemd-sysv` + `--privileged --cgroupns=host`, dockerd inside, own netns → `install`, the netns probe and the filtering tests all pass, on iptables **1.8.9**. Measured on the dev host |
| `grep -c` | PRINTS `0` and EXITS 1 on no match. `x=$(... | grep -c y) || true`, never `|| printf 0` — that emits `0\n0` and breaks every arithmetic test downstream. Bitten twice: the survey and the preflight |
