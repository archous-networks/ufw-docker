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
4. ~~**F1 + F2**~~ — **Done**, see *Implemented* below. The machinery exists; **cutting
   the actual `v1.0.0` tag is a decision, not a task**, and is left to the maintainer.
5. ~~**D3 last**~~ — **Done**, see *Implemented* below.

**Everything approved is now done except `B1`**, which needs a deliberate reboot into a
broken firewall on a real host — a decision about a production box, not a task.
`tests/cold-boot-check.sh` reduces it to `arm` → `reboot` → `verify` for whenever that
moment comes. Two of its three parts are already verified on a real reboot; only the
repair path is outstanding.

---

## The list

| # | | | |
|---|---|---|---|
| **B1** | **The self-heal unit's REPAIR path has still never run at a cold boot.** Two of three parts are now verified by observation rather than declaration, on a real reboot of the development host: the wiring survives a cold boot (a no-rule port still returned `000` afterwards, so it is filtering and not merely absent), and the unit runs at boot, in the boot environment, and correctly does nothing to a healthy firewall. What remains is the repair itself. **The first attempt reported PASS having exercised nothing** — emptying `DOCKER-USER` before a reboot proves nothing, because it is runtime state and ufw rewires it from the stanza at boot, long before the unit looks; the unit logged `ufw healthy at boot` and the test counted that as success. `arm` now installs a one-shot saboteur ordered `After=docker.service Before=ufw-docker-selfheal.service`, recreating the ordering a Docker daemon starting after ufw produces, and `verify` reports **INCONCLUSIVE** rather than PASS unless self-heal logged the repair. Needs one more reboot. | [suspected] | S2 |

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

- **F1 + F2 — releases, and verifying a download.** The README told people to curl
  `ufw-docker` from the tip of `main`, so a customer installing during a push got an
  arbitrary intermediate commit — possibly one between "stanza written" and "stanza
  verified" — on a tool that rewrites their firewall, with nothing to indicate anything
  was wrong.

  `.github/workflows/release.yml` publishes on a `v*` tag, and its publish job `needs:`
  the full matrix, so **the artifact cannot exist unless every leg was green**. It
  *calls* `test.yml` rather than repeating its steps: a release pipeline with its own
  slightly-different checks is one that eventually ships what `main` would have
  rejected. `tests/lint-version.sh` gates the three copies of the version — the tag,
  `VERSION`, and the version baked into the stanza that `status` reads back.

  `SHA256SUMS` ships alongside, and the docs are explicit about what it is *not*: it
  proves you got the bytes we published, not who published them. Anyone who could
  replace the artifact could replace the checksum beside it. That needs a signature,
  and there is not one yet. A checksum presented as provenance is worse than none,
  because it looks like it answered the question it did not.

  **Not done, deliberately:** no tag has been cut. `VERSION` is still `0.9.0`. Choosing
  when `v1.0.0` happens is the maintainer's call, and `lint-version.sh` will refuse a
  tag that disagrees with the file.

- **A7, A10, B5, C5, D3, E8, X3, X4, X5 — the S3 batch.**
  - **A7** host-network containers are listed in their own section of `containers`, and
    counted in `status`. The behaviour was always right; the *presentation* was the bug —
    they have no address, so they were dropped entirely and you could not see the thing
    you could not target. The wording is deliberately **"not governed by ufw-docker"**
    and never "unsupported": these work correctly, and spending that word on something
    harmless is how it stops being read for Swarm and rootless.
  - **A10** the per-container test network now takes an explicit
    `com.docker.network.bridge.name`. Matching is on subnets and never on interface
    names, so this should change nothing — and now every existing per-container
    assertion measures that for free. [suspected] → [verified] for one flag.
  - **B5** `remove` says it leaves the binary (the one question a preview exists to
    answer), and `--purge --force` deletes it. The `rm` runs from an `EXIT` trap: bash
    reads a script incrementally, so deleting it mid-run can leave the interpreter
    reading garbage off the freed inode.
  - **C5** `status --counters`. It deliberately does **not** warn on a zero — a quiet
    host is a normal host, and warning on that teaches people to ignore the output.
  - **D3** per-subcommand help, routed from the **dispatcher** so `remove --help` works
    without sudo. `lint-functions.sh` now fails if any dispatchable subcommand lacks a
    help block, so the next one cannot ship without it. Fixed a real lint bug on the
    way: `grep -oE 'cmd_[a-z_]+'` matched the substring inside `subcmd_help` and
    demanded a `cmd_help` that was never meant to exist. A lint that invents work is a
    lint people learn to override.
  - **E8** the container-recreate test no longer skips in CI. **Triage was wrong here**:
    it assumed another test already covered recreate and this one could be deleted.
    Nothing else in the suite recreates a container at all, so deleting it would have
    removed real coverage. It builds its own static-IPAM container instead, runs
    everywhere, and now asserts that the *rule still reaches the container* rather than
    merely that `DOCKER-USER` still has jumps.
  - **X3 / X4** the backend-change and update procedures are documented in
    `operations.md`, each with the step people skip: the **reboot** after switching
    backends (rules left in the old subsystem are still evaluated, and a `DROP` there
    wins), and **re-running `install`** after curling a new binary (otherwise a new
    binary enforces the old stanza).
  - **X5** the last three test ports that named real services — 9100 node_exporter,
    9200/9300 Elasticsearch — are gone. Every port in `TEST_PORTS` is a port the suite
    will delete a rule for, so none of them may be one a real service plausibly uses.
- **H1 — the premise was wrong, and that is the finding.** Step 3b was believed to "fire
  reliably at the end of every run". It does not: **zero occurrences across four full
  local suite runs and both CI backends.** The earlier observation came from the
  *string-matching* detection bug, which also matched a chain that does not exist — and
  an absent `ufw-user-input` at the end of a run is a perfectly ordinary state. Once the
  detection was corrected to require "present in nft AND unreadable by iptables", it
  stopped firing, because the thing it was reporting was never there.

  The genuine condition — a ufw chain expressed in native nft syntax — was observed once,
  for real, and remains unreproduced. The free experiment the triage proposed (does 3b
  fire on the legacy leg?) is answered and uninformative: it fires on neither, because it
  fires nowhere.

  A guard we cannot exercise is a guard we cannot trust, so rather than leave this open,
  the next real occurrence is now **self-reporting**: 3b writes a syslog line and dumps
  the nft table into the rescue snapshot before repairing, so whoever hits it has the
  evidence we currently lack instead of just a repaired host.

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
