#!/usr/bin/env bash
# tests/render-matrix.sh <results-dir> <README.md>
#
# Build the test-status table in README.md from the per-job result files CI
# collects, replacing whatever is between the two markers.
#
# WHY THE CELLS ARE TEXT AND NOT BADGE IMAGES
# -------------------------------------------
# Not because badges are unavailable -- a single workflow badge sits at the top
# of the README and works fine. Because a badge carries ONE BIT, and one bit is
# the thing that already failed us.
#
# Two consecutive CI runs were fully green while the rootless phase skipped on
# all ten legs. The run said "success" and the feature had zero coverage. A
# green tick cannot distinguish `rootless=7` from `rootless=SKIPPED`, and it
# cannot carry the kernel column either -- which is the one axis these legs
# cannot vary and therefore the one most worth printing.
#
# Two smaller reasons that also survive the repo going public:
#   - README images are proxied and CACHED by GitHub's camo. A status badge can
#     show a stale state; committed text cannot.
#   - Text diffs. `git log -p -- README.md` is a history of when each leg
#     started failing, which an <img> tag is not.
#
# RESULT FILE FORMAT -- one TSV line per job:
#   group<TAB>col1<TAB>col2<TAB>runner<TAB>kernel<TAB>status<TAB>notes
#
# group is one of: lint native distro coverage
# status is one of: pass fail skip
set -uo pipefail

DIR="${1:?usage: render-matrix.sh <results-dir> <README.md>}"
README="${2:?usage: render-matrix.sh <results-dir> <README.md>}"

BEGIN='<!-- BEGIN TEST MATRIX -->'
END='<!-- END TEST MATRIX -->'

grep -qF "$BEGIN" "$README" || { echo "no $BEGIN marker in $README" >&2; exit 1; }
grep -qF "$END"   "$README" || { echo "no $END marker in $README" >&2; exit 1; }

# Gather every result line. `find`, not a glob: artifacts land in one
# subdirectory per job.
# Both declared before the trap: under `set -u` a trap firing between the
# mktemp and the later assignment would die on an unbound $BODY.
ALL=""; BODY=""
trap 'rm -f "$ALL" "$BODY"' EXIT
ALL="$(mktemp)"
find "$DIR" -name '*.tsv' -type f -exec cat {} + 2>/dev/null | grep -v '^$' | sort > "$ALL"

# REFUSE on an empty collection rather than rendering an empty table. A
# failed artifact download would otherwise silently blank the matrix, and a
# README that says nothing reads as "nothing is tested" -- strictly worse than
# a table that is one run stale. Keeping the last known-good block is the safe
# direction when the inputs are missing.
if [ ! -s "$ALL" ]; then
    echo "no result rows under $DIR -- leaving the existing table alone" >&2
    exit 0
fi
echo "collected $(wc -l < "$ALL") result rows" >&2

# Refuse a table that is missing a whole SECTION.
#
# This is not hypothetical. On the first real run every distro leg uploaded
# nothing -- an artifact name may not contain a colon and every base has one
# -- so the table published with its ten distro rows simply absent. The page
# looked healthy and said this tool is tested on the native runner only. A
# silently truncated status table is worse than a stale one, and worse than
# no table at all, because it is confidently wrong in the safe-looking
# direction.
#
# The empty-collection guard above did not catch it: there were plenty of
# rows, just none of the ones that matter most. So check per GROUP.
missing=""
for g in ${MATRIX_EXPECT_GROUPS:-lint native distro}; do
    awk -F'\t' -v g="$g" '$1 == g { found = 1 } END { exit !found }' "$ALL" \
        || missing="$missing $g"
done
if [ -n "$missing" ]; then
    echo "REFUSING to write the table: no rows at all for:$missing" >&2
    echo "  Those jobs did not upload a result. The existing table is left in" >&2
    echo "  place -- stale, but complete and therefore not misleading." >&2
    exit 1
fi

# A signature over the RESULT ROWS ONLY -- not the header, which carries a
# timestamp and a run link and therefore differs on every single run.
#
# Without this the table would produce a bot commit on `main` after every
# push, whether or not anything changed. With it, the commit happens when a
# result actually moves, so the file's history is a log of status CHANGES
# rather than a log of CI having run.
SIG="$(sha256sum < "$ALL" | awk '{print $1}')"
SIGLINE="<!-- matrix-signature: $SIG -->"
if grep -qF "$SIGLINE" "$README"; then
    echo "results identical to the table already in $README; leaving it alone"
    exit 0
