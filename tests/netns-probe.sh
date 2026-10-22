#!/usr/bin/env bash
# A genuinely EXTERNAL vantage point, without needing a second machine.
#
# A Docker container is the obvious choice and is WRONG: the tool exempts every
# Docker subnet as container-originated, so a container probe RETURNs before it
# is ever judged, and the test passes no matter what. A network namespace on a
# veth pair is not a Docker subnet, so its traffic takes the same path an
# internet client's does -- PREROUTING/DNAT, then FORWARD, then DOCKER-USER.
set -uo pipefail
NS=ufwprobe; HOST_IP="${HOST_IP:?set HOST_IP}"
# The v6 side of the probe is ULA-only and self-contained: the probe reaches the
# container through the HOST END of the veth, which is a destination Docker has
# DNAT'd, so no global IPv6 on the host is needed. That is what makes a v6 test
# possible on a box with no IPv6 service at all.
V6_HOST=fd00:97::1
V6_PEER=fd00:97::2
case "${1:-}" in
  up)
    ip netns add $NS 2>/dev/null || true
    ip link add vprobe-h type veth peer name vprobe-n 2>/dev/null || true
    ip link set vprobe-n netns $NS 2>/dev/null || true
    ip addr add 10.97.0.1/24 dev vprobe-h 2>/dev/null || true
    ip link set vprobe-h up
    ip netns exec $NS ip addr add 10.97.0.2/24 dev vprobe-n 2>/dev/null || true
    ip netns exec $NS ip link set vprobe-n up
    ip netns exec $NS ip link set lo up
    ip netns exec $NS ip route add default via 10.97.0.1 2>/dev/null || true
    # nodad: without it the address sits "tentative" for a second or two and
    # binding to it fails, which looks exactly like a firewall block.
    ip addr add "$V6_HOST/64" dev vprobe-h nodad 2>/dev/null || true
    ip netns exec $NS ip addr add "$V6_PEER/64" dev vprobe-n nodad 2>/dev/null || true
    ip netns exec $NS ip -6 route add default via "$V6_HOST" 2>/dev/null || true
    ;;
  down)
    ip netns del $NS 2>/dev/null || true
    ip link del vprobe-h 2>/dev/null || true
    ;;
  get)   # $2 = port, $3 = scheme
    # ALWAYS exits 0. This reports a result; it does not assert one. curl exits
    # 28 on timeout, which is the expected outcome for a blocked port -- and as
    # a bare statement under bats' errexit that failed the test outright, which
    # cost a debugging round trip. The caller judges the printed code.
    code=$(ip netns exec $NS curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        "${3:-http}://${HOST_IP}:${2}/" 2>/dev/null)
    printf '%s' "${code:-000}"
    exit 0
    ;;
  get6)  # $2 = port, $3 = scheme -- the IPv6 twin of `get`
    # Targets the HOST END of the veth, not a global address: Docker's v6 DNAT
    # rule is `! -i docker0 --dport N -j DNAT`, which does not care which of the
    # host's addresses was aimed at. Same always-exits-0 contract as `get`.
    code=$(ip netns exec $NS curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        "${3:-http}://[${V6_HOST}]:${2}/" 2>/dev/null)
    printf '%s' "${code:-000}"
    exit 0
    ;;
  peer6) printf '%s' "$V6_PEER" ;;
esac
