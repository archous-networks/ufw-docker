#!/usr/bin/env bash
#
# Catch a function that is CALLED but never DEFINED.
#
# Shell does not notice until that line runs, so a rewrite can silently drop a
# helper and everything still parses. This happened: `require_docker` and
# `require_readable` disappeared during a refactor, so `status` quietly stopped
# checking Docker access and a non-docker-group user got the old misleading
# error back. It surfaced weeks later, by accident, while adding an unrelated
# subcommand. `bash -n` and shellcheck both pass on that code.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
FILE=${1:-ufw-docker}
rc=0

defined=$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$FILE" | tr -d '()' | sort -u)

# Words in a command position that look like our own helpers. Restricted to the
# project's naming conventions so this does not have to know every binary.
called=$(grep -oE '(^|[;&|(]|then |else |do |\|\| |&& )[[:space:]]*(cmd_[a-z_]+|require_[a-z_]+|install_[a-z_]+|remove_[a-z_]+|container_rows|stanza_subnets|strip_stanza|prune_backups|subnets|stanza|version_ge|say|ok|bad|warn|head_|die)\b' "$FILE" \
    | grep -oE '[a-z_][a-z0-9_]*$' | sort -u)

for fn in $called; do
    grep -qx "$fn" <<< "$defined" || { echo "CALLED BUT NOT DEFINED: $fn" >&2; rc=1; }
done

# Every subcommand the dispatcher offers must exist.
for sub in $(sed -n '/^case "${1:-}" in/,/^esac/p' "$FILE" \
             | grep -oE 'cmd_[a-z_]+' | sort -u); do
    grep -qx "$sub" <<< "$defined" || { echo "DISPATCHER CALLS MISSING: $sub" >&2; rc=1; }
done

# Every subcommand listed in the usage text must be dispatchable.
for doc in $(sed -n '2,30p' "$FILE" | grep -oE '^#   ufw-docker [a-z]+' | awk '{print $3}' | sort -u); do
    grep -qE "^    ${doc}[)|]" "$FILE" || { echo "DOCUMENTED BUT NOT DISPATCHED: $doc" >&2; rc=1; }
done

[ "$rc" -eq 0 ] && echo "ok  $FILE: all called functions defined, dispatcher and usage agree"
exit $rc
