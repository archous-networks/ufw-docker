#!/usr/bin/env bats
#
# These tests MUTATE THE LIVE FIREWALL of the machine they run on. Run them on a
# disposable VM or in CI, never on anything you care about.
#
# teardown_file always runs `ufw-docker rescue`, so a failing test cannot leave the host
# unreachable -- that is the single most important property of this suite.

REPO="${BATS_TEST_DIRNAME}/.."
HOST_IP="${HOST_IP:?set HOST_IP to the primary address of this host}"

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
ensure_service() {
    local port="${1:-8089}" i
    for i in $(seq 1 10); do
        curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null && return 0
        # Bring back anything a daemon restart stopped.
        docker start testsvc >/dev/null 2>&1 || true
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
reinstall() {
    local out rc
    out=$(sudo "$REPO/ufw-docker" install 2>&1); rc=$?
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
    sudo ufw delete allow 8089/tcp >/dev/null 2>&1 || true
    sudo ufw delete deny  8089/tcp >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 8089)" = "000" ]
}

@test "ufw allow opens a Docker-published port" {
    ensure_service 8089 || skip "nothing listening on 8089"
    sudo ufw allow 8089/tcp >/dev/null 2>&1
    [ "$(probe 8089)" != "000" ]
}

@test "ufw deny closes a Docker-published port" {
    sudo ufw delete allow 8089/tcp >/dev/null 2>&1
    sudo ufw deny 8089/tcp >/dev/null 2>&1
    [ "$(probe 8089)" = "000" ]
    sudo ufw delete deny 8089/tcp >/dev/null 2>&1
}

@test "source-restricted allow is honoured" {
    ensure_service 8089 || skip "nothing listening on 8089"
    sudo ufw allow from 10.97.0.0/24 to any port 8089 proto tcp >/dev/null 2>&1
    [ "$(probe 8089)" != "000" ]
    sudo ufw delete allow from 10.97.0.0/24 to any port 8089 proto tcp >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 8089)" = "000" ]
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
    [ -d /home/unms/app ] || skip "no UISP install here"
    ( cd /home/unms/app && sudo -u unms docker compose -p unms up -d --force-recreate ucrm >/dev/null 2>&1 )
    sleep 8
    [ "$(jumps)" -gt 0 ]
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
    local port=9300
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
    ensure_service 8089 || skip "nothing listening on 8089"
    # Before this was wired, `ufw route allow` -- the verb ufw intends for
    # forwarded traffic -- was ignored entirely, with no warning.
    sudo ufw route allow to any port 8089 proto tcp >/dev/null 2>&1
    [ "$(probe 8089)" != "000" ]
    sudo ufw route delete allow to any port 8089 proto tcp >/dev/null 2>&1
    sudo ufw reload >/dev/null 2>&1
    [ "$(probe 8089)" = "000" ]
}

