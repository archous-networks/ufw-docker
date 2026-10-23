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

# And the reverse: a label documented AS A MATRIX ROW that the tool does not
# know about.
#
# Scoped to the `## The matrix` section, not the whole page. An earlier version
# grepped the entire file for `(dev|site|ci)-[a-z0-9]+`, which (a) could not
# see a label containing a second hyphen and (b) would flag any host named
# anywhere on the page -- so the page could not carry a fleet inventory beside
# the matrix without the lint calling every host a missing row. The matrix and
# "machines we happen to have seen" are different claims and the page says so;
# the lint has to agree.
# The leading backtick is required, not cosmetic: it is what distinguishes a
# data row from the `| label | distro | ... |` HEADER, which otherwise comes
# back as a label named "label".
doc_matrix_labels() {
    awk '/^## The matrix/{f=1; next} /^## /{f=0} f' "$DOC" \
        | awk -F'|' '/^\| *`/ {gsub(/[ `]/, "", $2); if ($2 ~ /^[a-z][a-z0-9-]+$/) print $2}'
}

n_doc=0
while read -r lbl; do
    [ -n "$lbl" ] || continue
    n_doc=$((n_doc+1))
    rows | grep -q -- "$lbl" || {
        echo "### IN THE DOCS BUT NOT IN THE MATRIX: $lbl"
        echo "    the preflight will never match it; remove it or add the row"
        rc=1
    }
done < <(doc_matrix_labels | sort -u)

# A section heading that got renamed would silently disable the check above.
[ "$n_doc" -gt 0 ] || {
    echo "### NO ROWS FOUND under '## The matrix' in $DOC"
    echo "    the reverse check is doing nothing; did the heading change?"
    rc=1
}

if [ "$rc" -eq 0 ]; then
    echo "ok  platform matrix and docs/supported.md agree ($n rows)"
else
    echo
    echo "The matrix is the heredoc in ufw-docker (supported_matrix)."
    echo "'ufw-docker platforms' prints it as the tool sees it."
fi
exit $rc
