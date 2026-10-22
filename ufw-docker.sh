#!/usr/bin/env bash
#
# ufw-docker — make plain `ufw allow/deny` actually govern Docker-published ports.
#
#   ufw-docker.sh install    wire ufw into Docker's DOCKER-USER chain
#   ufw-docker.sh remove     undo it
#   ufw-docker.sh status     report what is wired and whether it is healthy
#
# Docker publishes ports by DNAT in PREROUTING and then FORWARDs them, while ufw
# filters INPUT. Forwarded traffic never traverses INPUT, so `ufw deny 443` has
# no effect on a published port -- the firewall reports a rule that does nothing.
#
# This bridges the two so the commands operators already know apply to containers.

set -uo pipefail

MARK_BEGIN="# BEGIN DOCKER-UFW"
MARK_END="# END DOCKER-UFW"
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$OFF"; }
warn() { printf '  %s%s%s\n' "$YLW" "$*" "$OFF"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$OFF"; }
say()  { printf '  %s\n' "$*"; }
head_(){ printf '\n%s\n' "$*"; }
die()  { bad "$*"; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $*)"; }

# Docker subnets, per address family. Derived at install time rather than
# hardcoding 172.16/12: a user-defined network can sit on 10.x or 192.168.x, and
# anything missed here would be silently dropped.
subnets() {   # $1 = 4|6
    docker network ls -q 2>/dev/null | while read -r id; do
        docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
    done | tr ' ' '\n' | grep -E '[0-9a-fA-F]' | {
        if [ "$1" = "6" ]; then grep ':'; else grep -v ':'; fi
    } | sort -u
}

# Build the stanza for one family. The chain names differ (ufw-user-input vs
# ufw6-user-input) and so do the rule files.
stanza() {   # $1 = 4|6
    local fam="$1" chain file nets
    if [ "$fam" = "6" ]; then chain="ufw6-user-input"; else chain="ufw-user-input"; fi
    nets="$(subnets "$fam")"
    [ -n "$nets" ] || return 1

    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' "# Managed by ufw-docker.sh. Do not edit; re-run 'install'."
    printf '%s\n' "*filter"
    printf '%s\n' "# after.rules is restored BEFORE user.rules, so $chain does not"
    printf '%s\n' "# exist yet. Declaring it creates it; user.rules fills it in afterwards."
    printf ':%s - [0:0]\n' "$chain"
    printf ':DOCKER-USER - [0:0]\n'
    printf '%s\n' "# Container-originated traffic is Docker's business."
    printf '%s\n' "$nets" | while read -r s; do [ -n "$s" ] && printf -- '-A DOCKER-USER -s %s -j RETURN\n' "$s"; done
    printf -- '-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n'
    printf '%s\n' "# Judge only what is heading INTO a container network."
    printf '%s\n' "$nets" | while read -r s; do [ -n "$s" ] && printf -- '-A DOCKER-USER -d %s -j %s\n' "$s" "$chain"; done
    printf '%s\n' "# Nothing matched: mirror ufw's default deny."
    printf '%s\n' "$nets" | while read -r s; do [ -n "$s" ] && printf -- '-A DOCKER-USER -d %s -j DROP\n' "$s"; done
    printf 'COMMIT\n'
    printf '%s\n' "$MARK_END"
}

strip_stanza() { sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" "$1" 2>/dev/null; }

# The hook that makes `ufw reload` survivable -- see the long note inside it.
install_hook() {
    local f=/etc/ufw/before.init
    [ -f "$f" ] && [ ! -f "$f.ufw-docker-backup" ] && cp -a "$f" "$f.ufw-docker-backup"
    cat > "$f" <<'INIT'
#!/bin/sh
# Managed by ufw-docker.sh.
#
# WHY THIS IS REQUIRED, AND IS NOT OPTIONAL:
#
# ufw deletes and recreates its own chains on every apply. iptables refuses to
# delete a chain that another chain still references -- and after our stanza
# runs once, DOCKER-USER references ufw-user-input. So from the SECOND `ufw
# reload` onward those deletes fail and ufw aborts half-way, leaving the
# firewall broken: logging chains missing and, critically, ufw-user-input EMPTY
# -- which silently removes the SSH allow rule.
#
# Measured without this hook: reload #1 fine; reload #2 -> ufw DOWN, 6 of 11
# logging chains, no SSH rule, box reachable only on existing conntrack entries.
#
# before.init runs BEFORE ufw's delete_chains step, so emptying DOCKER-USER here
# releases the references in time. after.rules repopulates it in the same run.
set -e
flush_docker_user() {
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        "$ipt" -S DOCKER-USER >/dev/null 2>&1 || continue
        "$ipt" -F DOCKER-USER 2>/dev/null || true
        "$ipt" -A DOCKER-USER -j RETURN 2>/dev/null || true
    done
}
case "$1" in
    start|stop|flush-all) flush_docker_user ;;
    status) ;;
    *) echo "'$1' not supported" >&2; exit 1 ;;
esac
exit 0
INIT
    chmod 0750 "$f"
}