@test "blocked container traffic is logged" {
    ensure_service 8089 || skip "nothing listening on 8089"
    # The LOG rule is rate-limited to 3/min with a burst of 10 -- the same limit
    # ufw uses. Earlier tests in this file generate blocks and drain that burst,
    # so a single probe can legitimately produce no line. Poll instead: at
    # 3/min a token frees up every 20s, so a minute is ample.
    sudo ufw delete allow 8089/tcp >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    local mark; mark=$(date +%s)
    local i
    for i in $(seq 1 12); do
        probe 8089 >/dev/null
        sleep 5
        if sudo journalctl -k --since "@$mark" --no-pager 2>/dev/null | grep -q 'UFW DOCKER BLOCK'; then
            return 0
        fi
    done
    echo "no [UFW DOCKER BLOCK] line in 60s" >&2
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
    sudo cp -a /etc/ufw/before.init "$saved"
    printf '#!/bin/sh\n# operator hook\nexit 0\n' | sudo tee /etc/ufw/before.init >/dev/null
    sudo chmod 0750 /etc/ufw/before.init
    run sudo "$REPO/ufw-docker" install
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'customised'
    sudo grep -q 'operator hook' /etc/ufw/before.init     # untouched
    sudo cp -a "$saved" /etc/ufw/before.init; rm -f "$saved"
    reinstall
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
    if ! docker network create --subnet 172.21.0.0/24 ctgtnet >/dev/null 2>&1; then
        echo "could not create ctgtnet - is 172.21.0.0/24 already used by:" >&2
        docker network ls -q | while read -r n; do
            docker network inspect "$n" --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null
        done | grep '172.21' >&2
        return 1
    fi
    docker run -d --name ctgt1 --network ctgtnet --ip 172.21.0.10 -p 18090:80 \
        python:3-alpine python -m http.server 80 >/dev/null 2>&1
    docker run -d --name ctgt2 --network ctgtnet --ip 172.21.0.11 -p 18091:80 \
        python:3-alpine python -m http.server 80 >/dev/null 2>&1
    sleep 6
    reinstall    # pick up the new subnet

    [ "$(probe 18090)" = "000" ]
    [ "$(probe 18091)" = "000" ]

    # A. destination only
    sudo ufw allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]      # the targeted container opens
    [ "$(probe 18091)" = "000" ]       # its neighbour on the same port does not
    sudo ufw --force delete allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1

    # B. source AND destination compose
    sudo ufw allow from 10.97.0.0/24 to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    sudo ufw --force delete allow from 10.97.0.0/24 to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1

    # B2. a source that does NOT match must stay closed
    sudo ufw allow from 10.98.0.0/24 to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" = "000" ]
    sudo ufw --force delete allow from 10.98.0.0/24 to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1

    # C. THE TRAP: naming the PUBLISHED port is accepted, listed, and matches
    #    nothing -- the dport is rewritten to the container port before we see
    #    it. This asserts the failure mode so it cannot quietly start "working"
    #    and give people a false mental model.
    sudo ufw allow to 172.21.0.10 port 18090 proto tcp >/dev/null 2>&1
    sudo ufw status | grep -q '18090'          # ufw really did accept it
    [ "$(probe 18090)" = "000" ]               # and it really does nothing
    sudo ufw --force delete allow to 172.21.0.10 port 18090 proto tcp >/dev/null 2>&1

    # D. ufw route targeting a container
    sudo ufw route allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    sudo ufw route delete allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1

    # E. deny one container, leave its neighbour alone
    sudo ufw allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
    sudo ufw allow to 172.21.0.11 port 80 proto tcp >/dev/null 2>&1
    sudo ufw --force delete allow to 172.21.0.11 port 80 proto tcp >/dev/null 2>&1
    sudo ufw deny to 172.21.0.11 port 80 proto tcp >/dev/null 2>&1
    [ "$(probe 18090)" != "000" ]
    [ "$(probe 18091)" = "000" ]
    sudo ufw --force delete deny to 172.21.0.11 port 80 proto tcp >/dev/null 2>&1
    sudo ufw --force delete allow to 172.21.0.10 port 80 proto tcp >/dev/null 2>&1
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
    docker run -d --name collc --network collnet --ip 172.23.0.10 -p 19100:9100 \
        python:3-alpine python -m http.server 9100 >/dev/null 2>&1
    start_host_listener 9100
    sleep 5
    reinstall

    clr() {
        sudo ufw --force delete allow 9100/tcp >/dev/null 2>&1
        sudo ufw --force delete allow to "$HOST_IP" port 9100 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow to 172.23.0.10 port 9100 proto tcp >/dev/null 2>&1
        sudo ufw reload >/dev/null 2>&1
    }

    clr; [ "$(probe 9100)" = "000" ] && [ "$(probe 19100)" = "000" ]

    clr; sudo ufw allow 9100/tcp >/dev/null 2>&1
    [ "$(probe 9100)" != "000" ]      # port-only: host open
    [ "$(probe 19100)" != "000" ]     # ...and container open too

    clr; sudo ufw allow to "$HOST_IP" port 9100 proto tcp >/dev/null 2>&1
    [ "$(probe 9100)" != "000" ]      # host only
    [ "$(probe 19100)" = "000" ]

    clr; sudo ufw allow to 172.23.0.10 port 9100 proto tcp >/dev/null 2>&1
    [ "$(probe 9100)" = "000" ]       # container only
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
    docker run -d --name remaptest --restart always -p 18443:443 python:3-alpine \
        python -m http.server 443 >/dev/null 2>&1
    sleep 5
    reinstall

    # The wrong rule alone: it must say so, and name the right port.
    sudo ufw allow 18443/tcp >/dev/null 2>&1
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'CANNOT match a container'
    echo "$output" | grep -q 'remaptest publishes 18443 -> 443/tcp'
    echo "$output" | grep -q 'ufw allow 443/tcp'

    # With the correct rule ALSO present it must go quiet -- a warning that
    # cannot be silenced by doing the right thing is noise, and noise gets
    # ignored along with everything else.
    sudo ufw allow 443/tcp >/dev/null 2>&1
    run sudo "$REPO/ufw-docker" status
    ! echo "$output" | grep -q 'CANNOT match a container'

    sudo ufw --force delete allow 18443/tcp >/dev/null 2>&1 || true
    sudo ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
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

    # The blind spot, which is BACKEND-DEPENDENT. A jump to a chain that does
    # not exist passes --test under nf_tables (rc=0) and is rejected under
    # legacy xtables. Asserted per backend rather than hardcoding one, so the
    # difference is a recorded property instead of something the legacy CI leg
    # trips over.
    #
    # Either way the stanza is safe by construction: it declares every chain it
    # jumps to. Under legacy the pre-write check is simply strictly stronger.
    local backend=nft
    sudo iptables --version 2>/dev/null | grep -q legacy && backend=legacy
    echo "# iptables backend: $backend" >&3

    run sudo bash -c 'printf "*filter\n:TESTCHAIN - [0:0]\n-A TESTCHAIN -j NOSUCHCHAIN\nCOMMIT\n" | iptables-restore --test'
    if [ "$backend" = legacy ]; then
        [ "$status" -ne 0 ]
    else
        [ "$status" -eq 0 ]
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
    docker run -d --name v6svc --restart always -p 9200:9200 python:3-alpine \
        python -m http.server 9200 --bind :: >/dev/null 2>&1
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
        sudo ufw --force delete allow 9200/tcp >/dev/null 2>&1
        sudo ufw --force delete deny 9200/tcp >/dev/null 2>&1
        sudo ufw --force delete allow to "$cip" port 9200 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow from "$peer" to any port 9200 proto tcp >/dev/null 2>&1
        sudo ufw --force delete allow from fd00:99::2 to any port 9200 proto tcp >/dev/null 2>&1
        sudo ufw reload >/dev/null 2>&1
    }

    clr6;  [ "$(probe6 9200)" = "000" ]                       # default deny

    clr6; sudo ufw allow 9200/tcp >/dev/null 2>&1
    [ "$(probe6 9200)" != "000" ]                             # allow opens it

    clr6; sudo ufw deny 9200/tcp >/dev/null 2>&1
    [ "$(probe6 9200)" = "000" ]                              # deny closes it

    clr6; sudo ufw allow to "$cip" port 9200 proto tcp >/dev/null 2>&1
    [ "$(probe6 9200)" != "000" ]                             # per-container v6 dst

    clr6; sudo ufw allow from "$peer" to any port 9200 proto tcp >/dev/null 2>&1
    [ "$(probe6 9200)" != "000" ]                             # source-restricted

    clr6; sudo ufw allow from fd00:99::2 to any port 9200 proto tcp >/dev/null 2>&1
    [ "$(probe6 9200)" = "000" ]                              # ...and a WRONG source

    clr6
    docker rm -f v6svc >/dev/null 2>&1 || true
    reinstall
}

@test "remove returns DOCKER-USER to stock" {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    [ "$(jumps)" -eq 0 ]
    [ "$(active)" -eq 1 ]
    [ "$(ssh_rule)" -gt 0 ]
}
