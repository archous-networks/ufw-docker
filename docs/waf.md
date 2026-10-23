# Where a WAF fits, and where it does not

Reasoning, not instructions. This exists because the question keeps coming up in the
same form — *"could we just put it behind Cloudflare / AWS WAF instead?"* — and the
answer is a shape worth writing down once.

## What a WAF is

A **Web Application Firewall** sits in front of a web app, reads each HTTP request —
URL, headers, cookies, body — and blocks the ones that look like attacks.

That is a different question from the one this tool answers:

| | decides based on | example rule |
|---|---|---|
| **Network firewall** — `ufw`, iptables, this tool | IP, port, protocol | "nothing reaches 443 except Cloudflare's ranges" |
| **WAF** — Cloudflare, AWS WAF, ModSecurity | the *content* of the request | "block query strings shaped like PHP argument injection" |

A network firewall does not care what is *in* the traffic, only where it came from and
where it is going. A WAF is the opposite: the connection is already allowed, and it is
judging the request. Layer 3/4 versus layer 7. They are not alternatives.

## The decisive point

**A WAF only filters traffic that goes through it.**

Cloudflare-style protection covers HTTP(S) on proxied DNS records. If the origin address
is reachable directly — which for a default install it is — an attacker resolves it once
and the WAF is decoration. **DNS is not an access control.**

This inverts the usual framing. A WAF is only worth anything if the origin is
unreachable *except* from the WAF, and enforcing that is a network-firewall job:

```
ufw allow from <WAF egress ranges> to any port 443 proto tcp
```

…with everything else denied, and — the part that is this tool's whole reason to exist —
with that rule actually applying to Docker-published ports instead of silently doing
nothing. See [architecture.md](architecture.md).

So the firewall is not an alternative to the WAF. **It is the precondition for the WAF
not being theatre.** This is the strongest single argument for `ufw-docker` in front of
anything edge-proxied.

## Three layers, and the labels matter

| | what it is | what it does |
|---|---|---|
| patching the vulnerable component | **remediation** | the bug is gone |
| `ufw-docker` | **containment** | the vulnerable thing is not reachable |
| WAF | **compensating control** | filters known-bad shapes out of what must stay public |

The failure mode is not using a WAF. It is **relabelling the third row as the first** —
treating a filter for known attack patterns as though the vulnerability were fixed.

## Why a container stack like UISP is a poor fit for a blanket HTTP proxy

Not every port on these hosts speaks HTTP, and the ones that do not are not optional.
On the development host, `docker ps` shows seven `unms-device-ws-*` workers and a
`unms-netflow` collector alongside `unms-nginx` and `ucrm`.

- **Long-lived device WebSockets.** Managed devices hold persistent connections to the
  controller. These are the control plane, not a web page.
- **NetFlow is UDP.** An HTTP proxy does not carry it at all.

Proxy the record naively and you risk breaking device management, while the device-facing
path — the one that cannot be proxied — stays exposed regardless. There is also real
operational cost in certificate handling, since a stack that manages its own ACME
certificates has to be reconciled with the proxy's TLS mode, and in request body limits
for file uploads. Check both against the specific plan rather than assuming.

## What a WAF does genuinely earn

Not nothing, and the honest case for it is about **time**:

- **Fleet-wide mitigation in minutes.** When a CVE lands and there are N instances to
  patch, an edge rule applies everywhere immediately while a rebuilt image takes days.
  That window is real, and a compensating control is exactly the right tool for it.
- **Rate limiting, bot and DDoS handling, request logging** — value independent of any
  particular CVE.

It is an **and**, never an **instead**.

## Reading a WAF changelog honestly

A worked example, because this is where the reasoning usually goes wrong.

An [emergency release dated 2026-10-21](https://developers.cloudflare.com/changelog/post/2026-10-21-emergency-waf-release-cfmr/)
was offered as evidence that a PHP CVE was covered. Reading it: seven rules, all named
*"Generic Rules — Anomalous Execution 1–7"*, all set to Block. It names **no CVE**, and
**does not mention PHP**.

Compare with releases that are genuinely targeted, which say so and cite the CVE:

| release | covers |
|---|---|
| [2026-08-26](https://developers.cloudflare.com/changelog/post/2026-08-26-emergency-waf-release/) | Next.js RCE, CVE-2026-75604 |
| [2026-04-30](https://developers.cloudflare.com/changelog/post/2026-04-30-emergency-waf-release/) | cPanel & WHM auth bypass, CVE-2026-41940 |
| [2026-05-15](https://developers.cloudflare.com/changelog/post/2026-05-15-emergency-waf-release/) | nginx heap overflow, CVE-2026-42945 |

**A generic-heuristic release is not coverage for a specific vulnerability.** It may well
catch common exploit shapes; it is not a statement that a given CVE is mitigated, and it
should not be read as one. When assessing whether a WAF covers something, look for the
CVE id.

## The recommendation

**Do not offer a WAF as the standard answer to a vulnerability in the stack.**

Technically it does not fit the shape of the stack, per the device plane above.
Commercially — and this weighs as heavily — making it standard converts it into an
implied guarantee. Telling customers they are covered means owning the bypass, and
generic anomaly rules will have both false negatives and false positives. That is taking
on liability for a control whose coverage cannot be characterised, to mitigate something
there is already a real fix for.

Offer it as an **optional edge-hardening add-on** for the HTTP surface, with the scope
stated plainly: *it does not cover the device plane, and it is worthless without origin
lockdown.*

Order of operations, which is the whole document in one line:

> **patch → reduce surface → then optionally filter what remains public.**

## What on this page is measured, and what is reasoned

In keeping with the rest of these docs, the distinction is explicit.

| claim | basis |
|---|---|
| the changelog contents above | **read directly** from the linked pages |
| the container set on a UISP host | **observed** — `docker ps` on the development host |
| `ufw allow from <range>` is honoured for container ports | **tested** — see the source-restricted test in the suite |
| NetFlow is UDP and not carried by an HTTP proxy | protocol fact, not measured here |
| WebSocket behaviour through a specific WAF plan | **reasoned, not tested** — verify per plan |
| an end-to-end origin lockdown to a real WAF's egress ranges | **not tested here.** Deferred as **A12** in [FUTURE.md](../FUTURE.md) |

The last row matters: the central recommendation of this page — lock the origin to the
WAF's ranges — follows from a mechanism the suite covers, but the full arrangement has
not been stood up and proven against a live WAF. Said plainly rather than implied.
