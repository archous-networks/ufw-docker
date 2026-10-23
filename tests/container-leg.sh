#!/usr/bin/env bash
#
# Run the FULL suite inside a real distribution, in one privileged container.
#
#   tests/container-leg.sh <base-image> <nft|legacy>
#   tests/container-leg.sh debian:12 nft
#
# See tests/containers/Dockerfile for why this exists and what is and is not
# real inside it. The short version: it gives CI the DISTRO'S OWN iptables,
# which is the variable every behaviour this tool depends on turns on.
#
# ── IT DOES NOT TOUCH THIS HOST'S FIREWALL ─────────────────────────────────
# The container gets its OWN network namespace, and netfilter rules are
# per-namespace. The suite inside enables ufw, flushes chains and restarts a
# Docker daemon -- all of it confined to that namespace. That is why this
# script, unlike tests/run.sh, needs no /etc/ufw-docker-tests-allowed marker
# on the host: there is nothing of the host's to disrupt.
#
# `--privileged` is still a loaded gun in general. It is required here because
# the nested daemon must create network interfaces and write netfilter rules.
set -uo pipefail

BASE="${1:?usage: container-leg.sh <base-image> <nft|legacy>}"
BACKEND="${2:?usage: container-leg.sh <base-image> <nft|legacy>}"
case "$BACKEND" in nft|legacy) ;; *) echo "backend must be nft or legacy" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
SLUG="$(printf '%s' "$BASE" | tr ':/.' '---')-$BACKEND"
IMAGE="ufw-docker-leg:$SLUG"
NAME="ufw-docker-leg-$SLUG"
KEEP="${KEEP_CONTAINER:-0}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
dexec() { docker exec "$NAME" "$@"; }

cleanup() {
    rc=$?
    [ -n "${NFLOG_WAS:-}" ] && ${SUDO:-} sysctl -q -w "net.netfilter.nf_log_all_netns=$NFLOG_WAS" 2>/dev/null
    if [ "$KEEP" = 1 ]; then
        echo "KEEP_CONTAINER=1 -- leaving $NAME running; docker rm -f $NAME when done"
    else
        # -v, so the anonymous graph-root volume goes with the container
        docker rm -fv "$NAME" >/dev/null 2>&1 || true
    fi
    # Inside cleanup, not appended to the trap: cleanup ends in `exit`, and an
    # `exit` inside an EXIT trap terminates immediately -- anything chained
    # after it in the trap string never runs, and the lock would be left behind
    # on every single run.
    rmdir "$LOCK" 2>/dev/null
    exit $rc
}

# ── ONE LEG AT A TIME PER MACHINE ──────────────────────────────────────────
# The legs are isolated from each other in every way that is namespaced --
# netfilter rules, interfaces, the nested daemons -- but the KERNEL RING
# BUFFER is not namespaced, and the drop-logging test reads it. Every leg's
# probe looks identical on the wire (SRC=10.97.0.2, DPT=19089), so two legs
# running side by side on one machine can each pass on the other's log line.
# A false pass, which is the direction that matters.
#
# In CI each leg gets its own runner, so this never engages there. It is for
# a developer running several by hand, which is exactly when it would be
# missed.
LOCK=/var/lock/ufw-docker-leg
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "another container leg holds $LOCK -- wait for it, or remove the directory if it is stale" >&2
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

say "build $IMAGE from $BASE"
docker build --build-arg "BASE=$BASE" -t "$IMAGE" "$HERE/containers" || exit 1

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO=sudo

# ── THE KERNEL DROPS OUR LOG LINES UNLESS TOLD NOT TO ──────────────────────
# `net.netfilter.nf_log_all_netns` defaults to 0, which means netfilter LOG
# calls are written to the kernel ring buffer ONLY from the initial network
# namespace. The stanza's `[UFW DOCKER BLOCK]` rule therefore fires, the
# packet is dropped correctly, and nothing is ever logged -- so the one test
# that proves blocked traffic is visible fails in here for a reason that has
# nothing to do with this tool.
#
# It is a GLOBAL sysctl, not a per-namespace one: it does not exist inside the
# container's /proc/sys at all, so it cannot be set from in there even with
# --privileged. It has to be set out here, and put back on the way out.
# WRITING IT NEEDS ROOT, and the first version of this guarded on
# `[ -w ... ] || [ $(id -u) -eq 0 ]` and then called bare `sysctl -w`. Run by
# a normal user in the docker group -- which is how anyone runs this -- the
# guard passed on neither branch, nothing was set, and the drop-logging test
# failed on every leg. It only appeared to work during development because
# the sysctl had been set by hand in an earlier debugging session: the check
# was passing on state the script had not established. Hence $SUDO.
NFLOG_PATH=/proc/sys/net/netfilter/nf_log_all_netns
if [ -r "$NFLOG_PATH" ]; then
    NFLOG_WAS="$(cat "$NFLOG_PATH")"
    $SUDO sysctl -q -w net.netfilter.nf_log_all_netns=1 \
        || { echo "WARNING: could not set $NFLOG_PATH -- the drop-logging test will fail" >&2; NFLOG_WAS=""; }
