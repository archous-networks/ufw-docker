#!/usr/bin/env bash
#
# The platform matrix lives in `ufw-docker` because the preflight must read it
# on a host that has only ever downloaded that one file. Humans, though, read
# docs/supported.md -- so there are two copies, and two copies drift.
#
# This fails the build when they disagree. It is the same discipline as
# lint-functions.sh: a documentation claim that has quietly stopped being true
# is worse than no claim, because people act on it.
#
# It does NOT need root, Docker or a firewall -- it is pure text, so it runs in
# the fast CI job next to shellcheck.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
TOOL="$REPO/ufw-docker"
DOC="$REPO/docs/supported.md"
rc=0

rows() { awk "/cat <<'MATRIX'/{f=1;next} /^MATRIX\$/{f=0} f" "$TOOL"; }

[ -f "$DOC" ] || { echo "MISSING: $DOC"; exit 1; }

n=0
# shellcheck disable=SC2034  # ufw/docker/by are read for field order, not used
while IFS='|' read -r label distro ver ufw backend docker by status; do
    label="$(echo "$label" | xargs)"; status="$(echo "$status" | xargs)"
    distro="$(echo "$distro" | xargs)"; ver="$(echo "$ver" | xargs)"
    backend="$(echo "$backend" | xargs)"
    [ -n "$label" ] || continue
    n=$((n+1))
    if ! grep -q -- "$label" "$DOC"; then
        echo "### IN THE MATRIX BUT NOT IN THE DOCS: $label"
        echo "    add a row for it to docs/supported.md"
        rc=1; continue
    fi
    # The status must match too. A row quietly promoted from unverified to
    # supported in one place and not the other is the dangerous case: the docs
    # would tell an operator we support something nothing has proven.
    line="$(grep -- "$label" "$DOC" | head -1)"
    case "$line" in
        *"$status"*) ;;
        *) echo "### STATUS DISAGREES for $label"
           echo "    ufw-docker says: $status"
           echo "    docs say:        $line"
           rc=1 ;;
    esac
    for f in "$distro" "$ver" "$backend"; do
        case "$line" in *"$f"*) ;; *)
            echo "### FIELD MISSING from the docs row for $label: '$f'"
            echo "    $line"; rc=1 ;;
        esac
    done
done < <(rows)

[ "$n" -gt 0 ] || { echo "### NO MATRIX ROWS FOUND — did the heredoc marker change?"; rc=1; }

# And the reverse: a label documented that the tool does not know about.
while read -r lbl; do
    [ -n "$lbl" ] || continue
    rows | grep -q -- "$lbl" || {
        echo "### IN THE DOCS BUT NOT IN THE MATRIX: $lbl"
        echo "    the preflight will never match it; remove it or add the row"
        rc=1
    }
done < <(grep -oE '\b(dev|site|ci)-[a-z0-9]+\b' "$DOC" | sort -u)

if [ "$rc" -eq 0 ]; then
    echo "ok  platform matrix and docs/supported.md agree ($n rows)"
else
    echo
    echo "The matrix is the heredoc in ufw-docker (supported_matrix)."
    echo "'ufw-docker platforms' prints it as the tool sees it."
fi
exit $rc