cmd_install() {
    require_root install
    command -v docker >/dev/null || die "docker is not installed"
    command -v ufw    >/dev/null || die "ufw is not installed"

    head_ "ufw-docker install"

    local v4 v6 wrote=0
    v4="$(subnets 4)"; v6="$(subnets 6)"
    say "IPv4 Docker subnets: $(echo "$v4" | tr '\n' ' ')"
    say "IPv6 Docker subnets: $(echo "$v6" | tr '\n' ' ')${v6:+}"
    [ -z "$v6" ] && say "  (none — Docker IPv6 is off; the v6 stanza is skipped)"

    install_hook; ok "before.init hook installed (required for reload safety)"

    cp -a /etc/ufw/after.rules  "/etc/ufw/after.rules.ufw-docker-bak-$(date +%Y%m%d%H%M%S)"
    strip_stanza /etc/ufw/after.rules
    if stanza 4 >> /etc/ufw/after.rules; then ok "IPv4 stanza written to after.rules"; wrote=1; fi

    if [ -n "$v6" ] && [ -f /etc/ufw/after6.rules ]; then
        cp -a /etc/ufw/after6.rules "/etc/ufw/after6.rules.ufw-docker-bak-$(date +%Y%m%d%H%M%S)"
        strip_stanza /etc/ufw/after6.rules
        if stanza 6 >> /etc/ufw/after6.rules; then ok "IPv6 stanza written to after6.rules"; wrote=1; fi
    fi

    [ "$wrote" -eq 1 ] || die "no Docker subnets found — nothing to wire"

    head_ "applying"
    ufw reload 2>&1 | sed 's/^/  /'
    cmd_status
}

cmd_remove() {
    require_root remove
    head_ "ufw-docker remove"
    strip_stanza /etc/ufw/after.rules  && ok "IPv4 stanza removed"
    strip_stanza /etc/ufw/after6.rules && ok "IPv6 stanza removed"
    if [ -f /etc/ufw/before.init.ufw-docker-backup ]; then
        mv /etc/ufw/before.init.ufw-docker-backup /etc/ufw/before.init
        chmod 0640 /etc/ufw/before.init
        ok "before.init restored to its original"
    fi
    for ipt in iptables ip6tables; do
        "$ipt" -S DOCKER-USER >/dev/null 2>&1 || continue
        "$ipt" -F DOCKER-USER 2>/dev/null; "$ipt" -A DOCKER-USER -j RETURN 2>/dev/null
    done
    ok "DOCKER-USER reset to stock"
    ufw reload 2>&1 | sed 's/^/  /'
    cmd_status || true
}

cmd_status() {
    head_ "ufw-docker status"
    local rc=0

    local act; act=$(ufw status 2>/dev/null | grep -c 'Status: active')
    [ "$act" -eq 1 ] && ok "ufw active" || { bad "ufw is NOT active"; rc=1; }

    local logc; logc=$(iptables -S 2>/dev/null | grep -cE '^-N ufw.*logging')
    [ "$logc" -ge 9 ] && ok "ufw chains complete ($logc logging chains)" \
        || { bad "ufw is half-built ($logc logging chains) — run ufw-rescue"; rc=1; }

    local sshr; sshr=$(iptables -S ufw-user-input 2>/dev/null | grep -c 'dport 22')
    [ "$sshr" -gt 0 ] && ok "SSH rule present" \
        || { bad "NO SSH rule in ufw-user-input — run ufw-rescue NOW"; rc=1; }

    # "Not installed" is a perfectly valid state -- on a host that never ran
    # install, or straight after remove. Reporting the absent hook as a fault
    # there made `remove` exit non-zero, which is wrong and made the tool look
    # broken when it had just done exactly what was asked.
    local installed=0
    grep -q "$MARK_BEGIN" /etc/ufw/after.rules 2>/dev/null && installed=1

    if [ "$installed" -eq 0 ]; then
        say "ufw-docker: NOT installed (ufw rules do not affect Docker ports)"
        return $rc
    fi

    [ -x /etc/ufw/before.init ] && grep -q 'ufw-docker' /etc/ufw/before.init 2>/dev/null \
        && ok "before.init hook installed" \
        || { bad "before.init hook MISSING — 'ufw reload' WILL break the firewall"; rc=1; }

    local j4; j4=$(iptables -S DOCKER-USER 2>/dev/null | grep -c 'ufw-user-input')
    [ "$j4" -gt 0 ] && ok "IPv4 wired ($j4 jumps into ufw-user-input)" \
        || { bad "stanza present but IPv4 NOT wired — run 'install' or 'ufw reload'"; rc=1; }

    local v6nets; v6nets="$(subnets 6)"
    local j6; j6=$(ip6tables -S DOCKER-USER 2>/dev/null | grep -c 'ufw6-user-input')
    if [ -n "$v6nets" ]; then
        [ "$j6" -gt 0 ] && ok "IPv6 wired ($j6 jumps into ufw6-user-input)" \
            || { bad "Docker has IPv6 networks but IPv6 is NOT wired — v6 is unfiltered"; rc=1; }
    else
        say "IPv6: Docker has no v6 networks; nothing to wire"
    fi
    return $rc
}

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    remove|uninstall) shift; cmd_remove "$@" ;;
    status)  shift; cmd_status "$@" ;;
    *) sed -n '2,14p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 1 ;;
esac
