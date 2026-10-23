#!/usr/bin/env bash
#
# Does the tool correctly classify Docker's firewall backend?
#
# WHY THIS IS A SELFTEST AND NOT A BATS TEST: there is no way to stand up
# Docker's nftables backend in CI -- it needs a daemon restart with a changed
# daemon.json, on a daemon new enough to have it, and the leg containers run
# whatever their distro ships. So the REFUSAL PATH would be the one branch in
# preflight that nothing ever executes, and an untested refusal path is how a
# tool starts refusing hosts that were perfectly fine.
#
# WHY THE REFUSAL EXISTS AT ALL. Read moby's own source, daemon/libnetwork/
# firewall_linux.go, setupUserChains():
#
#     // There's no equivalent to DOCKER-USER in the nftables implementation.
#     if nftables.Enabled() { return }
#
# With `"firewall-backend": "nftables"` in daemon.json the chain is never
# created and FORWARD never jumps to it. Every rule this tool writes would sit
# in a chain that does not exist. That is not a degraded mode, it is a total
# one, and it is a setting a Docker upgrade could plausibly start defaulting.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck disable=SC1090
source <(sed -n '/^unsupported_firewall_backend() {/,/^}/p' "$REPO/ufw-docker")

fail=0
check() {   # $1 = name, $2 = what docker info reports, $3 = expect ok|refuse
    local name="$1" reported="$2" expect="$3"
    # Stub the reader, not `docker` itself: this is testing the classification,
    # and a fake binary on PATH would also be testing the --format string.
    docker_firewall_backend() { printf '%s\n' "$reported"; }
    local got verdict
    got="$(unsupported_firewall_backend)"
    [ -z "$got" ] && verdict=ok || verdict=refuse
    if [ "$verdict" = "$expect" ]; then
        printf 'ok  %s\n' "$name"
    else
        printf 'NOT OK  %s — reported %q, expected %s, got %s (%q)\n' \
            "$name" "$reported" "$expect" "$verdict" "$got"
        fail=1
    fi
}

# Old daemons have no such field. Empty must NOT refuse -- every host in the
# matrix below Docker 28 reports nothing here, and refusing them all would
# have been a spectacular own goal.
check "empty (daemon predates API 1.49)"   ""                ok
check "iptables"                           "iptables"        ok
# Not values moby emits today, accepted deliberately: if the field ever gets
# more specific about WHICH iptables, that is still a DOCKER-USER world.
check "iptables-nft"                       "iptables-nft"    ok
check "iptables-legacy"                    "iptables-legacy" ok
# The one that matters.
check "nftables (no DOCKER-USER exists)"   "nftables"        refuse
# Anything unrecognised refuses rather than assuming. A backend nobody here
# has heard of is exactly the case where guessing 'probably fine' is wrong.
check "an unknown future backend"          "somethingelse"   refuse

[ "$fail" -eq 0 ] && echo "all firewall-backend classifications correct"
exit $fail
