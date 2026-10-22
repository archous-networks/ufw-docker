# TODO — approved for immediate work

Triaged 2026-10-22, item by item. Everything here was reviewed and marked **now**;
everything marked **later** moved to [FUTURE.md](FUTURE.md). Nothing is unsorted any more.

Severity is the original read: **S1** could leave someone unfiltered or locked out,
**S2** produces wrong or confusing behaviour, **S3** is ergonomics or polish.
Evidence tags: **[verified]** reproduced here · **[suspected]** reasoned, not reproduced ·
**[unknown]** we do not know.

## Suggested order

Not a rule, but these have real dependencies on each other:

1. **X1 + D4 + D5 together.** All three restructure `cmd_status`, and doing that three
   times is the waste. X1 is also what makes "unsupported" a refusal rather than a
   sentence in a doc.
2. **A11** — the legacy CI leg is currently failing and Debian 10 is in the estate, so
   this is the most load-bearing unknown.
3. **E10 stage 1** — the support matrix, which X1 reads and CI generates legs from.
4. **B6, B7** — the two recovery-path defects. B6 contains a live bug.
5. **F1 + F2** — release and checksums, once the above makes `v1.0.0` mean something.
6. **D3 last** — per-subcommand help, after the new flags exist, or it gets written twice.

---

## The list

| # | | | |
|---|---|---|---|
| **X1** | **Supported-environment preflight that REFUSES.** Nothing enforces our "untested" caveats today, so a customer on an unsupported setup gets the worst outcome: `install` succeeds, `status` reports everything wired, nothing is filtered. Checks: iptables backend is nft; **no mixed backends** (rules in both subsystems — both are evaluated, a `DROP` in either wins); Swarm inactive; Docker not rootless; ufw paths resolve (see D5). Runs in `install` **and** `status`, because a host that is fine today can have its backend switched tomorrow. `--dry-run` reports it. `--unsupported` **alone refuses** and lists each failed check, requiring `--force` as well — same pattern as `--include-backups`. Loudness must be **persistent**: a banner at install, a `# INSTALLED IN UNSUPPORTED MODE: <checks>` line in the stanza, a line in **every** `status` run, and a syslog audit entry. A host that took the flag must never quietly pass for supported. *No ufw-backend check is needed — upstream ufw has no native nftables backend.* | [verified] | S1 |
| **A11** | **iptables-legacy is unproven, and Debian 10 is in the estate** — so this is a real deployment target, not an edge case. The CI leg exists and **currently fails**: every "should be open" assertion fails while every "should be blocked" one passes. Hypothesis, not yet confirmed: nft rules created at boot coexist with the legacy rules we add, both are evaluated, and a `DROP` in either wins. Fix the leg with `nft flush ruleset` after the switch. Until it is green we cannot say whether legacy works. Already confirmed: legacy **rejects** `-j NOSUCHCHAIN` where nft accepts it. | [verified] | S2 |
| **E10** | **Supported-platform matrix, feeding the preflight and CI.** Lives **inside `ufw-docker`** as a heredoc — the single-file property means the preflight cannot read an external file. Field order mirrors `tools/ufw-docker-survey` so a pasted survey line can be matched against it. Columns: `label \| distro \| ver \| ufw \| backend \| docker \| verified-by \| status`. Three consumers: the preflight matches the live host; CI generates matrix legs from `status=supported` rows; a `tests/lint-supported.sh` fails on drift between the table and the docs. **Rule: a row may claim `supported` only where a green CI leg proves it** — a surveyed host matching no row is `unverified`. Use opaque `site-NN` labels; the mapping lives outside this repo. **Stage 1** (table, preflight wiring, lint, fix the legacy leg) is cheap. **Stage 2** (real Debian 10/11/12 legs) is not: GitHub hosts no Debian runners and the suite needs real kernel netfilter, systemd and a Docker daemon, so it means privileged DinD, VMs, or self-hosted runners. | [verified] | S2 |
| **D4** | **`status --json`.** The exit code is all monitoring gets today — "something is wrong", never what. Anything richer means scraping coloured prose, which changed wording several times in a single day. `--json` is also the natural home for the preflight verdict and its failed checks. **Build with X1**: `cmd_status` prints as it checks and must be restructured to collect-then-render. | | S3 |
| **D5** | **Derive ufw's paths instead of hardcoding them.** ufw has no CLI flag for this, but its Python module carries packager-patched constants: `python3 -c 'import ufw.common as c; print(c.config_dir, c.share_dir, c.state_dir, c.prefix_dir)'` → `/etc /usr/share/ufw /lib/ufw /usr`. All four derived paths verified to resolve here. Derive → fall back to Debian defaults if unavailable → **verify each path exists** → refuse as unsupported otherwise. ~10 lines; folds into X1. Gotchas: `config_dir` is `/etc`, **not** `/etc/ufw`; and it is ufw's internal module, justified only because it **fails loudly** where a wrong hardcoded path fails silently. | [verified] | S3 |
| **B6** | **`rescue` must stop inventing an SSH rule.** If `user.rules` has none, that usually means ufw never permitted SSH — so a blanket `ACCEPT` grants access that never existed rather than restoring anything, and `rescue --open` already covers the deliberate "get me in regardless" case. New behaviour: replay from `user.rules` → else replay from the newest `/var/backups/ufw-rescue-*` snapshot → else **invent nothing** and point at `--open`. Plus `status` must flag any blanket SSH `ACCEPT` in `INPUT` that ufw did not create, for hosts that already have one. **Live bug:** detection matches `--dport <port>` only, so an operator allowing SSH by interface (`ufw allow in on wg0`) reads as "no SSH rule" and that host gets port 22 opened to the world today. | [verified] | S2 |
| **B7** | **SSH port detection can miss, silently.** Add `systemctl show ssh.socket -p ListenStream` to the chain — socket activation is the default on Ubuntu 22.10+, and `sshd -T` can report 22 while the socket unit listens elsewhere. The more important half: make the bare-22 fallback **loud**. "Could not determine the SSH port, assuming 22" rather than presenting a guess as fact. | [suspected] | S2 |
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