fi

# Render one group's rows as markdown table rows.
#
# awk, NOT `while IFS=$'\t' read`. Tab is an IFS *whitespace* character, so
# bash collapses runs of it and an empty field silently shifts every column
# after it -- which it duly did, printing the notes where the status belongs.
# awk -F'\t' keeps empty fields empty.
#
# $1 group  $2 col1  $3 col2  $4 runner  $5 kernel  $6 status  $7 notes
rows_for() {
    awk -F'\t' -v g="$1" -v layout="$2" '
        function icon(s) {
            if (s == "pass") return "✅ pass"
            if (s == "fail") return "❌ **fail**"
            if (s == "skip") return "⏭️ skip"
            return "❔ " s
        }
        function dash(v) { return (v == "" || v == "-") ? "—" : v }
        $1 != g { next }
        layout == "matrix" {
            printf "| `%s` | %s | `%s` | `%s` | %s | %s |\n", $2, dash($3), $4, dash($5), icon($6), dash($7)
        }
        layout == "plain" {
            printf "| %s | %s | %s |\n", $2, icon($6), dash($7)
        }
    ' "$ALL"
}

# Is there anything in this group at all?
has() { awk -F'\t' -v g="$1" '$1 == g { found = 1 } END { exit !found }' "$ALL"; }

BODY="$(mktemp)"
{
    printf '%s\n' "$BEGIN"
    echo
    echo "<!-- GENERATED by tests/render-matrix.sh from CI results. Do not edit by hand. -->"
    printf '%s\n' "$SIGLINE"
    echo

    run_line=""
    [ -n "${GITHUB_RUN_ID:-}" ] && run_line=" · [run ${GITHUB_RUN_NUMBER:-?}](https://github.com/${GITHUB_REPOSITORY:-archous-networks/ufw-docker}/actions/runs/${GITHUB_RUN_ID})"
    echo "Every combination below runs on **every push**. Last updated $(date -u '+%Y-%m-%d %H:%M UTC')${run_line}, commit \`$(printf '%.7s' "${GITHUB_SHA:-unknown}")\`."
    echo

    # ── the distro legs ────────────────────────────────────────────────────
    if has distro; then
        echo '#### Distribution legs — each distro'"'"'s real userspace, in a systemd container'
        echo
        echo '| base | iptables | runner | kernel | result | suite and phases |'
        echo '|---|---|---|---|---|---|'
        rows_for distro matrix
        echo
    fi

    # ── the native suite ───────────────────────────────────────────────────
    if has native; then
        echo '#### Native runner — the same suite, plus the IPv6 legs'
        echo
        echo '| Docker IPv6 | iptables | runner | kernel | result | detail |'
        echo '|---|---|---|---|---|---|'
        rows_for native matrix
        echo
    fi

    # ── lint and coverage ──────────────────────────────────────────────────
    if has lint || has coverage; then
        echo '#### Static analysis and coverage'
        echo
        echo '| check | result | detail |'
        echo '|---|---|---|'
        rows_for lint plain
        rows_for coverage plain
        echo
    fi

    cat <<'NOTE'
> **The kernel column is the honest part of this table.** A container shares the
> host's kernel — `debian:10` above is buster's userspace (iptables 1.8.2, its own
> Docker and systemd) on the runner's kernel, not on buster's 4.19. The legs are
> split deliberately across two runner images so more than one kernel is
> represented, but every kernel here is a modern one.
> → [testing.md](docs/testing.md#what-a-leg-does-not-cover)
NOTE
    printf '%s\n' "$END"
} > "$BODY"

# Splice: everything before BEGIN, the new body, everything after END.
OUT="$(mktemp)"
awk -v b="$BEGIN" -v e="$END" -v body="$BODY" '
    index($0, b) == 1 { inblock = 1; while ((getline l < body) > 0) print l; close(body); next }
    index($0, e) == 1 { inblock = 0; next }
    !inblock { print }
' "$README" > "$OUT"

if cmp -s "$OUT" "$README"; then
    echo "README test matrix unchanged"
    rm -f "$OUT"
    exit 0
fi
mv "$OUT" "$README"
echo "README test matrix updated"
