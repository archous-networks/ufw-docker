#!/usr/bin/env bats
#
# These tests MUTATE THE LIVE FIREWALL of the machine they run on. Run them on a
# disposable VM or in CI, never on anything you care about.
#
# teardown_file always runs `ufw-docker rescue`, so a failing test cannot leave the host
# unreachable -- that is the single most important property of this suite.

REPO="${BATS_TEST_DIRNAME}/.."
HOST_IP="${HOST_IP:?set HOST_IP to the primary address of this host}"

# Derived the same way the tool derives it (D5), so these tests keep working on
# a host whose ufw is packaged somewhere other than /etc/ufw. The older tests
# below still hardcode the Debian path; that is a known inconsistency, not a
# statement that the path is fixed.
AFTER4="$(python3 -c 'import ufw.common as c; print(c.config_dir + "/ufw/after.rules")' 2>/dev/null || echo /etc/ufw/after.rules)"
BEFORE_INIT="$(dirname "$AFTER4")/before.init"

# The install flags THIS host needs. X1 refuses environments it has not been
# proven on, and the legacy CI leg is deliberately one of them -- so every test
# that calls `install` directly needs the same override `reinstall` uses, or it
# fails on the preflight long before reaching what it meant to test.
install_args() { host_supported || printf '%s' "--unsupported --force"; }

# `install` colours its output, and a colour code between `-j` and the target
# makes awk read the escape as the chain name.
strip_ansi_stream() { sed -E 's/\x1b\[[0-9;]*m//g'; }

probe()  { sudo HOST_IP="$HOST_IP" "$REPO/tests/netns-probe.sh" get "$1" "${2:-http}"; }
health() { sudo iptables -S ufw-user-input 2>/dev/null; }
logchains() { sudo iptables -S 2>/dev/null | grep -cE '^-N ufw.*logging'; }
ssh_rule()  { sudo iptables -S ufw-user-input 2>/dev/null | grep -c 'dport 22'; }
jumps()     { sudo iptables -S DOCKER-USER 2>/dev/null | grep -c 'ufw-user-input'; }
active()    { sudo ufw status 2>/dev/null | grep -c 'Status: active'; }

# Confirm something is actually listening behind the port under test, from the
# host, before asserting anything about the firewall. A probe of a port with no
# listener returns 000 whatever the rules say -- which is indistinguishable from
# "correctly blocked" and silently turns the allow-tests into passes-for-free.
# The suite's own service, on a port NOTHING else serves.
#
# It used to be 19089, and it used to be created by the CI workflow rather than
# here. Both were wrong, and together they were worse than either alone:
#
#   - 19089 is published by unms-nginx on a UISP host. `ensure_service` only
#     curls 127.0.0.1, so it found the OPERATOR'S service, happily probed that
#     instead of a container the suite controls, and then deleted their rule
#     for it. On this development host that took UISP's device endpoint down
#     mid-run and left it down.
#   - creating it only in CI meant a local run silently fell through to
#     whatever happened to answer on 19089 -- a CI/local divergence of exactly
#     the kind that has already cost this project two cancelled runs.
#
# The suite now creates it, identically everywhere. Pick any replacement port
# the same way: high, and not in any service list.
TESTSVC_PORT=19089

start_testsvc() {
    # 1:1 ON PURPOSE. Published 19089:80 would be REMAPPED, and after DNAT the
    # rule must name the CONTAINER port -- so `ufw allow 19089` could never
    # match, and the "allow opens it" tests would fail while the "blocked"
    # ones passed vacuously. That is a real property of this design, covered
    # by its own test rather than tripped over here.
    #
    # --restart always is REQUIRED, not tidiness: one test restarts the Docker
    # daemon, which stops a no-policy container and removes its DNAT rule.
    # Later tests would then probe a port with nothing behind it and fail for
    # a reason that has nothing to do with the firewall.
    #
    # --bind :: makes it dual-stack. `python -m http.server` binds 0.0.0.0 by
    # default, and a v6 probe of a v4-only listener gets a TCP RST -> 000,
    # which is indistinguishable from "correctly blocked".
    docker run -d --name testsvc --restart always \
        -p "${TESTSVC_PORT}:${TESTSVC_PORT}" python:3-alpine \
        python -m http.server "$TESTSVC_PORT" --bind :: >/dev/null 2>&1
}

ensure_service() {
    local port="${1:-$TESTSVC_PORT}" i
    for i in $(seq 1 10); do
        curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null && return 0
        # Bring back anything a daemon restart stopped -- or create it, if this
        # is the first call of the run.
        docker start testsvc >/dev/null 2>&1 || start_testsvc
        sleep 2
    done
    return 1
}

# ── THE INVARIANT: a test may touch only what it created ──────────────────
#
# Everything else in the operator's rule set must be byte-identical before and
# after EVERY test. This is the mechanical form of a rule that used to be
# discipline, and discipline lost twice in a row:
#
#   - a test re-added `allow 22/tcp` unconditionally and LEAKED a blanket SSH
#     rule onto a host whose SSH was deliberately restricted to one source;
#   - the fix for that then DELETED CI's SSH rule and never put it back,
#     because it asked "did we add it?" when it needed "did we delete it?".
#
# Both bugs were invisible in the environment they were written in and obvious
# in the other one. The check below does not care what the host's rules look
# like -- only whether they still look the same -- so the two environments are
# free to differ, which they do in several ways besides this one.
#
# The verdict logic lives in rules-lib.bash so it can be self-tested against
# synthetic inputs (tests/invariant-selftest.sh). A check that never fires is
# indistinguishable from one that cannot, and this suite has already shipped
# three assertions that passed for the wrong reason.
# shellcheck source=tests/rules-lib.bash
source "${BATS_TEST_DIRNAME}/rules-lib.bash"

# The operator's DECLARED rules, which is the durable thing. The live chains are
# flushed and rebuilt by tests legitimately (that is what test 19 exercises);
# user.rules is what survives, and it is what both bugs above corrupted.
op_rules() {
    sudo cat /etc/ufw/user.rules /etc/ufw/user6.rules 2>/dev/null \
        | grep -E -- '^-A ufw6?-user-' | sort
}

assert_operator_rules_intact() {
    local before="$BATS_FILE_TMPDIR/rules-before" after="$BATS_FILE_TMPDIR/rules-after"
    [ -f "$before" ] || return 0
    op_rules > "$after"
    local out
    if ! out=$(rules_diff_report "$before" "$after"); then
        printf '%s\n' "$out" >&3
        return 1
    fi
    return 0
}

# Start a listener on the HOST (not in a container), safely.
#
# THE `3>&-` IS LOAD-BEARING AND IS NOT TIDINESS. bats blocks on exit until
# every process holding its fd 3 has gone. A background process started without
# closing fd 3 inherits it, and bats then waits for that process to end --
# forever, for a `python -m http.server`.
#
# Measured, because it cost two cancelled CI jobs:
#
#     sleep 25 >/dev/null 2>&1 &        -> bats exits after 25s
#     sleep 25 >/dev/null 2>&1 3>&- &   -> bats exits immediately
#
# Redirecting stdout and stderr is NOT enough; both listeners here already did
# that. In CI a test failed before its `kill` line, the orphan held fd 3, and
# the job sat at the "Run the suite" step until the timeout cancelled it --
# which also threw away the diagnostics that would have explained the original
# failure. The PID file is the second line of defence: teardown kills anything
# a failed test did not.
start_host_listener() {   # $1 = port
    python3 -m http.server "$1" --bind 0.0.0.0 >/dev/null 2>&1 3>&- &
    echo $! >> "$BATS_FILE_TMPDIR/hostpids"
    sleep 2
}

stop_host_listeners() {
    local pid
    [ -f "$BATS_FILE_TMPDIR/hostpids" ] || return 0
    while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$BATS_FILE_TMPDIR/hostpids"
    : > "$BATS_FILE_TMPDIR/hostpids"
    return 0
}

# Re-install, and SAY WHY if it fails.
#
# Every one of these was `reinstall` as a
# bare statement: under bats' errexit a non-zero install fails the test with
# nothing but the line number, and the output that would have explained it was
# sent to /dev/null. A CI run failed that way at test 17 and cascaded through
# fifteen more tests, and the log could not say why for any of them.
#
# install's exit code is cmd_status's, so a non-zero result means the firewall
# is genuinely unhealthy -- exactly the thing worth printing.
#
# It prints to FD 3, not stderr. bats captures a test's stdout and stderr and
# --tap does not replay them, so the first version of this helper ran in CI and
# its diagnostics went nowhere. FD 3 is bats' pass-through to the terminal.
# What backend is this host ACTUALLY on? Several tests assert properties that
# only hold on an environment the preflight calls supported, and CI
# deliberately runs one leg on iptables-legacy to find out whether it works.
host_backend() {
    iptables --version 2>/dev/null | grep -oE '\(nf_tables\)|\(legacy\)' | tr -d '()'
}
# ASK THE TOOL. An earlier version of this duplicated the rule ("backend is
# nf_tables"), and the moment the preflight grew a platform-matrix check the
# two disagreed: the suite would believe the host supported while `install`
# refused it, and every reinstall would fail. One source of truth.
host_supported() {
    sudo "$REPO/ufw-docker" status --json 2>/dev/null \
        | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("supported") else 1)' 2>/dev/null
}

