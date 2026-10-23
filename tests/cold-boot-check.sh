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
set -uo pipefail

MARK=/var/lib/ufw-docker-coldboot-test
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
    - empty DOCKER-USER, so your Docker-published ports are UNFILTERED
    - leave them that way until you reboot and the self-heal unit runs
    - NOT affect SSH (that is INPUT, untouched)

  Reboot promptly after this. If you change your mind:
      sudo $REPO/ufw-docker install

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

    for ipt in iptables ip6tables; do
        "$ipt" -S DOCKER-USER >/dev/null 2>&1 || continue
        "$ipt" -F DOCKER-USER 2>/dev/null
        "$ipt" -A DOCKER-USER -j RETURN 2>/dev/null
    done
    echo "  DOCKER-USER emptied. jumps now: $(iptables -S DOCKER-USER | grep -c 'ufw-user-input')"
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
    echo "--- syslog ---"
    journalctl -t ufw-docker -b --no-pager 2>/dev/null | sed 's/^/  /' | head -20
    echo

    rc=0
    if [ "${jumps:-0}" -gt 0 ]; then
        echo "PASS  DOCKER-USER was rewired across a real cold boot"
    else
        echo "FAIL  DOCKER-USER is still empty — the unit did not repair it"
        echo "      This is the finding B1 exists to get. Capture the journal above."
        rc=1
    fi
    "$REPO/ufw-docker" status >/dev/null 2>&1 \
        && echo "PASS  status is healthy" \
        || { echo "FAIL  status reports a problem — run: $REPO/ufw-docker status"; rc=1; }
    rm -f "$MARK"
    exit $rc
    ;;
*)
    sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 1
    ;;
esac
