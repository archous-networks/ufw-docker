#!/usr/bin/env bash
#
# B1: does the self-heal unit actually repair the firewall at a REAL cold boot?
#
# Everything else about that unit is verified: systemd drives it against a
# genuinely broken firewall, it repairs it, it restores a RESTRICTED SSH rule
# rather than a blanket one, it logs what it did, and it leaves a healthy
# firewall alone. Its enablement and its After=/Wants= ordering are asserted
# declaratively.
#
# All of that happens on a RUNNING host. The one thing left is the boot race
# itself -- ufw, docker and this unit coming up in the right order on a cold
# start -- and the only honest way to test a boot race is to boot.
#
# So this is deliberately NOT part of the suite. It is two commands with a
# reboot between them, run when the operator decides the host can take it.
#
#   sudo tests/cold-boot-check.sh arm      # break it, on purpose
#   sudo reboot
#   sudo tests/cold-boot-check.sh verify   # did the unit put it back?
#
# HOW THIS BREAKS THINGS, AND WHY THE OBVIOUS WAY DOES NOT WORK
#
# The first version simply emptied DOCKER-USER and rebooted. That proves
# nothing: DOCKER-USER is RUNTIME state, not configuration. At boot ufw starts
# and applies after.rules, which contains our stanza and rewires the chain --
# so by the time the self-heal unit runs, the ordinary boot path has already
# repaired it. The unit logged "ufw healthy at boot" and the test reported
# PASS, having exercised nothing. A test that passes for the wrong reason.
#
# The condition the unit actually exists for is: ufw applies the stanza, and
# then something flushes DOCKER-USER AFTERWARDS -- which is what a Docker
# daemon starting after ufw does. So this installs a one-shot saboteur unit
# ordered After=docker.service and Before=ufw-docker-selfheal.service, which
# recreates exactly that ordering on the next boot.
set -uo pipefail

MARK=/var/lib/ufw-docker-coldboot-test
SABOTEUR=/etc/systemd/system/ufw-docker-coldboot-saboteur.service
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

case "${1:-}" in
arm)
    # WHAT THIS COSTS, said plainly before it happens.
    #
    # Emptying DOCKER-USER does not lock anybody out -- SSH arrives on INPUT,
    # which this does not touch. What it does is leave Docker-published ports
    # UNFILTERED from now until the unit repairs them after the reboot. On a
    # host with containers facing the internet that is a real, if brief,
    # exposure window, and it lasts until you actually reboot.
    cat <<EOF

  This will:
    - install a one-shot systemd unit that, ON THE NEXT BOOT ONLY, empties
      DOCKER-USER after ufw has applied the stanza
    - leave your firewall COMPLETELY UNCHANGED right now
    - NOT affect SSH at any point (that is INPUT, untouched)

  On the next boot your Docker-published ports are unfiltered for the few
  seconds between the saboteur running and the self-heal unit repairing it.
  If the unit does NOT repair it, they stay unfiltered until you run
  'ufw-docker install' -- which is the finding this test exists to get.

  To cancel before rebooting:
      sudo $0 disarm

EOF
    printf '  type "break it" to continue: '
    read -r reply
    [ "$reply" = "break it" ] || { echo "  aborted; nothing changed"; exit 1; }

    systemctl is-enabled ufw-docker-selfheal.service >/dev/null 2>&1 \
        || { echo "!! the self-heal unit is not enabled; nothing would repair this" >&2
             echo "   run: sudo $REPO/ufw-docker install" >&2; exit 1; }

    {
        echo "armed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "boot_before=$(cat /proc/sys/kernel/random/boot_id)"
        echo "jumps_before=$(iptables -S DOCKER-USER 2>/dev/null | grep -c 'ufw-user-input')"
    } > "$MARK"

    # The saboteur: empty DOCKER-USER AFTER ufw has applied the stanza, which
    # is the ordering a Docker daemon starting after ufw produces. Emptying it
    # now instead would be undone by the reboot itself.
    cat > "$SABOTEUR" <<'UNIT'
