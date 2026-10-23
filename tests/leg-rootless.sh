#!/usr/bin/env bash
#
# A9: rootless Docker ALONGSIDE a rootful daemon.
#
# FUTURE.md expected this to be the bad case -- "the rootless containers are
# neither protected nor mentioned". Standing it up showed that half right, and
# the wrong half matters:
#
#   NOT protected   -- false. A rootless published port is a userspace
#                      listener on the host, not a DNAT. Its traffic arrives
#                      on INPUT, so ORDINARY ufw rules govern it. Measured:
#                      zero rules in iptables-save mention the port, and
#                      `ufw deny <port>` blocks it outright.
#   NOT mentioned   -- true, and that was the real defect. `ufw-docker
#                      containers` printed an EMPTY table on a host with a
#                      rootless container publishing a port, and `status` said
#                      nothing. An operator auditing exposure with this tool
#                      got a clean bill of health for a port that was open.
#
# So this leg asserts both: that the tool now NAMES the rootless daemon, and
# that the INPUT-path claim the warning makes is actually true on this distro.
#
# SKIPS, LOUDLY, where rootless cannot be stood up -- older bases may lack
# rootlesskit or the contrib scripts. A skip is printed as a skip; it must
# never read as a pass.
set -uo pipefail

NAME="${1:?usage: leg-rootless.sh <container>}"
PORT="${2:-18099}"
dexec() { docker exec "$NAME" "$@"; }
say() { printf '\n-- %s\n' "$*"; }
rc=0
fail() { echo "FAIL  $*"; rc=1; }
pass() { echo "pass  $*"; }
skip() { echo "SKIP  $*"; }

