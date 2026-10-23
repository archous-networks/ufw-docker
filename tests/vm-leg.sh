#!/usr/bin/env bash
#
# Run the FULL suite inside a REAL VIRTUAL MACHINE -- that distro's own
# kernel, booted from power-on.
#
#   tests/vm-leg.sh <debian-10|debian-11|debian-12> <nft|legacy> [distro|ce]
#   tests/vm-leg.sh debian-10 nft ce
#
# ── WHY THIS EXISTS WHEN tests/container-leg.sh ALREADY RUNS THE SUITE ─────
# A container leg is that distro's USERSPACE on the runner's kernel. It gives
# us the distro's iptables, which is the variable most behaviour turns on, and
# it was the right first move. But it cannot give us the distro's KERNEL, and
# two things live only there:
#
#   1. The netfilter implementation that shipped WITH that release. `debian:10`
#      today is Debian 10 tooling on a 6.x kernel; a real one runs 4.19.
#   2. Configurations a modern kernel makes impossible to build at all. The
#      headline case: Debian 10's own `docker.io` is 18.09.1, which predates
#      cgroup v2 and will not start on the runner's kernel -- see
#      tests/containers/Dockerfile. On a 4.19 guest, cgroups are v1 and it
#      starts fine. A stock Debian 10 box running its own Docker is the most
#      ordinary old host there is, and the container matrix cannot express it.
#
# ── WHY THIS IS AFFORDABLE, WHICH IT WAS NOT WHEN FUTURE.md WAS WRITTEN ────
# GitHub's standard runners expose /dev/kvm -- nested virtualisation is on.
# Measured 2026-10-23 on ubuntu-24.04 and ubuntu-22.04; both booted a real
# 4.19 and a real 6.1 kernel under `-accel kvm`. Standard runners are free and
# unmetered on public repos, so this costs nothing but wall clock.
#
# That is MEASURED, NOT CONTRACTUAL. GitHub does not promise nested virt, and
# a future image could withdraw it. So this script REFUSES to run rather than
# falling back to TCG emulation: a silent fallback would turn a 10-minute leg
# into a multi-hour one and look like a hang, and -- worse -- a leg that
# quietly stops testing the thing it exists for is this project's recurring
# failure mode.
set -uo pipefail

DISTRO="${1:?usage: vm-leg.sh <debian-10|debian-11|debian-12> <nft|legacy> [distro|ce]}"
BACKEND="${2:?usage: vm-leg.sh <distro> <nft|legacy> [distro|ce]}"
DOCKER_FROM="${3:-}"

case "$BACKEND" in nft|legacy) ;; *) echo "backend must be nft or legacy" >&2; exit 2 ;; esac

case "$DISTRO" in
    debian-10) CODENAME=buster;   IMG=debian-10-genericcloud-amd64.qcow2; WANT_KERNEL=4.19 ;;
    debian-11) CODENAME=bullseye; IMG=debian-11-genericcloud-amd64.qcow2; WANT_KERNEL=5.10 ;;
    debian-12) CODENAME=bookworm; IMG=debian-12-genericcloud-amd64.qcow2; WANT_KERNEL=6.1  ;;
    *) echo "unknown distro: $DISTRO" >&2; exit 2 ;;
esac

# Default Docker source per distro, matching what a real box of that age runs.
# Debian 10 is the interesting one and can go either way, so it is explicit.
if [ -z "$DOCKER_FROM" ]; then
    case "$DISTRO" in
        debian-10) DOCKER_FROM=distro ;;   # 18.09.1 -- only reachable here
        *)         DOCKER_FROM=distro ;;
    esac
