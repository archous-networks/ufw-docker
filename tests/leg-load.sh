#!/usr/bin/env bash
#
# "Real load is untested" -- the third standing gap next to the kernel and
# cold boot. A leg is a clean room; the development host runs sixteen
# containers and a live UISP stack, and nothing in the suite had ever pointed
# more than one connection at a rule.
#
# BE HONEST ABOUT WHAT THIS IS. It is NOT a benchmark, and deliberately so: a
# throughput number from a container on a shared CI runner is noise, and a
# test that fails on a busy runner teaches people to re-run until green. What
# it measures is CORRECTNESS UNDER CONCURRENCY, which is deterministic:
#
#   - N concurrent connections against a DENY must ALL be refused. One leak is
#     a failure, and a leak is exactly what a conntrack or rule-ordering bug
#     looks like -- invisible at one connection at a time.
#   - N concurrent connections against an ALLOW must ALL succeed. Dropping
#     legitimate traffic under load is the other half of the same bug.
#   - the rule set must be BYTE-IDENTICAL afterwards, and status still green.
#     Nothing here should rewrite the firewall; if the chain changed under
#     load, something is rebuilding it that should not be.
set -uo pipefail

NAME="${1:?usage: leg-load.sh <container>}"
PORT="${2:-18077}"
CONC="${LEG_LOAD_CONC:-20}"
TOTAL="${LEG_LOAD_TOTAL:-200}"
dexec() { docker exec "$NAME" "$@"; }
say() { printf '\n-- %s\n' "$*"; }
rc=0
fail() { echo "FAIL  $*"; rc=1; }
pass() { echo "pass  $*"; }