# A HELPER, NOT A STYLE CHOICE. `cmd | grep -q pattern` under `set -o pipefail`
# is wrong in TWO independent ways, and this phase hit both before it worked:
#
#   1. grep -q exits the moment it matches, the producer keeps writing into a
#      closed pipe, takes SIGPIPE and exits 141 -- which pipefail makes the
#      status of the whole pipeline. So a MATCH reports failure. Measured: 141.
#
#   2. pipefail also propagates the PRODUCER's own exit status. `ufw-docker
#      status` returns 1 whenever any check is red, so "does its output mention
#      X" came back false purely because something unrelated was wrong.
#
# Both inverted real results: `status` printed `IPv4 wired` in plain sight
# while the check looking for it declared the host unwired. The question being
# asked is "did this command SAY X", which is independent of how it exited --
# so capture the output, discard the status, and match in bash.
#
# Substrings, not regexes: `case` would treat a glob character as one.
says() {   # says <substring> <command...>
    local want="$1"; shift
    local out; out="$("$@" 2>&1 || true)"
    case "$out" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

cleanup() {
    dexec sh -c '
        su - rootless -c "XDG_RUNTIME_DIR=/run/user/1000 DOCKER_HOST=unix:///run/user/1000/docker.sock PATH=/usr/sbin:/usr/bin:/sbin:/bin docker rm -f rl-web" >/dev/null 2>&1
        pkill -u rootless -f dockerd >/dev/null 2>&1
        pkill -u rootless -f rootlesskit >/dev/null 2>&1
        loginctl disable-linger rootless >/dev/null 2>&1
        userdel -r rootless >/dev/null 2>&1
        ufw delete deny '"$PORT"'/tcp >/dev/null 2>&1
        ufw delete allow '"$PORT"'/tcp >/dev/null 2>&1
    ' >/dev/null 2>&1 || true
}
trap cleanup EXIT

# PRECONDITION. `status` returns early on a host where the tool is not
# installed, so the rootless warning would never be printed and the assertions
# below would fail for a reason that has nothing to do with rootless.
say "precondition: the tool is installed"
# Ask `status` rather than grepping after.rules: the marker is
# `BEGIN DOCKER-UFW`, and the first version of this check spelled it backwards.
says 'IPv4 wired' dexec /usr/local/sbin/ufw-docker status \
    || { echo "FAIL  the tool is not installed and wired — status returns early and reports nothing. Not a pass."
         dexec /usr/local/sbin/ufw-docker status 2>&1 | tail -20; exit 1; }

say "is rootless installable on this base?"
# dockerd-rootless.sh ships in the distro's own docker packaging on Debian
# (/usr/share/docker.io/contrib) and in docker-ce-rootless-extras on a
# docker-ce host. Find it rather than hardcoding one of those.
RLSH="$(dexec sh -c 'ls /usr/share/docker.io/contrib/dockerd-rootless.sh /usr/bin/dockerd-rootless.sh /usr/libexec/docker/cli-plugins/../dockerd-rootless.sh 2>/dev/null | head -1' 2>/dev/null)"
if [ -z "$RLSH" ]; then
    skip "no dockerd-rootless.sh on this base — rootless cannot be stood up here"
    exit 0
fi
echo "found: $RLSH"

dexec sh -c 'apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rootlesskit slirp4netns uidmap dbus-user-session >/dev/null 2>&1' || true
if ! dexec sh -c 'command -v rootlesskit >/dev/null && command -v slirp4netns >/dev/null'; then
    skip "rootlesskit/slirp4netns not available on this base"
    exit 0
fi

say "stand up a rootless daemon beside the rootful one"
dexec sh -c '
    set -e
    id rootless >/dev/null 2>&1 || useradd -m -s /bin/bash rootless
    grep -q "^rootless:" /etc/subuid || echo "rootless:100000:65536" >> /etc/subuid
    grep -q "^rootless:" /etc/subgid || echo "rootless:100000:65536" >> /etc/subgid
    loginctl enable-linger rootless
' || { skip "could not prepare the rootless user"; exit 0; }
sleep 2

UID_R="$(dexec id -u rootless)"
# --iptables=false because a rootless daemon has no business writing host
# netfilter rules, and leaving it on inside a privileged container lets it try.
# PATH must include /usr/sbin: dockerd lives there and is NOT on a normal
# user's PATH, which fails as a bare `exec: dockerd: not found` from inside
# rootlesskit and reads like a rootless problem rather than a PATH one.
dexec sh -c "su - rootless -c '
    export XDG_RUNTIME_DIR=/run/user/$UID_R
    export PATH=$(dirname "$RLSH"):/usr/sbin:/usr/bin:/sbin:/bin
    nohup dockerd-rootless.sh --iptables=false > /tmp/rootless.log 2>&1 &
'" || true
for _ in $(seq 1 30); do
    dexec test -S "/run/user/$UID_R/docker.sock" && break
    sleep 1
done
if ! dexec test -S "/run/user/$UID_R/docker.sock"; then
    skip "rootless dockerd did not come up on this base"
    dexec sh -c 'tail -5 /tmp/rootless.log' 2>/dev/null || true
    exit 0
fi
pass "rootless daemon up: $(dexec sh -c "su - rootless -c 'XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock docker info --format {{.ServerVersion}}'" 2>/dev/null)"

say "publish a port from a rootless container"
dexec sh -c "docker save python:3-alpine | su - rootless -c 'XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock PATH=/usr/sbin:/usr/bin:/sbin:/bin docker load'" >/dev/null 2>&1 \
    || { skip "could not side-load the image into the rootless daemon"; exit 0; }
dexec sh -c "su - rootless -c '
    export XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock PATH=/usr/sbin:/usr/bin:/sbin:/bin
    docker run -d --name rl-web -p $PORT:80 python:3-alpine python -m http.server 80
'" >/dev/null 2>&1 || { skip "rootless container would not start"; exit 0; }
sleep 4

LEGIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
# `|| true`, NOT `|| echo 000`. curl's -w already prints 000 when the
# connection is refused AND exits non-zero, so the obvious-looking fallback
# emits "000000" -- which compares unequal to "000", so every BLOCKED result
# was read as reachable. That is what made this phase claim ufw's default-deny
# does not cover a rootless port, when it does.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$LEGIP:$PORT/" 2>/dev/null || true; }

say "assertions"

# FIRST, before any ufw rule for this port exists. Counting afterwards counts
# the rule we just added: the first version of this phase did exactly that and
# reported "1 iptables rule(s) mention 18099 — the INPUT-path explanation is
# wrong", having found its own `ufw allow`.
n="$(dexec sh -c "iptables-save 2>/dev/null | awk '/$PORT/{n++} END{print n+0}'")"
[ "${n:-0}" -eq 0 ] \
    && pass "no iptables rule mentions the published port (it is a userspace listener)" \
    || { fail "$n iptables rule(s) mention $PORT before we add any — the INPUT-path explanation is wrong"
         dexec sh -c "iptables-save | grep $PORT" || true; }

# ufw is ACTIVE on a leg with the default deny-incoming policy, so the very
# first observation is the one the warning text claims: ufw's default policy
# reaches a rootless published port, which is exactly how bridge containers do
# NOT behave. An earlier version asserted reachability up front and failed
# here -- reading a correct default-deny as "the port never came up".
if [ "$(code)" = 000 ]; then
    pass "ufw's DEFAULT deny already covers the rootless port (unlike a bridge container)"
else
    fail "the rootless port was reachable despite ufw default-deny — the default-policy claim is wrong"
    # Say enough to tell a wrong claim from a wrong fixture. Measured on a
    # clean leg this is 000 both with and without ufw-docker installed, so a
    # 200 here means something about THIS host differs, and these four lines
    # are what distinguishes the cases.
    dexec sh -c 'ufw status verbose | head -5' || true
    dexec sh -c "ufw status | grep -F '$PORT' || echo '(no ufw rule for the port)'" || true
    dexec sh -c "ss -tlnp 2>/dev/null | grep -F '$PORT'" || true
    dexec sh -c 'iptables -L ufw-user-input -n -v | head -8' || true
fi

dexec sh -c "ufw allow $PORT/tcp" >/dev/null 2>&1
sleep 1
[ "$(code)" = 200 ] \
    && pass "plain 'ufw allow <published port>' opens it" \
    || { fail "'ufw allow $PORT/tcp' did not open the rootless port — the rest proves nothing"
         dexec sh -c "ufw status | grep $PORT" || true; exit 1; }
dexec sh -c "ufw delete allow $PORT/tcp" >/dev/null 2>&1
sleep 1

says 'rootless Docker daemon' dexec /usr/local/sbin/ufw-docker status \
    && pass "status NAMES the rootless daemon" \
    || fail "status is silent about a rootless daemon — the A9 defect"

says 'rootless Docker daemon' dexec /usr/local/sbin/ufw-docker containers \
    && pass "containers says its table does not cover the rootless daemon" \
    || fail "containers printed its table with no mention of the rootless daemon"

# And closing it explicitly, which is the direction an operator actually needs.
dexec sh -c "ufw deny $PORT/tcp" >/dev/null 2>&1
sleep 1
[ "$(code)" = 000 ] \
    && pass "plain 'ufw deny <published port>' closes it (it arrives on INPUT)" \
    || fail "'ufw deny $PORT/tcp' did NOT close the rootless port — status tells operators it would"
dexec sh -c "ufw delete deny $PORT/tcp" >/dev/null 2>&1

exit $rc
