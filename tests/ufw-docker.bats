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

setup_file() {
    sudo HOST_IP="$HOST_IP" "${BATS_TEST_DIRNAME}/netns-probe.sh" up
    # A rule we can prove host-level filtering with, independent of Docker.
    sudo ufw allow 22/tcp >/dev/null 2>&1
    sudo "$REPO/ufw-docker" install >/dev/null 2>&1
}

teardown_file() {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1 || true
    # setup_file added a blanket SSH allow for the host-level test; leaving it
    # behind would quietly widen the operator's SSH exposure after a test run.
    sudo ufw delete allow 22/tcp >/dev/null 2>&1 || true
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

@test "remove returns DOCKER-USER to stock" {
    sudo "$REPO/ufw-docker" remove --force >/dev/null 2>&1
    [ "$(jumps)" -eq 0 ]
    [ "$(active)" -eq 1 ]
    [ "$(ssh_rule)" -gt 0 ]
}
