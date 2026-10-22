#!/usr/bin/env bash
#
# Does `ssh_rules_in` actually find the rules that permit SSH?
#
# This exists because the answer was NO, in a way no test could have caught by
# accident. The matcher looked for `--dport <port>`, and `ufw allow in on wg0`
# writes `-A ufw-user-input -i wg0 -j ACCEPT` with no --dport at all. A host
# whose only SSH path was an interface therefore read as "no SSH rule" -- and
# `rescue` responded by opening the port to the world, unattended, at boot.
#
# The development host had BOTH an interface rule and a --dport rule, so the
# matcher looked correct there. That is exactly the environment-dependent
# masking this project keeps paying for, so the check lives here: pure logic
# against synthetic inputs, no firewall, no root, runs in the fast CI job.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck disable=SC1090
source <(sed -n '/^ssh_rules_in() {/,/^}/p' "$REPO/ufw-docker")

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

check() {   # $1 = name, $2 = expect found|none, $3 = port, $4... = rule lines
    local name="$1" expect="$2" port="$3"; shift 3
    local f="$TMP/rules"; : > "$f"
    local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
    local got; got="$(ssh_rules_in "$f" "$port" | grep -c . || true)"
    local verdict=none; [ "${got:-0}" -gt 0 ] && verdict=found
    if [ "$verdict" = "$expect" ]; then
        printf 'ok  %s\n' "$name"
    else
        printf 'NOT OK  %s — expected %s, got %s\n' "$name" "$expect" "$verdict"
        sed 's/^/        /' "$f"
        fail=1
    fi
}

check "explicit dport rule is found"            found 22 \
    '-A ufw-user-input -p tcp --dport 22 -j ACCEPT'
check "source-restricted dport rule is found"   found 22 \
    '-A ufw-user-input -p tcp --dport 22 -s 10.0.0.1 -j ACCEPT'
# THE BUG. Without this case the matcher looks fine on any host that also has
# a --dport rule, which is most of them.
check "INTERFACE-scoped allow is found"         found 22 \
    '-A ufw-user-input -i wg0 -j ACCEPT'
check "source-scoped portless allow is found"   found 22 \
    '-A ufw-user-input -s 10.9.0.0/24 -j ACCEPT'
check "v6 chain is searched too"                found 22 \
    '-A ufw6-user-input -p tcp --dport 22 -j ACCEPT'
check "non-default SSH port is honoured"        found 2222 \
    '-A ufw-user-input -p tcp --dport 2222 -j ACCEPT'

check "a rule for a DIFFERENT port is not it"   none 22 \
    '-A ufw-user-input -p tcp --dport 443 -j ACCEPT'
check "an empty rule set finds nothing"         none 22 ''
# A DROP is not permission. Treating it as one would make rescue decide the
# operator already allowed SSH and leave them locked out.
check "a portless DROP is not permission"       none 22 \
    '-A ufw-user-input -i wg0 -j DROP'
check "a portless REJECT is not permission"     none 22 \
    '-A ufw-user-input -s 10.9.0.0/24 -j REJECT'
# 2222 must not be matched by a rule for 22222, or vice versa.
check "port match is not a prefix match"        none 22 \
    '-A ufw-user-input -p tcp --dport 2200 -j ACCEPT'

if [ "$fail" -eq 0 ]; then
    echo "ok  ssh-detect self-test: the matcher finds every form of SSH permission"
else
    echo "FAILED"
fi
exit $fail
