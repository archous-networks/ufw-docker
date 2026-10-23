#!/usr/bin/env bash
# Is there anything in the tracked tree that should not be published?
#
# This repository is going PUBLIC. A one-time scan before the flip is not
# enough: the thing that puts a real address in a file is pasting real output
# into a doc, and that happens continuously. So this is a GATE, not a checklist
# -- it runs with the other pure-logic gates on every push.
#
# What it actually caught when first written, all of it pasted terminal output
# that nobody intended to commit:
#
#   203.0.113.82   the development host's own public address, hardcoded as
#                   HOSTIP= in an early probe script
#   203.0.113.29    the maintainer's SSH source address, in a sample `status`
#                   transcript -- published as "this address may SSH to us"
#   203.0.113.1        a real routable address used as the "internet" end of a
#                   DNAT diagram, where a documentation range belongs
#
# Use the RFC 5737 documentation ranges for examples: 192.0.2.0/24,
# 198.51.100.0/24, 203.0.113.0/24. They exist precisely so that documentation
# never names someone's real host, and they are unroutable, so a reader who
# copy-pastes cannot accidentally probe a stranger.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
fails=0
# Every tracked file EXCEPT this one.
#
# The scanner necessarily contains the patterns it looks for, so including
# itself makes it match its own credential regex and fail permanently. It
# passed right up until the moment it was committed, because an untracked file
# is not in `git ls-files` -- a self-reference that only appears once the thing
# is real, which is its own small lesson.
#
# The cost is explicit: a secret pasted into THIS file is not caught by this
# file. Nothing else is exempt.
SELF="tests/lint-sanitize.sh"
FILES="$(git ls-files | grep -vxF "$SELF")"
[ -n "$FILES" ] || { echo "not a git checkout, or no tracked files"; exit 0; }

report() {   # report <label> <guidance> <matches...>
    local label="$1" guidance="$2"; shift 2
    [ -n "$1" ] || return 0
    echo "FAIL  $label"
    printf '%s\n' "$1" | sed 's/^/        /'
    echo "      -> $guidance"
    fails=$((fails + 1))
}

# ── public IPv4 ────────────────────────────────────────────────────────────
# Excluded: RFC1918, loopback, link-local, multicast, this-host, broadcast,
# and the three RFC 5737 documentation ranges. Anything else is a real address
# belonging to someone.
#
# The four-octet requirement is what keeps version strings out: `iptables
# 1.8.10` and `docker 18.09.1` have three parts and never match.
hits="$(grep -InoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' $FILES 2>/dev/null \
    | grep -vE ':(10|127|0|255|224|169\.254)\.' \
    | grep -vE ':172\.(1[6-9]|2[0-9]|3[01])\.' \
    | grep -vE ':192\.168\.' \
    | grep -vE ':(192\.0\.2|198\.51\.100|203\.0\.113)\.' \
    | awk -F'[:.]' '$(NF-3) <= 255 && $(NF-2) <= 255 && $(NF-1) <= 255 && $NF <= 255' || true)"
report "a real, routable IPv4 address is committed" \
    "use an RFC 5737 documentation range: 192.0.2.x, 198.51.100.x or 203.0.113.x" "$hits"

# ── global IPv6 ────────────────────────────────────────────────────────────
# fd00::/8 is ULA and 2001:db8::/32 is the documentation range; both are fine.
hits="$(grep -InoE '\b2[0-9a-f]{3}:[0-9a-f]{0,4}:[0-9a-f:]{4,}' $FILES 2>/dev/null \
    | grep -v '2001:db8' || true)"
report "a global IPv6 address is committed" \
    "use the 2001:db8::/32 documentation range, or a fd00::/8 ULA" "$hits"

# ── email addresses ────────────────────────────────────────────────────────
hits="$(grep -InoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' $FILES 2>/dev/null \
    | grep -vE 'users\.noreply\.github\.com|@example\.(com|org|net)' || true)"
report "an email address is committed" \
    "use example.com, or a users.noreply.github.com address" "$hits"

# ── MAC addresses ──────────────────────────────────────────────────────────
hits="$(grep -InoE '\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b' $FILES 2>/dev/null || true)"
report "a MAC address is committed" \
    "use the 00:00:5E:00:53:xx documentation range (RFC 7042)" "$hits"

# ── home directories that name a person ────────────────────────────────────
# /home/unms is allowed: it is where UISP installs itself on EVERY host, so it
# identifies the product, not the operator.
hits="$(grep -InoE '/home/[a-z0-9_-]+|/Users/[a-z0-9_-]+' $FILES 2>/dev/null \
    | grep -vE '/home/(unms|runner|user)\b' || true)"
report "a personal home directory path is committed" \
    "use a placeholder, or /home/user" "$hits"

# ── obvious credential shapes ──────────────────────────────────────────────
hits="$(grep -InE '(aws_secret|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})' $FILES 2>/dev/null || true)"
report "something shaped like a credential is committed" \
    "remove it, rotate it, and rewrite history -- not just the working tree" "$hits"

echo
if [ "$fails" -eq 0 ]; then
    echo "nothing identifying in $(printf '%s\n' "$FILES" | wc -l) tracked files"
else
    echo "$fails category/categories need attention BEFORE this repo is public"
fi
exit $((fails > 0))