fi
case "$DOCKER_FROM" in distro|ce) ;; *) echo "docker source must be 'distro' or 'ce'" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
WORK="${VM_WORK_DIR:-${RUNNER_TEMP:-/tmp}/ufw-docker-vm-$DISTRO-$BACKEND}"
SSH_PORT="${VM_SSH_PORT:-2222}"
MEM="${VM_MEM_MB:-4096}"
CPUS="${VM_CPUS:-2}"
KEEP="${KEEP_VM:-0}"
BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-300}"
SUITE_TIMEOUT="${VM_SUITE_TIMEOUT:-3600}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ── FACTS FOR THE README TABLE ─────────────────────────────────────────────
# The table's kernel column must show the GUEST's kernel -- that is the entire
# claim this leg makes, and it is the one thing a container leg cannot say.
# Written to a file as each fact becomes known rather than parsed back out of
# the log afterwards: a parser would be a second source of truth, and the
# phase-counting parser in leg-summary.sh has already drifted from its log
# once (it matched `-- phase:` while the log said `== phase:`, so every leg
# row lost its counts while looking fine).
fact() { [ -n "${VM_FACTS_FILE:-}" ] && printf '%s=%s\n' "$1" "$2" >> "$VM_FACTS_FILE"; return 0; }

mkdir -p "$WORK"
KEY="$WORK/id_ed25519"
SERIAL="$WORK/serial.log"
QEMU_PID=""

cleanup() {
    rc=$?
    if [ "$KEEP" = 1 ] && [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "KEEP_VM=1 -- leaving the guest up; ssh -p $SSH_PORT -i $KEY debian@127.0.0.1"
    elif [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null
        wait "$QEMU_PID" 2>/dev/null
    fi
    exit $rc
}
trap cleanup EXIT INT TERM

# ── REFUSE RATHER THAN EMULATE ─────────────────────────────────────────────
say "check this runner can actually virtualise"
if [ ! -e /dev/kvm ]; then
    cat >&2 <<'MSG'
### /dev/kvm DOES NOT EXIST ON THIS RUNNER

This leg runs a real VM and will not emulate instead -- TCG would take hours
and would look like a hang. Nested virtualisation was present on GitHub's
standard runners when this was written (2026-10-23) but has never been
promised, so this is the failure mode to expect if that changes.

If it is gone for good, FUTURE.md's kernel-gap entry needs reopening.
MSG
    exit 1
fi
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "/dev/kvm is not accessible to $(id -un); trying to widen it" >&2
    sudo chmod 0666 /dev/kvm || { echo "### could not make /dev/kvm usable" >&2; exit 1; }
fi
[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "### /dev/kvm still not usable" >&2; exit 1; }
echo "ok  /dev/kvm is usable by $(id -un)"

say "dependencies"
need=""
for c in qemu-system-x86_64 cloud-localds qemu-img ssh scp; do
    command -v "$c" >/dev/null 2>&1 || need="$need $c"
done
if [ -n "$need" ]; then
    echo "installing for:$need"
    sudo apt-get update -qq
    sudo apt-get install -y -qq qemu-system-x86 qemu-utils cloud-image-utils openssh-client || exit 1
fi
qemu-system-x86_64 --version | head -1

say "fetch the $DISTRO cloud image"
BASE_IMG="$WORK/$IMG"
if [ ! -s "$BASE_IMG" ]; then
    curl -fsSL --retry 3 -o "$BASE_IMG.part" \
        "https://cloud.debian.org/images/cloud/$CODENAME/latest/$IMG" || exit 1
    mv "$BASE_IMG.part" "$BASE_IMG"
fi
ls -lh "$BASE_IMG"

# An overlay, so a re-run starts from the pristine image without downloading
# it again -- and so nothing this leg does can corrupt the cached base.
say "overlay disk"
OVERLAY="$WORK/overlay.qcow2"
rm -f "$OVERLAY"
qemu-img create -q -f qcow2 -b "$BASE_IMG" -F qcow2 "$OVERLAY" 20G || exit 1

say "cloud-init seed"
rm -f "$KEY" "$KEY.pub"
ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C ufw-docker-vm-leg
cat > "$WORK/user-data" <<EOF
#cloud-config
hostname: ufw-docker-vm
users:
  - name: debian
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$KEY.pub")
ssh_pwauth: false
EOF
printf 'instance-id: ufw-docker-vm\nlocal-hostname: ufw-docker-vm\n' > "$WORK/meta-data"
cloud-localds "$WORK/seed.img" "$WORK/user-data" "$WORK/meta-data" || exit 1

say "boot the guest (KVM, $CPUS vcpu, ${MEM}MB)"
qemu-system-x86_64 \
    -accel kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -drive "file=$OVERLAY,if=virtio,format=qcow2" \
    -drive "file=$WORK/seed.img,if=virtio,format=raw" \
    -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22" -device virtio-net-pci,netdev=n0 \
    -nographic -serial "file:$SERIAL" -display none \
    > "$WORK/qemu.log" 2>&1 &
QEMU_PID=$!

SSH_OPTS="-i $KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=5"
# shellcheck disable=SC2086  # SSH_OPTS is a deliberate word list
vssh() { ssh $SSH_OPTS debian@127.0.0.1 "$@"; }

say "wait for ssh (up to ${BOOT_TIMEOUT}s)"
start=$(date +%s)
until vssh true 2>/dev/null; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "### QEMU DIED DURING BOOT"; tail -40 "$WORK/qemu.log" "$SERIAL"; exit 1
    fi
    if [ $(( $(date +%s) - start )) -gt "$BOOT_TIMEOUT" ]; then
        echo "### GUEST DID NOT COME UP IN ${BOOT_TIMEOUT}s"; tail -60 "$SERIAL"; exit 1
    fi
    sleep 3
done
echo "ssh up after $(( $(date +%s) - start ))s"

say "wait for cloud-init to finish"
vssh 'sudo cloud-init status --wait' || true

say "what we actually booted"
vssh 'set -e
    . /etc/os-release; echo "distro:  $PRETTY_NAME"
    echo "kernel:  $(uname -r)"
    echo "cgroups: $(stat -fc %T /sys/fs/cgroup)"
' || exit 1
GUEST_KERNEL="$(vssh 'uname -r' 2>/dev/null)"
case "$GUEST_KERNEL" in
    "$WANT_KERNEL"*) echo "ok  this is $DISTRO's own kernel ($GUEST_KERNEL)"
                     fact kernel "$GUEST_KERNEL" ;;
    *) echo "### EXPECTED a $WANT_KERNEL kernel, got '$GUEST_KERNEL' -- the whole point of"
       echo "    this leg is the distro's own kernel, so this is a failure, not a note."
       exit 1 ;;
