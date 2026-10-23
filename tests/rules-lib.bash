# The operator-rule invariant, as a library so it can be self-tested.
#
# A check that never fires is indistinguishable from a check that cannot fire,
# and this suite has already shipped three assertions that passed for the wrong
# reason. The logic therefore lives here, pure and file-driven, and
# tests/invariant-selftest.sh exercises it against synthetic inputs on every CI
# run. The bats suite supplies the real rule files; this decides the verdict.

# Ports and addresses the suite owns.
#
# EVERY PORT HERE IS A PORT THE SUITE WILL DELETE A RULE FOR. So a port only
# belongs here if no real service plausibly listens on it. 443 used to be in
# this list -- the remapped-port test published 18443:443 -- and on a UISP host
# unms-nginx publishes 443, so the test deleted the operator's own web rule.
# It now uses container port 19443 instead, which nothing serves.
#
# 8089 was the same bug and is also gone: UISP publishes it, so the suite was
# probing unms-nginx and deleting the operator's rule for it. The suite now
# creates its own container on 19089 instead -- see start_testsvc().
#
# Port 80 is absent and the per-container tests no longer use it either: with
# `-p 18090:80` the post-DNAT dport is 80, so on any host serving a website
# `ufw allow 80/tcp` matched and the "blocked with no rule" baseline could not
# hold. They use container port 19080 now, covered by the 172.21.x address
# rule rather than by port. A bare `ufw allow 80/tcp` is still flagged, which
# is correct -- the suite never creates one.
#
# 9100, 9200 and 9300 are gone too -- node_exporter and Elasticsearch listen
# on those, and nothing in TEST_PORTS may be a port a real service plausibly
# uses, because every port here is one the suite will DELETE A RULE FOR.
TEST_PORTS='18080|18090|18443|19080|19089|19100|19101|19200|19300|19443|19500'
TEST_ADDRS='-d (172\.21\.|172\.23\.|172\.24\.|fd00:dead:beef:)|-s (10\.97\.|10\.98\.|fd00:97:|fd00:99:)'

test_owned() {   # $1 = one rule line
    printf '%s' "$1" | grep -qE -- "dport ($TEST_PORTS)\b" && return 0
    printf '%s' "$1" | grep -qE -- "$TEST_ADDRS" && return 0
    return 1
}

# rules_diff_report <before-file> <after-file>
# Prints violations on stdout; returns 1 if there were any.
rules_diff_report() {
    local before="$1" after="$2" bad=0 line

    # DELETIONS ARE ALWAYS A BUG. No test has any business removing a rule the
    # operator put there. This is the exact failure that cost two CI runs and
    # eleven misattributed test failures.
    local deleted=0 leaked=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "### THIS TEST DELETED AN OPERATOR RULE ###"
        echo "    $line"
        deleted=1; bad=1
    done < <(comm -23 "$before" "$after")
    if [ "$deleted" -eq 1 ]; then
        echo "    There is no allowlist for this and there will not be one."
        echo "    Restore whatever you deleted, or test it on a port of your own."
    fi

    # ADDITIONS are allowed only on ports and addresses the suite owns.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        test_owned "$line" && continue
        echo "### THIS TEST LEAKED A RULE THE SUITE DOES NOT OWN ###"
        echo "    $line"
        leaked=1; bad=1
    done < <(comm -13 "$before" "$after")
    if [ "$leaked" -eq 1 ]; then
        echo "    If that rule is YOURS -- a new test using a port or address not yet"
        echo "    declared -- add it in tests/rules-lib.bash and re-run:"
        echo "        TEST_PORTS='$TEST_PORTS'"
        echo "        TEST_ADDRS='$TEST_ADDRS'"
        echo "    If it is NOT yours, the test is changing the operator's rules."
        echo "    Delete the rule before the test ends."
    fi

    return $bad
}