else
    echo "WARNING: $NFLOG_PATH absent -- the drop-logging test will fail" >&2
fi

# ── KERNEL MODULES ARE HOST STATE TOO ──────────────────────────────────────
# A container cannot load a module: it has no /lib/modules for the running
# kernel, so `modprobe` inside it fails with
#
#     FATAL: Module ip6_tables not found in directory /lib/modules/6.17.0-azure
#
# and ufw's `enable` dies on `can't initialize ip6tables table filter`. This
# is the same class of thing as the sysctl above -- namespaced rules, global
# kernel.
#
# It did not show up locally, and that is the interesting part: the
# development host already has ip_tables and ip6_tables loaded because its
# OWN ufw uses them, so every local leg inherited a kernel that happened to
# be ready. The GitHub runner's does not, and all three legacy legs failed
# there while passing here. "Works on the dev host" was load-bearing and
# invisible.
#
# NOT undone afterwards, unlike the sysctl: unloading a module that something
# else may be using is a real risk, and an unused table costs nothing -- it
# holds no rules, so it cannot change how anything is filtered.
for m in ip_tables iptable_filter iptable_nat ip6_tables ip6table_filter nf_tables; do
    ${SUDO:-} modprobe "$m" 2>/dev/null || true
done

say "boot systemd in $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true
# /sys/fs/cgroup rw and --cgroupns=host are what let systemd manage units. The
# tmpfs mounts keep systemd's runtime state off the image layer.
# BOTH graph roots need an ANONYMOUS VOLUME, and this is not tidiness.
#
# /var/lib/docker  -- without it the nested daemon's graph root sits on this
#   container's own overlay layer, overlay2 refuses to stack there, and
#   dockerd silently falls back to vfs, which copies the whole filesystem per
#   layer. Measured: eleven tests in eight minutes against twelve for all 51.
#
# /var/lib/containerd -- required from Docker 29 onwards, which stores images
#   in the CONTAINERD image store rather than the daemon's own graph driver.
#   `docker info` reports `overlayfs` instead of `overlay2`, the daemon starts
#   cleanly, and then every `docker run` dies with exit 125:
#
#     failed to mount /tmp/containerd-mountNNN: ... fstype: overlay ...
#     workdir=/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/...
#     err: invalid argument
#
#   Volume one does nothing for it, because the snapshots are not under
#   /var/lib/docker at all. This is exactly why the Ubuntu 22.04 and 24.04
#   legs (docker.io 29.1.3) failed while Debian 11 and 12 (20.10) passed --
#   a split that looks like a distro difference and is a Docker-29 one.
docker run -d --name "$NAME" \
    --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v /var/lib/docker -v /var/lib/containerd \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,mode=1777 \
    "$IMAGE" >/dev/null || exit 1
trap cleanup EXIT INT TERM

# `systemctl is-system-running` returns `degraded` for masked/absent units we
# do not care about, so wait for it to stop being `initializing` rather than
# for a specific verdict.
for _ in $(seq 1 60); do
    state="$(dexec systemctl is-system-running 2>/dev/null || true)"
    case "$state" in starting|initializing|"") sleep 1 ;; *) break ;; esac
done
echo "systemd: ${state:-unknown}"

say "distro and tool versions"
dexec sh -c '. /etc/os-release; echo "distro:  $PRETTY_NAME"'
dexec sh -c 'iptables --version; ufw --version | head -1; docker --version'

