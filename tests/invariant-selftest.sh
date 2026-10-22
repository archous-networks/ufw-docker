#!/usr/bin/env bash
# Prove the operator-rule invariant actually fires. Touches nothing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=tests/rules-lib.bash
source ./rules-lib.bash

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

check() {   # $1 = name, $2 = expected rc, $3 = before, $4 = after
    printf '%s\n' "$3" | sort > "$TMP/b"
    printf '%s\n' "$4" | sort > "$TMP/a"
    local out rc
    out=$(rules_diff_report "$TMP/b" "$TMP/a"); rc=$?
    if [ "$rc" -eq "$2" ]; then
        echo "ok  $1"
    else
        echo "NOT OK  $1 — expected rc=$2, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/        /'
        fail=1
    fi
}

SSH='-A ufw-user-input -p tcp -m tcp --dport 22 -j ACCEPT'
SSHR='-A ufw-user-input -s 203.0.113.29/32 -p tcp -m tcp --dport 22 -j ACCEPT'

check "unchanged passes"                       0 "$SSH" "$SSH"
check "DELETED blanket SSH rule is caught"     1 "$SSH" ""
check "DELETED restricted SSH rule is caught"  1 "$SSHR" ""
check "leaked blanket SSH rule is caught"      1 "$SSHR" "$SSHR
$SSH"
check "leaked unrelated rule is caught"        1 "$SSH" "$SSH
-A ufw-user-input -p tcp -m tcp --dport 3306 -j ACCEPT"
check "bare port 80 is caught"                 1 "$SSH" "$SSH
-A ufw-user-input -p tcp -m tcp --dport 80 -j ACCEPT"
check "test-owned port is allowed"             0 "$SSH" "$SSH
-A ufw-user-input -p tcp -m tcp --dport 19089 -j ACCEPT"
check "test-owned container dst is allowed"    0 "$SSH" "$SSH
-A ufw-user-input -d 172.21.0.10/32 -p tcp -m tcp --dport 80 -j ACCEPT"
check "test-owned probe src is allowed"        0 "$SSH" "$SSH
-A ufw-user-input -s 10.97.0.0/24 -p tcp -m tcp --dport 19089 -j ACCEPT"
check "test-owned v6 dst is allowed"           0 "$SSH" "$SSH
-A ufw6-user-input -d fd00:dead:beef::2/128 -p tcp -m tcp --dport 9200 -j ACCEPT"
check "a delete still fails amid allowed adds" 1 "$SSH" "-A ufw-user-input -p tcp -m tcp --dport 19089 -j ACCEPT"

[ "$fail" -eq 0 ] && echo "ok  invariant self-test: the check fires on every violation" || echo "FAILED"
exit $fail
