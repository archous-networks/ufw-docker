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
| Docker daemon restart | `DOCKER-USER` preserved; 100 samples at 0.5s across a restart, never empty — and now known to be by design, see the `setupUserChain()` row below |
| `iptables -S <absent chain>` | prints `... is incompatible, use 'nft' tool` — the **same** message as a genuinely incompatible chain. Never key on that string alone. |
| bats + a helper that exits non-zero | a bare `helper args` statement fails the test under errexit. `netns-probe.sh get` always exits 0 for this reason |
| bats + a background process | it inherits **fd 3** and bats blocks on exit until it dies. `>/dev/null 2>&1` is NOT enough — add `3>&-`. Measured: 25s vs 0s. Hung two CI jobs to their timeout |
| bats + diagnostics on failure | a test's stdout/stderr is captured and `--tap` never replays it. Print to `>&3` or you see nothing |
| GitHub's run-level CI status | **unreliable in BOTH directions.** Seen reporting `completed/success` with both bats jobs still `queued`, and `in_progress/null` with all three jobs `completed/success`. The false-green is the dangerous one. Gate on `/actions/runs/<id>/jobs`, never the run |
| destination IP is the only discriminator | no dst → rule hits host AND containers; dst=host-ip → host only; dst=container-ip → that container only. Measured. |
| IPv6 without daemon `ip6tables` | Docker adds its own `raw`/PREROUTING DROP ahead of FORWARD, so our v6 stanza is correct but never consulted |
| IPv6 WITH daemon `ip6tables` | that DROP disappears and the v6 stanza governs. allow/deny/source/destination all behave exactly as v4. Measured; CI runs both legs |
| a v6 probe of a v4-only listener | TCP RST → `000`, identical to "correctly blocked". `python -m http.server` needs `--bind ::` |
| `iptables-restore --test` | catches **syntax** (`--bogus` → rc=2) on both backends, always. A jump to a nonexistent chain is **version-dependent, not backend-dependent**: nft 1.8.9/1.8.10 accept it (rc=0), nft **1.8.2 rejects it** exactly as legacy does. The suite **records** this rather than asserting it — the earlier per-backend assertion failed the Debian 10 leg against a tool behaving perfectly — and asserts the guarantee separately ("the stanza never jumps to a chain it does not declare") |
| `iptables-restore` is in `/usr/sbin` | not on a plain user's `PATH`. A `command -v` guard that looks fine interactively passes vacuously; the tool only ever runs this as root |
| `ufw logging off` | does not reach our own `LOG` rule. `install` reads the setting and bakes it in; `status` reports the drift |
| **mixed iptables backends** | the kernel evaluates **both**, and a `DROP` in either wins. Switching the alternative does NOT move existing rules. This is what made the legacy CI leg fail for days while the stanza it wrote was correct; `nft flush ruleset` after the switch fixed it. Hardest failure here to see from outside — everything looks wired and nothing flows |
| **iptables-legacy itself** | works, everywhere we claim support: green on Debian 10/11/12 and Ubuntu 22.04/24.04, iptables 1.8.2 through 1.8.10. The earlier failure was the mixed-backend runner above, not legacy |
| `ufw allow in on <iface>` | writes `-A ufw-user-input -i wg0 -j ACCEPT` — **no `--dport` at all**. Matching SSH rules on `--dport` alone reads such a host as "no SSH rule"; `rescue` then opened port 22 to the world. Measured |
| self-heal's syslog tag | `ufw-docker-selfheal`, **not** `ufw-docker`. Grepping the latter returns "No entries" and hides the evidence |
| `SELFHEAL_DELAY` (20s) | load-bearing, and now validated: a chain emptied at boot was caught exactly 20s later. Checking immediately would find everything fine every time, and the unit would be useless without ever looking broken |
| cold boot | verified by observation, not declaration: wiring survives, the unit runs in the boot environment, leaves a healthy firewall alone, **and repairs a broken one**. Per push as an init boot (`tests/leg-coldboot.sh`); on real hardware, still manual (`tests/cold-boot-check.sh`) |
| `ufw`'s shebang | `#! /usr/bin/python3` — so the interpreter that can import `ufw.common` is guaranteed wherever ufw runs. That is what makes deriving ufw's paths safe (D5) |
| Debian/Ubuntu iptables, ufw and docker.io by release | 10 → 1.8.2 / 0.36 / 18.09.1 · 11 → 1.8.7 / 0.36 / 20.10.5 · 12 → 1.8.9 / 0.36.2 / 20.10.24 · Ubuntu 22.04 → 1.8.7 / 0.36.1 / **29.1.3** · Ubuntu 24.04 → 1.8.10 / 0.36.2 / 29.1.3. Measured from the leg images, not looked up |
| systemd inside a privileged container | **works**, and is now the CI distro matrix. `systemd-sysv` + `--privileged --cgroupns=host` + dockerd inside gives a real init, a real daemon and its own netns. 51/51 green on `debian:12` / iptables **1.8.9** — the fleet's version, which a GitHub runner cannot reach. `tests/container-leg.sh` |
| what a nested leg does NOT cover | **the kernel, and only the kernel** — always the runner's, so `debian:10` is Debian 10 *userspace* on a 6.x kernel. Cold boot and load used to be on this list and are now post-suite phases |
| `docker restart` of a systemd leg IS an init boot | every unit re-runs, ordering is re-evaluated, `/run` is a fresh tmpfs. That is the surface the self-heal unit's `After=` lives on, so the boot-ordering race is testable per push (`tests/leg-coldboot.sh`). It is **not** a kernel boot: no initramfs, no module load, no real NIC |
| **`boot_id` does not change in a container** | `/proc/sys/kernel/random/boot_id` is the runner kernel's. The obvious "did we reboot?" check **fails open** — it would pass forever while proving nothing. Use a marker in `/run`, which is a `--tmpfs` recreated on container start |
| a rootless published port is a **userspace listener** | not a DNAT. Its traffic arrives on `INPUT`, so **zero** iptables rules mention it and plain `ufw deny <published port>` blocks it. Measured in a leg, both ways. The tool does not govern it — but ordinary ufw does, under ufw's DEFAULT policy, which is the opposite of how bridge containers behave |
| detecting a rootless daemon needs a **PID-namespace filter** | a container's processes are visible in the host's `ps`, so a nested rootless `dockerd` made the HOST report one. Compare `/proc/<pid>/ns/pid` against `/proc/1/ns/pid`; inside a container `/proc/1` is that container's init, so a genuinely local daemon is still found |
| **`DOCKER-USER` preservation IS contractual** | moby's `setupUserChain()` says so: *"The daemon does not delete or modify any pre-existing rules from the DOCKER-USER filter chain."* `NewChain` does `-n -L` then `-N` only if absent (never flushes); `EnsureJumpRule` does `-D` then `-I` at position 1, so Docker actively **re-hooks** the chain first in FORWARD on every daemon start and firewall reload. Read at v26.1.4, v28.0.0 and master |
| **Docker's nftables backend has NO `DOCKER-USER`** | `setupUserChains()` opens with `if nftables.Enabled() { return }` — *"There's no equivalent to DOCKER-USER in the nftables implementation."* With `"firewall-backend": "nftables"` the chain is never created and the whole design is inert. Read from `docker info`'s `FirewallBackend.Driver` (API ≥ 1.49; empty on older daemons, which is correct). Now a preflight refusal |
| `AddReturnRule` is gone on moby master | which is *why* Docker 29 creates the chain empty — the row below was the symptom, this is the cause |
| a `status` check can be green about a **dead repair path** | the self-heal unit pointing at a binary that is not there printed every check green, including "DOCKER-USER is reached from FORWARD", while the unit failed at every boot and left the chain at 0 jumps. Found by restarting a leg's init. `status` now checks the unit's `ExecStart` target exists and that it is enabled |
| netfilter `LOG` in a non-initial netns | **silently discarded** unless `net.netfilter.nf_log_all_netns=1`. The rule fires, the packet drops, no line appears — indistinguishable from broken logging. A GLOBAL sysctl: it is absent from the container's own `/proc/sys`, so it cannot be set from inside even with `--privileged` |
| the kernel ring buffer is not namespaced | a leg's `journalctl -k` reads the HOST's dmesg. The drop-logging test used to grep the `[UFW DOCKER BLOCK]` prefix alone and would have passed on the host's lines; it now requires its own packet (`SRC=10.97.0.2 … DPT=19089`) |
| `--tmpfs /tmp` is **noexec** | so a `PATH` stub placed under `/tmp` is found by `command -v` and silently NOT executed — the real binary runs instead. Four tests failed with nothing pointing at a filesystem. Mount it `exec` |
| iptables 1.8.2 (Debian 10) prints `-p 6` | not `-p tcp`. Anything that matches rule TEXT by protocol name reads an old host as having no such rule. `rescue`'s SSH replay handles it; new matchers must |
| bats by release | debian:10 → **0.4.0** (the original bats: no `setup_file`/`teardown_file`, and it does not error, it simply never calls them) · debian:11 and ubuntu:22.04 → 1.2.1 · debian:12 → 1.8.2 · ubuntu:24.04 → 1.10.0. The leg images pin one bats-core so a red leg means the DISTRO differs, not the harness |
| **counting jumps inside `DOCKER-USER` proves nothing** | the chain can be byte-perfect and never entered. `FORWARD -j DOCKER-USER` is what makes it reachable, Docker creates it, and `"iptables": false` in daemon.json means it never exists. Checked by the preflight, by `status` and by self-heal now; nothing checked it before |
| ufw's default policy and containers | ufw keeps the default on the BUILT-IN chain, and our jump enters `ufw-user-input` directly — so `ufw default allow incoming` does NOT extend to containers. Installing on such a host takes every published port from open to closed |
| `subnets()` must be driver-filtered | a macvlan/ipvlan network sits on a REAL LAN and never traverses `DOCKER-USER`. Sweeping its subnet in would exempt that LAN from forward filtering in one direction and default-deny it in the other. Allowlist `bridge`; report the rest |
| `cmd && false \|\| true` in a test | **always succeeds.** cmd true → `false` runs → `\|\| true` swallows it; cmd false → `\|\| true`. Four assertions here were vacuous in both directions. Write `! cmd` |
| **Docker 29 creates `DOCKER-USER` EMPTY** | no `-A DOCKER-USER -j RETURN`, which every earlier version added. Measured on 29.1.3. Semantically identical — an empty chain falls through — but anything comparing the chain's TEXT to "a single RETURN" is comparing against a stock that no longer exists. `rescue` still writes the RETURN, which is harmless and self-documenting; the suite's restore replays the snapshot verbatim rather than assuming either shape |
| Docker 29 uses the containerd image store | `docker info` says `overlayfs`, not `overlay2`, and images live under `/var/lib/containerd`. A nested daemon needs a volume there too or every `docker run` exits 125 — with an error that names a mount, not a storage driver |
| Docker 18.09 on a cgroup v2 host | **cannot start at all**: `Error starting daemon: Devices cgroup isn't mounted`. cgroup v2 support arrived in Docker 20.10, so Debian 10's own `docker.io` is unusable on any current kernel and the Debian 10 leg uses docker-ce from Docker's own buster repo |
| editing a bash script while it runs | bash reads the file by BYTE OFFSET. An edit mid-run shifts the file underneath the running shell, which resumes mid-token — observed as `line 184: he: command not found` followed by the whole suite running a second time. Looked like a tool bug for several minutes |
| rootless Docker needs a **cgroup user slice** | it defaults to the systemd cgroup driver, which resolves container cgroups under `/sys/fs/cgroup/user.slice/user-<uid>.slice` — present only where logind made a session for that user. A leg uses `--cgroupns=host`, sees the runner's tree, and every `docker run` fails with `cgroup.controllers: no such file or directory`. It passed on the dev box only because the maintainer's OWN login session had created `user-1000.slice` and the test user got uid 1000 — passing on state the script had not established, same shape as `nf_log_all_netns`. Force `--exec-opt native.cgroupdriver=cgroupfs`, and pin the test user to an odd uid so a local run cannot borrow a real slice |
| rootless Docker by distro | Debian 11/12 `docker.io` ships `/usr/share/docker.io/contrib/dockerd-rootless.sh`; **Ubuntu's `docker.io` 29.x ships neither it nor `docker-ce-rootless-extras`**, and a direct `rootlesskit` invocation gets a daemon that **panics in its own `Shutdown` path** during `NewDaemon` — a nil deref that hides the real init failure. A9 is covered on Debian legs only, and the skip says so loudly |
| a rootless daemon's socket exists before it is ready | rootlesskit creates `$XDG_RUNTIME_DIR/docker.sock` before dockerd finishes init, and it survives dockerd dying. `test -S` passed against a daemon that had already panicked and the phase reported `rootless daemon up:` with an EMPTY version. Poll `docker version --format {{.Server.Version}}` |
| `iptables-save` prints packet counters | in every `:CHAIN POLICY [pkts:bytes]` line, so "did the rule set change?" is false after any traffic. Normalise with `sed 's/\[[0-9]*:[0-9]*\]/[0:0]/'`. Comparing them made a load test fail on three legs and pass on seven — flaky, which reads as infrastructure rather than as the bug it was meant to find |
| **`cmd \| grep -q` under `set -o pipefail`** | wrong in **two** independent ways, and the leg phases hit both. (1) `grep -q` exits on the first match, the producer writes into a closed pipe, takes **SIGPIPE and exits 141**, and pipefail makes that the pipeline's status — so a MATCH reports failure. (2) pipefail also propagates the **producer's own** exit status, and `ufw-docker status` returns 1 whenever any check is red — so "does it mention X" came back false for an unrelated reason. Both inverted real results: `status` printed `IPv4 wired` in plain sight while the check looking for it declared the host unwired. Capture the output, discard the status, match with `case` |
| `curl -w '%{http_code}' \|\| echo 000` | emits **`000000`** on a refused connection — curl's `-w` already prints `000` *and* exits non-zero, so the fallback double-prints and every BLOCKED result compares unequal to `000`. It made a correctly-blocked port read as reachable. Use `\|\| true` |
| `grep -c` | PRINTS `0` and EXITS 1 on no match. `x=$(... | grep -c y) || true`, never `|| printf 0` — that emits `0\n0` and breaks every arithmetic test downstream. Bitten **three** times: the survey, the preflight, and the leg runner's rule counts. Prefer `awk '/re/{n++} END{print n+0}'`, which has one exit status and one line of output |
| **a container image has no kernel in it** | `docker run --rm debian:10 uname -r` prints the HOST's kernel and `/boot` is empty. So the distro matrix varies userspace — iptables 1.8.2→1.8.10, ufw, systemd, the distro's own Docker — and **cannot** vary the kernel: all ten legs share the runner's. The resulting pairing is old userspace on a NEW kernel, which Linux's don't-break-userspace rule makes the forgiving direction; the risky one (new userspace, old kernel — Docker CE's repo on an old distro) is a real deployment shape these legs do not build |
| `runs-on: ubuntu-latest` is a moving label | GitHub is rolling it from 24.04 to 26.04 across a month-long window, so the kernel under the whole suite changes with no commit, and during a partial rollout **two jobs in the same run can land on different images**. Every job here is pinned. The two available images are also the only kernel breadth obtainable without a VM, so they are spent deliberately — see docs/testing.md |
| **`IFS=$'\t' read` COLLAPSES empty fields** | tab is an IFS *whitespace* character, so bash treats runs of tabs as one delimiter and every column after an empty field shifts left. A TSV row with an empty column silently printed its notes where its status belonged. `awk -F'\t'` does not collapse; use it for anything field-positional |
| the status table's cells are **text**, deliberately | not an availability problem — one GitHub-native workflow badge sits at the top of the README. A badge carries ONE BIT, and one bit is exactly what failed: two consecutive green runs with the rootless phase skipped on all ten legs. `rootless=7` vs `rootless=SKIPPED` is the distinction, and no tick expresses it; nor can a tick carry the kernel column. Also: README images are proxied and **cached** by camo, so a badge can show a stale state, and text diffs — `git log -p -- README.md` is a record of when a leg started failing |
| going public changes the Actions calculus | standard GitHub-hosted runners are **free and unmetered on public repos**, so the main cost of the slow routes disappears. A QEMU-under-TCG job (no `/dev/kvm` needed, software emulation, ~30–60 min) stops being something to ration and becomes a nightly — which is the only way to reach an old kernel AND a true power-on boot. Larger runners stay paid |
| `kcov` traces bash through bats' subshells | verified: `kcov --include-pattern=ufw-docker --bash-dont-parse-binary-dir out/ bats t.bats` attributes lines in the tool, not the test file. Reports `percent_covered`, `covered_lines`, `total_lines` as JSON. Coverage here is **advisory, never gating** — the hardest lines to cover are `rescue` and the preflight refusals, and a threshold pushes those toward tests that execute a line without asserting on it |
| there are **two** IPv6 switches, and they fail differently | Docker's (`"ipv6": true, "ip6tables": true`) decides whether our v6 stanza is ever *consulted*; ufw's (`IPV6=no` in `/etc/default/ufw`) decides whether ufw *loads after6.rules at all*. The tool keyed everything off `subnets 6` and never read ufw's, so an `IPV6=no` host got the symptom ("IPv6 is NOT wired") with no cause — and the obvious response, re-running `install`, cannot possibly help. An unreadable `/etc/default/ufw` is treated as ENABLED, because the failure that must never happen is a false all-clear about v6 |
| upgrading over an existing stanza was **never tested** | every test started from a clean host — the one state no production box is in after its first install. `strip_stanza` deletes by MARKER, so a half-working upgrade leaves two stanzas or an orphaned old rule, and `install` prints success either way. The real-previous-revision test takes `git log -- ufw-docker \| sed -n 2p` rather than a pinned SHA, and needs `fetch-depth: 0` — a shallow clone has no previous revision and the test skips **silently**, which is the untested-but-green shape again |
| **kcov cannot trace across `sudo`** | it follows children by ptrace, and sudo's setuid exec breaks the trace. Measured: the same one-line bats file reports **931 lines / 4.40%** calling the tool directly and **0 lines / 0.00%** calling it through `sudo`. This suite uses `sudo` 248 times, so coverage of this project is structurally zero with a real sudo in the way — and the first run published that `0.00% (0 of 0)` as a green **pass**. `tests/coverage-shim/sudo` execs directly (the job is already root) and restores it to 931 lines; it is on PATH for the coverage job only. **Zero executable lines is not zero coverage, it is no measurement** — report it as a skip |
| a GitHub artifact name may not contain `:` | and every distro base has one (`debian:12`). All ten legs ran their full suite and all three phases green, then failed on the upload step — and because they uploaded nothing, the README table published with its entire distro section absent while looking perfectly healthy. GH expressions have no string-replace, so build the slug in a step and pass it via `$GITHUB_ENV`. The table now refuses per GROUP, not just on an empty collection |
| the two `say()` implementations differ | `container-leg.sh` prints `\033[1m== %s\033[0m`; `leg-rootless.sh` and friends print `-- %s`. A parser written against one silently matches nothing from the other, which is how every leg row lost its phase counts. Strip ANSI first and accept both markers. **The cosmetic fix made it worse**: suppressing "load=none" noise on the native job (which genuinely has no phases) also suppressed the evidence that detection was broken on the legs, which do |
| a Python edit helper that writes once at the END | loses every successful edit when a later one raises. Three coverage fixes printed `ok` and never reached disk; the grep that was supposed to confirm them is what caught it. Write after each edit, and verify with an independent `grep -c` rather than trusting the script's own output |
