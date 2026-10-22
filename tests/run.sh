#!/usr/bin/env bash
#
# Run the test suite safely. Use this rather than calling bats directly.
#
#   sudo HOST_IP=<this host's address> tests/run.sh [bats args...]
#
# ── WHY A WRAPPER ──────────────────────────────────────────────────────────
# These tests mutate GLOBAL system state: ufw's chains, /etc/ufw/*.rules, and
# Docker's DOCKER-USER chain. Two consequences, both learned the hard way:
#
#  1. NOTHING ELSE MAY TOUCH THE FIREWALL WHILE THEY RUN. During development a
#     manual `ufw-docker install` was run against a host where a suite was still
#     going; the suite's teardown stripped the stanza underneath it, and the
#     result looked exactly like a reproducible `disable`/`enable` bug that did
#     not exist. A second suite was then started alongside the first. The lock
#     below makes that impossible rather than merely discouraged.
#
#  2. KILLING THE RUN LEAVES A BROKEN FIREWALL. bats' teardown_file never fires
#     on SIGINT/SIGTERM, so ufw is left half-built -- no SSH rule, chains
#     missing. The trap below runs `rescue` on ANY exit, including Ctrl-C.
#
# Neither is theoretical; both happened on the development host.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
LOCK=/var/lock/ufw-docker-tests

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
: "${HOST_IP:?set HOST_IP to the primary address of this host}"

if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another ufw-docker test run holds $LOCK" >&2
    echo "wait for it, or remove the directory if it is stale" >&2
    exit 1
fi

cleanup() {
    local rc=$?
    echo
    echo "--- restoring the firewall (runs on any exit, including Ctrl-C) ---"
    # Timestamped: when this phase stalls, the log should say so plainly rather
    # than simply stopping. A healthy firewall rescues in seconds; a broken one
    # takes the full teardown-and-rebuild path, which is where the time goes.
    echo "    [$(date -u +%H:%M:%S)] rescue starting"
    # BOUNDED. A CI run once failed late and then sat in this teardown for 13
    # minutes until the job timeout cancelled it -- which threw away the
    # post-failure diagnostics that would have explained the failure. A rescue
    # that cannot finish in 3 minutes is itself the thing to report.
    if ! timeout 180 "$REPO/ufw-docker" rescue 2>&1 | sed 's/^/    /'; then
        echo "    !!! rescue did not finish in 180s -- firewall state below" >&2
        timeout 20 ufw status verbose 2>&1 | sed 's/^/    /' >&2 || true
        timeout 20 iptables -S ufw-user-input 2>&1 | sed 's/^/    /' >&2 || true
    fi
    echo "    [$(date -u +%H:%M:%S)] rescue finished"
    rmdir "$LOCK" 2>/dev/null
    exit $rc
}
trap cleanup EXIT INT TERM

bats "$@" "$HERE/ufw-docker.bats"