# A HELPER, NOT A STYLE CHOICE. `cmd | grep -q pattern` under `set -o pipefail`
# is wrong in TWO independent ways, and this phase hit both before it worked:
#
#   1. grep -q exits the moment it matches, the producer keeps writing into a
#      closed pipe, takes SIGPIPE and exits 141 -- which pipefail makes the
#      status of the whole pipeline. So a MATCH reports failure. Measured: 141.
#
#   2. pipefail also propagates the PRODUCER's own exit status. `ufw-docker
#      status` returns 1 whenever any check is red, so "does its output mention
#      X" came back false purely because something unrelated was wrong.
#
# Both inverted real results: `status` printed `IPv4 wired` in plain sight
# while the check looking for it declared the host unwired. The question being
# asked is "did this command SAY X", which is independent of how it exited --
# so capture the output, discard the status, and match in bash.
#
# Substrings, not regexes: `case` would treat a glob character as one.
says() {   # says <substring> <command...>
    local want="$1"; shift
    local out; out="$("$@" 2>&1 || true)"
    case "$out" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

cleanup() {
    dexec sh -c "docker rm -f load-web >/dev/null 2>&1
        ufw delete allow $PORT/tcp >/dev/null 2>&1
        ufw delete deny $PORT/tcp >/dev/null 2>&1" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# PRECONDITION. The suite's teardown_file removes the tool, so a phase that
# assumes an installed host silently tests an unfiltered one -- where every
# connection succeeds and the DENY half of this looks like a leak.
say "precondition: the tool is installed and wired"
# Ask `status` rather than grepping after.rules: the marker is
# `BEGIN DOCKER-UFW`, and the first version of this check spelled it backwards.
says 'IPv4 wired' dexec /usr/local/sbin/ufw-docker status \
    || { echo "FAIL  the tool is not installed and wired — nothing would be filtering. Not a pass."
         dexec /usr/local/sbin/ufw-docker status 2>&1 | tail -20; exit 1; }

say "start a published container"
# PUBLISH 1:1, AND DO NOT "TIDY" THIS TO -p $PORT:80.
#
# By the time a packet reaches DOCKER-USER it has already been DNAT'd, so the
# destination port is the CONTAINER port, not the published one. With
# `-p 18077:80` the rule that governs it is `ufw deny 80` -- and `ufw deny
# 18077` matches nothing at all.
#
# The first version of this script published 18077:80 and then reported
# "200 of 200 LEAKED THROUGH a deny rule under concurrency". Nothing leaked:
# the rule could never have matched. Worse, the ALLOW half had passed for the
# same reason -- 200/200 succeeded because nothing was filtering either way.
# A vacuous pass and a false alarm from one mistake, and it is precisely the
# trap `status` warns operators about. tests/run.sh publishes 19089:19089 for
# this same reason.
dexec sh -c "docker rm -f load-web >/dev/null 2>&1
    docker run -d --name load-web -p $PORT:$PORT python:3-alpine python -m http.server $PORT" >/dev/null 2>&1 \
    || { echo "FAIL  could not start the load container"; exit 1; }
sleep 4

LEGIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"

# Count OUTCOMES, not a pass/fail per request: the interesting number is how
# many of N behaved differently from the rest, and printing it makes a flake
# distinguishable from a leak at a glance.
hammer() {   # -> "<ok> <blocked>"
    local ok=0 blocked=0 line
    while read -r line; do
        case "$line" in 200) ok=$((ok+1)) ;; *) blocked=$((blocked+1)) ;; esac
    done < <(seq "$TOTAL" | xargs -P "$CONC" -I{} \
        curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://$LEGIP:$PORT/" 2>/dev/null)
    echo "$ok $blocked"
}

say "baseline: $TOTAL requests at concurrency $CONC against an ALLOW"
dexec sh -c "ufw allow $PORT/tcp" >/dev/null 2>&1
sleep 1
read -r ok blocked <<<"$(hammer)"
echo "allow: ok=$ok blocked=$blocked"
[ "$ok" -eq "$TOTAL" ] \
    && pass "every connection succeeded under load with an ALLOW in place" \
    || fail "$blocked of $TOTAL were dropped while the rule said allow"

rules_before="$(dexec sh -c 'iptables-save 2>/dev/null | grep -v "^#" | grep -vE "^\[" ')"

say "$TOTAL requests at concurrency $CONC against a DENY"
dexec sh -c "ufw delete allow $PORT/tcp; ufw deny $PORT/tcp" >/dev/null 2>&1
sleep 1
# ONE connection first. If the rule is not biting at all, that is a SETUP
# error -- a mismatched port, an uninstalled tool -- and reporting it as
# "N of N leaked under concurrency" sends you hunting a conntrack bug that
# does not exist. Ask the cheap question before the expensive one.
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LEGIP:$PORT/" 2>/dev/null)" = 200 ]; then
    echo "FAIL  a SINGLE connection got through the deny — this is a setup fault,"
    echo "      not a concurrency one. Check the published port matches the rule."
    dexec sh -c "ufw status | grep $PORT; iptables -S ufw-user-input | grep $PORT" || true
    exit 1
fi
read -r ok blocked <<<"$(hammer)"
echo "deny: ok=$ok blocked=$blocked"
[ "$ok" -eq 0 ] \
    && pass "no connection got through under load with a DENY in place" \
    || fail "$ok of $TOTAL LEAKED THROUGH a deny rule under concurrency"

say "the firewall did not rewrite itself under load"
rules_after="$(dexec sh -c 'iptables-save 2>/dev/null | grep -v "^#" | grep -vE "^\[" ')"
# The deny itself is an expected difference; compare everything EXCEPT rules
# mentioning the test port.
b="$(printf '%s\n' "$rules_before" | grep -v "$PORT" | sort)"
a="$(printf '%s\n' "$rules_after"  | grep -v "$PORT" | sort)"
if [ "$b" = "$a" ]; then
    pass "the rest of the rule set is byte-identical after $((TOTAL*2)) connections"
else
    fail "the rule set changed under load:"
    diff <(printf '%s\n' "$b") <(printf '%s\n' "$a") | head -20
fi

dexec /usr/local/sbin/ufw-docker status >/dev/null 2>&1 \
    && pass "status is still green after the load" \
    || fail "status reports a problem after the load"

exit $rc
