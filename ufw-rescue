#!/usr/bin/env bash
#
# ufw-rescue — get SSH back, and put ufw into a working state.
#
#   ufw-rescue          restore: strip our Docker stanza, rebuild ufw from its
#                       own config files, verify
#   ufw-rescue --open   emergency: firewall OFF, INPUT wide open. Use only if
#                       the restore above cannot get you back in.
#
# Intended to be run FROM THE CONSOLE as root when SSH is refused.
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
# Wiring ufw into Docker's DOCKER-USER chain can leave the firewall half-built:
# ufw deletes and recreates its own chains on every reload, and an outside
# reference to one of them makes those deletes fail. The symptom is brutal --
# `ufw-user-input` ends up EMPTY, which silently drops the SSH allow rule, so
# existing sessions survive on conntrack while every new login is refused.
#
# ── DESIGN RULES ───────────────────────────────────────────────────────────
#  * No `set -e`. A rescue script must push through failures, not abort on the
#    first one. Each step is independent and reports for itself.
#  * SSH is restored FIRST, before any cleanup, so a failure later still leaves
#    you able to log in.
#  * No network access, no package installs, no repo checkout. Console only.
#  * Idempotent: running it twice is harmless.

set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; OFF=$'\033[0m'
ok()   { printf '  %s%s%s\n' "$GRN" "$*" "$OFF"; }
warn() { printf '  %s%s%s\n' "$YLW" "$*" "$OFF"; }
bad()  { printf '  %s%s%s\n' "$RED" "$*" "$OFF"; }
say()  { printf '  %s\n' "$*"; }
head_(){ printf '\n%s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { bad "must run as root"; exit 1; }

MODE="restore"
case "${1:-}" in
    --open) MODE="open" ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    "") ;;
    *) bad "unknown argument: $1"; exit 1 ;;
esac

STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="/var/backups/ufw-rescue-${STAMP}"
mkdir -p "$BACKUP"

head_ "ufw-rescue (${MODE})"
say "forensic snapshot: $BACKUP"
iptables-save  > "$BACKUP/iptables.v4"  2>/dev/null
ip6tables-save > "$BACKUP/iptables.v6"  2>/dev/null
cp -a /etc/ufw/after.rules  "$BACKUP/" 2>/dev/null
cp -a /etc/ufw/after6.rules "$BACKUP/" 2>/dev/null
cp -a /etc/ufw/user.rules   "$BACKUP/" 2>/dev/null

# ── 1. SSH FIRST ───────────────────────────────────────────────────────────
# Before touching anything else. A blanket accept at the top of INPUT works no
# matter what state ufw's chains are in, and survives the cleanup below.
head_ "1. restoring SSH"
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null \
  || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null
if iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null; then
    ok "temporary blanket ACCEPT on tcp/22 is in place"
    say "(removed at the end if ufw comes back healthy with its own SSH rule)"
else
    bad "could not insert the SSH rule — is iptables working at all?"
fi

if [ "$MODE" = "open" ]; then
    head_ "2. emergency: taking the firewall down"
    ufw --force disable >/dev/null 2>&1
    for t in INPUT FORWARD OUTPUT; do iptables -P "$t" ACCEPT 2>/dev/null; done
    ok "ufw disabled; INPUT/FORWARD/OUTPUT policies set to ACCEPT"
    warn "THIS HOST IS NOW UNFILTERED. Re-run 'ufw-rescue' without --open"
    warn "once you have access, to rebuild a working firewall."
    exit 0
fi

# ── 2. remove our Docker stanza ────────────────────────────────────────────
head_ "2. removing the DOCKER-UFW stanza"
for f in /etc/ufw/after.rules /etc/ufw/after6.rules; do
    [ -f "$f" ] || continue
    if grep -qF 'BEGIN DOCKER-UFW' "$f" 2>/dev/null; then
        sed -i '/# BEGIN DOCKER-UFW/,/# END DOCKER-UFW/d' "$f"
        ok "stripped from $f"
    else
        say "not present in $f"
    fi
done

# ── 3. release references to ufw's chains ──────────────────────────────────
# This is the step that actually unblocks ufw. While DOCKER-USER still jumps to
# ufw-user-input, iptables refuses to delete that chain, ufw's rebuild fails
# part-way, and the firewall is left inconsistent.
head_ "3. returning DOCKER-USER to stock"
for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null || continue
    if "$ipt" -S DOCKER-USER >/dev/null 2>&1; then
        "$ipt" -F DOCKER-USER 2>/dev/null
        "$ipt" -A DOCKER-USER -j RETURN 2>/dev/null
        ok "$ipt: DOCKER-USER reset to a single RETURN"
    fi
done