reinstall() {
    local out rc force=""
    # X1 refuses to install on an environment it has not been proven on, which
    # is correct -- and which would stop the legacy CI leg before it could tell
    # us ANYTHING about whether legacy works. The leg exists precisely to
    # answer that, so here, and only here, we take the documented override.
    #
    # This is not a way around the preflight. It is how the preflight earns the
    # right to stop refusing: when this leg is green, legacy becomes a proven
    # environment and the override stops being needed. Until then the refusal
    # is the correct production behaviour and the tests above assert it.
    host_supported || force="--unsupported --force"
    # shellcheck disable=SC2086
    out=$(sudo "$REPO/ufw-docker" install $force 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
        {
            echo "--- install exited $rc ---"
            echo "$out"
            echo "--- ufw status ---";      sudo ufw status verbose 2>&1 || true
            echo "--- DOCKER-USER ---";     sudo iptables -S DOCKER-USER 2>&1 || true
            echo "--- ufw-user-input ---";  sudo iptables -S ufw-user-input 2>&1 || true
        } >&3
        return $rc
    fi
    return 0
}

setup_file() {
    sudo HOST_IP="$HOST_IP" "${BATS_TEST_DIRNAME}/netns-probe.sh" up
    # A rule we can prove host-level filtering with, independent of Docker.
    # Only add it if it is not already there, and record that we did -- the
    # teardown must not delete an SSH rule the environment provided. In CI the
    # workflow adds one before the suite runs; removing it made `rescue` find no
    # SSH rule, fall back to a blanket ACCEPT, and report the job as failed.
    if sudo ufw status 2>/dev/null | grep -qE '^22/tcp +ALLOW'; then
        echo no > "$BATS_FILE_TMPDIR/we-added-ssh"
    else
        echo yes > "$BATS_FILE_TMPDIR/we-added-ssh"
        sudo ufw allow 22/tcp >/dev/null 2>&1
    fi
    # Own the service container too, so a local run and a CI run exercise the
    # same thing. Created BEFORE reinstall so its subnet is in the stanza.
    if docker inspect testsvc >/dev/null 2>&1; then
        echo no  > "$BATS_FILE_TMPDIR/we-made-testsvc"
    else
        echo yes > "$BATS_FILE_TMPDIR/we-made-testsvc"
    fi
    ensure_service >/dev/null 2>&1 || true

    reinstall

    # The baseline every test is measured against. Taken AFTER the SSH rule
    # above, so whatever this host's SSH rule looks like is simply part of the
    # baseline and no test needs to know its shape.
    op_rules > "$BATS_FILE_TMPDIR/rules-before"
}

# Fail the test that BREAKS the SSH rule, not the five downstream tests that
# merely observe it missing. Test 14 deleted it and eleven later tests failed;
# the log blamed all of them and none of them was the cause. This names it.
teardown() {
    # FIRST, unconditionally: a test that failed early never reached its own
    # cleanup, and one orphan holding fd 3 hangs the whole run on exit.
    stop_host_listeners

    # A test that deliberately breaks before.init hands us its backup up front,
    # so a failed assertion cannot leave the hook customised -- which makes
    # every later `install` refuse and turns one failure into a cascade.
    if [ -f "$BATS_FILE_TMPDIR/restore-before-init" ]; then
        local saved; saved="$(cat "$BATS_FILE_TMPDIR/restore-before-init")"
        [ -f "$saved" ] && sudo cp -a "$saved" "$BEFORE_INIT"
        rm -f "$saved" "$BATS_FILE_TMPDIR/restore-before-init"
        reinstall || true
    fi

    # Same contract as before.init above: a test that loosens ufw's DEFAULT
    # policy, or unhooks DOCKER-USER from FORWARD, records that up front so a
    # failed assertion cannot leave the host that way. teardown always runs;
    # the rest of a test after a failed assertion does not.
    if [ -f "$BATS_FILE_TMPDIR/restore-default-incoming" ]; then
        sudo ufw default deny incoming >/dev/null 2>&1 || true
        rm -f "$BATS_FILE_TMPDIR/restore-default-incoming"
    fi
    if [ -f "$BATS_FILE_TMPDIR/restore-forward-jump" ]; then
        sudo iptables -C FORWARD -j DOCKER-USER 2>/dev/null \
            || sudo iptables -I FORWARD 1 -j DOCKER-USER 2>/dev/null || true
        rm -f "$BATS_FILE_TMPDIR/restore-forward-jump"
    fi
    if [ -f "$BATS_FILE_TMPDIR/restore-stanza" ]; then
        local sv; sv="$(cat "$BATS_FILE_TMPDIR/restore-stanza")"
        [ -f "$sv" ] && sudo cp -a "$sv" "$AFTER4"
        rm -f "$sv" "$BATS_FILE_TMPDIR/restore-stanza"
        reinstall || true
    fi
    # A test that repoints or disables the self-heal unit hands us the original
    # up front. A unit file left mutated is invisible until the next boot --
    # exactly the failure these tests exist to catch, manufactured by the suite.
    if [ -f "$BATS_FILE_TMPDIR/restore-selfheal-unit" ]; then
        local su; su="$(cat "$BATS_FILE_TMPDIR/restore-selfheal-unit")"
        [ -f "$su" ] && sudo cp -a "$su" /etc/systemd/system/ufw-docker-selfheal.service
        sudo systemctl daemon-reload 2>/dev/null || true
        sudo systemctl enable ufw-docker-selfheal.service >/dev/null 2>&1 || true
        rm -f "$su" "$BATS_FILE_TMPDIR/restore-selfheal-unit"
    fi
    # A test that set IPV6=no must not leave it set -- every v6 assertion
    # after it would then be testing the disabled path without saying so.
    if [ -f "$BATS_FILE_TMPDIR/restore-ufw-defaults" ]; then
        local ud; ud="$(cat "$BATS_FILE_TMPDIR/restore-ufw-defaults")"
        [ -f "$ud" ] && sudo cp -a "$ud" /etc/default/ufw
        rm -f "$ud" "$BATS_FILE_TMPDIR/restore-ufw-defaults"
    fi
    if [ -f "$BATS_FILE_TMPDIR/restore-dummy-net" ]; then
        sudo docker network rm ufwmacvlan >/dev/null 2>&1 || true
        sudo ip link del ufwdummy0 >/dev/null 2>&1 || true
        rm -f "$BATS_FILE_TMPDIR/restore-dummy-net"
    fi

    local rc=0

    if [ "$(ssh_rule)" -eq 0 ]; then
        {
            echo "### THIS TEST LEFT THE HOST WITH NO SSH RULE IN ufw-user-input ###"
            echo "### everything after it will fail for this reason, not its own ###"
            sudo ufw status verbose 2>&1 || true
            grep -- '-A ufw-user-input' /etc/ufw/user.rules 2>/dev/null || echo "(none in user.rules either)"
        } >&3
        rc=1
    fi

    assert_operator_rules_intact || rc=1
    return $rc
}

teardown_file() {
    # STRICT, and FIRST -- before anything below unwinds the setup. Mid-run a
    # test-owned rule may legitimately still be in place; by the end nothing
    # the suite created may remain, so this compares exactly.
    local leftover
    leftover=$(op_rules | diff "$BATS_FILE_TMPDIR/rules-before" - || true)
    if [ -n "$leftover" ]; then
        {
            echo "### THE SUITE LEFT THE OPERATOR'S RULE SET CHANGED ###"
            printf '%s\n' "$leftover"
        } >&3
    fi

    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1 || true
    # Remove the blanket SSH allow ONLY if we added it. Leaving one behind would
    # widen the operator's exposure; deleting one we were given breaks whatever
    # put it there.
    if [ "$(cat "$BATS_FILE_TMPDIR/we-added-ssh" 2>/dev/null)" = yes ]; then
        sudo ufw delete allow 22/tcp >/dev/null 2>&1 || true
    fi
    # Same rule as the SSH rule: remove it only if we made it.
    if [ "$(cat "$BATS_FILE_TMPDIR/we-made-testsvc" 2>/dev/null)" = yes ]; then
        docker rm -f testsvc >/dev/null 2>&1 || true
    fi
    sudo HOST_IP="$HOST_IP" "${BATS_TEST_DIRNAME}/netns-probe.sh" down || true
    # Non-negotiable: never leave a broken firewall behind.
    # BOUNDED, like the one in run.sh. This one was missed: a run that ended
    # with a broken firewall hit rescue TWICE (here, then again in run.sh's
    # trap), and an unbounded one here ate the job's remaining time before the
    # bounded one was ever reached.
    sudo timeout 180 "$REPO/ufw-docker" rescue >/dev/null 2>&1 || true

    # (the strict comparison now runs at the TOP of this function, before the
    # unwinding above can muddy it)
}

@test "install wires DOCKER-USER into ufw-user-input" {
    [ "$(jumps)" -gt 0 ]
}

@test "install leaves ufw healthy" {
    [ "$(active)" -eq 1 ]
    [ "$(logchains)" -ge 9 ]
    [ "$(ssh_rule)" -gt 0 ]
}

@test "before.init hook is installed (required for reload safety)" {
    sudo test -x /etc/ufw/before.init
    sudo grep -q 'ufw-docker' /etc/ufw/before.init
}

@test "a Docker-published port with no ufw rule is BLOCKED" {
    sudo ufw delete allow 19089/tcp >/dev/null 2>&1 || true
    sudo ufw delete deny  19089/tcp >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 19089)" = "000" ]
}

@test "ufw allow opens a Docker-published port" {
    ensure_service 19089 || skip "nothing listening on 19089"
    sudo ufw allow 19089/tcp >/dev/null 2>&1
    [ "$(probe 19089)" != "000" ]
}

@test "ufw deny closes a Docker-published port" {
    sudo ufw delete allow 19089/tcp >/dev/null 2>&1
    sudo ufw deny 19089/tcp >/dev/null 2>&1
    [ "$(probe 19089)" = "000" ]
    sudo ufw delete deny 19089/tcp >/dev/null 2>&1
}

@test "source-restricted allow is honoured" {
    ensure_service 19089 || skip "nothing listening on 19089"
    sudo ufw allow from 10.97.0.0/24 to any port 19089 proto tcp >/dev/null 2>&1
    [ "$(probe 19089)" != "000" ]
    sudo ufw delete allow from 10.97.0.0/24 to any port 19089 proto tcp >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 19089)" = "000" ]
}

