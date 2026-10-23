#!/usr/bin/env bash
# Does `ufw_ipv6_enabled` read ufw's own IPv6 switch correctly?
#
# Why a selftest and not a bats test: the interesting cases are the MALFORMED
# ones -- a commented-out IPV6 line, a quoted value, trailing whitespace, an
# unreadable file. Reproducing those on a live host means editing
# /etc/default/ufw and running `ufw reload` per case, which is slow, needs
# root, and leaves the firewall in whatever state the last case set. As pure
# text against temp files it is instant and the host is never touched.
#
# The direction of the default is the point. An unreadable or absent file
# reports ENABLED, because that is ufw's own default -- and because the
# failure we must never produce is a false all-clear about IPv6. Reporting
# "enabled" keeps the v6 checks live; reporting "disabled" would silence them.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck disable=SC1090
source <(sed -n '/^ufw_ipv6_enabled() {/,/^}/p' "$REPO/ufw-docker")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

# check <expected: yes|no> <label> <file contents...>
check() {
    local want="$1" label="$2"; shift 2
    UFW_DEFAULTS="$TMP/ufw"
    printf '%s\n' "$@" > "$UFW_DEFAULTS"
    local got=no
    ufw_ipv6_enabled && got=yes
    if [ "$got" = "$want" ]; then
        printf 'ok    %-46s -> %s\n' "$label" "$got"
    else
        printf 'FAIL  %-46s -> %s (wanted %s)\n' "$label" "$got" "$want"
        fails=$((fails + 1))
    fi
}

check yes "IPV6=yes"                       'IPV6=yes'
check no  "IPV6=no"                        'IPV6=no'
check no  "IPV6=NO (ufw does not care about case)" 'IPV6=NO'
check no  'IPV6="no" (quoted, as shipped)' 'IPV6="no"'
check no  "IPV6=no with trailing space"    'IPV6=no '
check no  "IPV6 = no with spaces"          'IPV6 = no'
check yes "# IPV6=no commented out"        '# IPV6=no'
check yes "IPV6=no only inside a comment"  'ENABLED=yes' '# note: IPV6=no was tried once'
check yes "IPV6NOTREALLY=no"               'IPV6NOTREALLY=no'
check yes "no IPV6 line at all"            'ENABLED=yes' 'LOGLEVEL=low'
check yes "a real /etc/default/ufw shape"  'IPV6=yes' 'DEFAULT_INPUT_POLICY="DROP"'

# The two cases that are not a file's contents.
UFW_DEFAULTS="$TMP/does-not-exist"
if ufw_ipv6_enabled; then
    printf 'ok    %-46s -> yes\n' "absent file defaults to ENABLED"
else
    printf 'FAIL  %-46s -> no (wanted yes)\n' "absent file defaults to ENABLED"
    fails=$((fails + 1))
fi

UFW_DEFAULTS="$TMP/unreadable"
printf 'IPV6=no\n' > "$UFW_DEFAULTS"
chmod 000 "$UFW_DEFAULTS"
# Running as root makes mode 000 readable anyway, so this case only proves
# anything unprivileged. Skip rather than pass vacuously.
if [ "$(id -u)" -eq 0 ]; then
    printf 'skip  %-46s (root reads mode 000 regardless)\n' "unreadable file defaults to ENABLED"
elif ufw_ipv6_enabled; then
    printf 'ok    %-46s -> yes\n' "unreadable file defaults to ENABLED"
else
    printf 'FAIL  %-46s -> no (wanted yes)\n' "unreadable file defaults to ENABLED"
    fails=$((fails + 1))
fi
chmod 644 "$UFW_DEFAULTS"

echo
if [ "$fails" -eq 0 ]; then echo "all ufw IPv6-switch cases classified correctly"; else echo "$fails case(s) wrong"; fi
exit $((fails > 0))