esac

# ── AN EOL RELEASE NEEDS archive.debian.org, AND A RETRY CANNOT SUBSTITUTE ─
# When a Debian release goes EOL its packages move to archive.debian.org. A
# cloud image still points at deb.debian.org / security.debian.org, so every
# apt-get fails -- but it fails in a way that looks like a transient mirror
# problem rather than a permanent move.
#
# The debian-11 leg showed exactly how misleading that is. `apt-get update`
# reported `Hit:1 ... bullseye-security InRelease` -- index current, not even
# modified -- and the install then 404'd on seven .debs that index names. An
# up-to-date index pointing at a pruned pool is the SIGNATURE of an EOL
# release, and no amount of refreshing fixes it; only repointing does. The
# retry in apt_install() below is for a genuinely stale index, which is a
# different fault with the same error text.
case "$CODENAME" in
    buster|bullseye) ARCHIVED=1 ;;
    *)               ARCHIVED=0 ;;
esac

say "apt sources and index (archived=$ARCHIVED)"
vssh "set -e
    if [ '$ARCHIVED' = 1 ]; then
        for f in /etc/apt/sources.list \$(ls /etc/apt/sources.list.d/*.list 2>/dev/null); do
            sudo sed -i -e 's|deb.debian.org/debian-security|archive.debian.org/debian-security|g' \\
                        -e 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' \\
                        -e 's|security.debian.org|archive.debian.org|g' \\
                        -e 's|deb.debian.org|archive.debian.org|g' \"\$f\"
            sudo sed -i '/$CODENAME-updates/d' \"\$f\"
        done
        echo 'Acquire::Check-Valid-Until \"false\";' | sudo tee /etc/apt/apt.conf.d/99no-check-valid >/dev/null
        echo '--- rewritten sources ---'
        grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
    fi
    sudo apt-get update
" || exit 1

# ── apt_install: update, then install, then ONE retry after a fresh update ──
# A cloud image ships a package index from the day it was built. When a point
# release has since superseded a package, the stale index names a .deb that is
# no longer in the pool and apt fails with a bare 404 -- which is what killed
# the first debian-11 leg (it asked for docker.io 20.10.5+deb11u4, long gone).
# The first `apt-get update` above usually fixes that; the retry is for the
# case where the index moved under us between update and install.
apt_install() {
    vssh "sudo apt-get install -y -qq --no-install-recommends $*" && return 0
    echo "apt install failed; refreshing the index and retrying once" >&2
    vssh "sudo apt-get update && sudo apt-get install -y -qq --no-install-recommends $*"
}

say "install ufw, iptables and the suite's tools"
apt_install ufw iptables nftables iproute2 curl ca-certificates procps git jq || exit 1

# ── THE BACKEND IS CHOSEN BEFORE DOCKER IS INSTALLED, AND THAT IS THE POINT ─
# Installing docker.io starts the daemon immediately, and the daemon writes
# its chains through whichever `iptables` the alternatives system points at.
# Switching the alternative AFTERWARDS and restarting does NOT undo that: the
# legacy and nft rule sets are separate tables that the kernel evaluates BOTH
# of, so the first daemon's rules stay live in the other backend and silently
# contend with the new ones.
#
# That is not a theory. The first `debian-10 legacy` leg installed docker
# first and failed 8 of 63 -- every one of them a test where traffic should
# have been ALLOWED through and was not, while the DENY tests passed, which
# is exactly the signature of a stale DROP left behind in the other table.
# Its nft sibling, identical but for this, passed 63/63.
say "select the $BACKEND backend (before any daemon exists)"
if [ "$BACKEND" = legacy ]; then
    vssh 'sudo update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
          sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true' || exit 1
else
    vssh 'sudo update-alternatives --set iptables  /usr/sbin/iptables-nft  2>/dev/null || true
          sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft 2>/dev/null || true' || exit 1
fi
vssh 'echo "iptables is now: $(/usr/sbin/iptables --version)"' || exit 1

say "install docker ($DOCKER_FROM)"
if [ "$DOCKER_FROM" = ce ]; then
    vssh "set -e
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \\
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable' \\
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update
    " || exit 1
    apt_install docker-ce docker-ce-cli containerd.io || exit 1
else
    apt_install docker.io || exit 1
fi

say "daemon up?"
DOCKER_VER="$(vssh 'for _ in $(seq 1 30); do sudo docker info >/dev/null 2>&1 && break; sleep 2; done
                    sudo docker info --format "{{.ServerVersion}}" 2>/dev/null' 2>/dev/null | tr -d '\r')"
[ -n "$DOCKER_VER" ] && fact docker "$DOCKER_VER"
vssh 'sudo docker info --format "daemon up: {{.ServerVersion}} / {{.Driver}}"' || {
    echo "### THE DAEMON DID NOT COME UP"
    vssh 'sudo journalctl -u docker --no-pager | tail -40' || true
    exit 1
}

# Count rules in BOTH backends, as the container leg does. If the daemon wrote
# into the one we did not select, these numbers say so immediately -- and that
# is the failure this ordering exists to prevent, so it is worth seeing on
# every run rather than only when something breaks.
# `grep -c` prints 0 AND exits 1 on no match, so count with awk instead.
vssh 'echo "legacy rules: $(sudo iptables-legacy -S 2>/dev/null | awk "/^-A/{n++} END{print n+0}")"
      echo "nft rules:    $(sudo iptables-nft    -S 2>/dev/null | awk "/^-A/{n++} END{print n+0}")"' || true

# /usr/sbin is NOT on a non-root user's PATH on Debian, so a bare `iptables`
# here printed "command not found" and an empty version, and the leg carried
# on regardless. Spell the paths, and fail if either is missing: these two
# versions are the whole reason the leg exists, so not knowing them is not a
# cosmetic problem.
vssh 'set -e
    echo "iptables: $(/usr/sbin/iptables --version)"
    echo "ufw:      $(/usr/sbin/ufw --version | head -1)"
' || { echo "### could not read the iptables/ufw versions in the guest" >&2; exit 1; }

# The suite needs $BATS_FILE_TMPDIR, which arrived in bats 1.4. Debian ships
# far older (buster has the original bats 0.4.0, not bats-core at all), so
# pin the same version tests/containers/Dockerfile pins -- a leg that tested a
# different bats than its sibling legs would be comparing two things at once.
say "bats v1.11.1 from source (the distro's is too old)"
vssh "set -e
    sudo rm -rf /tmp/bats-core
    git clone -q --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git /tmp/bats-core
    sudo /tmp/bats-core/install.sh /usr/local
    bats --version
" || exit 1

say "side-load the suite's image"
# Same reasoning as the container leg: pulling python:3-alpine inside every
# guest is another chance to meet Docker Hub's anonymous rate limit from one
# shared runner IP, and that failure reads like a firewall fault.
if docker pull -q python:3-alpine >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    docker save python:3-alpine | ssh $SSH_OPTS debian@127.0.0.1 'sudo docker load' || exit 1
else
    echo "NOTE could not pre-pull on the runner; the guest will pull it itself"
fi

say "copy the working tree in"
# Tracked files only, as a tar -- a clean checkout, not the maintainer's
# working tree. Identical to the container leg, including the consequence:
# there is no .git inside, so the upgrade test needs the previous revision
# handed to it as a plain file (below) or it silently skips.
# shellcheck disable=SC2086
git -C "$REPO" ls-files -z | tar -C "$REPO" --null -T - -cf - \
    | ssh $SSH_OPTS debian@127.0.0.1 'mkdir -p ~/ufw-docker && tar -C ~/ufw-docker -xf -' || exit 1

PREV_REV="$(git -C "$REPO" log --format=%H -- ufw-docker 2>/dev/null | sed -n '2p')"
if [ -n "$PREV_REV" ]; then
    # shellcheck disable=SC2086
    if git -C "$REPO" show "$PREV_REV:ufw-docker" 2>/dev/null \
        | ssh $SSH_OPTS debian@127.0.0.1 'cat > ~/ufw-docker/tests/.prev-ufw-docker'; then
        vssh 'chmod 0755 ~/ufw-docker/tests/.prev-ufw-docker'
        say "previous revision ${PREV_REV:0:7} placed for the upgrade test"
    fi
else
    say "NOTE no previous revision in git; the upgrade-from-real-release test will skip"
fi

say "prepare the suite"
vssh 'set -e
    sudo install -m 0755 ~/ufw-docker/ufw-docker /usr/local/sbin/ufw-docker
    sudo ufw allow 22/tcp >/dev/null
    sudo ufw --force enable >/dev/null
    sudo touch /etc/ufw-docker-tests-allowed
    sudo ufw status verbose
' || exit 1

say "run the suite"
# ── WHY THIS IS DETACHED AND POLLED, NOT JUST `ssh ... tests/run.sh` ───────
# We reach the guest over SSH, and the thing under test rewrites that guest's
# firewall. A bug -- or a test doing its job -- can drop the control
# connection, and a dropped connection would then be indistinguishable from a
# failed suite. So the suite runs detached, writes its own exit status to a
# file, and we poll for that file. Losing SSH mid-run becomes a reconnect
# rather than a verdict.
vssh 'set -e
    cd ~/ufw-docker
    HOST_IP=$(ip -4 -br addr show scope global | awk "NR==1{print \$3}" | cut -d/ -f1)
    echo "probing $HOST_IP"
    rm -f ~/suite.rc ~/suite.log
    setsid sh -c "
        cd \$HOME/ufw-docker
        HOST_IP=$HOST_IP sudo -E env HOST_IP=$HOST_IP tests/run.sh --tap > \$HOME/suite.log 2>&1
        echo \$? > \$HOME/suite.rc
    " </dev/null >/dev/null 2>&1 &
    sleep 1
' || exit 1

start=$(date +%s)
shown=0
rc=""
while :; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -gt "$SUITE_TIMEOUT" ]; then
        echo "### SUITE EXCEEDED ${SUITE_TIMEOUT}s"
        vssh 'tail -40 ~/suite.log' 2>/dev/null || true
        rc=124; break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "### THE GUEST DIED MID-SUITE"; tail -40 "$SERIAL"; rc=1; break
    fi
    # Stream whatever is new, tolerating a connection that is briefly gone.
    total="$(vssh 'wc -l < ~/suite.log 2>/dev/null || echo 0' 2>/dev/null | tr -dc '0-9')"
    if [ -n "$total" ] && [ "$total" -gt "$shown" ]; then
        # BOUNDED to $total, not open-ended. An unbounded `shown+1,$p` prints
        # whatever arrived between the wc and the sed, then prints it AGAIN on
        # the next pass because `shown` only advanced as far as the wc said.
        # The first run duplicated test 14 this way -- harmless in itself, but
        # a log that invents a second pass of a test is exactly the kind of
        # evidence this suite is read for.
        vssh "sed -n '$((shown + 1)),${total}p' ~/suite.log" 2>/dev/null && shown="$total"
    fi
    got="$(vssh 'cat ~/suite.rc 2>/dev/null' 2>/dev/null | tr -dc '0-9')"
    if [ -n "$got" ]; then
        # Drain anything written after the last poll.
        total="$(vssh 'wc -l < ~/suite.log 2>/dev/null || echo 0' 2>/dev/null | tr -dc '0-9')"
        [ -n "$total" ] && [ "$total" -gt "$shown" ] && vssh "sed -n '$((shown + 1)),${total}p' ~/suite.log" 2>/dev/null
        rc="$got"; break
    fi
    sleep 5
done
SUITE_SECONDS=$(( $(date +%s) - start ))
echo
echo "suite wall clock: ${SUITE_SECONDS}s"

if [ "${rc:-1}" -ne 0 ]; then
    say "DIAGNOSTICS (leg failed, rc=$rc)"
    vssh 'sudo ufw status verbose; echo; sudo iptables -S DOCKER-USER; echo; sudo iptables -S ufw-user-input' 2>/dev/null || true
    vssh 'sudo journalctl -u docker --no-pager | tail -30' 2>/dev/null || true
fi

say "shut the guest down cleanly"
# A clean shutdown, not a kill: this leg's whole premise is a real machine,
# and a real machine's shutdown path is part of what we are entitled to
# assert about. It also flushes the guest's logs before we lose them.
vssh 'sudo systemctl poweroff' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo "NOTE the guest did not power off in 60s; killing it"
    kill "$QEMU_PID" 2>/dev/null
fi
QEMU_PID=""

say "vm leg $DISTRO / $BACKEND / docker=$DOCKER_FROM / kernel=$GUEST_KERNEL -> rc=${rc:-1}"
exit "${rc:-1}"