@test "a REMAPPED published port is matched by its CONTAINER port, not the published one" {
    # The sharpest trap in this design, pinned so it cannot regress silently.
    # Docker DNATs in PREROUTING, before FORWARD -- so by the time DOCKER-USER
    # sees the packet the dport is the CONTAINER port. Publishing 18443:18080
    # means `ufw allow 18443` does NOTHING and `ufw allow 18080` is what works.
    docker rm -f remapsvc >/dev/null 2>&1 || true
    docker run -d --name remapsvc -p 18443:18080 python:3-alpine \
        python -m http.server 18080 >/dev/null 2>&1
    sleep 5
    reinstall   # pick up any new subnet

    sudo ufw allow 18443/tcp >/dev/null 2>&1
    run probe 18443
    [ "$output" = "000" ]              # the published port does NOT work
    sudo ufw delete allow 18443/tcp >/dev/null 2>&1

    sudo ufw allow 18080/tcp >/dev/null 2>&1
    run probe 18443
    [ "$output" != "000" ]             # the container port DOES
    sudo ufw delete allow 18080/tcp >/dev/null 2>&1

    docker rm -f remapsvc >/dev/null 2>&1 || true
}

@test "REGRESSION: repeated ufw reload does not break the firewall" {
    # Without before.init this fails on reload #2: ufw aborts half-built,
    # ufw-user-input ends up EMPTY, and the SSH allow silently disappears.
    for _ in 1 2 3 4 5; do sudo ufw reload >/dev/null 2>&1; done
    [ "$(active)" -eq 1 ]
    [ "$(logchains)" -ge 9 ]
    [ "$(ssh_rule)" -gt 0 ]
    [ "$(jumps)" -gt 0 ]
}

@test "REGRESSION: reload does not duplicate DOCKER-USER rules" {
    local before after
    before=$(sudo iptables -S DOCKER-USER | wc -l)
    sudo ufw reload >/dev/null 2>&1
    after=$(sudo iptables -S DOCKER-USER | wc -l)
    [ "$before" -eq "$after" ]
}

@test "ufw disable then enable restores the wiring" {
    sudo ufw --force disable >/dev/null 2>&1
    sudo ufw --force enable  >/dev/null 2>&1
    [ "$(active)" -eq 1 ]
    [ "$(jumps)" -gt 0 ]
    [ "$(ssh_rule)" -gt 0 ]
}

@test "rules survive a container recreate" {
    # E8. This was UISP-specific and skipped in CI, so whether it was green
    # depended on WHERE it ran -- the exact shape this suite spent a day
    # removing. It also asserted only that DOCKER-USER still had jumps, which
    # is a much weaker claim than the one that matters.
    #
    # Triage assumed another test already covered recreate in CI and that this
    # one could simply be deleted. It did not: nothing else in the suite
    # recreates a container at all, so deleting this would have removed real
    # coverage. It builds its own container instead, and now runs everywhere.
    #
    # STATIC IPAM address on purpose. A dynamic address CHANGES on recreate and
    # a rule naming the old one then matches nothing -- that is real, documented
    # behaviour and the reason `containers` flags dynamic addresses, so it is
    # not something to assert against. The static case is the one an operator
    # writing per-container rules should be in.
    docker rm -f recreatesvc >/dev/null 2>&1 || true
    docker network rm recreatenet >/dev/null 2>&1 || true
    docker network create --subnet 172.24.0.0/24 recreatenet >/dev/null 2>&1 \
        || skip "172.24.0.0/24 is in use on this host"

    mk_recreatesvc() {
        docker run -d --name recreatesvc --network recreatenet --ip 172.24.0.10 \
            -p 19500:19500 python:3-alpine \
            python -m http.server 19500 >/dev/null 2>&1
    }

    mk_recreatesvc; sleep 5
    reinstall                                  # pick up the new subnet

    sudo ufw allow to 172.24.0.10 port 19500 proto tcp >/dev/null 2>&1
    [ "$(probe 19500)" != "000" ]              # the rule governs it

    # Recreate it, deliberately WITHOUT re-running install. Docker rebuilds its
    # own DNAT and this tool must not need to be told.
    docker rm -f recreatesvc >/dev/null 2>&1
    mk_recreatesvc; sleep 5

    local rc=0
    [ "$(jumps)" -gt 0 ]             || rc=1   # the wiring survived
    [ "$(probe 19500)" != "000" ]    || rc=1   # and the rule still reaches it

    sudo ufw --force delete allow to 172.24.0.10 port 19500 proto tcp >/dev/null 2>&1
    docker rm -f recreatesvc >/dev/null 2>&1 || true
    docker network rm recreatenet >/dev/null 2>&1 || true
    reinstall
    [ "$rc" -eq 0 ]
}

@test "rules survive a Docker daemon restart" {
    # Poll rather than sleeping a fixed 20s. A single sample after an async
    # operation is a coin flip -- this test failed once that way while 100
    # samples at 0.5s across a real restart never saw the rules missing.
    sudo systemctl restart docker
    local i
    for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && [ "$(jumps)" -gt 0 ] && break
        sleep 2
    done
    [ "$(jumps)" -gt 0 ]
    [ "$(ssh_rule)" -gt 0 ]
}

@test "host-level INPUT filtering still works independently" {
    # The whole point: wiring FORWARD in must not change host behaviour.
    #
    # THIS TEST USED TO USE PORT 22, AND THAT WAS A BUG THAT COST TWO CI RUNS.
    # It ran `ufw delete allow 22/tcp` unconditionally and restored it only if
    # setup_file had added it. In CI the workflow adds `allow 22/tcp` BEFORE the
    # suite, so setup_file recorded "not ours", the delete succeeded, and the
    # rule was gone for the rest of the run -- after which `status` reported no
    # SSH rule, every `install` exited non-zero, install's own health check
    # rolled the stanza back out, and eleven downstream tests failed for a
    # reason none of them had anything to do with.
    #
    # It was invisible locally only by luck: this host's rule is
    # `allow from <ip> to any port 22`, which `ufw delete allow 22/tcp` does not
    # match, so the delete quietly did nothing.
    #
    # A firewall suite has no business deleting the SSH rule of the box it is
    # running on to prove a point any port can prove. It uses its own port now.
    local port=19300
    start_host_listener "$port"

    sudo ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe $port)" = "000" ]          # host port, no rule -> blocked

    sudo ufw allow "$port/tcp" >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe $port)" != "000" ]         # ...and an INPUT allow opens it

    sudo ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe $port)" = "000" ]          # ...and removing it closes it again

    stop_host_listeners
}

@test "ufw route rules are honoured" {
    ensure_service 19089 || skip "nothing listening on 19089"
    # Before this was wired, `ufw route allow` -- the verb ufw intends for
    # forwarded traffic -- was ignored entirely, with no warning.
    sudo ufw route allow to any port 19089 proto tcp >/dev/null 2>&1
    [ "$(probe 19089)" != "000" ]
    sudo ufw route delete allow to any port 19089 proto tcp >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 19089)" = "000" ]
}

@test "blocked container traffic is logged" {
    ensure_service 19089 || skip "nothing listening on 19089"
    # The LOG rule is rate-limited to 3/min with a burst of 10 -- the same limit
    # ufw uses. Earlier tests in this file generate blocks and drain that burst,
    # so a single probe can legitimately produce no line. Poll instead: at
    # 3/min a token frees up every 20s, so a minute is ample.
    sudo ufw delete allow 19089/tcp >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    local mark; mark=$(date +%s)
    local i
    for i in $(seq 1 12); do
        probe 19089 >/dev/null
        sleep 5
        # MATCH OUR OWN PACKET, not merely the prefix. The kernel ring buffer
        # is global -- it is not namespaced the way the rules are -- so a run
        # inside tests/container-leg.sh reads the HOST's dmesg and can see the
        # host's own `[UFW DOCKER BLOCK]` lines. Grepping the prefix alone
        # would pass on evidence this test did not produce, which is the exact
        # shape of failure this suite keeps finding in itself.
        if sudo journalctl -k --since "@$mark" --no-pager 2>/dev/null \
            | grep 'UFW DOCKER BLOCK' | grep -q "SRC=10.97.0.2 .*DPT=19089 "; then
            return 0
        fi
    done
    # Name the non-obvious cause. Inside a nested namespace the rule fires and
    # the packet IS dropped, but the kernel discards the log line unless
    # `net.netfilter.nf_log_all_netns=1` -- so this reads as "logging broken"
    # when nothing about logging is broken. container-leg.sh sets it.
    echo "no [UFW DOCKER BLOCK] line for SRC=10.97.0.2 DPT=19089 in 60s" >&2
    echo "  (in a nested netns, check net.netfilter.nf_log_all_netns on the HOST)" >&2
    return 1
}

@test "subnet drift is detected" {
    docker network create --subnet 10.78.0.0/24 drifttest >/dev/null 2>&1
    run sudo "$REPO/ufw-docker" status
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'SUBNET DRIFT'
    echo "$output" | grep -q '10.78.0.0/24'
    reinstall   # re-install clears it
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'all Docker IPv4 subnets are covered'
    docker network rm drifttest >/dev/null 2>&1
    reinstall
}

@test "selfheal rewires DOCKER-USER if it is found empty" {
    # The B2 scenario: a future Docker that flushes DOCKER-USER on startup would
    # leave container ports unfiltered while everything LOOKS fine.
    sudo iptables -F DOCKER-USER
    sudo iptables -A DOCKER-USER -j RETURN
    [ "$(jumps)" -eq 0 ]
    sudo SELFHEAL_DELAY=0 "$REPO/ufw-docker" selfheal
    [ "$(jumps)" -gt 0 ]
}

@test "selfheal restores a missing SSH rule, restricted not blanket" {
    sudo iptables -F ufw-user-input
    [ "$(ssh_rule)" -eq 0 ]
    sudo SELFHEAL_DELAY=0 "$REPO/ufw-docker" selfheal
    [ "$(ssh_rule)" -gt 0 ]
    # It must NOT have left a blanket ACCEPT behind in INPUT.
    [ "$(sudo iptables -S INPUT | grep -c 'dport 22')" -eq 0 ]
    reinstall
}

