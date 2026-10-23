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
# A skip must never read as coverage. The first CI run skipped on all ten
# legs and the run was green, which says "rootless is tested" to anyone who
# does not read the log.
skip() {
    echo "SKIP  $*"
    echo "      A9 IS NOT COVERED BY THIS LEG — a green leg does not mean rootless was tested."
}

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

dexec sh -c 'apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rootlesskit slirp4netns uidmap dbus-user-session >/dev/null 2>&1' || true
if ! dexec sh -c 'command -v rootlesskit >/dev/null && command -v slirp4netns >/dev/null'; then
    skip "rootlesskit/slirp4netns not available on this base"
    exit 0
fi

say "how will we start the rootless daemon on this base?"
# Debian's docker.io ships the upstream wrapper at
# /usr/share/docker.io/contrib/dockerd-rootless.sh, and a docker-ce host has it
# from docker-ce-rootless-extras. UBUNTU'S docker.io 29.x SHIPS NEITHER --
# verified on 24.04, where contrib holds only check-config.sh and
# nuke-graph-directory.sh, and docker-ce-rootless-extras is not in the archive.
#
# Skipping there costs four of the ten legs, so fall back to invoking
# rootlesskit directly. That is not a reimplementation: the wrapper's whole job
# is this one exec, and the flags below are the ones it passes. The port
# driver matters most and is stated explicitly rather than left to default,
# because `builtin` is what makes a published port a USERSPACE LISTENER -- the
# single fact every assertion in this phase rests on.
#
# Which path was used is printed, because "rootless worked" means something
# slightly different in each case and a reader should not have to guess.
RLSH="$(dexec sh -c 'ls /usr/share/docker.io/contrib/dockerd-rootless.sh /usr/bin/dockerd-rootless.sh 2>/dev/null | head -1' 2>/dev/null)"
if [ -n "$RLSH" ]; then
    echo "using the distro's own wrapper: $RLSH"
    START="export PATH=$(dirname "$RLSH"):/usr/sbin:/usr/bin:/sbin:/bin
           nohup dockerd-rootless.sh --iptables=false > /tmp/rootless.log 2>&1 &"
else
    echo "no dockerd-rootless.sh on this base — invoking rootlesskit directly"
    START="export PATH=/usr/sbin:/usr/bin:/sbin:/bin
           nohup rootlesskit \
               --net=slirp4netns --mtu=65520 --disable-host-loopback \
               --port-driver=builtin \
               --copy-up=/etc --copy-up=/run --propagation=rslave \
               dockerd --iptables=false > /tmp/rootless.log 2>&1 &"
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
    $START
'" || true
# ASK THE DAEMON, do not look for its socket file.
#
# rootlesskit creates the socket before dockerd has finished initialising, and
# it survives dockerd dying. Waiting on `test -S` therefore succeeds on a
# daemon that is already dead -- which is exactly what happened on Ubuntu
# 24.04, where docker.io 29.1.3 panics inside its own Shutdown path during
# NewDaemon. The phase printed `pass rootless daemon up:` with an EMPTY
# version and carried on. A readiness check that cannot fail is not one.
rlver() {
    dexec sh -c "su - rootless -c 'XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock docker version --format {{.Server.Version}}'" 2>/dev/null
}
RLVER=""
for _ in $(seq 1 40); do
    RLVER="$(rlver)"
    [ -n "$RLVER" ] && break
    sleep 1
done
if [ -z "$RLVER" ]; then
    skip "rootless dockerd did not come up on this base (no version from the socket)"
    dexec sh -c 'grep -nE "level=(error|fatal)|^panic|error:" /tmp/rootless.log | tail -10' 2>/dev/null | sed 's/^/      /' || true
    exit 0
fi
pass "rootless daemon up: $RLVER"

say "publish a port from a rootless container"
if ! out="$(dexec sh -c "docker save python:3-alpine | su - rootless -c 'XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock PATH=/usr/sbin:/usr/bin:/sbin:/bin docker load'" 2>&1)"; then
    skip "could not side-load the image into the rootless daemon"
    printf '%s\n' "$out" | tail -10 | sed 's/^/      /'
    exit 0
fi
# SAY WHY. The first CI run skipped here on every leg that got this far, and
# the message alone -- "rootless container would not start" -- was useless:
# ten green legs, zero A9 coverage, and nothing to act on.
if ! out="$(dexec sh -c "su - rootless -c '
    export XDG_RUNTIME_DIR=/run/user/$UID_R DOCKER_HOST=unix:///run/user/$UID_R/docker.sock PATH=/usr/sbin:/usr/bin:/sbin:/bin
    docker run -d --name rl-web -p $PORT:80 python:3-alpine python -m http.server 80
'" 2>&1)"; then
    skip "rootless container would not start"
    printf '%s\n' "$out" | tail -10 | sed 's/^/      /'
    echo "      --- rootless daemon log ---"
    dexec sh -c 'tail -15 /tmp/rootless.log' 2>/dev/null | sed 's/^/      /' || true
    exit 0
fi
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
