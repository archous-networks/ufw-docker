# FUTURE — deferred, with the reason

Triaged 2026-10-22 alongside [TODO.md](TODO.md). Everything here was reviewed and
deliberately deferred. Nothing is here because we ran out of time to think about it.

Each entry says **what would bring it forward**, because "later" without a trigger is
just a way of never deciding.

---

## H2 · Is Docker's preservation of `DOCKER-USER` contractual, or incidental?
**S1 · [unknown] · needs a full investigation, not a drive-by note**

The whole design rests on Docker not clobbering a populated `DOCKER-USER`. Empirically it
holds, and it has been tested harder than most things here: 100 samples at 0.5s across a
daemon restart (always 3 jumps, never 0), survives a cold boot, a container recreate,
`ufw reload`, and `ufw disable`/`enable`.

What is unknown is whether Docker **guarantees** it or we are leaning on an implementation
detail. "Documented as the place to put your rules" is not the same as "guaranteed to be
preserved by every future daemon".

**Why deferred, not dismissed:** the mitigation already exists and is tested — self-heal
detects exactly this state (stanza installed, `DOCKER-USER` unwired) and reloads. So the
blast radius is "unfiltered until the next boot or self-heal run", not "unfiltered
forever". This is about knowing how much to trust it, not about changing behaviour.

**Scope when it happens:** read Docker's source for how `DOCKER-USER` is created and what
may flush it, pin the finding to a version, and state plainly whether it is a guarantee or
an implementation detail. The answer may legitimately be "still not guaranteed, but here is
the code path and here is what would have to change."

**Brings it forward:** any observed instance of `DOCKER-USER` being emptied in the wild, or
a Docker major release that touches chain management.

---

## A2b · Make `ufw allow 8443` work for a remapped port
**S2 · [verified] · plausible, but a different architecture**

Publish `8443:443` and the rule that works is `ufw allow 443`. Part one — `status` naming
rules that can never match — is **done**. Making the published port actually work means
matching pre-DNAT with `-m conntrack --ctorigdstport`, which in turn means generating
`DOCKER-USER` from ufw's rule set and keeping the two in sync.

**Why deferred:** that is a resident translator, not a static stanza. The static stanza is
what makes this tool auditable, survivable and inspectable with plain `iptables -S` — and
it is what lets `rescue` reason about the firewall at all. Trading that away to remove a
footgun we now warn about loudly is not obviously the right deal.

**Brings it forward:** evidence that the warning is not enough — operators hitting it
repeatedly despite being told.

---

## A3 · Target a container by name
**S2 · [verified] · possible feature**

iptables matches addresses, not names. Targeting by **address** works today, is verified
to survive a container recreate with static IPAM, and `ufw-docker containers` flags the
containers on dynamic addresses — the ones a rule cannot safely name.

**Why deferred:** closing the dynamic case needs an `ipset` per container plus a
`docker events` watcher keeping it populated. Same architectural trade as A2b: a resident
daemon. Static IPAM covers the real need and is documented.

**A cheaper middle ground, if wanted:** `status` could flag a rule whose destination no
running container holds any more — the same shape as the subnet-drift check, ~30 lines. It
does not give name-based rules, only drift detection after the fact.

**Brings it forward:** a deployment that genuinely cannot pin addresses.

---

## A9 · Rootless Docker
**S2 · [suspected] · potential**

Rootless Docker uses slirp4netns or pasta in a user namespace; port forwarding happens in
userspace and host netfilter largely does not see it. Expected — **but not verified** — to
fail visibly, because `require_docker` would not find the socket (`$XDG_RUNTIME_DIR`).

**The case that would be bad:** rootless running *alongside* a rootful daemon, where
`require_docker` finds the rootful socket, wires happily, and the rootless containers are
neither protected nor mentioned.

**Why deferred:** not believed to be anywhere in the estate; it is a developer-laptop and
shared-hosting pattern, not ISP infrastructure. `caveats.md` states it as untested and
almost certainly unsupported, so nothing implies it works. X1 will refuse on it.

**Brings it forward:** a survey result showing rootless anywhere.

---

## A12 · Origin lockdown to a WAF's egress ranges
**S2 · [unknown]**