@test "the self-heal UNIT repairs a broken firewall, not just the function" {
    # Tests 18 and 19 call `ufw-docker selfheal` directly, which proves the
    # repair LOGIC and nothing about the thing that actually runs unattended at
    # boot. This drives the real systemd unit instead: its ExecStart path, its
    # ordering, Type=oneshot, and the repair happening in systemd's environment
    # rather than a bats shell.
    systemctl list-unit-files ufw-docker-selfheal.service >/dev/null 2>&1 \
        || skip "no systemd unit here"
    command -v journalctl >/dev/null || skip "no journalctl on this host"

    # The unit calls /usr/local/sbin/ufw-docker, NOT $REPO/ufw-docker. Without
    # this the test would happily pass against whatever stale binary happens to
    # be installed there -- which is not the thing under test.
    sudo install -m 0755 "$REPO/ufw-docker" /usr/local/sbin/ufw-docker

    # Enabled and correctly ordered, or the repair logic will never get the
    # chance to run no matter how good it is. Checked declaratively because a
    # reboot cannot be part of a test suite.
    sudo systemctl is-enabled ufw-docker-selfheal.service
    local after; after=$(systemctl show -p After --value ufw-docker-selfheal.service)
    echo "$after" | grep -q 'ufw.service'
    echo "$after" | grep -q 'docker.service'
    systemctl show -p WantedBy --value ufw-docker-selfheal.service | grep -q 'multi-user.target'

    # Break it the way a bad boot does: ufw up, chains present, no user rules.
    sudo iptables -F ufw-user-input
    [ "$(ssh_rule)" -eq 0 ]

    local mark; mark=$(date +%s)
    # restart, not start: RemainAfterExit=yes means a `start` on an already
    # active oneshot does nothing at all, which would pass vacuously.
    # Blocks for the unit's real 20s delay -- deliberately not short-circuited,
    # since the delay is part of what is being tested.
    sudo systemctl restart ufw-docker-selfheal.service

    [ "$(ssh_rule)" -gt 0 ]                                       # SSH is back
    [ "$(sudo iptables -S INPUT | grep -c 'dport 22')" -eq 0 ]    # restricted, not blanket

    # And it must have said what it did. A silent repair is its own problem:
    # nobody would ever know the host had come up broken.
    local jl; jl=$(sudo journalctl -t ufw-docker-selfheal --since "@$mark" --no-pager 2>/dev/null)
    echo "$jl" | grep -q 'running rescue'
    # rescue strips the stanza by design, so the host is reachable but UNWIRED.
    # That warning is the difference between a safe host and one that looks
    # fine and filters nothing.
    echo "$jl" | grep -q 'RECOVERED but UNWIRED'

    reinstall
}

@test "the self-heal unit leaves a HEALTHY firewall alone" {
    # The other half, and the more dangerous one: a repair path that fires when
    # it should not would rebuild the firewall on every boot of every host.
    systemctl list-unit-files ufw-docker-selfheal.service >/dev/null 2>&1 \
        || skip "no systemd unit here"
    command -v journalctl >/dev/null || skip "no journalctl on this host"
    sudo install -m 0755 "$REPO/ufw-docker" /usr/local/sbin/ufw-docker

    local before_rules before_jumps mark
    before_rules=$(sudo iptables -S ufw-user-input)
    before_jumps=$(jumps)
    mark=$(date +%s)

    sudo systemctl restart ufw-docker-selfheal.service

    [ "$(sudo iptables -S ufw-user-input)" = "$before_rules" ]
    [ "$(jumps)" -eq "$before_jumps" ]
    sudo journalctl -t ufw-docker-selfheal --since "@$mark" --no-pager 2>/dev/null \
        | grep -q 'ufw healthy at boot'
}

@test "install refuses to overwrite a customised before.init" {
    local saved; saved=$(mktemp)
    sudo cp -a "$BEFORE_INIT" "$saved"
    # Hand the restore to teardown BEFORE breaking anything. If an assertion
    # below fails, bats abandons the test at that line -- and this test used to
    # leave a customised hook behind, which made `install` refuse for the rest
    # of the run and turned one failure into six. teardown always runs.
    echo "$saved" > "$BATS_FILE_TMPDIR/restore-before-init"

    printf '#!/bin/sh\n# operator hook\nexit 0\n' | sudo tee "$BEFORE_INIT" >/dev/null
    sudo chmod 0750 "$BEFORE_INIT"
    # shellcheck disable=SC2046
    run sudo "$REPO/ufw-docker" install $(install_args)
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'customised'
    sudo grep -q 'operator hook' "$BEFORE_INIT"     # untouched
}

@test "remove without --force changes nothing" {
    local before; before=$(jumps)
    run sudo "$REPO/ufw-docker" remove
    echo "$output" | grep -q 'WOULD REMOVE'
    echo "$output" | grep -q 'force'
    [ "$(jumps)" -eq "$before" ]
}

@test "per-container rules: destination, source+dest, route, deny, and the published-port trap" {
    # Verified capability, not just a caveat: after DNAT the destination IS the
    # container address, so a rule naming it matches -- and does not affect a
    # different container on the same container port.
    docker rm -f ctgt1 ctgt2 >/dev/null 2>&1 || true
    docker network rm ctgtnet >/dev/null 2>&1 || true
    # Fail with a USEFUL message if the subnet is taken. A leftover network from
    # ad-hoc testing once held this range, and `create` failing silently made the
    # error point at the line rather than at the cause.
    # A10: a CUSTOM BRIDGE NAME, not the br-<hash> Docker picks. The stanza
    # matches on subnets and never on interface names, so this ought to make
    # no difference -- but "ought to" is reasoning, and every per-container
    # assertion below then measures it for free. Converting a [suspected] to a
    # [verified] for the cost of one flag.
    if ! docker network create --subnet 172.21.0.0/24 \
            -o com.docker.network.bridge.name=ufwdtest0 ctgtnet >/dev/null 2>&1; then
        echo "could not create ctgtnet - is 172.21.0.0/24 already used by:" >&2
        docker network ls -q | while read -r n; do
            docker network inspect "$n" --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null
        done | grep '172.21' >&2
        return 1
    fi
    # CONTAINER PORT 19080, NOT 80. After DNAT the dport is the CONTAINER port,
    # so with `-p 18090:80` these probes are judged as port 80 -- and any host
    # that serves a website has `ufw allow 80/tcp`, which matches, so the
    # "with no rule it is BLOCKED" baseline fails before the test has tested
    # anything. Found exactly that way on this host, the hour after a 80/tcp
    # rule was legitimately added for UISP.
    docker run -d --name ctgt1 --network ctgtnet --ip 172.21.0.10 -p 18090:19080 \
        python:3-alpine python -m http.server 19080 >/dev/null 2>&1
    docker run -d --name ctgt2 --network ctgtnet --ip 172.21.0.11 -p 18091:19080 \
        python:3-alpine python -m http.server 19080 >/dev/null 2>&1
    sleep 6
    reinstall    # pick up the new subnet

    [ "$(probe 18090)" = "000" ]
    [ "$(probe 18091)" = "000" ]

    # A. destination only
    sudo ufw allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]      # the targeted container opens
    [ "$(probe 18091)" = "000" ]       # its neighbour on the same port does not
    sudo ufw --force delete allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1

    # B. source AND destination compose
    sudo ufw allow from 10.97.0.0/24 to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    sudo ufw --force delete allow from 10.97.0.0/24 to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1

    # B2. a source that does NOT match must stay closed
    sudo ufw allow from 10.98.0.0/24 to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" = "000" ]
    sudo ufw --force delete allow from 10.98.0.0/24 to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1

    # C. THE TRAP: naming the PUBLISHED port is accepted, listed, and matches
    #    nothing -- the dport is rewritten to the container port before we see
    #    it. This asserts the failure mode so it cannot quietly start "working"
    #    and give people a false mental model.
    sudo ufw allow to 172.21.0.10 port 18090 proto tcp >/dev/null 2>&1
    sudo ufw status | grep -q '18090'          # ufw really did accept it
    [ "$(probe 18090)" = "000" ]               # and it really does nothing
    sudo ufw --force delete allow to 172.21.0.10 port 18090 proto tcp >/dev/null 2>&1

    # D. ufw route targeting a container
    sudo ufw route allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    sudo ufw route delete allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1

    # E. deny one container, leave its neighbour alone
    sudo ufw allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    sudo ufw allow to 172.21.0.11 port 19080 proto tcp >/dev/null 2>&1
    sudo ufw --force delete allow to 172.21.0.11 port 19080 proto tcp >/dev/null 2>&1
    sudo ufw deny to 172.21.0.11 port 19080 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    [ "$(probe 18091)" = "000" ]
    sudo ufw --force delete deny to 172.21.0.11 port 19080 proto tcp >/dev/null 2>&1
    sudo ufw --force delete allow to 172.21.0.10 port 19080 proto tcp >/dev/null 2>&1
    docker rm -f ctgt1 ctgt2 >/dev/null 2>&1 || true
    docker network rm ctgtnet >/dev/null 2>&1 || true
    reinstall
}

@test "destination scopes a rule to the host or to a container, not both" {
    # A host service and a container on the SAME port number. A port-only rule
    # hits both; a destination-qualified rule hits exactly one. This is the
    # property that makes the shared namespace workable, so it is pinned.
    docker rm -f collc >/dev/null 2>&1 || true
    docker network rm collnet >/dev/null 2>&1 || true
    docker network create --subnet 172.23.0.0/24 collnet >/dev/null 2>&1 || skip "172.23.0.0/24 in use"
    docker run -d --name collc --network collnet --ip 172.23.0.10 -p 19100:19101 \
        python:3-alpine python -m http.server 19101 >/dev/null 2>&1
    start_host_listener 19101
    sleep 5
    reinstall

    clr() {
        sudo ufw --force delete allow 19101/tcp >/dev/null 2>&1
        sudo ufw --force delete allow to "$HOST_IP" port 19101 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow to 172.23.0.10 port 19101 proto tcp >/dev/null 2>&1
        sudo ufw reload >/dev/null 2>&1
    }

    clr; [ "$(probe 19101)" = "000" ] && [ "$(probe 19100)" = "000" ]

    clr; sudo ufw allow 19101/tcp >/dev/null 2>&1
    [ "$(probe 19101)" != "000" ]      # port-only: host open
    [ "$(probe 19100)" != "000" ]     # ...and container open too

    clr; sudo ufw allow to "$HOST_IP" port 19101 proto tcp >/dev/null 2>&1
    [ "$(probe 19101)" != "000" ]      # host only
    [ "$(probe 19100)" = "000" ]

    clr; sudo ufw allow to 172.23.0.10 port 19101 proto tcp >/dev/null 2>&1
    [ "$(probe 19101)" = "000" ]       # container only
    [ "$(probe 19100)" != "000" ]

    clr
    stop_host_listeners
    docker rm -f collc >/dev/null 2>&1 || true
    docker network rm collnet >/dev/null 2>&1 || true
    reinstall
}

