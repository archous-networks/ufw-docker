#!/usr/bin/env bash
#
# VERSION, the git tag, and the version the stanza records must all agree.
#
# They are three copies of one fact. The stanza's copy is the one that matters
# operationally -- `status` reads it to tell an operator which version wired
# their host, and warns on a mismatch -- so a release whose binary says 0.9.0
# while the tag says v1.0.0 makes that warning lie in both directions.
#
# Pure text: no root, no Docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
TOOL="$REPO/ufw-docker"
rc=0

V="$(grep -oE '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$TOOL" | head -1 | cut -d'"' -f2)"
if [ -z "$V" ]; then
    echo "### NO WELL-FORMED VERSION in ufw-docker"
    echo "    expected a line like: VERSION=\"1.2.3\""
    exit 1
fi
echo "ufw-docker VERSION = $V"

# The tag, when there is one. Locally there usually is not, and that is fine --
# this half only gates a release.
TAG="${1:-${GITHUB_REF_NAME:-}}"
if [ -n "$TAG" ] && [ "${TAG#v}" != "$TAG" ]; then
    if [ "${TAG#v}" != "$V" ]; then
        echo "### TAG AND VERSION DISAGREE"
        echo "    tag:              $TAG  (implies ${TAG#v})"
        echo "    ufw-docker says:  $V"
        echo "    Bump VERSION in ufw-docker, or tag the version that is in it."
        rc=1
    else
        echo "ok  tag $TAG matches VERSION"
    fi
else
    echo "    (no vX.Y.Z tag in context — skipping the tag comparison)"
fi

# The stanza must carry the same version, since `status` reads it back.
if ! grep -q 'Managed by ufw-docker \$VERSION' "$TOOL"; then
    echo "### THE STANZA NO LONGER RECORDS \$VERSION"
    echo "    'status' reads that line to report which version wired a host,"
    echo "    and to warn when the binary has since been replaced."
    rc=1
else
    echo "ok  the stanza records \$VERSION"
fi

[ "$rc" -eq 0 ] && echo "ok  version metadata is consistent"
exit $rc