[`docs/waf.md`](docs/waf.md) argues that a WAF is worth nothing unless the origin is
unreachable except from the WAF — and that locking it down is this tool's job. The
mechanism that rests on (source-restricted allow on a container port) **is** tested. The
full arrangement has never been stood up against a live Cloudflare or AWS WAF.

Two separate risks: whether ~22 source rules in `ufw-user-input` behave and perform as
expected (likely fine, unmeasured); and that **the ranges rotate** with nothing here
tracking them, so a host can be locked to a stale list.

**Why deferred:** we have no WAF to test against. `docs/waf.md` already states this
honestly in its measured-vs-reasoned table, so the page does not claim more than we know.

**Brings it forward:** a customer putting a UISP instance behind Cloudflare or AWS WAF.

---

## X2 · Support for the other environments — **DONE**
**S2 · the other half of X1**

Moved out of "deferred" on 2026-10-22: the real CI matrix was built. It is kept here
rather than deleted because the *reasoning* about what is and is not covered is still
live, and because the kernel caveat below is a standing limitation, not a finished task.

| environment | status |
|---|---|
| iptables-legacy | **done.** A11 green; evidenced by run 39868550084, and now by a `legacy` leg per distro |
| Debian 10 / 11 / 12, Ubuntu 22.04 / 24.04 | **done.** `tests/container-leg.sh`, run per distro × backend on every push |
| rootless Docker | A9 above — still open |
| Swarm | closed as out of scope — see `caveats.md` |

### What it turned out to cost

The blocker was recorded here as "no GitHub Debian runners", which is true and was read
as meaning VMs, DinD or self-hosted infrastructure. It meant none of those: a privileged
container with `systemd-sysv`, `--cgroupns=host` and dockerd inside gives a real init, a
real daemon, its own network namespace and **that distro's own iptables**. One day, as
estimated.

It paid for itself the same day, on the oldest leg:

- **a real portability bug** — `awk 'length(a)'` on an array, which Debian 10's mawk
  rejects outright, so SSH port detection silently fell through to guessing port 22 on
  every Debian 10 host. `rescue` depends on that detection.
- **Docker 18.09 cannot start on a cgroup v2 kernel at all** (`Devices cgroup isn't
  mounted`), so Debian 10's own `docker.io` is not a configuration that exists in the
  field — the leg uses docker-ce, which is what such a host must run.
- **iptables 1.8.2 prints `-p 6`, not `-p tcp`.** Anything matching rule text by protocol
  name reads an old host as having no rule.

### The standing limitation: the kernel is always the runner's

A leg is that distro's **userspace** on whatever kernel the runner boots. `debian:10`
is Debian 10 tooling on a 6.x kernel, not the 4.19 a real Debian 10 box runs. A failure
that needs the distro's own kernel is not caught, and no amount of containers fixes it.

Also not covered, and listed so nobody assumes otherwise: **cold boot** (the self-heal
unit's entire purpose, still `tests/cold-boot-check.sh` on real hardware, still manual)
and **real load** (a leg is a clean room; the development host runs sixteen containers
and a live UISP stack).

**What would close the kernel gap:** real VMs per distro — self-hosted runners or a
nested-virt provider. Deferred again, and now a much smaller gap than it was: everything
reachable without a distro kernel is already covered per push.

---

## F3 · A `.deb` package
**S3 · very plausible, but currently redundant**

A `.deb` would give versioning, integrity, correct paths, dependency declaration and
`apt`-native upgrades. Almost all of that is already being solved more cheaply:

| `.deb` would give | already covered by |
|---|---|
| versioning | F1 — tags + releases |
| integrity | F2 — `SHA256SUMS` |
| correct paths | D5 — derived from `ufw.common`, verified, refused if absent |
| dependency checks | X1 — the preflight, which checks more than a dependency list can |
| upgrade path | X4 — `curl` + re-run `install`, already idempotent |

What only a `.deb` gives is `apt`-native upgrade and a signed APT repo — meaningful, but
only with the ongoing commitment that implies: GPG key management, repo hosting, keyring
distribution to every host.

There is also a mild tension with the design. The single-file property is load-bearing —
*one file cannot be half-installed*, which is why `rescue` lives in the same file as
`install`. A `.deb` does not break that, but it adds a packaging layer plus maintainer
scripts, which are their own class of bug on a firewall tool.

**Brings it forward:** `curl`-install becoming real friction for netops, or a customer
requiring packaged software.
