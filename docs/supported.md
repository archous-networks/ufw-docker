# Supported platforms

This tool **refuses to install** on a platform nothing has proven it works on. That is
not caution for its own sake: the failure it prevents is silent. `install` would succeed,
`status` would report everything wired, and nothing would be filtered.

The authoritative copy of this table is a heredoc inside `ufw-docker` itself, because the
preflight has to read it on a host that has only ever downloaded that one file. This page
is the human-readable copy, and `tests/lint-supported.sh` fails the build if the two
disagree.

```
ufw-docker platforms      # the matrix, plus where this host sits in it
```

## The matrix

| label | distro | ver | ufw | backend | docker | verified by | status |
|---|---|---|---|---|---|---|---|
| `dev-00` | debian | 12 | 0.36.2 | nf_tables | 29.7.1 | full suite, every run | **supported** |
| `site-00` | debian | 12 | 0.36.2 | nf_tables | 29.9.2 | survey; same class as `dev-00` | **supported** |
| `ci-nft` | ubuntu | 24 | 0.36.x | nf_tables | ci | CI, both IPv6 legs green | **supported** |
| `ci-legacy` | ubuntu | 24 | 0.36.x | legacy | ci | CI, green on run 39868550084 | **supported** |

Matching is on **distro + major version + iptables backend**. ufw and Docker versions are
recorded but deliberately *not* matched on — they move constantly, and gating on them
would turn every routine upgrade into a refusal.

## The rule for adding a row

> A row may say `supported` only where the **verified by** column names real evidence.

Not "it ought to work". Not "it is the same family as one that does". The whole point of
the matrix is to make the difference between *proven* and *assumed* impossible to blur,
because this project has twice been wrong about which was which.

To add one:

1. Run `sudo tools/ufw-docker-survey` on the host and keep the output.
2. Get a green CI leg for that distro/version/backend combination, or run the full suite
   on a host of that class.
3. Add the row, with the evidence named.

Labels are opaque on purpose: **customer names do not belong in a public repo.** The
`site-NN` mapping is kept outside it.

## What is deliberately not in the matrix

Some things are refused by the preflight regardless of platform, because they are
properties of the *mechanism* rather than of the OS:

| check | why |
|---|---|
| mixed iptables backends | the kernel evaluates both, and a `DROP` in either wins — so our rules can be perfectly correct and still be overridden |
| Docker Swarm | publishes through its own ingress mesh, a path this tool does not govern |
| rootless Docker | publishes via a userspace proxy, so traffic never traverses `DOCKER-USER` |
| ufw's files not where ufw says | we would write a stanza nothing reads, and report success |

And one thing that is explicitly **not** a failure: `--network host` containers. They are
understood, correctly unaffected, and governed by ordinary ufw `INPUT` rules. Spending
the word "unsupported" on something harmless is how it stops being read when it matters.

## Overriding it

```
sudo ufw-docker install --unsupported --force
```

Both flags are required — one flag is something you can paste from a forum post without
reading it. The fact is recorded in the installed stanza and reported by **every**
`status` run afterwards, because the person reading `status` is rarely the person who
typed `--force`.

An accepted override **warns** and leaves `status` exiting 0. An environment that became
unsupported *after* install — somebody switched the backend — **goes red**, because that
is a change nobody agreed to.