[Unit]
Description=TEST ONLY - empty DOCKER-USER after ufw, to exercise ufw-docker-selfheal
After=ufw.service docker.service
Before=ufw-docker-selfheal.service
Wants=ufw.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in iptables ip6tables; do $i -F DOCKER-USER 2>/dev/null; $i -A DOCKER-USER -j RETURN 2>/dev/null; done; logger -t ufw-docker-coldboot "saboteur emptied DOCKER-USER"'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null
    systemctl enable ufw-docker-coldboot-saboteur.service >/dev/null 2>&1 \
        || { echo "!! could not enable the saboteur unit" >&2; rm -f "$SABOTEUR"; exit 1; }

    echo "  saboteur installed: it will empty DOCKER-USER on the NEXT boot,"
    echo "  after ufw has applied the stanza and before the self-heal unit runs."
    echo "  The firewall is UNCHANGED right now."
    echo
    echo "  NOW REBOOT, then run: sudo $0 verify"
    ;;

verify)
    [ -f "$MARK" ] || { echo "not armed — run '$0 arm' first" >&2; exit 1; }
    # Declared before sourcing so shellcheck can see where they come from; the
    # marker file sets them.
    armed=""; boot_before=""; jumps_before=""
    # shellcheck disable=SC1090
    . "$MARK"
    now="$(cat /proc/sys/kernel/random/boot_id)"
    if [ "$now" = "$boot_before" ]; then
        echo "!! this host has NOT rebooted since arming (same boot_id)." >&2
        echo "   The whole point is the boot race. Reboot, then verify." >&2
        exit 1
    fi

    jumps="$(iptables -S DOCKER-USER 2>/dev/null | grep -c 'ufw-user-input')"
    echo "armed at        : $armed"
    echo "jumps before    : $jumps_before"
    echo "jumps after boot: $jumps"
    echo
    echo "--- what the unit says it did ---"
    systemctl status ufw-docker-selfheal.service --no-pager -l 2>&1 | sed 's/^/  /' | head -20
    echo
    # The RIGHT tag. cmd_selfheal logs as ufw-docker-selfheal, not ufw-docker,
    # and the first version of this script grepped the latter -- so it printed
    # "No entries" and hid the single piece of evidence that mattered.
    echo "--- saboteur ---"
    journalctl -t ufw-docker-coldboot -b --no-pager 2>/dev/null | sed 's/^/  /'
    echo "--- self-heal ---"
    heal="$(journalctl -t ufw-docker-selfheal -b --no-pager 2>/dev/null)"
    printf '%s\n' "$heal" | sed 's/^/  /'
    echo

    rc=0
    # Did the saboteur actually fire? If it did not, the test exercised
    # nothing and must NOT report success.
    if ! journalctl -t ufw-docker-coldboot -b --no-pager 2>/dev/null | grep -q saboteur; then
        echo "INCONCLUSIVE  the saboteur never ran, so nothing was broken to repair."
        echo "              Not a pass. Check: systemctl status ufw-docker-coldboot-saboteur"
        rc=1
    elif printf '%s' "$heal" | grep -q 'healthy at boot'; then
        # This is the trap the first version of this script fell into.
        echo "INCONCLUSIVE  self-heal found the firewall already healthy, so something"
        echo "              else repaired it before the unit looked. The unit's repair"
        echo "              path was NOT exercised. Not a pass."
        rc=1
    elif printf '%s' "$heal" | grep -q 'DOCKER-USER unwired'; then
        echo "PASS  the self-heal unit SAW the broken chain and repaired it"
    else
        echo "INCONCLUSIVE  self-heal logged nothing recognisable this boot."
        rc=1
    fi

    if [ "${jumps:-0}" -gt 0 ]; then
        echo "PASS  DOCKER-USER is wired now (jumps: $jumps)"
    else
        echo "FAIL  DOCKER-USER is still empty — your container ports are UNFILTERED."
        echo "      Repair with: sudo $REPO/ufw-docker install"
        rc=1
    fi
    "$REPO/ufw-docker" status >/dev/null 2>&1 \
        && echo "PASS  status is healthy" \
        || { echo "FAIL  status reports a problem — run: $REPO/ufw-docker status"; rc=1; }
    # ALWAYS remove the saboteur, pass or fail. A test fixture that survives
    # the test is a trap for the next boot.
    systemctl disable ufw-docker-coldboot-saboteur.service >/dev/null 2>&1
    rm -f "$SABOTEUR"
    systemctl daemon-reload 2>/dev/null
    echo
    echo "  saboteur removed; the next boot is a normal one."
    rm -f "$MARK"
    exit $rc
    ;;

disarm)
    systemctl disable ufw-docker-coldboot-saboteur.service >/dev/null 2>&1
    rm -f "$SABOTEUR" "$MARK"
    systemctl daemon-reload 2>/dev/null
    echo "  disarmed; the next boot is a normal one."
    ;;
*)
    sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 1
    ;;
esac
