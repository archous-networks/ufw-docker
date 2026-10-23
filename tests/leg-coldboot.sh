#!/usr/bin/env bash
#
# COLD BOOT, in a leg. The half of B1 that used to need real hardware.
#
# tests/cold-boot-check.sh is still the real thing and is still manual: it
# arms a saboteur, you reboot the machine, and it tells you what happened.
# That is the only way to test a KERNEL boot, and nothing here replaces it.
#
# What this does replace is the part that was manual for no good reason. A leg
# container runs systemd as pid 1, so `docker restart` is a genuine init boot:
# every unit is re-run, ordering is re-evaluated, and /run is a fresh tmpfs.
# That is exactly the surface the self-heal unit's ordering lives on.
#
# BE CLEAR ABOUT WHAT THIS DOES *NOT* COVER, because the name invites
# over-reading:
#   - no kernel boot. /proc/sys/kernel/random/boot_id is the RUNNER's and does
#     not change here, which is why the freshness signal below is /run and not
#     boot_id -- the obvious check would silently pass forever.
#   - no initramfs, no module loading, no real NIC coming up, so nothing that
#     depends on network-online.target against actual hardware is exercised.
#
# What it DOES prove, per push, on every distro in the matrix: that with ufw,
# docker and this unit all starting together, and DOCKER-USER emptied after
# ufw has applied the stanza, the unit notices and repairs it.
set -uo pipefail

NAME="${1:?usage: leg-coldboot.sh <container>}"
dexec() { docker exec "$NAME" "$@"; }
say() { printf '\n-- %s\n' "$*"; }
rc=0
fail() { echo "FAIL  $*"; rc=1; }
pass() { echo "pass  $*"; }

# A HELPER, NOT A STYLE CHOICE. `cmd | grep -q pattern` under `set -o pipefail`
# is wrong in TWO independent ways, and this phase hit both before it worked:
#
#   1. grep -q exits the moment it matches, the producer keeps writing into a
#      closed pipe, takes SIGPIPE and exits 141 -- which pipefail makes the
#      status of the whole pipeline. So a MATCH reports failure. Measured: 141.
#
#   2. pipefail also propagates the PRODUCER's own exit status. `ufw-docker
#      status` returns 1 whenever any check is red, so "does its output mention
#      X" came back false purely because something unrelated was wrong.
#
# Both inverted real results: `status` printed `IPv4 wired` in plain sight
# while the check looking for it declared the host unwired. The question being
# asked is "did this command SAY X", which is independent of how it exited --
# so capture the output, discard the status, and match in bash.
#
# Substrings, not regexes: `case` would treat a glob character as one.
says() {   # says <substring> <command...>
    local want="$1"; shift
    local out; out="$("$@" 2>&1 || true)"
    case "$out" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

# THE TRAP THIS WALKED INTO FIRST, preserved from cold-boot-check.sh because it
# is just as easy to re-make here: simply emptying DOCKER-USER and restarting
# proves nothing. DOCKER-USER is runtime state. At boot ufw applies after.rules,
# the stanza rewires the chain, and the unit correctly reports "healthy at
# boot" -- a pass that exercised none of the repair path.
#
# The condition the unit exists for is ufw applying the stanza and something
# flushing DOCKER-USER AFTERWARDS, which is what a Docker daemon starting after
# ufw does. So: a one-shot unit ordered between the two.
# PRECONDITION, asserted rather than assumed. The first run of this phase
# found an UNINSTALLED host -- the suite's teardown_file removes the tool --
# so the saboteur emptied a chain nobody was repairing, the unit never ran,
# and the final `status` check passed because status on an uninstalled host is
# correctly rc=0. Three failures and one vacuous pass, all from a precondition
# nothing checked.
say "precondition: the tool is installed and wired"
# Ask `status`, rather than grepping after.rules for a marker string. The
# first version of this check spelled the marker backwards -- it is
# `BEGIN DOCKER-UFW`, not `BEGIN UFW-DOCKER` -- and all three phases inherited
# the same typo. The suite had the identical transposition inside a negative
# assertion, where it had been passing unconditionally. One source of truth.
if ! says 'IPv4 wired' dexec /usr/local/sbin/ufw-docker status; then
    echo "FAIL  the tool is not installed and wired — nothing for the self-heal unit to repair."
    echo "      This phase proves nothing without it. Not a pass."
    dexec /usr/local/sbin/ufw-docker status 2>&1 | tail -20
    exit 1
fi
pre_jumps="$(dexec sh -c 'iptables -S DOCKER-USER 2>/dev/null | awk "/ufw-user-input/{n++} END{print n+0}"')"
if [ "${pre_jumps:-0}" -eq 0 ]; then
    echo "FAIL  DOCKER-USER has no jumps before we even start — already broken."
    exit 1
fi
pass "stanza installed, DOCKER-USER wired ($pre_jumps jumps)"

say "arm the saboteur (empties DOCKER-USER after ufw, before self-heal)"
dexec sh -c 'cat > /etc/systemd/system/ufw-docker-legboot-saboteur.service <<UNIT
[Unit]
Description=TEST ONLY - empty DOCKER-USER after ufw, to exercise ufw-docker-selfheal
After=ufw.service docker.service
Before=ufw-docker-selfheal.service
Wants=ufw.service docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "for i in iptables ip6tables; do \$i -F DOCKER-USER 2>/dev/null; \$i -A DOCKER-USER -j RETURN 2>/dev/null; done; logger -t ufw-docker-legboot saboteur-ran"

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable ufw-docker-legboot-saboteur.service >/dev/null 2>&1' \
    || { echo "FAIL  could not arm the saboteur"; exit 1; }

# The freshness signal. /run is a --tmpfs, so it is recreated on container
# start; a marker surviving means the init never actually restarted and every
# assertion below would be reporting on the PREVIOUS boot.
dexec sh -c 'touch /run/legboot-marker' || true
jumps_before="$(dexec sh -c 'iptables -S DOCKER-USER 2>/dev/null | awk "/ufw-user-input/{n++} END{print n+0}"')"

# EVERY journal read below is bounded by this, and it is not a nicety.
#
# `journalctl -b` means "this BOOT", and a boot is identified by boot_id -- the
# RUNNER's kernel boot_id, which does not change when a container's init
# restarts. So `-b` inside a leg spans everything since the host came up,
# including the bats suite that just ran four self-heal tests and logged
# `DOCKER-USER unwired` among them. Grepping `-b` for that string would match
# the SUITE's line and report a pass without the unit having run at all.
#
# Same trap as the kernel ring buffer not being namespaced, and the same shape
# as the boot_id check this script deliberately does not use.
SINCE="$(dexec date -u '+%Y-%m-%d %H:%M:%S')"
jrnl() { dexec journalctl -t "$1" --utc --since "$SINCE" --no-pager 2>/dev/null; }

say "restart the container init"
docker restart -t 30 "$NAME" >/dev/null || { echo "FAIL  container did not restart"; exit 1; }
for _ in $(seq 1 90); do
    state="$(dexec systemctl is-system-running 2>/dev/null || true)"
    case "$state" in starting|initializing|"") sleep 1 ;; *) break ;; esac
