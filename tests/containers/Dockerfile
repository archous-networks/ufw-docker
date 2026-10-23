# A REAL distribution, running systemd and its own Docker daemon, inside one
# container on a stock GitHub runner.
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
# Until this landed, CI tested exactly one environment: Ubuntu 24.04 with
# iptables 1.8.10. Nothing in the fleet runs that. Debian 12 / iptables 1.8.9
# was verified only by a human running the suite by hand on one host, so a
# Debian-only regression would have reached `main` green.
#
# The blocker was believed to be "GitHub has no Debian runners", which is true
# and was taken to mean VMs, DinD services or self-hosted infrastructure.
# It does not. A privileged container with systemd as pid 1 and dockerd inside
# gives a real init, a real daemon, its own network namespace and THAT
# DISTRO'S OWN iptables binary -- which is the variable that actually matters
# here, since every behaviour this tool depends on is an iptables behaviour.
#
# ── WHAT IS REAL IN HERE, AND WHAT IS NOT ──────────────────────────────────
# Real:  the distro's iptables/ufw/nftables packages and versions, systemd as
#        pid 1, a genuine dockerd creating genuine DOCKER-USER chains, a
#        separate network namespace, and the netns probe's veth vantage point.
# Not:   the kernel. It is the runner's, shared by every leg. A distro whose
#        OWN kernel lacks an nftables feature would not be caught here.
#        Stated plainly in docs/supported.md rather than papered over.
ARG BASE=debian:12
FROM ${BASE}

ARG BASE
ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Debian 10 AND 11 are both past end of life now -- bullseye's LTS ended in
# August 2026 -- so deb.debian.org no longer carries either and the stock
# sources 404 partway through the install. (Debian 11 failed here for exactly
# that reason, several packages into a build that looked fine until it was
# not.) Point them at archive.debian.org, and stop apt refusing a Release
# file whose Valid-Until has passed: that check is right everywhere except
# here, where testing an old release is the entire point.
#
# The security suite is named differently per release -- `buster/updates` but
# `bullseye-security` -- which is why this is a case and not one template.
# Bookworm and the Ubuntu bases are current and are left alone.
RUN set -eux; \
    . /etc/os-release; \
    case "${VERSION_CODENAME:-}" in \
      buster) \
        printf '%s\n' \
          'deb http://archive.debian.org/debian buster main' \
          'deb http://archive.debian.org/debian buster-updates main' \
          'deb http://archive.debian.org/debian-security buster/updates main' \
          > /etc/apt/sources.list; \
        printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99archive; \
        ;; \
      bullseye) \
        printf '%s\n' \
          'deb http://archive.debian.org/debian bullseye main' \
          'deb http://archive.debian.org/debian bullseye-updates main' \
          'deb http://archive.debian.org/debian-security bullseye-security main' \
          > /etc/apt/sources.list; \
        printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99archive; \
        ;; \
    esac

# ── DEBIAN 10 NEEDS DOCKER-CE, AND THAT IS NOT A SHORTCUT ──────────────────
# Every other base here installs the DISTRO'S own Docker, deliberately: it is
# what a box built from that release's repositories actually runs, and its age
# tracks the release. Debian 10 cannot. Its `docker.io` is 18.09.1, cgroup v2
# support did not arrive until Docker 20.10, and on any current kernel the
# daemon refuses to start at all:
#
#     Error starting daemon: Devices cgroup isn't mounted
#
# That is not a container artifact -- a real Debian 10 host on a cgroup v2
# kernel hits exactly the same wall. So docker-ce from Docker's own buster
# repository (26.1.4 is the newest published there) is not a convenience, it
# is the only combination that exists in the field.
#
# The keyring is dearmored rather than used as .asc: buster's apt is 1.8 and
# wants a binary keyring for `signed-by`.
RUN set -eux; \
    . /etc/os-release; \
    if [ "${VERSION_CODENAME:-}" = buster ]; then \
        apt-get update -qq; \
        apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg; \
        install -m 0755 -d /etc/apt/keyrings; \
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
        chmod a+r /etc/apt/keyrings/docker.gpg; \
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian buster stable" \
            > /etc/apt/sources.list.d/docker.list; \
    fi

# systemd-sysv is what provides /sbin/init. Without it the container has no
# pid 1 that can start units, and `ufw` on Debian is a systemd unit.
#
# `sudo` is required by the SUITE, not by this image: the bats tests invoke
# every privileged command through it even when already root, so that one set
# of tests runs unchanged on a developer's host and here.
RUN set -eux; \
    . /etc/os-release; \
    if [ "${VERSION_CODENAME:-}" = buster ]; then \
        DOCKER_PKGS="docker-ce docker-ce-cli containerd.io"; \
    else \
        DOCKER_PKGS="docker.io"; \
    fi; \
    apt-get update -qq; \
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv dbus \
        $DOCKER_PKGS \
        ufw iptables nftables iproute2 \
        curl ca-certificates procps kmod \
        sudo \
        git; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ── ONE BATS ACROSS EVERY LEG, PINNED ──────────────────────────────────────
# The distro's own bats is NOT used, and this is the one place where "what the
# distro ships" is the wrong answer. The five bases ship four different
# versions:
#
#     debian:10    Bats 0.4.0      <- the original bats, not bats-core
#     debian:11    Bats 1.2.1
#     ubuntu:22.04 Bats 1.2.1
#     debian:12    Bats 1.8.2
#     ubuntu:24.04 Bats 1.10.0
#
# 0.4.0 has no `setup_file` or `teardown_file` at all. It does not error on
# them -- it simply never calls them, so on Debian 10 the suite's entire
# per-file setup silently did not happen: no probe namespace, no service
# container, no install. Ten tests failed and every one of them looked like a
# tool defect on old iptables. It was the harness.
#
# bats is the measuring instrument, not the thing being measured. Pinning one
# version is what makes a red leg mean "this distro behaves differently"
# rather than "this distro's bats behaves differently".
ARG BATS_VERSION=v1.11.1
RUN set -eux; \
    git clone --depth 1 --branch "$BATS_VERSION" \
        https://github.com/bats-core/bats-core.git /tmp/bats-core; \
    /tmp/bats-core/install.sh /usr/local; \
    rm -rf /tmp/bats-core; \
    bats --version

# NO storage-driver is pinned here, on purpose. overlay2 cannot stack on the
# runner's own overlay filesystem, so the obvious fix is to force vfs -- and
# that was the first version of this. It works, and it is SLOW: eleven tests
# in eight minutes, against ten legs and a 30-minute job budget.
#
# The nested daemon instead gets /var/lib/docker on its own volume (see
# container-leg.sh), which is real filesystem rather than a layer of this
# container's overlay, so it selects overlay2 by itself. Pinning vfs here
# would override that and quietly put the slowness back.

# systemd units that are meaningless in a container and merely add noise or
# failure to `systemctl is-system-running`.
RUN set -eux; \
    rm -f /lib/systemd/system/multi-user.target.wants/systemd-update-utmp-runlevel.service; \
    systemctl mask \
        systemd-udevd.service systemd-udev-trigger.service \
        systemd-modules-load.service systemd-journald-audit.socket \
        sys-kernel-debug.mount sys-kernel-config.mount \
        systemd-firstboot.service || true; \
    systemctl enable docker || true

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
