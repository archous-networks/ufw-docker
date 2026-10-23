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

# ANSI is stripped FIRST. The phase headers come from container-leg.sh's
# say(), which prints '\033[1m== phase: ...\033[0m' -- `==`, bold, not the
# `--` that leg-rootless.sh's own say() uses. Matching only `^-- phase:`
# found nothing, so every leg row lost its phase counts.
#
# That is the second time the same mistake has been made in this file's
# lifetime, and the first fix HID it: suppressing "load=none" noise on the
# native job (which genuinely has no phases) also suppressed the evidence
# that detection was broken on the legs, which do. A cosmetic fix that
# makes a real failure look tidy is worse than the noise it removed.
#
# Both markers are accepted now, so either say() works.
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | awk '
    /^(--|==) phase: correctness under load/     { ph = "load";     sawphase = 1; next }
    /^(--|==) phase: rootless alongside rootful/ { ph = "rootless"; sawphase = 1; next }
    /^(--|==) phase: cold boot/                  { ph = "coldboot"; sawphase = 1; next }

    # The suite is TAP, so count its plan and its failures from the TAP stream
    # rather than from the phase helpers, which use a different vocabulary.
    ph == "" && /^ok [0-9]/                      { okc++ }
    ph == "" && /^not ok [0-9]/                  { nokc++ }
    # A TAP skip is `ok 38 <name> # skip <reason>` -- the directive is at the
    # END of the ok line, not the start of a line of its own. The rule here
    # used to be /^# skip/, which TAP never emits, so skipc was ALWAYS zero
    # and every row read "suite=63/63" for a run that passed 60 and skipped 3.
    #
    # That is this file being caught by the thing it was written to catch: the
    # header above complains that a tick cannot distinguish "7 assertions
    # passed" from "skipped entirely", and the summary meant to fix that was
    # doing the same thing one level down. TAP counts a skip as ok, so the
    # total stays 63 and the skipped count is reported beside it.
    ph == "" && /^ok [0-9]+.*# *[Ss][Kk][Ii][Pp]/ { skipc++ }

    ph != "" && /^pass  /                        { p[ph]++ }
    ph != "" && /^FAIL  /                        { f[ph]++ }
    ph != "" && /^SKIP  /                        { s[ph]++ }

    # A phase that never ran at all -- the suite failed first.
    /extra phases SKIPPED/                       { aborted = 1 }

    END {
        printf "suite=%d/%d", okc + 0, okc + nokc + 0
        if (skipc > 0) printf " (%d skipped)", skipc

        if (aborted) { printf "; phases not run"; print ""; exit }

        # The NATIVE job runs this too, and it has no phases at all -- so
        # without this every native row read "load=none; rootless=none;
        # coldboot=none", which looks like three failures rather than three
        # things that were never part of that job.
        if (!sawphase) { print ""; exit }

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
'