done
echo "systemd after restart: ${state:-unknown}"
for _ in $(seq 1 30); do dexec docker info >/dev/null 2>&1 && break; sleep 2; done

say "assertions"
if dexec test -e /run/legboot-marker 2>/dev/null; then
    fail "/run survived the restart — the init did NOT reboot, nothing below means anything"
else
    pass "/run is a fresh tmpfs (the init really restarted)"
fi

# Without this the whole test can pass having broken nothing. Not a pass --
# INCONCLUSIVE is a distinct outcome and must not be graded as success.
if says saboteur-ran jrnl ufw-docker-legboot; then
    pass "the saboteur ran, so there was genuinely something to repair"
else
    fail "the saboteur never ran — INCONCLUSIVE, not a pass"
fi

heal="$(jrnl ufw-docker-selfheal)"
case "$heal" in
    *"DOCKER-USER unwired"*)
        pass "self-heal SAW the broken chain and repaired it" ;;
    *"healthy at boot"*)
        # INCONCLUSIVE, and graded as a failure on purpose. Something repaired
        # the chain before the unit looked, so its repair path never ran.
        fail "self-heal found it already healthy — the repair path was NOT exercised" ;;
    *)
        fail "self-heal logged nothing recognisable this boot"
        printf '%s\n' "${heal:-(no journal entries since the restart)}" | sed 's/^/      /' ;;
esac

jumps_after="$(dexec sh -c 'iptables -S DOCKER-USER 2>/dev/null | awk "/ufw-user-input/{n++} END{print n+0}"')"
echo "jumps: before=$jumps_before after=$jumps_after"
[ "${jumps_after:-0}" -gt 0 ] \
    && pass "DOCKER-USER is wired again" \
    || fail "DOCKER-USER is still empty — container ports would be UNFILTERED"

if dexec systemctl is-active --quiet ufw-docker-selfheal.service; then
    pass "the self-heal unit itself is active, not failed"
else
    fail "the self-heal unit is $(dexec systemctl is-active ufw-docker-selfheal.service 2>&1) — see status check 'selfheal'"
fi

# NOT just rc=0. `status` returns 0 on a host where the tool is not installed
# at all, so a bare exit-code check here passed on the very run that proved
# nothing. Require that it says it IS wired.
if says 'IPv4 wired' dexec /usr/local/sbin/ufw-docker status; then
    dexec /usr/local/sbin/ufw-docker status >/dev/null 2>&1 \
        && pass "status is green AND reports the host wired" \
        || fail "status reports the host wired but still exits non-zero"
else
    fail "status does not report the host as wired after the boot"
fi

# ALWAYS, pass or fail. A fixture that survives its own test poisons whatever
# runs next in this container.
say "disarm"
dexec sh -c 'systemctl disable ufw-docker-legboot-saboteur.service >/dev/null 2>&1
rm -f /etc/systemd/system/ufw-docker-legboot-saboteur.service
systemctl daemon-reload 2>/dev/null' || true

exit $rc
