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

# ── THE MARKER ─────────────────────────────────────────────────────────────
# A deliberate per-HOST opt-in, not a per-command one.
#
# The realistic accident is not a user: deployments download the single
# `ufw-docker` file and never see this directory. It is one of US, running a
# command we have run a hundred times, in the wrong SSH session.
#
# An environment variable would not help with that -- it travels in shell
# history and in muscle memory, which is precisely the failure. A file does
# not travel. It is a property of the machine, so the box itself decides.
#
# Note it is NOT a heuristic like "does this look like production". This tool
# is FOR production Docker hosts, and the development host is a full UISP
# stack on purpose -- that is why the container-recreate test runs here and
# skips in CI. Any heuristic smart enough to refuse a customer's box would
# refuse the most valuable test environment there is.
MARKER=/etc/ufw-docker-tests-allowed
if [ ! -e "$MARKER" ]; then
    cat >&2 <<EOF

  REFUSING TO RUN -- this host is not marked as safe to disrupt.

  WHY
    These tests do not simulate a firewall, they rewrite THIS host's one.
    Over a full run they will:

      - restart the Docker daemon            (every container bounces)
      - flush and rebuild ufw's chains       (brief loss of filtering)
      - open and close ports on this host    (brief exposure)
      - add and remove Docker networks and containers

    On a box somebody depends on, that is an outage and a transient hole.
    Everything is restored afterwards and \`$REPO/ufw-docker rescue\` runs on
    ANY exit, including Ctrl-C -- but "it recovers" is not a reason to run it
    somewhere it should never have run.

    The tool itself is a different matter and is meant for production hosts.
    This restriction is on the TEST SUITE only.

  HOW TO ALLOW IT, if this host is genuinely yours to disrupt
    sudo touch $MARKER

  HOW TO UNDO THAT
    sudo rm $MARKER

  CI creates this marker as a step, because its runners are disposable.
  If you are reading this on a customer's machine, the answer is no.

EOF
    exit 1
fi

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
