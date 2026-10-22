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
      - DELETE YOUR RULES on ports it drives (brief OUTAGE)
      - add and remove Docker networks and containers

    That fourth one is the one people do not expect. The suite deletes rules
    on every port in TEST_PORTS, so if you have a rule on one of those ports
    your service is unreachable for the length of the run. The ports are
    chosen so nothing real listens on them -- that was not always true, and
    on this project's own UISP host it took the device endpoint down -- but
    check tests/rules-lib.bash against what you run before you believe it.
    Your state is snapshotted and restored at the end either way.

    On a box somebody depends on, that is an outage and a transient hole.
    Everything is restored afterwards: \`$REPO/ufw-docker rescue\` runs on ANY
    exit including Ctrl-C, and /etc/ufw plus ufw's enabled state are snapshotted
    before the run and put back after it, with a diff printed if anything does
    not match. But "it recovers" is not a reason to run it somewhere it should
    never have run.

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

# ── LEAVE THE HOST EXACTLY AS IT WAS ───────────────────────────────────────
# `rescue` guarantees a WORKING firewall. It does not guarantee THIS host's
# firewall. Those are different promises, and only the first was being kept.
#
# What the suite legitimately changes and never put back:
#
#   - ufw-docker's install state. teardown_file ends in `remove --force`, so a
#     host that HAD the stanza installed was handed back without it. That is
#     how the development host was found unwired.
#   - rules on any port in TEST_PORTS. Those ports are now chosen so nothing
#     real listens on them, but they were not always: the suite used to drive
#     8089 and 443, which unms-nginx publishes, and deleted the operator's
#     rules for both. Port choice is a judgement that can be got wrong again,
#     so the restore does not assume it was got right.
#   - ufw's enabled/disabled state, and any files the suite left in /etc/ufw.
#
# The bats-level check (`rules-before` / teardown_file) only ever REPORTED this
# drift, and only for user rules. Reporting is not restoring. This snapshots
# the whole of /etc/ufw plus the enabled flag, puts it all back, and then
# proves it by comparing a fingerprint taken before and after.
#
# This runs in CI too, deliberately. Making it local-only would leave the
# restore path untested by the one thing that runs on every push -- and a
# behaviour that differs between CI and the development host is exactly the
# shape of bug that cost this project two cancelled runs. Set
# UFW_DOCKER_NO_RESTORE=1 to skip it.
SNAP=""

fingerprint() {
    # Declared state AND live state. Neither alone is enough: user.rules can be
    # correct while the chains are not, which is the whole failure mode
    # `rescue` exists for. No packet counters appear in any of this, so a
    # fingerprint is stable across a run that merely passed traffic.
    ufw status verbose 2>/dev/null
    echo "--- DOCKER-USER (v4)"; iptables  -S DOCKER-USER 2>/dev/null
    echo "--- DOCKER-USER (v6)"; ip6tables -S DOCKER-USER 2>/dev/null
    echo "--- /etc/ufw"
    ( cd /etc/ufw && sha256sum user.rules user6.rules after.rules after6.rules \
        before.rules before6.rules before.init ufw.conf 2>/dev/null )
}

snapshot_state() {
    [ -z "${UFW_DOCKER_NO_RESTORE:-}" ] || { echo "state restore DISABLED (UFW_DOCKER_NO_RESTORE)"; return 0; }
    SNAP=$(mktemp -d /var/tmp/ufw-docker-pre-suite.XXXXXXXX) || { SNAP=""; return 0; }
    tar -C /etc/ufw -cf "$SNAP/etc-ufw.tar" . 2>/dev/null
    ( cd /etc/ufw && find . -type f | sort ) > "$SNAP/manifest"
    ufw status 2>/dev/null | head -1 > "$SNAP/enabled"
    fingerprint > "$SNAP/fingerprint"
    echo "pre-suite state snapshotted to $SNAP"
}

restore_state() {
    [ -n "$SNAP" ] || return 0
    # Files first. Extracting over the top restores everything that existed;
    # the manifest comparison then deletes what the suite ADDED (its
    # .ufw-docker-bak-* copies), which "the same as before" also requires.
    tar -C /etc/ufw -xf "$SNAP/etc-ufw.tar" 2>/dev/null
    ( cd /etc/ufw && find . -type f | sort ) > "$SNAP/manifest-now"
    comm -13 "$SNAP/manifest" "$SNAP/manifest-now" | while IFS= read -r f; do
        [ -n "$f" ] && rm -f "/etc/ufw/$f"
    done
    # Then the live chains, rebuilt FROM the restored files. A full
    # disable/enable rather than `reload` because the suite may have left ufw
    # disabled, and because enable is what replays after.rules -- which is what
    # re-wires DOCKER-USER when the stanza was part of the original state.
    if grep -qi 'active' "$SNAP/enabled"; then
        ufw --force disable >/dev/null 2>&1
        ufw --force enable  >/dev/null 2>&1
    else
        ufw --force disable >/dev/null 2>&1
    fi
}

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

    # AFTER rescue, not before: rescue deliberately strips the DOCKER-UFW
    # stanza as part of returning to a known-good baseline, so restoring first
    # would simply have it removed again.
    if [ -n "$SNAP" ]; then
        echo "    [$(date -u +%H:%M:%S)] restoring this host's pre-suite state"
        restore_state
        fingerprint > "$SNAP/fingerprint-after"
        if diff -u "$SNAP/fingerprint" "$SNAP/fingerprint-after" > "$SNAP/drift" 2>&1; then
            echo "    host state matches the pre-suite snapshot"
            rm -rf "$SNAP"
        else
            {
                echo "    !!! THIS HOST WAS NOT RETURNED TO ITS PRE-SUITE STATE"
                echo "    The suite changed something the restore does not cover."
                echo "    Diff (- before, + now):"
                sed 's/^/      /' "$SNAP/drift"
                echo "    Snapshot KEPT for recovery: $SNAP"
                echo "    To put the files back by hand:"
                echo "        sudo tar -C /etc/ufw -xf $SNAP/etc-ufw.tar"
                echo "        sudo ufw --force disable && sudo ufw --force enable"
            } >&2
            rc=1
        fi
        echo "    [$(date -u +%H:%M:%S)] restore finished"
    fi

    rmdir "$LOCK" 2>/dev/null
    exit $rc
}
trap cleanup EXIT INT TERM

snapshot_state

bats "$@" "$HERE/ufw-docker.bats"
