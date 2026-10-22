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
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1
}

teardown_file() {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1 || true
    # Remove the blanket SSH allow ONLY if we added it. Leaving one behind would
    # widen the operator's exposure; deleting one we were given breaks whatever
    # put it there.
    if [ "$(cat "$BATS_FILE_TMPDIR/we-added-ssh" 2>/dev/null)" = yes ]; then
        sudo ufw delete allow 22/tcp >/dev/null 2>&1 || true
    fi
    sudo HOST_IP="$HOST_IP" "${BATS_TEST_DIRNAME}/netns-probe.sh" down || true
    # Non-negotiable: never leave a broken firewall behind.
    sudo "$REPO/ufw-docker" rescue >/dev/null 2>&1 || true
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
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1   # pick up any new subnet

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
    sudo ufw delete allow 22/tcp >/dev/null 2>&1 || true
    sudo ufw reload >/dev/null 2>&1
    run sudo ip netns exec ufwprobe timeout 4 bash -c "exec 3<>/dev/tcp/${HOST_IP}/22"
    [ "$status" -ne 0 ]      # refused: no allow rule for this source
    sudo ufw allow 22/tcp >/dev/null 2>&1
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
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1   # re-install clears it
    run sudo "$REPO/ufw-docker" status
    echo "$output" | grep -q 'all Docker IPv4 subnets are covered'
    docker network rm drifttest >/dev/null 2>&1
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1
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
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1
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
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1
}

@test "remove without --force changes nothing" {
    local before; before=$(jumps)
    run sudo "$REPO/ufw-docker" remove
    echo "$output" | grep -q 'WOULD REMOVE'
    echo "$output" | grep -q 'force'
    [ "$(jumps)" -eq "$before" ]
}

@test "remove returns DOCKER-USER to stock" {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    [ "$(jumps)" -eq 0 ]
    [ "$(active)" -eq 1 ]
    [ "$(ssh_rule)" -gt 0 ]
}
