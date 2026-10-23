#!/usr/bin/env bash
# tests/leg-summary.sh <leg.log>
#
# Condense one distro leg's output into a single line the README table can
# show: how many bats tests ran, and what each post-suite phase actually
# proved.
#
# This exists because of a specific failure. Two consecutive CI runs were
# fully green while the rootless phase skipped on all ten legs -- the run said
# "success" and the feature had zero coverage. A green tick that cannot
# distinguish "7 assertions passed" from "skipped entirely" is the same bug in
# a different place, so the table reports the COUNTS, not a colour.
#
# Parsing the log rather than having the phases write a structured file is
# deliberate: the log is what a human reads when a leg goes red, so keeping
# the summary derived from it means the two can never disagree.
set -uo pipefail

LOG="${1:?usage: leg-summary.sh <leg.log>}"
[ -r "$LOG" ] || { echo "suite=? (no log)"; exit 0; }

awk '
    # `say()` prints "-- phase: <name>"; everything after it belongs to that
    # phase until the next one. Lines before the first phase header are the
    # bats suite itself.
    /^-- phase: correctness under load/          { ph = "load";     next }
    /^-- phase: rootless alongside rootful/      { ph = "rootless"; next }
    /^-- phase: cold boot/                       { ph = "coldboot"; next }

    # The suite is TAP, so count its plan and its failures from the TAP stream
    # rather than from the phase helpers, which use a different vocabulary.
    ph == "" && /^ok [0-9]/                      { okc++ }
    ph == "" && /^not ok [0-9]/                  { nokc++ }
    ph == "" && /^# skip|# SKIP/                 { skipc++ }

    ph != "" && /^pass  /                        { p[ph]++ }
    ph != "" && /^FAIL  /                        { f[ph]++ }
    ph != "" && /^SKIP  /                        { s[ph]++ }

    # A phase that never ran at all -- the suite failed first.
    /extra phases SKIPPED/                       { aborted = 1 }

    END {
        printf "suite=%d/%d", okc + 0, okc + nokc + 0
        if (skipc > 0) printf " (%d skipped)", skipc

        if (aborted) { printf "; phases not run"; print ""; exit }

        n = split("load rootless coldboot", order, " ")
        for (i = 1; i <= n; i++) {
            k = order[i]
            if (s[k] > 0 && p[k] == 0)      printf "; %s=SKIPPED", k
            else if (f[k] > 0)              printf "; %s=%dpass/%dFAIL", k, p[k] + 0, f[k]
            else if (p[k] > 0)              printf "; %s=%d", k, p[k]
            else                            printf "; %s=none", k
        }
        print ""
    }
' "$LOG"
