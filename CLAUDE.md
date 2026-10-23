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
| changing a firewall on a host you are SSH'd into | [.claude/skills/firewall-safety/SKILL.md](.claude/skills/firewall-safety/SKILL.md) |

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
| Debian/Ubuntu iptables, ufw and docker.io by release | 10 → 1.8.2 / 0.36 / 18.09.1 · 11 → 1.8.7 / 0.36 / 20.10.5 · 12 → 1.8.9 / 0.36.2 / 20.10.24 · Ubuntu 22.04 → 1.8.7 / 0.36.1 / **29.1.3** · Ubuntu 24.04 → 1.8.10 / 0.36.2 / 29.1.3. Measured from the leg images, not looked up |
| systemd inside a privileged container | **works**, and is now the CI distro matrix. `systemd-sysv` + `--privileged --cgroupns=host` + dockerd inside gives a real init, a real daemon and its own netns. 51/51 green on `debian:12` / iptables **1.8.9** — the fleet's version, which a GitHub runner cannot reach. `tests/container-leg.sh` |
| what a nested leg does NOT cover | the kernel (always the runner's, so `debian:10` is Debian 10 *userspace* on a 6.x kernel), cold boot, and real load. The container legs are the per-push gate; the host run is still what proves boot behaviour |
| netfilter `LOG` in a non-initial netns | **silently discarded** unless `net.netfilter.nf_log_all_netns=1`. The rule fires, the packet drops, no line appears — indistinguishable from broken logging. A GLOBAL sysctl: it is absent from the container's own `/proc/sys`, so it cannot be set from inside even with `--privileged` |
| the kernel ring buffer is not namespaced | a leg's `journalctl -k` reads the HOST's dmesg. The drop-logging test used to grep the `[UFW DOCKER BLOCK]` prefix alone and would have passed on the host's lines; it now requires its own packet (`SRC=10.97.0.2 … DPT=19089`) |
| `--tmpfs /tmp` is **noexec** | so a `PATH` stub placed under `/tmp` is found by `command -v` and silently NOT executed — the real binary runs instead. Four tests failed with nothing pointing at a filesystem. Mount it `exec` |
| iptables 1.8.2 (Debian 10) prints `-p 6` | not `-p tcp`. Anything that matches rule TEXT by protocol name reads an old host as having no such rule. `rescue`'s SSH replay handles it; new matchers must |
| bats by release | debian:10 → **0.4.0** (the original bats: no `setup_file`/`teardown_file`, and it does not error, it simply never calls them) · debian:11 and ubuntu:22.04 → 1.2.1 · debian:12 → 1.8.2 · ubuntu:24.04 → 1.10.0. The leg images pin one bats-core so a red leg means the DISTRO differs, not the harness |
| **Docker 29 creates `DOCKER-USER` EMPTY** | no `-A DOCKER-USER -j RETURN`, which every earlier version added. Measured on 29.1.3. Semantically identical — an empty chain falls through — but anything comparing the chain's TEXT to "a single RETURN" is comparing against a stock that no longer exists. `rescue` still writes the RETURN, which is harmless and self-documenting; the suite's restore replays the snapshot verbatim rather than assuming either shape |
| Docker 29 uses the containerd image store | `docker info` says `overlayfs`, not `overlay2`, and images live under `/var/lib/containerd`. A nested daemon needs a volume there too or every `docker run` exits 125 — with an error that names a mount, not a storage driver |
| Docker 18.09 on a cgroup v2 host | **cannot start at all**: `Error starting daemon: Devices cgroup isn't mounted`. cgroup v2 support arrived in Docker 20.10, so Debian 10's own `docker.io` is unusable on any current kernel and the Debian 10 leg uses docker-ce from Docker's own buster repo |
| editing a bash script while it runs | bash reads the file by BYTE OFFSET. An edit mid-run shifts the file underneath the running shell, which resumes mid-token — observed as `line 184: he: command not found` followed by the whole suite running a second time. Looked like a tool bug for several minutes |
| `grep -c` | PRINTS `0` and EXITS 1 on no match. `x=$(... | grep -c y) || true`, never `|| printf 0` — that emits `0\n0` and breaks every arithmetic test downstream. Bitten **three** times: the survey, the preflight, and the leg runner's rule counts. Prefer `awk '/re/{n++} END{print n+0}'`, which has one exit status and one line of output |
