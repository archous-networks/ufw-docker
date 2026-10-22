# The operator-rule invariant, as a library so it can be self-tested.
#
# A check that never fires is indistinguishable from a check that cannot fire,
# and this suite has already shipped three assertions that passed for the wrong
# reason. The logic therefore lives here, pure and file-driven, and
# tests/invariant-selftest.sh exercises it against synthetic inputs on every CI
# run. The bats suite supplies the real rule files; this decides the verdict.

# Ports and addresses the suite owns. Port 443 is here because the remapped-port
# test publishes 18443:443 and must write a rule for the CONTAINER port to prove
# the warning can be silenced. Port 80 is deliberately absent: the
# per-container tests use container port 80, but always with a 172.21.x
# destination, so the address list covers them. A bare `ufw allow 80/tcp` is
# therefore flagged, which is correct -- the suite never creates one.
TEST_PORTS='443|8089|9100|9200|9300|18080|18090|18443|19100'
TEST_ADDRS='-d (172\.21\.|172\.23\.|fd00:dead:beef:)|-s (10\.97\.|10\.98\.|fd00:97:|fd00:99:)'

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