# ── 3b. nft fallback ───────────────────────────────────────────────────────
# Observed for real after a test run: ufw-user-input ended up expressed in
# NATIVE nft syntax (`tcp dport 22 accept`, without the `meta l4proto tcp`
# prefix iptables-nft emits). The compat layer then refuses to touch it --
#   iptables: chain `ufw-user-input' in table `filter' is incompatible, use 'nft'
# -- so every iptables -F/-X above silently does nothing, ufw cannot rebuild,
# and the firewall stays broken. The only way out is to clear the chains at the
# nft level, which also means removing the base-chain jumps that reference them.
head_ "3b. checking for nft-incompatible chains"
if command -v nft >/dev/null 2>&1; then
    # Match the SPECIFIC error. An absent chain also makes iptables fail, and
    # treating that as incompatibility sent this down the nft path on a healthy
    # host -- a rescue script must not take drastic action on a false positive.
    if iptables -S ufw-user-input 2>&1 | grep -q 'incompatible'; then
        warn "ufw chains are not readable by iptables; clearing them with nft"
        for base in INPUT FORWARD OUTPUT; do
            while :; do
                h=$(nft -a list chain ip filter "$base" 2>/dev/null \
                    | grep -E 'jump ufw' | grep -oE 'handle [0-9]+' | head -1 | awk '{print $2}')
                [ -n "$h" ] || break
                nft delete rule ip filter "$base" handle "$h" 2>/dev/null || break
            done
        done
        for c in $(nft list table ip filter 2>/dev/null | grep -oE 'chain ufw[A-Za-z0-9_-]*' | awk '{print $2}'); do
            nft flush chain ip filter "$c" 2>/dev/null
        done
        for c in $(nft list table ip filter 2>/dev/null | grep -oE 'chain ufw[A-Za-z0-9_-]*' | awk '{print $2}'); do
            nft delete chain ip filter "$c" 2>/dev/null
        done
        LEFT=$(nft list table ip filter 2>/dev/null | grep -c 'chain ufw')
        [ "$LEFT" -eq 0 ] && ok "nft: ufw chains cleared" \
                          || warn "nft: $LEFT ufw chain(s) remain"
    else
        say "iptables can read ufw's chains — no nft cleanup needed"
    fi
else
    say "nft not available — skipping"
fi

# ── 4. tear ufw down to nothing ────────────────────────────────────────────
head_ "4. tearing ufw down"
ufw --force disable >/dev/null 2>&1
for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null || continue
    CHAINS=$("$ipt" -S 2>/dev/null | grep -oE '^-N ufw[A-Za-z0-9_-]*' | awk '{print $2}')
    for c in $CHAINS; do "$ipt" -F "$c" 2>/dev/null; done
    for c in $CHAINS; do "$ipt" -X "$c" 2>/dev/null; done
    # Chains still referenced by the builtin INPUT/FORWARD/OUTPUT jumps cannot
    # be deleted ("CHAIN_DEL failed (Device or resource busy)"), and ufw does
    # not remove those jumps on disable. That is FINE -- `ufw enable` flushes
    # and reuses them. What actually matters is that they are EMPTY, so no stale
    # rule survives the rebuild. Reporting the leftover count as a problem was a
    # false alarm, which is the last thing a rescue script should produce.
    LEFT=$("$ipt" -S 2>/dev/null | grep -cE '^-N ufw')
    STALE=$("$ipt" -S 2>/dev/null | grep -cE '^-A ufw')
    if [ "$STALE" -eq 0 ]; then
        ok "$ipt: ufw chains emptied ($LEFT skeleton chain(s) kept, reused on rebuild)"
    else
        warn "$ipt: $STALE rule(s) still in ufw chains after flush"
    fi
done

# ── 5. rebuild from ufw's own config ───────────────────────────────────────
# user.rules is untouched by any of the above, so the operator's real rules --
# including their SSH allow -- come back exactly as they were.
head_ "5. rebuilding ufw"
if ufw --force enable 2>&1 | sed 's/^/  /'; then :; fi

# ── 6. verify ──────────────────────────────────────────────────────────────
head_ "6. verification"
RC=0
ufw status >/dev/null 2>&1 && ufw status | grep -q 'Status: active' \
  && ok "ufw is active" || { bad "ufw is NOT active"; RC=1; }

LOGCHAINS=$(iptables -S 2>/dev/null | grep -cE '^-N ufw.*logging')
[ "$LOGCHAINS" -ge 9 ] && ok "logging chains complete ($LOGCHAINS)" \
  || { bad "only $LOGCHAINS logging chains — ufw is still half-built"; RC=1; }

SSHRULES=$(iptables -S ufw-user-input 2>/dev/null | grep -c 'dport 22')
if [ "$SSHRULES" -gt 0 ]; then
    ok "ufw has its own SSH rule back:"
    iptables -S ufw-user-input | grep 'dport 22' | sed 's/^/      /'
    iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null \
      && say "removed the temporary blanket ACCEPT"
else
    warn "ufw has NO SSH rule — leaving the blanket tcp/22 ACCEPT in place"
    warn "add one with: ufw allow from <your-ip> to any port 22 proto tcp"
    RC=1
fi

head_ "result"
if [ "$RC" -eq 0 ]; then
    ok "firewall restored and verified"
else
    bad "restore incomplete — SSH should still work, but check the above"
    say "if you are still locked out, run: ufw-rescue --open"
fi
say "snapshot of the broken state kept at: $BACKUP"
exit $RC