@test "status names a rule that can never match a remapped container port" {
    # The A2 footgun, caught rather than merely documented: publish 18443:443,
    # write `ufw allow 18443`, and ufw lists a rule that cannot possibly match
    # because DNAT rewrote the port before DOCKER-USER ever saw the packet.
    # That is this project's own failure mode reappearing one layer up.
    docker rm -f remaptest >/dev/null 2>&1 || true
    # 19443, NOT 443. A UISP host publishes 443 from unms-nginx, so a test
    # that writes and then deletes `ufw allow 443/tcp` deletes the rule the
    # operator's web UI depends on. That is not hypothetical: it is how this
    # host's UISP went dark. The container port only has to be a port that is
    # NOT the published one; it has no reason to be a real service's port.
    docker run -d --name remaptest --restart always -p 18443:19443 python:3-alpine \
        python -m http.server 19443 >/dev/null 2>&1
    sleep 5
    reinstall

    # The wrong rule alone: it must say so, and name the right port.
    sudo ufw allow 18443/tcp >/dev/null 2>&1
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'CANNOT match a container'
    echo "$output" | grep -q 'remaptest publishes 18443 -> 19443/tcp'
    echo "$output" | grep -q 'ufw allow 19443/tcp'

    # With the correct rule ALSO present it must go quiet -- a warning that
    # cannot be silenced by doing the right thing is noise, and noise gets
    # ignored along with everything else.
    sudo ufw allow 19443/tcp >/dev/null 2>&1
    run sudo "$REPO/ufw-docker" status
    ! echo "$output" | grep -q 'CANNOT match a container'

    sudo ufw --force delete allow 18443/tcp >/dev/null 2>&1 || true
    sudo ufw --force delete allow 19443/tcp >/dev/null 2>&1 || true
    docker rm -f remaptest >/dev/null 2>&1 || true
    reinstall
}

@test "containers subcommand lists addresses and flags dynamic ones" {
    run sudo "$REPO/ufw-docker" containers
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'NAME'
    echo "$output" | grep -qE '(static|dynamic)'
}

@test "install --dry-run changes absolutely nothing" {
    # The whole value of a dry run is that it is inert. Asserting on the output
    # alone would pass even if it had written the file, so this compares the
    # state on both sides instead.
    local before_rules before_chain before_init
    before_rules=$(sudo md5sum /etc/ufw/after.rules | awk '{print $1}')
    before_chain=$(sudo iptables -S DOCKER-USER)
    before_init=$(sudo md5sum /etc/ufw/before.init 2>/dev/null | awk '{print $1}')

    run sudo "$REPO/ufw-docker" install --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'DRY RUN'
    echo "$output" | grep -q 'would append to /etc/ufw/after.rules'
    echo "$output" | grep -q 'nothing was changed'

    [ "$(sudo md5sum /etc/ufw/after.rules | awk '{print $1}')" = "$before_rules" ]
    [ "$(sudo iptables -S DOCKER-USER)" = "$before_chain" ]
    [ "$(sudo md5sum /etc/ufw/before.init 2>/dev/null | awk '{print $1}')" = "$before_init" ]
}

@test "install parses the stanza before writing it" {
    run sudo "$REPO/ufw-docker" install --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'stanza parses'
}

@test "iptables-restore --test actually rejects a malformed rule" {
    # Pins the mechanism the pre-write check depends on. If a future iptables
    # stopped failing on bad syntax, the check above would silently become a
    # no-op that still prints "stanza parses".
    run sudo bash -c 'printf "*filter\n:TESTCHAIN - [0:0]\n-A TESTCHAIN --bogus\nCOMMIT\n" | iptables-restore --test'
    [ "$status" -ne 0 ]

    # The blind spot: a jump to a chain that does not exist. This is REPORTED,
    # NOT ASSERTED, and that is a correction.
    #
    # It used to assert rc=0 under nf_tables and rc!=0 under legacy, on the
    # strength of measuring one host. Debian 10 disproved it: iptables 1.8.2
    # in nft mode REJECTS the unresolvable jump, exactly as legacy does, so
    # the leg failed on a tool that was behaving perfectly. The rule is not
    # "nft accepts it" -- it is "nft 1.8.9 and 1.8.10 accept it, 1.8.2 does
    # not", which is a property of a version we do not control and must not
    # pin a test to.
    #
    # What matters is the SAFETY claim, and that is asserted on its own below
    # ("the stanza never jumps to a chain it does not declare"). Where --test
    # catches the jump, the pre-write check is simply strictly stronger.
    local backend=nft
    sudo iptables --version 2>/dev/null | grep -q legacy && backend=legacy
    local version; version="$(sudo iptables --version 2>/dev/null | awk '{print $2}')"

    run sudo bash -c 'printf "*filter\n:TESTCHAIN - [0:0]\n-A TESTCHAIN -j NOSUCHCHAIN\nCOMMIT\n" | iptables-restore --test'
    echo "# unresolvable jump: iptables $version/$backend -> rc=$status$([ "$status" -eq 0 ] && echo ' (ACCEPTED - the blind spot is present here)' || echo ' (rejected)')" >&3
}

@test "the stanza never jumps to a chain it does not declare" {
    # THE REAL GUARANTEE, and until now it existed only as a comment claiming
    # the stanza was "safe by construction". A claim nothing checks is a claim
    # that quietly stops being true -- and this one is load-bearing, because
    # `iptables-restore --test` does not reliably catch an unresolvable jump
    # (see above). If that is our only protection, it has to be enforced.
    run sudo "$REPO/ufw-docker" install --dry-run
    [ "$status" -eq 0 ]

    local bad
    bad="$(printf '%s\n' "$output" | strip_ansi_stream | awk '
        # :CHAIN - [0:0]  declares a chain
        /^[[:space:]]*:[^[:space:]]+ /          { d = $1; sub(/^:/, "", d); declared[d] = 1 }
        # -j TARGET  jumps to one
        /^[[:space:]]*-A / {
            for (i = 1; i < NF; i++) if ($i == "-j") jump[$(i+1)] = 1
        }
        END {
            # Targets the kernel always provides. Anything else must have been
            # declared by the stanza itself.
            split("ACCEPT DROP RETURN LOG REJECT QUEUE", std, " ")
            for (i in std) builtin[std[i]] = 1
            for (t in jump) if (!(t in builtin) && !(t in declared)) print t
        }')"

    if [ -n "$bad" ]; then
        echo "# stanza jumps to undeclared chain(s):" >&3
        printf '#   %s\n' $bad >&3
        false
    fi
}

@test "--version reports a version, and the stanza carries the same one" {
    run sudo "$REPO/ufw-docker" --version
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE '^ufw-docker [0-9]+\.[0-9]+\.[0-9]+$'
    local v; v=$(echo "$output" | awk '{print $2}')
    sudo grep -q "Managed by ufw-docker $v" /etc/ufw/after.rules
}

@test "status --rules lists the chains containers are judged by" {
    run sudo "$REPO/ufw-docker" status --rules
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'rules containers are judged by'
    echo "$output" | grep -q 'ufw-user-forward'
    echo "$output" | grep -q 'ufw-user-input'
    # The SSH rule is in ufw-user-input, so it must appear in the listing.
    echo "$output" | grep -q 'dport 22'
}

@test "our logging follows ufw's, and status reports a divergence" {
    sudo ufw logging off >/dev/null 2>&1

    # Installed stanza still logs; ufw no longer does. status must say so
    # rather than leave the operator to find out from an empty log.
    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'ufw logging is OFF but ours is still ON'

    # A fresh stanza matches the new setting.
    run sudo "$REPO/ufw-docker" install --dry-run
    echo "$output" | grep -q 'ufw logging is OFF, so ours is too'
    ! echo "$output" | grep -q 'UFW DOCKER BLOCK'

    sudo ufw logging on >/dev/null 2>&1
    reinstall
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'blocked container traffic is logged'
}

bakcount() { sudo find /etc/ufw -maxdepth 1 -name 'after.rules.ufw-docker-bak-*' | wc -l; }

@test "remove keeps backups by default; --include-backups keeps only the fresh one" {
    # install writes a backup, so there is something to reason about.
    reinstall
    [ "$(bakcount)" -gt 0 ]

    # Default: every backup survives, plus the one this remove just took.
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    [ "$(bakcount)" -gt 1 ]

    # --include-backups deletes the rest but DELIBERATELY keeps the backup taken
    # by this run -- the moment you are undoing a firewall change is the worst
    # moment to also destroy the only copy of what it looked like.
    reinstall
    sudo "$REPO/ufw-docker" remove --force --include-backups >/dev/null 2>&1
    [ "$(bakcount)" -eq 1 ]

    # It also refuses to be destructive without --force.
    run sudo "$REPO/ufw-docker" remove --include-backups
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'pass --force'
    [ "$(bakcount)" -eq 1 ]

    reinstall
    [ "$(jumps)" -gt 0 ]
}

@test "state changes leave an audit trail in syslog" {
    command -v journalctl >/dev/null || skip "no journalctl on this host"
    sudo journalctl -t ufw-docker --no-pager -n 1 >/dev/null 2>&1 || skip "journal not readable"
    reinstall
    sleep 1
    run sudo journalctl -t ufw-docker --since "-2 min" --no-pager
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'install complete and verified'
}

