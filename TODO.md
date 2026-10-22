# Known gaps

Everything below is a real gap in `ufw-docker` as it stands. Nothing here is decided —
this is the raw list to review, triage, and split between "now" and `FUTURE.md`.

Each item is marked:

- **[verified]** — reproduced or confirmed on the dev host
- **[suspected]** — reasoned from the code or from how the components behave; not reproduced
- **[unknown]** — we genuinely do not know

Rough severity is my read, not a decision: **S1** could leave someone unfiltered or locked
out, **S2** produces wrong or confusing behaviour, **S3** is ergonomics or polish.

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
- **Docs** restructured into `docs/`, with the README as a table of contents.
- **Tests** 15 → 22, covering every item above.

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

## A. Coverage — things it silently does not do

| # | Gap | | |
|---|---|---|---|
| A2 | **Remapped ports need the container port.** Published `8443:443` means `ufw allow 443`, not `8443`, because DNAT runs before FORWARD. Pinned by a test, but still a footgun. Fixing it properly means translating ufw's rules into `DOCKER-USER` with `--ctorigdstport` — a resident translator, not a static stanza. | [verified] | S2 |
| A3 | **No way to target a container by name.** Rules can target a container's *address* (verified — see `docs/per-container.md`), but iptables matches addresses, not names. Static IPAM addresses make that usable today; tracking a **dynamic** address needs `ipset` plus a `docker events` watcher, i.e. a resident daemon. Not built. | [verified] | S2 |
| A3b | **`status` does not list containers and their current addresses**, so writing a per-container rule means looking the address up by hand, and a drifted one is invisible. | [verified] | S3 |
| A5 | **Host and container policy share one namespace.** `ufw allow 22` opens 22 on the host *and* on any container publishing it. There is no way to express "SSH to the host, never to a container". Inherent to jumping into `ufw-user-input`. | [verified] | S2 |
| A6 | **IPv6 filtering is unreachable unless the Docker daemon has `ip6tables` enabled** — now understood rather than merely untested. With a v6-enabled *network* but a daemon lacking v6 support, Docker installs its own `raw`/PREROUTING `DROP` for inbound traffic to container v6 addresses, ahead of FORWARD: `DROP !br-xxxx -> fd00:dead:beef::2`. Our stanza is correct and applied but never consulted. Verifying the stanza for real needs `"ipv6": true, "ip6tables": true` in `daemon.json` and a daemon restart — a change to the host's Docker config, not made here. | [verified] | S1 |
| A7 | **`--network host` containers are unaffected** — they use INPUT, not FORWARD. Correct behaviour, nowhere documented, and a reasonable person would expect otherwise. | [verified] | S3 |
| A8 | **Swarm / overlay networks untested.** `docker_gwbridge` and ingress have their own paths; no idea whether subnet derivation covers them. | [suspected] | S2 |
| A9 | **Rootless Docker almost certainly unsupported** — it uses slirp4netns, not these chains. Untested, undocumented. | [suspected] | S2 |
| A10 | **Custom bridge names** (`com.docker.network.bridge.name`) should be fine since we match subnets, not interfaces — but untested. | [suspected] | S3 |
| A11 | **Only tested against iptables-nft.** A host with legacy iptables, or a pure-nftables ufw, is unknown territory. | [verified] | S2 |

## B. Safety and failure modes

| # | Gap | | |
|---|---|---|---|
| B1 | **Self-heal has never repaired anything at boot.** Its detection ran and said `ufw healthy at boot`; `rescue` is well exercised by hand; the two have never been joined up in anger because no boot has gone wrong. The one path whose entire purpose is an unattended lockout is the one never exercised. | [verified] | S1 |
| B5 | **`remove` does not uninstall the binary.** It undoes all configuration but leaves `/usr/local/sbin/ufw-docker` behind. Arguably right, but undocumented and surprising. | [verified] | S3 |
| B6 | **`rescue`'s blanket fallback is unbounded in time.** When `user.rules` has no SSH rule, it leaves a blanket ACCEPT in place indefinitely — loudly, but forever. No expiry, no follow-up check. | [verified] | S2 |
| B7 | **SSH port detection could miss.** `sshd -T` is authoritative, but if it fails and the `ss` parse misfires, the fallback is a bare `22` — which on a host using a different port protects nothing. | [suspected] | S2 |
| B8 | **No validation that `after.rules` is well-formed** before handing it to ufw. A malformed stanza shows up as a failed reload, which B3 does not catch. | [verified] | S1 |

