# TODO — approved for immediate work

Triaged 2026-10-22, item by item. Everything here was reviewed and marked **now**;
everything marked **later** moved to [FUTURE.md](FUTURE.md). Nothing is unsorted any more.

Severity is the original read: **S1** could leave someone unfiltered or locked out,
**S2** produces wrong or confusing behaviour, **S3** is ergonomics or polish.
Evidence tags: **[verified]** reproduced here · **[suspected]** reasoned, not reproduced ·
**[unknown]** we do not know.

## Suggested order

Not a rule, but these have real dependencies on each other:

1. ~~**X1 + D4 + D5 together.**~~ **Done** — see *Implemented* below.
2. ~~**A11**~~ and ~~**E10 stage 1**~~ — **Done**, see *Implemented* below.
3. ~~**B6, B7**~~ — **Done**, see *Implemented* below.
4. **F1 + F2** — release and checksums, once the above makes `v1.0.0` mean something.
5. **D3 last** — per-subcommand help, after the new flags exist, or it gets written twice.

---

## The list

| # | | | |
|---|---|---|---|
| **X5** | **Three test ports still fail the test-port rule.** The rule, now written into `tests/rules-lib.bash`: *every port in `TEST_PORTS` is a port the suite will delete a rule for, so it must be a port nothing real listens on.* **9100** (node_exporter), **9200** (Elasticsearch HTTP) and **9300** (Elasticsearch transport) fail it. Nothing in this estate runs them, so there is no live breakage — but 8089, 443 and container-port 80 were all *also* fine until the day they were not, and each cost a debugging round trip. Move `collc`'s container port off 9100, `v6svc` off 9200, and the host listener off 9300. Cheap and mechanical; the only care needed is keeping `v6svc` published **1:1**, since the remap trap depends on it. | [verified] | S3 |
| **H1** | **The nft-incompatible chain condition is handled but not understood.** `rescue` step 3b fires reliably at the end of a full run and has never escaped into a failure — but a fix we do not understand is a fix we cannot rely on, and the first version of its detection was wrong in a way that would have run a destructive teardown on a healthy host. Reproduce minimally (interleave `iptables -F`/`-X` on a ufw chain with a `ufw reload`), find the mechanism in the nft compatibility layer, document it. Free experiment: if 3b never fires on the legacy leg, that localises it to iptables-nft. | [unknown] | S2 |
| **B1** | **The self-heal unit has never repaired anything at a real cold boot.** Much reduced — the unit is now driven by systemd against a genuinely broken firewall and verified to repair it, restore a *restricted* SSH rule, log what it did, and leave a healthy firewall alone; its enablement and ordering are asserted declaratively. What remains is only the cold-boot path: all of that is systemd driving the unit on a *running* host, so the boot race is verified by declaration rather than observation. Needs one deliberate reboot into breakage. | [verified] | S2 |
| **F1** | **Tags and releases.** `main` is the only thing anyone can fetch, so a customer curling mid-push gets an arbitrary intermediate state. Point the README at `releases/latest/download/ufw-docker` (stable, never an intermediate commit) and document the pinned `releases/download/vX.Y.Z/` form. Release workflow: on tag, run CI, attach the artifact **only on green**. Lint: `VERSION` must equal the tag. Branch protection on `main` requiring green CI rather than a dev branch — dev branches solve the developer problem, releases solve the user problem. Sequence **after** X1 and A11 so `v1.0.0` means "refuses on anything unproven". | [verified] | S2 |
| **F2** | **No checksum or signature.** Publish `SHA256SUMS` with each release and document verifying before install. Rides along with F1 at almost no extra cost. | [verified] | S2 |
| **A7** | **`--network host` containers are unaffected, and nothing says so.** Correct behaviour — they traverse `INPUT`, so plain ufw rules govern them — but it is the opposite of what a user of this tool will assume, and they have **no address of their own**, so `-d <ip>` can never target them and `containers` shows nothing to target. Same presentation discipline as X1 (detected, named in `containers` and `status`, documented alongside) but **deliberately different vocabulary**: *"not governed by ufw-docker — host network, plain ufw INPUT rules apply"*, **not** "unsupported". It does not trip the preflight. Reserving "unsupported" for genuinely dangerous cases is what keeps the word worth reading. | [verified] | S3 |
| **C5** | **Chain counters are not surfaced.** `status --counters` (or fold into `--rules`) showing `DOCKER-USER` packet/byte counts with a one-line interpretation. Value: **"wired but counters flat"** is the cheapest visible signal of the wired-but-filtering-nothing family. Do **not** warn on flat counters — a quiet host is legitimate; show the number and let the operator read it. Update `logging.md`, which currently tells you to run raw `iptables -L -v -n` yourself. | [verified] | S3 |
| **B5** | **`remove` leaves the binary, undocumented.** Keep that behaviour — reinstall is the likely next step and `rescue` must stay available exactly when you have just unwound the firewall — but **say so** in the preview and the done message, since the preview exists to answer "what remains?". Add `--purge` to also remove the binary, requiring `--force`, orthogonal to `--include-backups` so they compose. **Implementation note:** bash reads a script incrementally, so deleting `$0` mid-run can make it read garbage. Do the `rm` from an `EXIT` trap. | [verified] | S3 |
| **A10** | **Custom bridge names untested.** Matching is on subnets, never interface names, so it should be irrelevant — but that is reasoning, not measurement. Add `com.docker.network.bridge.name` to the network the per-container test already creates; existing assertions then cover it. ~3 lines, converts [suspected] → [verified] for free. | [suspected] | S3 |
| **E8** | **Test 12 skips in CI**, so its green/red depends on *where* it runs — the exact shape we spent a day removing. The property is not UISP-specific, and test 22 already creates its own static-IPAM container and asserts survival across recreate **in CI**. Read both, determine the overlap, then either generalise test 12 to create its own container or **retire it as duplicate**. Likely outcome: delete. Removes a skip that makes CI look more thorough than it is. | | S3 |
| **D3** | **No per-subcommand help.** `remove --help` gives the global block rather than explaining `--force`, `--include-backups`, `--purge`. **Sequence last** — the items above add `--dry-run`, `--rules`, `--counters`, `--unsupported`, `--purge` and the preflight flags, so writing this first means writing it twice. No man page: it fights the single-file design for something `--help` already covers. The dangerous half is already fixed — the usage block is marker-ranged, after a hardcoded line range silently truncated it once. | [verified] | S3 |
| **X3** | **Document the backend-change procedure.** `ufw-docker remove --force` → switch the alternative → **reboot** (or flush the departing backend's ruleset) → `ufw-docker install`. The reboot is the guaranteed-clean step; `remove` unwinds our stanza but Docker's own chains stay in the old backend, and both are evaluated. X1's mixed-backend check is what catches whoever skips a step — the check and the procedure are two halves of one thing. | | S3 |
| **X4** | **Document the update process.** `curl` the new file, then re-run `install` — which refreshes all three pieces of installed state (the stanza, `before.init` if tool-managed, the selfheal unit), then reloads and verifies. Worth stating: the `before.init` backup is taken **once only**, so the original is preserved across updates; and the gap between the two commands is safe, because the old stanza keeps working and `status` flags the version mismatch. **The trap:** curl without re-running `install` leaves a new binary enforcing the *old* version's rules. | | S3 |

---

## Implemented since this list was written

- **A1** `ufw route` rules are now honoured — `DOCKER-USER` consults `ufw-user-forward`
  before `ufw-user-input`, so the verb ufw intends for forwarded traffic wins. Verified.
- **A4 / C4** subnet drift is detected by `status`, which names the uncovered networks and
  exits non-zero. Verified by creating a network post-install.
- **B1 / E2** the self-heal repair path is exercised: a missing SSH rule is restored
  *restricted, not blanket*, with no leftovers; and it now warns `RECOVERED but UNWIRED`
  because `rescue` strips the stanza by design.
- **B2** self-heal gained the canary for the one failure with no other symptom — stanza
  installed but `DOCKER-USER` unwired. Verified: 0 → 3 jumps.
- **A6** reclassified from "untested" to **understood**: Docker's own `raw`/PREROUTING
  DROP sits ahead of FORWARD when the daemon lacks `ip6tables`, so the v6 stanza is
  correct but unreachable. Full verification needs a daemon config change.
- **A3b / C3** `status` now reports a container count, `ufw-docker containers` lists
  addresses and flags dynamic ones, and `status --rules` lists the two chains containers
  are judged by, in the order consulted. Verified.
- **A5 withdrawn — it was wrong.** It claimed host and container policy "share one
  namespace" with no way to express host-only. That is a property of **port-only** rules;
  the destination separates them cleanly, measured three ways in `docs/scoping.md` and
  pinned by a test.
- **B8** the stanza is parsed with `iptables-restore --test` **before** a byte is written,
  so a malformed one is refused rather than discovered by a failed `ufw reload`. Partial
  by nature: `--test` catches syntax, not a jump to a nonexistent chain (measured, rc=0).
  The latter is covered by construction, and both rows are pinned by a test.
- **C1** every state-changing run logs one line to syslog (`journalctl -t ufw-docker`).
- **C2** our `LOG` rule now follows `ufw logging` at install time, and `status` reports a
  divergence in either direction. Both directions tested.
- **D1** `install --dry-run` previews the exact stanza and changes nothing — asserted by
  comparing `after.rules`, `DOCKER-USER` and `before.init` on both sides.
- **D2** `--version`, and the stanza carries the version that wrote it, so `status` warns
  when the binary has moved on.
- **E6** `--include-backups` and the `remove` dry-run default are both tested.
- **E9** shellcheck is now gating, not advisory — the file is clean at `-S warning`.
- **Docs** restructured into `docs/`, with the README as a table of contents.
- **A6 / E3 closed.** The daemon was given `"ipv6": true, "ip6tables": true` with a ULA
  `fixed-cidr-v6`, and the v6 path is now verified end to end: Docker's `raw`/PREROUTING
  DROP **disappears** (it existed only because the daemon lacked `ip6tables`), and
  allow / deny / source-restricted / per-container-destination all behave exactly as on
  v4. The netns probe gained a v6 side, and **CI now runs the whole suite twice** —
  `ip6tables` off and on — because both are real deployments exercising different code.
- **E1 closed.** CI is green on all three jobs — `shellcheck` (including the invariant
  self-test), `bats (docker ipv6=false)` and `bats (docker ipv6=true)` — in under five
  minutes. Note `gh run list` reports a run-level conclusion *before* its jobs finish;
  query `/jobs` if you ever gate on this.
- **E2 closed.** Two tests now drive the real systemd unit rather than the function:
  one against a broken firewall (repairs, restricted not blanket, logs what it did), one
  against a healthy firewall (changes nothing — the more dangerous direction, and the one
  that was never covered at all).
- **A8 closed as OUT OF SCOPE, not fixed.** Swarm is not run anywhere at Archous and is
  not on the roadmap, so `docs/caveats.md` now states plainly that it is unsupported and
  explains the trap: `install` will appear to succeed and `status` will report everything
  wired, because `subnets()` does pick up overlay subnets — while published Swarm ports
  route through the ingress mesh with IPVS rather than plain DNAT, which `DOCKER-USER`
  may not sit in at all. Wired-looking and filtering nothing. An untested claim of
  support is worse than a stated limitation.
- **Tests** 15 → 38, covering every item above.

- **The suite now returns the host to the state it was in.** `rescue` only ever promised a
  *working* firewall, not *this host's* firewall, and the gap was not theoretical: the
  remapped-port test published `18443:443` and deleted `allow 443/tcp` on its way out, which
  is how this development host's UISP web UI went dark and stayed dark until it was noticed
  by hand. Three changes: the remap test moved to container port **19443**; `443` left
  `TEST_PORTS`; and `tests/run.sh` snapshots `/etc/ufw` plus ufw's enabled state before the
  run, restores both after, and **exits non-zero with a diff** if a fingerprint of the
  declared *and* live state does not match. Runs in CI too, so the restore path is exercised
  on every push rather than only where it matters most. Verified by inflicting the exact
  damage — delete the operator's 443 rule, leak a stray rule, leave a file in `/etc/ufw` —
  and confirming all three were undone.

  The underlying lesson is the one this project keeps relearning: **the bats-level invariant
  only ever *reported* this drift, and reporting is not restoring.**

- **The suite no longer tests against the operator's own services.** `ensure_service` only
  curls `127.0.0.1:<port>`, and the port was **8089** — which `unms-nginx` publishes on a
  UISP host. So the suite probed the operator's service rather than a container it
  controlled, and deleted their rule for it. Compounding it, the container was created by
  the **CI workflow**, so a local run had nothing of its own and fell through to whatever
  answered. `setup_file` now creates the container, on **19089**, and the CI step is gone —
  CI and local run the identical path. Found the honest way: after `allow 8089/tcp` was
  added to this host, the next run failed 34 of 38 tests and named the culprit on the first
  one.

- **The per-container tests used container port 80.** Same root cause, found an hour later
  on the same host: `-p 18090:80` means the post-DNAT dport is **80**, so on any host that
  serves a website `ufw allow 80/tcp` matches and the "with no rule it is BLOCKED" baseline
  fails before the test has tested anything. Moved to container port **19080**. This is the
  third instance of one mistake — a test port chosen without asking whether a real service
  uses it — which is why the rule is now written down in `tests/rules-lib.bash` and why X5
  exists for the three that remain.

- **X1 — the supported-environment preflight, as a refusal.** Five checks: iptables
  backend is nf_tables; rules are not present in *both* backends (the kernel evaluates
  both and a `DROP` in either wins, which is the hardest failure here to see from
  outside); Swarm inactive; Docker not rootless; ufw's files where ufw says they are.
  `install` **refuses**, because the failure it guards is silent — install succeeds,
  `status` reports everything wired, nothing is filtered. `--unsupported` **alone still
  refuses**; it takes `--force` as well, since one flag is something you can paste from
  a forum post without reading it. Loudness is persistent and has four channels: an
  install banner, a `# INSTALLED IN UNSUPPORTED MODE: <keys>` line baked into the
  stanza, a line in **every** `status`, and a syslog entry.

  **The grading rule was the interesting part, and it came out of a failing test.**
  `install` ends by calling `cmd_status`, so a *successful* forced install exited 1 —
  making `--force` useless in automation. An exit code that is permanently 1 is an exit
  code nobody reads, and then the real fault arrives unnoticed. So: a preflight failure
  already accepted at install time **warns and stays green**; one that is *not* accepted
  means something changed underneath the install and **goes red**. That distinction is
  what keeps the exit code worth gating on.
- **D4 — `status --json`,** which forced `cmd_status` to collect-then-render. Stable
  per-check `key`s so an alert names a condition instead of matching a sentence, plus
  `supported`, `preflight_failed` and `installed_unsupported` at the top level. A side
  benefit of the restructure: messages carry no colour, because colour is applied at
  render time, which is what makes them safe to serialise.
- **D5 — ufw's paths are derived, not hardcoded.** From `ufw.common`'s packager-patched
  constants, run under **ufw's own interpreter** rather than a bare `python3`: ufw is a
  Python program and its shebang names the one interpreter certain to import its
  modules. Derive → fall back to the Debian defaults → **verify the files exist** →
  fail the preflight otherwise. Note `config_dir` is `/etc`, not `/etc/ufw`. ~40
  hardcoded literals replaced by five variables.

- **A11 — iptables-legacy works, and the leg that said otherwise was never testing it.**
  The runner boots with Docker's chains already in the nft subsystem, and
  `update-alternatives --set iptables iptables-legacy` only changes which binary *we*
  then talk to. The kernel evaluates both, so a leftover nft `DROP` beat the legacy
  `ACCEPT` we added — which is exactly why every "should be OPEN" assertion failed
  while every "should be BLOCKED" one passed, and why tests 1/10/18/38 kept proving the
  stanza was written correctly the whole time. `nft flush ruleset` after the switch
  gives a genuinely single-backend host: the leg now reports legacy=12 rules, nft=0, and
  **44/44 green** (run 39868550084). Legacy is now a `supported` row with that run named
  as its evidence.

  Two things found on the way. A failing test left `before.init` customised and turned
  one failure into six, so that test now hands its backup to `teardown` *before* breaking
  anything — `teardown` always runs, while a failed assertion abandons the test at its
  line. And ufw's own rate-limiting LOG rule went missing mid-run, which the
  operator-rule invariant flagged; it was downstream of that same cascade and vanished
  once the cascade did. Worth recording that the right move there was to fix the known
  cause and re-measure rather than reason out a fix for the symptom.
- **E10 stage 1 — the supported-platform matrix.** A heredoc inside `ufw-docker`, because
  the preflight must read it on a host that downloaded only that file. Matching is on
  distro + major version + iptables backend; ufw and Docker versions are recorded but
  deliberately not matched on, since gating on them would make every routine upgrade a
  refusal. Three consumers: the preflight, `ufw-docker platforms`, and
  `tests/lint-supported.sh`, which fails the build when the heredoc and
  `docs/supported.md` disagree — proven to fire in both directions, including the
  dangerous one where the docs claim `supported` for something nothing proved.

  **It also removed a second source of truth.** X1 had shipped with a hardcoded
  "backend must be nf_tables" check *and* a backend column in the matrix. Those
  disagreed the instant the legacy leg went green. The matrix owns it now. The same
  mistake had appeared in the suite, where `host_supported()` re-implemented the rule
  instead of asking the tool; it asks now.
- **The survey refused to be wrong.** `tools/ufw-docker-survey` run without root
  reported `ufw NOT INSTALLED`, `iptables NOT FOUND`, `stanza (none)` and `before.init
  CUSTOMISED BY OPERATOR` — four confident falsehoods on a completely healthy host,
  because every one of those reads is root-only and the code treated "cannot read" as
  "not there". It now refuses without root and explains why. This output is pasted into
  the platform matrix, so a wrong answer becomes a row nobody re-checks. Also fixed the
  `/usr/sbin` PATH assumption that caused two of the four — the third time that trap
  has bitten this project.

- **B6 — `rescue` no longer invents an SSH rule, and the detection that made it
  necessary was itself broken.** Two defects, and the second is why the first mattered.

  It used to insert a blanket `ACCEPT` when `user.rules` had no rule for the SSH port.
  That does not *restore* access on a host whose SSH is deliberately restricted — it
  *grants* access that never existed, unattended, because the self-heal unit runs rescue
  at boot. Now: replay from `user.rules` → else replay from the newest
  `/var/backups/ufw-rescue-*` snapshot → else **invent nothing** and point at `--open`.

  **The live bug:** the matcher looked for `--dport <port>` only, so `ufw allow in on
  wg0` (`-A ufw-user-input -i wg0 -j ACCEPT`, no port) read as "no SSH rule" and that
  host got 22 opened to the world. Confirmed by measurement, not reasoning. It also only
  searched `ufw-user-input`, never `ufw6-user-input` — a second bug found while fixing
  the first. The same blind spot existed in rescue's *verification* step, which would
  have told such a host "ufw has NO SSH rule" and left the temporary rules in place
  permanently; it now uses the same matcher, so the two cannot disagree.

  `tests/ssh-detect-selftest.sh` pins it with 11 synthetic cases and is proven to fail
  against the old matcher. It includes the cases that must NOT match — a portless `DROP`
  is not permission, or rescue would conclude you were already covered and leave you
  locked out. And `status` now names any blanket SSH `ACCEPT` left in `INPUT` by an older
  version, since those are still out there.

  Worth recording *why* this hid: the development host had both an interface rule and a
  `--dport` rule, so the matcher looked correct here. Pure-logic self-tests exist
  precisely because the environment keeps voting.
- **B7 — SSH port detection asks systemd first, and admits when it is guessing.**
  `systemctl show ssh.socket sshd.socket -p ListenStream` now leads the chain, because
  socket activation has been the Ubuntu default since 22.10 and `sshd -T` reports 22
  there while the socket listens elsewhere — a confident wrong answer that opens the
  wrong port and leaves the real one shut. `rescue` prints which source it used, and the
  fallback to 22 is announced as a **GUESS** rather than presented as a finding. The
  detector is shared with `status`, so both ask the same question.

## Fixed while compiling this list

Three defects turned up during the audit and were fixed rather than listed, because they
were bugs rather than decisions:

- **`install` overwrote a customised `/etc/ufw/before.init`.** A backup was taken, but an
  operator's own hook was silently replaced and simply stopped running. Demonstrated on
  this host before the guard existed. It now refuses, prints the snippet to add, and
  leaves the file untouched — and `install` aborts rather than continuing without the
  hook, since `ufw reload` without it drops the SSH rule.
- **`install` never checked whether the apply worked.** It ran `ufw reload` and trusted
  it. A malformed stanza would leave ufw half-built, with the tool reporting success. It
  now verifies active/logging-chains/SSH-rule and rolls the stanza back if the firewall is
  unhealthy.
- **Blocked container traffic was invisible.** `-j DROP` was bare, so ufw logged host
  blocks and said nothing about container blocks — the opposite of what a ufw user expects.
  Now routed through `ufw-docker-logging-deny` with a `[UFW DOCKER BLOCK]` prefix and the
  same 3/min limit ufw uses. (C2 below is the residue: it ignores `ufw logging off`.)

Also corrected: `rescue`'s nft detection matched the string `incompatible`, which
iptables-nft **also** prints for a chain that does not exist — so a perfectly normal
absent chain would have triggered a destructive nft teardown. It now requires the chain to
be present in `nft` *and* unreadable by `iptables`.

---