probe6() { sudo HOST_IP="$HOST_IP" "$REPO/tests/netns-probe.sh" get6 "$1" "${2:-http}"; }
v6nets() {
    docker network ls -q 2>/dev/null | while read -r i; do
        docker network inspect "$i" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
    done | tr ' ' '\n' | grep -c ':' || true
}

@test "IPv6: with daemon ip6tables OFF, status says there is nothing to wire" {
    [ "$(v6nets)" -eq 0 ] || skip "Docker has IPv6 networks — this is the ip6tables-ON leg"
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'IPv6: Docker has no v6 networks; nothing to wire'
    # And it must NOT be reported as a fault: a v4-only Docker is a normal host.
    ! echo "$output" | grep -q 'IPv6 is NOT wired'
}

@test "IPv6: ufw governs a v6-published container port exactly as it does v4" {
    [ "$(v6nets)" -gt 0 ] || skip "Docker has no IPv6 networks — daemon ipv6/ip6tables is off"
    reinstall

    # --bind :: is NOT optional. `python -m http.server` binds 0.0.0.0 only, so
    # a v6 probe of it gets a TCP RST -- which returns 000, exactly like a
    # correctly blocked port. That cost a real debugging round: the firewall was
    # working the whole time and the service was not listening.
    docker rm -f v6svc >/dev/null 2>&1 || true
    docker run -d --name v6svc --restart always -p 19200:19200 python:3-alpine \
        python -m http.server 19200 --bind :: >/dev/null 2>&1
    sleep 6
    local cip
    cip=$(docker inspect v6svc --format '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}')
    [ -n "$cip" ]

    # HOST_IP must be passed through: the probe script hard-requires it, and
    # sudo does not forward the environment. Without it this returns empty and
    # the `from <peer>` rules below are silently nonsense.
    local peer; peer=$(sudo HOST_IP="$HOST_IP" "$REPO/tests/netns-probe.sh" peer6)
    [ -n "$peer" ]
    clr6() {
        sudo ufw --force delete allow 19200/tcp >/dev/null 2>&1
        sudo ufw --force delete deny 19200/tcp >/dev/null 2>&1
        sudo ufw --force delete allow to "$cip" port 19200 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow from "$peer" to any port 19200 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow from fd00:99::2 to any port 19200 proto tcp >/dev/null 2>&1
        sudo ufw reload >/dev/null 2>&1
    }

    clr6;  [ "$(probe6 19200)" = "000" ]                       # default deny

    clr6; sudo ufw allow 19200/tcp >/dev/null 2>&1
    [ "$(probe6 19200)" != "000" ]                             # allow opens it

    clr6; sudo ufw deny 19200/tcp >/dev/null 2>&1
    [ "$(probe6 19200)" = "000" ]                              # deny closes it

    clr6; sudo ufw allow to "$cip" port 19200 proto tcp >/dev/null 2>&1
    [ "$(probe6 19200)" != "000" ]                             # per-container v6 dst

    clr6; sudo ufw allow from "$peer" to any port 19200 proto tcp >/dev/null 2>&1
    [ "$(probe6 19200)" != "000" ]                             # source-restricted

    clr6; sudo ufw allow from fd00:99::2 to any port 19200 proto tcp >/dev/null 2>&1
    [ "$(probe6 19200)" = "000" ]                              # ...and a WRONG source

    clr6
    docker rm -f v6svc >/dev/null 2>&1 || true
    reinstall
}

# ── X1 / D4 / D5: the supported-environment preflight ─────────────────────
#
# A stub that makes the preflight fail, by reporting Docker Swarm as active.
# Every other docker call passes straight through.
#
# It used to stub the iptables BACKEND instead, and that broke the moment the
# legacy CI leg went green: legacy became a supported platform, so claiming to
# be legacy no longer made the environment unsupported and these tests started
# asserting against a host that passed. Swarm is the right lever because it is
# orthogonal to the platform matrix -- no row will ever make Swarm supported.
#
# Stubbing is the honest way to test a refusal. Actually switching the host's
# backend mid-suite would strand rules in the other subsystem, which is the
# very thing X1's mixed-backend check exists to catch.
unsup_env() {
    local d="$BATS_FILE_TMPDIR/stub" real
    real="$(command -v docker)"
    mkdir -p "$d"
    cat > "$d/docker" <<STUB
#!/bin/sh
case "\$*" in
  *Swarm.LocalNodeState*) echo active; exit 0 ;;
esac
exec $real "\$@"
STUB
    chmod +x "$d/docker"
    printf '%s' "PATH=$d:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

@test "install REFUSES an unsupported environment, and changes nothing" {
    host_supported || skip "host backend is $(host_backend); this asserts the supported -> unsupported transition"
    local before after
    before="$(sudo md5sum "$AFTER4" | awk '{print $1}')"

    run sudo env "$(unsup_env)" "$REPO/ufw-docker" install
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'UNSUPPORTED ENVIRONMENT'
    echo "$output" | grep -q 'swarm' 
    # It must say how to proceed, or the refusal is just a wall.
    echo "$output" | grep -q -- '--unsupported --force'

    after="$(sudo md5sum "$AFTER4" | awk '{print $1}')"
    [ "$before" = "$after" ]        # a refusal that edited the file is not a refusal
}

@test "--unsupported ALONE still refuses; it takes both flags" {
    host_supported || skip "host backend is $(host_backend); this asserts a refusal from a clean, supported baseline"
    # One flag is something you can paste from a forum post without reading it.
    run sudo env "$(unsup_env)" "$REPO/ufw-docker" install --unsupported
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'alone is not enough'
    # `cmd && false || true` is ALWAYS TRUE -- when cmd succeeds, `false`
    # runs and `|| true` swallows it; when cmd fails, `||` runs `true`. This
    # assertion was vacuous in both directions for its whole life. `! cmd` is
    # the form that can fail.
    ! sudo grep -q 'INSTALLED IN UNSUPPORTED MODE' "$AFTER4"
}

@test "--unsupported --force installs, and says so FOREVER afterwards" {
    host_supported || skip "host backend is $(host_backend); this asserts the marker appearing and then clearing"
    run sudo env "$(unsup_env)" "$REPO/ufw-docker" install --unsupported --force
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'PROCEEDING ANYWAY'

    # Recorded in the stanza, so it outlives the shell that typed --force.
    sudo grep -q 'INSTALLED IN UNSUPPORTED MODE: swarm' "$AFTER4"

    # And reported by status even though the environment now PASSES the
    # preflight -- the person reading status is rarely the person who forced it.
    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'INSTALLED IN UNSUPPORTED MODE'

    # The grading rule, which is the subtle part. On the SAME unsupported
    # environment, an accepted host WARNS and still exits 0 -- because an exit
    # code that is permanently 1 is an exit code nobody reads, and then the
    # real fault arrives unnoticed. The not-accepted case is asserted
    # separately below and must still be rc=1.
    run sudo env "$(unsup_env)" "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'accepted at install time'

    # A clean reinstall clears it -- but only where a clean install is possible.
    # On the legacy leg reinstall must itself pass --unsupported --force, so the
    # marker correctly stays.
    reinstall
    if host_supported; then
        run sudo "$REPO/ufw-docker" status
        ! echo "$output" | grep -q 'INSTALLED IN UNSUPPORTED MODE'
    fi
}

@test "status --json is valid JSON and reports the preflight verdict" {
    host_supported || skip "host backend is $(host_backend); this asserts the supported case"
    run sudo "$REPO/ufw-docker" status --json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -m json.tool >/dev/null

    printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d["supported"] is True, d["supported"]
assert d["installed"] is True, d["installed"]
assert d["preflight_failed"] == [], d["preflight_failed"]
assert d["ufw_paths_derived"] is True, "D5: paths should derive from ufw.common"
assert any(c["key"] == "wired-v4" for c in d["checks"]), "missing wired-v4"
assert all("\033" not in c["message"] for c in d["checks"]), "colour leaked into JSON"
'
}

@test "status --json reports an unsupported environment as machine-readable" {
    # NOT accepted: this host was installed cleanly and the backend changed
    # underneath it, which is a fault rather than a known risk. That premise
    # needs a clean install, which the legacy leg cannot give us.
    host_supported || skip "host backend is $(host_backend); needs a clean (unforced) install"
    reinstall
    run sudo env "$(unsup_env)" "$REPO/ufw-docker" status --json
    [ "$status" -eq 1 ]            # non-zero is what monitoring gates on
    printf '%s' "$output" | python3 -c '
import json,sys
d = json.load(sys.stdin)
assert d["healthy"] is False
assert d["supported"] is False
assert d["preflight_failed"] == ["swarm"], d["preflight_failed"]
'
}

@test "D5: ufw paths are derived from ufw itself, not hardcoded" {
    host_supported || skip "host backend is $(host_backend); this asserts the supported case"
    # The value of deriving is that a wrong path fails LOUDLY. Prove the
    # derivation actually ran and landed somewhere real, rather than silently
    # falling back to the Debian default and happening to be right.
    run sudo "$REPO/ufw-docker" status --json
    [ "$status" -eq 0 ]
    local dir
    dir="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ufw_dir"])')"
    [ -d "$dir" ]
    [ -f "$dir/after.rules" ]
    # and it agrees with what ufw's own module says
    local want
    want="$(python3 -c 'import ufw.common as c; print(c.config_dir + "/ufw")')"
    [ "$dir" = "$want" ]
}

@test "status names a blanket SSH ACCEPT that ufw did not create" {
    # B6. An older `rescue` inserted exactly this and, when ufw came back
    # without its own SSH rule, left it in place -- permanently widening a
    # host whose SSH was meant to be restricted, with nothing ever mentioning
    # it again. The behaviour is gone; the rules it already left are not.
    run sudo "$REPO/ufw-docker" status
    ! echo "$output" | grep -q 'blanket SSH ACCEPT'

    sudo iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT
    run sudo "$REPO/ufw-docker" status
    sudo iptables -D INPUT -p tcp --dport 22 -j ACCEPT    # before any assertion
    echo "$output" | grep -q 'blanket SSH ACCEPT'
    echo "$output" | grep -q 'outside'

    run sudo "$REPO/ufw-docker" status
    ! echo "$output" | grep -q 'blanket SSH ACCEPT'
}