## C. Observability

| # | Gap | | |
|---|---|---|---|
| C1 | **`install` / `remove` / `status` leave no audit trail.** Nothing goes to syslog, so "who wired this host and when" is unanswerable. The self-heal unit does log; the tool itself does not. | [verified] | S2 |
| C2 | **`[UFW DOCKER BLOCK]` logs regardless of `ufw logging off`.** Our chain has its own LOG rule, so disabling ufw logging does not disable ours — a divergence from the behaviour the operator asked for. | [verified] | S2 |
| C3 | **`status` does not show effective policy.** It reports that we are wired, not *which* ufw rules currently govern containers. That is the question an operator actually has. | [verified] | S2 |
| C5 | **Chain counters are not surfaced.** `iptables -L DOCKER-USER -v` has the drop counts; nothing presents them. | [verified] | S3 |

## D. Ergonomics

| # | Gap | | |
|---|---|---|---|
| D1 | **No `--dry-run` for `install`.** `remove` previews by default; `install` does not, which is an inconsistent contract. | [verified] | S2 |
| D2 | **No `--version`**, and no version string anywhere in the file. | [verified] | S3 |
| D3 | **`--help` is the header comment.** Fine, but there is no man page and no `-h` on subcommands. | [verified] | S3 |
| D4 | **No machine-readable `status`** (`--json`), which monitoring would want. | [verified] | S3 |
| D5 | **Debian/Ubuntu paths are hardcoded** (`/etc/ufw/...`, `/usr/share/ufw/...`). Other distros will fail in unhelpful ways. | [verified] | S3 |

## E. Testing

| # | Gap | | |
|---|---|---|---|
| E1 | **CI has never been confirmed green.** The workflow now calls `tests/run.sh --tap`, which has never run on a GitHub runner. The lock and trap behaviour there is unverified. | [verified] | S1 |
| E2 | **No test for the self-heal repair path** (B1) — would need to break ufw, reboot, and assert recovery. |  | S1 |
| E3 | **No functional IPv6 test** (A6) — needs a v6-capable host. |  | S1 |
| E6 | **No test for `--include-backups`** or for the `remove` dry-run default. |  | S2 |
| E8 | **One test needs a UISP-shaped host** and skips elsewhere, so container-recreate coverage is thinner in CI than locally. |  | S3 |
| E9 | **shellcheck is advisory** (`|| true`), so it can never fail the build. |  | S3 |
| E10 | **Single platform.** Debian 12, one host, one Docker version. | | S2 |

## F. Packaging and distribution

| # | Gap | | |
|---|---|---|---|
| F1 | **No versioning, tags or releases.** `main` is the only thing anyone can fetch, so "which version is this host running" has no answer. | [verified] | S2 |
| F2 | **No checksum or signature** for the `curl | sudo install` one-liner. The README warns about the pattern; it does not give a way to verify. | [verified] | S2 |
| F3 | **No `.deb`**, which would solve F1, F2, D5 and the install ergonomics together. | | S3 |

## G. Documentation

| # | Gap | | |
|---|---|---|---|

## H. Unexplained

| # | Gap | | |
|---|---|---|---|
| H1 | **The nft-incompatible chain condition.** Recurs reliably at the end of a full suite run, where teardown's `rescue` interleaves `iptables -F/-X` with ufw's rebuild. Step 3b handles it every time, so it is contained — but the mechanism is unknown, and a fix we do not understand is a fix we cannot rely on. | [unknown] | S2 |
| H2 | **Is Docker's preservation of `DOCKER-USER` contractual or incidental?** We rely on it across daemon restart and cold boot, both verified empirically. Whether Docker *guarantees* it is not established, and B2 is the consequence if it ever changes. | [unknown] | S1 |