say "select the $BACKEND backend"
# Same lesson as the native legacy leg (A11): switching the alternative only
# changes which binary WE talk to. The kernel evaluates BOTH subsystems, so
# anything the daemon already wrote into the other one still applies and a
# stale DROP beats a fresh ACCEPT. Flush, then restart the daemon so it
# rebuilds its chains under the selected backend.
# NOTE THE ASYMMETRY, AND DO NOT "TIDY" IT.
#
# nft leg: select the alternative and restart the daemon. Nothing else. In
#   particular do NOT run `iptables-legacy` to clean up -- merely INVOKING it
#   loads the legacy module and instantiates its built-in chains, which is how
#   the first version of this script manufactured the very "iptables-legacy
#   tables present" warning it was trying to avoid.
#
# legacy leg: the container boots with the daemon's chains already in nft, and
#   the kernel evaluates BOTH subsystems -- so a leftover nft rule still
#   applies and a stale DROP beats a fresh ACCEPT. That is A11, the bug that
#   made the native legacy leg fail for days while the stanza it wrote was
#   perfectly correct. `nft flush ruleset` first, then let the daemon rebuild.
if [ "$BACKEND" = legacy ]; then
    dexec sh -c "
        set -e
        update-alternatives --set iptables  /usr/sbin/iptables-legacy
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
        nft flush ruleset
        systemctl restart docker
    " || exit 1
else
    dexec sh -c "
        set -e
        update-alternatives --set iptables  /usr/sbin/iptables-nft
        update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
        systemctl restart docker
    " || exit 1
fi

for _ in $(seq 1 30); do dexec docker info >/dev/null 2>&1 && break; sleep 2; done
dexec docker info --format 'daemon up: {{.ServerVersion}} / {{.Driver}}' || exit 1
# `grep -c` prints 0 AND exits 1 on no match, so `$(... grep -c ...) || echo 0`
# emits "0\n0". This project has now been bitten by that three times; count
# with awk instead, which has one exit status and one line of output.
echo "legacy rules: $(dexec sh -c 'iptables-legacy -S 2>/dev/null | awk "/^-A/{n++} END{print n+0}"')"
echo "nft rules:    $(dexec sh -c 'iptables-nft    -S 2>/dev/null | awk "/^-A/{n++} END{print n+0}"')"

say "side-load the test image"
# The suite's only image, handed over from the outer daemon instead of pulled
# again inside every leg. Ten legs pulling the same image is ten chances to
# meet Docker Hub's anonymous rate limit from one shared runner IP, and a rate
# limit here fails the leg in a way that reads like a firewall fault.
docker pull -q python:3-alpine >/dev/null 2>&1 || true
docker save python:3-alpine | docker exec -i "$NAME" docker load || exit 1

say "copy the working tree in"
# A tar of the tracked tree, not a bind mount: the suite is exercised against
# a copy that looks like a clone, and nothing it does can reach back out.
# -i, because `docker exec` without it gives the command NO stdin and tar
# reads an empty stream -- which fails as "does not look like a tar archive",
# a message that sends you looking at the tar invocation instead.
# Extract into a directory we make first. `tar --one-top-level=ufw-docker`
# looks neater and fails here with "ufw-docker: Cannot open: File exists",
# because the archive's own top level contains a FILE of that name -- the
# tool itself.
git -C "$REPO" ls-files -z | tar -C "$REPO" --null -T - -cf - \
    | docker exec -i "$NAME" sh -c 'mkdir -p /root/ufw-docker && tar -C /root/ufw-docker -xf -' || exit 1

say "prepare the suite"
dexec sh -c '
    set -e
    install -m 0755 /root/ufw-docker/ufw-docker /usr/local/sbin/ufw-docker
    ufw allow 22/tcp >/dev/null
    ufw --force enable >/dev/null
    touch /etc/ufw-docker-tests-allowed
    ufw status verbose
' || exit 1

say "run the suite"
# HOST_IP is the container's own address on the runner's bridge. From inside,
# this container IS the host: the netns probe builds its veth here and aims at
# this address, which the nested daemon has DNAT'd.
# LEG_BATS_ARGS lets you narrow a leg while debugging it, e.g.
#   LEG_BATS_ARGS='-f "install wires"' tests/container-leg.sh debian:10 nft
# Empty for a real run, which is what CI passes.
dexec sh -c "
    cd /root/ufw-docker
    HOST_IP=\$(ip -4 -br addr show scope global | awk 'NR==1{print \$3}' | cut -d/ -f1)
    echo \"probing \$HOST_IP\"
    HOST_IP=\"\$HOST_IP\" tests/run.sh --tap ${LEG_BATS_ARGS:-}
"
rc=$?

if [ $rc -ne 0 ]; then
    say "DIAGNOSTICS (leg failed, rc=$rc)"
    dexec sh -c 'ufw status verbose; echo; iptables -S DOCKER-USER; echo; iptables -S ufw-user-input' || true
fi

say "leg $BASE / $BACKEND -> rc=$rc"
exit $rc