@test "rescue replays an interface-scoped SSH rule instead of inventing one" {
    # The regression test for the live bug: ufw permits SSH only via an
    # interface, so there is no --dport 22 rule anywhere. rescue must NOT
    # conclude "no SSH rule" and open the port to the world.
    sudo ufw allow in on lo >/dev/null 2>&1

    run sudo "$REPO/ufw-docker" rescue
    sudo ufw --force delete allow in on lo >/dev/null 2>&1
    reinstall

    [ "$status" -eq 0 ]
    # It found a permitting rule...
    echo "$output" | grep -q 'replayed your own rule'
    # ...and did not invent anything.
    ! echo "$output" | grep -q 'NOT inventing one'
    ! echo "$output" | grep -qi 'BLANKET ACCEPT'
}

@test "status --counters shows DOCKER-USER traffic, and does not cry about zeroes" {
    run sudo "$REPO/ufw-docker" status --counters
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'DOCKER-USER counters'
    echo "$output" | grep -q 'ufw-user-input'
    # A flat counter is a normal host, not a fault. If this ever starts
    # warning, it will be ignored along with everything else this prints.
    ! echo "$output" | grep -qiE 'WARN.*counter|counter.*(suspicious|problem)'
    echo "$output" | grep -q 'not evidence of a problem'
}

@test "remove says it leaves the binary, and --purge needs --force" {
    # The preview exists to answer "what remains?", and it never mentioned the
    # one thing that always did.
    run sudo "$REPO/ufw-docker" remove
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "itself"
    echo "$output" | grep -q -- '--purge --force'

    run sudo "$REPO/ufw-docker" remove --purge
    [ "$status" -ne 0 ]
    echo "$output" | grep -q -- '--purge deletes this binary'
    # and it changed nothing
    sudo grep -q 'BEGIN DOCKER-UFW' "$AFTER4"
}

@test "containers lists host-network containers separately, not as unsupported" {
    # A7. They have no address of their own, so container_rows drops them and
    # the operator cannot see the thing they cannot target.
    docker rm -f hostnetsvc >/dev/null 2>&1 || true
    docker run -d --name hostnetsvc --network host python:3-alpine \
        python -m http.server 19400 >/dev/null 2>&1
    sleep 3

    run sudo "$REPO/ufw-docker" containers
    docker rm -f hostnetsvc >/dev/null 2>&1 || true

    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'hostnetsvc'
    echo "$output" | grep -q 'HOST network'
    # The VOCABULARY matters as much as the detection. These are correctly
    # governed by ordinary ufw rules, so calling them "unsupported" would
    # spend a word we need for Swarm and rootless on something harmless.
    ! echo "$output" | grep -qi 'unsupported'
    echo "$output" | grep -qi 'ordinary ufw rules'
}

@test "each subcommand explains its OWN flags, without root" {
    # D3. `remove --help` used to print the global block, which lists every
    # subcommand and explains none of their flags -- so the one question it
    # was asked was the one it would not answer.
    run "$REPO/ufw-docker" remove --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q -- '--include-backups'
    echo "$output" | grep -q -- '--purge'
    # ...and NOT the global block
    ! echo "$output" | grep -q 'ufw-docker rescue --open'

    # Routed from the dispatcher so it works without sudo. Refusing to explain
    # a flag until you are root is a small, daily, pointless obstruction.
    [ "$(id -u)" -ne 0 ] || skip "running as root; cannot prove the non-root path here"
}

@test "every dispatchable subcommand has its own help" {
    local sub
    for sub in install remove status rescue containers platforms selfheal; do
        run "$REPO/ufw-docker" "$sub" --help
        [ "$status" -eq 0 ] || { echo "no help for $sub" >&3; return 1; }
        echo "$output" | grep -q "ufw-docker $sub" \
            || { echo "help for $sub does not name it" >&3; return 1; }
    done
}

@test "an ORPHANED DOCKER-USER is reported, not called wired" {
    # THE FALSE GREEN. Everything else in this suite asks what is INSIDE
    # DOCKER-USER. Nothing asked whether a packet ever gets there -- so a host
    # with no `-A FORWARD -j DOCKER-USER` had a byte-perfect stanza, three
    # jumps into ufw-user-input, a green `status`, and zero filtering.
    #
    # Real trigger: `"iptables": false` in daemon.json, or a third-party
    # firewall rebuilding FORWARD.
    reinstall
    [ "$(jumps)" -gt 0 ]                      # wired, by the old definition

    echo yes > "$BATS_FILE_TMPDIR/restore-forward-jump"
    sudo iptables -D FORWARD -j DOCKER-USER

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 1 ]                        # must go RED, not merely warn
    echo "$output" | grep -q 'NOT reached from FORWARD'
    # ...and it must still be able to say the chain itself is intact, so the
    # operator can tell "orphaned" from "unwired" -- different fixes.
    echo "$output" | grep -q 'IPv4 wired'

    sudo iptables -I FORWARD 1 -j DOCKER-USER
    rm -f "$BATS_FILE_TMPDIR/restore-forward-jump"
    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
}

@test "selfheal says UNWIRED when the stanza is gone, even with nothing to repair" {
    # The unit used to report "ufw healthy at boot" here. Its whole job is to
    # notice an unfiltered host, and this is one: ufw is genuinely fine, the
    # stanza is simply absent. after.rules is a dpkg conffile, so an ufw
    # package upgrade can do exactly this.
    reinstall
    local saved="$BATS_FILE_TMPDIR/after4.stanza-test"
    sudo cp -a "$AFTER4" "$saved"
    echo "$saved" > "$BATS_FILE_TMPDIR/restore-stanza"

    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    # The marker is 'BEGIN DOCKER-UFW', not 'BEGIN UFW-DOCKER'. This line had
    # the two halves transposed, so the grep could never match and the `!`
    # made it true unconditionally -- a negative assertion that passed whether
    # the stanza was there or not. Found when three new leg phases copied the
    # same wrong string and refused to run.
    ! sudo grep -q 'BEGIN DOCKER-UFW' "$AFTER4"          # genuinely gone

    local mark; mark=$(date +%s)
    sudo SELFHEAL_DELAY=0 "$REPO/ufw-docker" selfheal
    run sudo journalctl -t ufw-docker-selfheal --since "@$mark" --no-pager
    echo "$output" | grep -q 'UNWIRED'
    echo "$output" | grep -vq 'ufw healthy at boot'

    sudo cp -a "$saved" "$AFTER4"
    rm -f "$saved" "$BATS_FILE_TMPDIR/restore-stanza"
    reinstall
}

@test "a macvlan network is EXCLUDED from the stanza and named in status" {
    # subnets() used to take every network regardless of driver. A macvlan on
    # a real LAN would then put `-d <LAN> -j ufw-user-input` and
    # `-s <LAN> -j RETURN` at the very top of FORWARD -- judging and exempting
    # an entire real network whose traffic never reaches DOCKER-USER anyway.
    #
    # A dummy parent, so this touches no real interface.
    sudo ip link add ufwdummy0 type dummy 2>/dev/null || skip "cannot create a dummy interface here"
    echo yes > "$BATS_FILE_TMPDIR/restore-dummy-net"
    sudo ip link set ufwdummy0 up
    sudo docker network create -d macvlan -o parent=ufwdummy0 \
        --subnet 192.168.237.0/24 ufwmacvlan >/dev/null 2>&1 \
        || skip "macvlan networks are not creatable here"

    run sudo "$REPO/ufw-docker" install --dry-run $(install_args)
    [ "$status" -eq 0 ]
    # The subnet must appear NOWHERE in the stanza we would write.
    ! echo "$output" | grep -q '192.168.237.0/24'

    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'does NOT govern'
    echo "$output" | grep -q 'ufwmacvlan'

    sudo docker network rm ufwmacvlan >/dev/null 2>&1 || true
    sudo ip link del ufwdummy0 >/dev/null 2>&1 || true
    rm -f "$BATS_FILE_TMPDIR/restore-dummy-net"
}

@test "a default-ALLOW-incoming host is warned that containers are still default-deny" {
    # Installing here takes every published port from open to closed, because
    # our jump enters ufw-user-input directly and ufw keeps the default policy
    # on the built-in chain. That is an outage caused by the install, so it
    # has to be said out loud before and after.
    echo yes > "$BATS_FILE_TMPDIR/restore-default-incoming"
    sudo ufw default allow incoming >/dev/null 2>&1

    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'default incoming policy is ALLOW'
    echo "$output" | grep -q 'default-DENY'

    run sudo "$REPO/ufw-docker" install --dry-run $(install_args)
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'will be DROPPED for containers'

    sudo ufw default deny incoming >/dev/null 2>&1
    rm -f "$BATS_FILE_TMPDIR/restore-default-incoming"
    run sudo "$REPO/ufw-docker" status
    ! echo "$output" | grep -q 'default incoming policy is ALLOW'
}

@test "remove returns DOCKER-USER to stock" {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    [ "$(jumps)" -eq 0 ]
    [ "$(active)" -eq 1 ]
    [ "$(ssh_rule)" -gt 0 ]
}

