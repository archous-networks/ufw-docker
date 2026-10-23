# Releases, and verifying a download

## Why not to install from `main`

The README used to say:

```bash
curl -fsSL https://raw.githubusercontent.com/.../main/ufw-docker | sudo install ...
```

That fetches **whatever commit happens to be at the tip of `main` at that instant**. If
you run it during a push you get an arbitrary intermediate state — possibly a commit
between "stanza written" and "stanza verified" — on a tool whose job is to rewrite your
firewall. Nothing warns you, because from curl's point of view nothing went wrong.

A release is a fixed set of bytes that cannot change under you.

```bash
# latest release — moves forward when we publish, never mid-push
curl -fsSL https://github.com/archous-networks/ufw-docker/releases/latest/download/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker

# a pinned version — these bytes, permanently
curl -fsSL https://github.com/archous-networks/ufw-docker/releases/download/v1.0.0/ufw-docker \
  | sudo install -m 0755 /dev/stdin /usr/local/sbin/ufw-docker
```

> **Dev branches solve the developer's problem. Releases solve the user's.** The question
> here was never "how do we keep unfinished work off `main`" — it was "what does a
> customer get when they curl". Those have different answers, and this is the second.

## Verify before you install

```bash
cd "$(mktemp -d)"
base=https://github.com/archous-networks/ufw-docker/releases/latest/download
curl -fsSLO $base/ufw-docker
curl -fsSLO $base/SHA256SUMS
sha256sum -c SHA256SUMS        # must print: ufw-docker: OK
less ufw-docker
sudo install -m 0755 ufw-docker /usr/local/sbin/ufw-docker
```

**What a checksum does and does not buy you.** It proves the bytes you fetched are the
bytes we published — it catches a truncated download, a mangled proxy, a stale CDN copy.
It does **not** prove who published them: anyone who could replace the artifact could
replace `SHA256SUMS` beside it. That needs a signature, and there is not one yet. Saying
so is the point; a checksum presented as provenance is worse than no checksum, because
it answers a question nobody asked while looking like it answered the real one.

## What a release guarantees

The artifact is attached by `.github/workflows/release.yml`, and the publish job
`needs:` the full test matrix — which since 2026-10-22 means the lint job, the three
native `bats` legs (including both IPv6 configurations) **and ten distro legs**, each
running the whole suite inside a real Debian or Ubuntu release on both iptables
backends. **The artifact cannot exist unless every leg was green** —
shellcheck, the five lints and self-tests, and all three bats legs including
iptables-legacy.

That workflow *calls* `test.yml` rather than repeating its steps. A release pipeline with
its own slightly-different checks is one that eventually ships something `main` would
have rejected.

It also re-checks that the tag and `VERSION` agree (`tests/lint-version.sh`). Those are
three copies of one fact — the tag, `VERSION`, and the version baked into the installed
stanza — and the stanza's copy is the operationally important one: `status` reads it to
report which version wired a host, and warns when the binary has since been replaced.
Shipping `v1.0.0` containing `0.9.0` makes that report lie in both directions.

## Cutting a release

```bash
# 1. VERSION in ufw-docker is the version you are about to tag
tests/lint-version.sh v1.0.0

# 2. tag it
git tag -a v1.0.0 -m 'v1.0.0'
git push origin v1.0.0
```

The workflow runs the full matrix, then publishes `ufw-docker` and `SHA256SUMS`. If any
leg fails, the tag exists but **no artifact does** — which is the correct outcome, and
visible rather than silent.

`workflow_dispatch` can re-run the publish for an existing tag, for the case where the
release step itself failed after a green matrix.

## Upgrading an installed host

Fetch the new file and **re-run `install`** — see [operations.md](operations.md). The
trap worth repeating: curling the new binary *without* re-running `install` leaves a new
binary enforcing the previous version's stanza. `status` flags that mismatch, which is
exactly why the stanza records the version that wrote it.