@test "a self-heal unit that cannot run is RED, not a green firewall" {
    # THE THIRD FALSE GREEN, found by restarting a leg container's init.
    #
    # `install` warns once if the binary is not at the path the unit names, and
    # then nothing mentioned it again. Such a host printed every check green --
    # including "DOCKER-USER is reached from FORWARD" -- while the unit went
    # `failed` at every boot and DOCKER-USER was left at 0 jumps.
    #
    # The firewall is not broken in this state. The thing that REPAIRS it
    # unattended is, which is only discovered on the boot where it was needed.
    reinstall
    local unit=/etc/systemd/system/ufw-docker-selfheal.service
    [ -f "$unit" ]

    local saved="$BATS_FILE_TMPDIR/selfheal.unit"
    sudo cp -a "$unit" "$saved"
    echo "$saved" > "$BATS_FILE_TMPDIR/restore-selfheal-unit"

    sudo sed -i 's|^ExecStart=.*|ExecStart=/usr/local/sbin/ufw-docker-absent selfheal|' "$unit"
    sudo systemctl daemon-reload

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 1 ]                       # RED: the recovery path is dead
    echo "$output" | grep -q 'ufw-docker-absent'
    echo "$output" | grep -q 'NOT executable'
    # It must still say the firewall itself is fine, so the operator can tell
    # "unfiltered now" from "unrecoverable later" -- very different urgencies.
    echo "$output" | grep -q 'DOCKER-USER is reached from FORWARD'

    sudo cp -a "$saved" "$unit"
    sudo systemctl daemon-reload
    rm -f "$saved" "$BATS_FILE_TMPDIR/restore-selfheal-unit"

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'self-heal unit enabled'
}

@test "a self-heal unit left behind but disabled is reported, not assumed to run" {
    # Half-removed is the state that lies: the unit file is present, so
    # everything LOOKS configured, and `systemctl disable` means it never runs.
    # Either enable it or remove it -- what must not happen is a host that
    # believes it has unattended recovery and does not.
    reinstall
    local unit=/etc/systemd/system/ufw-docker-selfheal.service
    local saved="$BATS_FILE_TMPDIR/selfheal.unit.disabled"
    sudo cp -a "$unit" "$saved"
    echo "$saved" > "$BATS_FILE_TMPDIR/restore-selfheal-unit"

    sudo systemctl disable ufw-docker-selfheal.service >/dev/null 2>&1
    [ "$(systemctl is-enabled ufw-docker-selfheal.service 2>&1)" != enabled ]

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'NOT enabled'

    sudo systemctl enable ufw-docker-selfheal.service >/dev/null 2>&1
    rm -f "$saved" "$BATS_FILE_TMPDIR/restore-selfheal-unit"
    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
}

# ── upgrading over an existing stanza ──────────────────────────────────────
# Nothing tested this, and it is the single most common thing that will ever
# happen to a deployed host: a newer `ufw-docker` run over a firewall an older
# one already wired. Every production box gets here eventually; none of them
# get there through a clean install.
#
# The hazard is specific. `strip_stanza` deletes by MARKER, so an upgrade is
# "remove whatever is between the markers, append the new one". If that ever
# half-works the result is two stanzas, or an orphaned rule from the old one
# still being applied -- and in both cases `install` prints success.

old_stanza_into_after4() {   # $1 = version string to claim
    # A stanza shaped like one an older release wrote: same markers (that is
    # what makes it ours to replace), an older version line, and one rule the
    # current generator would never emit. That last line is the probe -- it is
    # how we tell "replaced" from "appended alongside".
    sudo tee -a "$AFTER4" >/dev/null <<EOF
# BEGIN DOCKER-UFW
# Managed by ufw-docker $1. Do not edit; re-run 'install'.
*filter
:ufw-user-input - [0:0]
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -s 192.0.2.0/24 -j RETURN
-A DOCKER-USER -d 192.0.2.0/24 -j ufw-user-input
-A DOCKER-USER -j RETURN
COMMIT
# END DOCKER-UFW
EOF
}

# `grep -c` PRINTS 0 and EXITS 1 on no match, so the obvious
# `grep -c ... || echo 0` emits "0\n0" and every `-eq` against it dies with
# "integer expression expected". This file's own CLAUDE.md documents that trap
# and it was walked into anyway -- caught here by a test that failed loudly
# rather than one that quietly compared the wrong thing.
#
# awk has one exit status and one line of output, which is the whole reason to
# prefer it. The -f guard keeps the missing-file case to a single path too.
stanza_count() {
    sudo test -f "$AFTER4" || { echo 0; return 0; }
    sudo awk '/^# BEGIN DOCKER-UFW$/ { n++ } END { print n + 0 }' "$AFTER4"
}

@test "install over an older version's stanza leaves exactly ONE stanza" {
    reinstall
    # Start from a known-clean single stanza, then plant an older one after it
    # so the file genuinely has two -- the state an append-only bug produces.
    sudo sed -i "/^# BEGIN DOCKER-UFW\$/,/^# END DOCKER-UFW\$/d" "$AFTER4"
    [ "$(stanza_count)" -eq 0 ]
    old_stanza_into_after4 "0.0.1-ancient"
    [ "$(stanza_count)" -eq 1 ]

    run sudo "$REPO/ufw-docker" install $(install_args)
    [ "$status" -eq 0 ]

    # ONE stanza, and its markers are balanced.
    [ "$(stanza_count)" -eq 1 ]
    [ "$(sudo grep -c '^# END DOCKER-UFW$' "$AFTER4")" -eq 1 ]

    # The old version line is gone and the current one is there.
    local ver; ver="$(grep '^VERSION=' "$REPO/ufw-docker" | cut -d'"' -f2)"
    ! sudo grep -q '0.0.1-ancient' "$AFTER4"
    sudo grep -q "Managed by ufw-docker $ver" "$AFTER4"
}

@test "an older stanza's rules do not survive the upgrade" {
    # The probe rule from the planted stanza names 192.0.2.0/24 (TEST-NET-1),
    # which no Docker bridge will ever use -- so if it is still in the file
    # after the upgrade, the old stanza was appended to rather than replaced.
    reinstall
    sudo sed -i "/^# BEGIN DOCKER-UFW\$/,/^# END DOCKER-UFW\$/d" "$AFTER4"
    old_stanza_into_after4 "0.0.1-ancient"
    sudo grep -q '192.0.2.0/24' "$AFTER4"          # planted, and present

    run sudo "$REPO/ufw-docker" install $(install_args)
    [ "$status" -eq 0 ]

    ! sudo grep -q '192.0.2.0/24' "$AFTER4"        # gone from the file
    # And gone from the live chain, which is the half that actually filters.
    ! sudo iptables -S DOCKER-USER | grep -q '192.0.2.0/24'
}

@test "upgrading does not accumulate DOCKER-USER jumps" {
    # Three installs in a row. The jump count must be identical each time:
    # a stanza appended rather than replaced would double it, and the host
    # would still look healthy because MORE jumps is not an error condition
    # anything checks for.
    reinstall
    local a b c
    a=$(jumps)
    reinstall; b=$(jumps)
    reinstall; c=$(jumps)
    [ "$a" -gt 0 ]
    [ "$a" -eq "$b" ]
    [ "$b" -eq "$c" ]
}

@test "install over the PREVIOUS revision of this tool, not a synthetic one" {
    # The tests above plant a stanza we wrote by hand, which proves the marker
    # logic but assumes the old format was what we think it was. This runs the
    # actual previous revision of the file out of git, so the "before" state is
    # one that genuinely existed.
    #
    # Dynamic rather than a pinned SHA: "the revision before this one" is both
    # the realistic upgrade and a target that stays correct as history grows.
    local old="$BATS_TEST_TMPDIR/ufw-docker-prev" prev
    prev="$(cd "$REPO" && git log --format=%H -- ufw-docker 2>/dev/null | sed -n '2p')"
    if [ -n "$prev" ]; then
        (cd "$REPO" && git show "$prev:ufw-docker") > "$old" 2>/dev/null \
            || skip "could not read $prev:ufw-docker"
    elif [ -s "$REPO/tests/.prev-ufw-docker" ]; then
        # A distro leg gets tracked files only, with no .git -- so
        # container-leg.sh drops the previous revision here instead. Without
        # this branch the test skipped on all ten legs and ran only on the
        # five native ones, quietly.
        cp "$REPO/tests/.prev-ufw-docker" "$old"
    else
        skip "no previous revision available (shallow clone, and no .prev-ufw-docker)"
    fi
    chmod +x "$old"

    # The old revision installs, or this test has nothing to upgrade FROM.
    # Skip rather than fail: an old revision refusing this host is a fact about
    # that revision, not a regression in the current one.
    run sudo "$old" install $(install_args)
    [ "$status" -eq 0 ] || skip "the previous revision does not install here (rc=$status)"
    [ "$(stanza_count)" -eq 1 ]

    # Now the upgrade.
    run sudo "$REPO/ufw-docker" install $(install_args)
    [ "$status" -eq 0 ]
    [ "$(stanza_count)" -eq 1 ]

    local ver; ver="$(grep '^VERSION=' "$REPO/ufw-docker" | cut -d'"' -f2)"
    sudo grep -q "Managed by ufw-docker $ver" "$AFTER4"

    # And the host is healthy afterwards -- an upgrade that leaves a green
    # file and a red firewall is the failure worth catching.
    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'IPv4 wired'
}

# ── ufw's own IPv6 switch ──────────────────────────────────────────────────

@test "ufw with IPV6=no is reported as the CAUSE, not just 'not wired'" {
    # Only meaningful where Docker actually has v6 networks -- otherwise there
    # is no v6 stanza to be dead, and `status` correctly says so. That makes
    # this an ipv6=true-leg test; skipping elsewhere is honest, not a gap.
    sudo docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
        | grep -q ':' || skip "Docker has no IPv6 networks on this leg"

    reinstall
    local defaults=/etc/default/ufw
    [ -f "$defaults" ] || skip "no $defaults on this host"
    local saved="$BATS_FILE_TMPDIR/ufw-defaults.saved"
    sudo cp -a "$defaults" "$saved"
    echo "$saved" > "$BATS_FILE_TMPDIR/restore-ufw-defaults"

    sudo sed -i 's/^IPV6=.*/IPV6=no/' "$defaults"
    sudo grep -q '^IPV6=no' "$defaults"

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'IPV6=no'
    echo "$output" | grep -q 'UNFILTERED'
    # It must still be specific about WHY re-running install will not help.
    echo "$output" | grep -q 'never loads'

    sudo cp -a "$saved" "$defaults"
    rm -f "$saved" "$BATS_FILE_TMPDIR/restore-ufw-defaults"

    run sudo "$REPO/ufw-docker" status
    [ "$status" -eq 0 ]
}
