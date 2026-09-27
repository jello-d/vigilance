#!/bin/sh
# test/fault-lid.t - a REAL lid switch, through logind, into the ladder.
#
# FAULTS: lid-close-at-open, lid-close-at-sleep.
#
# WHY A REAL LID AND NOT `loginctl lock-session`. The bug these cells exist for
# (5bea063) was about what a LID does, and every test of that path so far used
# the SIGNAL rather than the CAUSE:
#
#   19:21:47  Lid closed (on AC)  ->  cross wake: sleep -> lock
#   19:22:47  OVERDUE sleep: seat idle 2725s against a 600s deadline
#   ...27 more, one a minute...
#   19:51:28  Lid opened                     <- the only thing that ended it
#
# logind answers a lid close with Session.Lock, `go` is DECLARATIVE and travels
# in whichever direction reaches its target, so from `sleep` it crossed `wake`
# and LIT THE PANEL. Lid shut, screen on, thirty minutes. `go <rung> atleast` is
# the fix, and this is the first test to drive it from an actual switch.
#
# WHAT IT TOOK TO GET HERE, because each piece silently holds the chain open:
#
#   a lockable session   `Class=greeter` CANNOT be locked -- logind answers
#                        "Session does not support lock screen" -- so greetd's
#                        default slot is no use. Measured: `su -l` gives
#                        Class=user, and that one locks.
#   a reachable trigger  the unit rendered for root points into /root, which
#                        vig cannot read, so as vig it sits at `activating`
#                        for ever. /opt/vigilance is vig-readable.
#   lid policy = lock    the guest defaulted to HandleLidSwitch=suspend, so a
#                        synthetic lid close SUSPENDED the machine running the
#                        test. Very likely why this scenario hung the guest when
#                        it was first attempted and had to be set aside.
#
# AND THE FIRST CLOSE IS NOT ACTED ON. Measured, three in a row: logind logged
# four lid-closed events and only two "Locking sessions". The first produced
# nothing; every later one worked. The cause is logind's and is NOT explained
# here, so this PRIMES and then ASSERTS that priming worked, rather than letting
# a missed event read as a passing case.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-lid

VUID=$(id -u vig 2>/dev/null || echo)
VRUN=/run/user/${VUID:-0}
VLOG=/home/vig/.local/state/vigilance.log
V=/opt/vigilance/bin/vigilant
UNIT=/etc/systemd/user/vigilance-logind.service
AS="sudo -u vig -H env XDG_RUNTIME_DIR=$VRUN HOME=/home/vig"
AS="$AS DBUS_SESSION_BUS_ADDRESS=unix:path=$VRUN/bus"
HOLD=

_cleanup() {
  if [ -n "${HOLD:-}" ]; then kill "$HOLD" 2>/dev/null || true; fi
  $AS systemctl --user stop vigilance-logind.service >/dev/null 2>&1 || true
  rm -f "$UNIT" 2>/dev/null || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

# A vig session logind will actually lock, or empty. `if`, never `[ ] &&`: an
# AND-OR list whose test fails returns non-zero and `set -e` kills the shell.
_lockable() {
  loginctl list-sessions --no-legend 2>/dev/null \
    | while read -r _i _u _nm _r; do
        if [ "$_nm" = vig ]; then
          _c=$(loginctl show-session "$_i" -p Class --value 2>/dev/null || true)
          if [ "${_c:-}" = user ]; then printf '%s' "$_i"; return 0; fi
        fi
      done
}
_depth_vig() { $AS "$V" status 2>/dev/null | awk '/^depth:/ {print $2}'; }
_vlog_at()   { wc -l < "$VLOG" 2>/dev/null || echo 0; }
_vlog_since() { tail -n +$(( ${1:-0} + 1 )) "$VLOG" 2>/dev/null || true; }
# The switch is a STATE, not an edge, so the device must stay alive long enough
# for logind to read it. uinject holds it and destroys it on exit.
_close_lid() {
  # HELD ACROSS THE MEASUREMENT. A switch is a STATE, not an edge, which
  # uinject's own header says and my first version ignored: it held the lid for
  # 4s and asserted at 8s, so every assertion ran against a lid that had already
  # been released and a device that no longer existed.
  python3 "$HERE/test/uinject" lid close 14 >/dev/null 2>&1 &
  _cl=$!
  sleep 8
  kill "$_cl" 2>/dev/null || true
  wait "$_cl" 2>/dev/null || true
}

# --- the substrate this needs, each asserted rather than assumed ------------
command -v python3 >/dev/null 2>&1 \
  || fail "no python3, so uinject cannot synthesise a lid switch and every case
below would assert against an event that never happened"
[ -c /dev/uinput ] || modprobe uinput >/dev/null 2>&1 || true
[ -c /dev/uinput ] || fail "no /dev/uinput; the lid cannot be injected here"
[ -n "${VUID:-}" ] || fail "no vig user. This runs as a second account because
root's own session is manager-class and logind refuses to lock one"
[ -x "$V" ] || fail "no published vigilant at $V. This runs as vig, so it needs
the SHARED install rather than root's user prefix"

# @PLUGINS@ substituted with the PUBLISHED tree, not root's: the whole reason a
# shared install exists is that another uid has to run these.
mkdir -p /etc/systemd/user
sed "s#@PLUGINS@#/opt/vigilance/libexec/vigilance#g" \
  "$HERE/systemd/vigilance-logind.service" > "$UNIT" \
  || fail "could not render the logind listener unit"
$AS systemctl --user daemon-reload >/dev/null 2>&1 || true
$AS systemctl --user restart vigilance-logind.service >/dev/null 2>&1 || true

# `su -l`, because pam_systemd registers a Class=user session for it.
setsid su -l vig -c 'sleep 180' >/dev/null 2>&1 &
HOLD=$!
_n=0
while [ "$_n" -lt 60 ]; do
  if [ -n "$(_lockable)" ]; then break; fi
  sleep 0.25; _n=$((_n + 1))
done
[ -n "$(_lockable)" ] || fail "no lockable Class=user session for vig appeared.
logind will not send Session.Lock to a greeter- or manager-class session, so
without one a lid close has nowhere to land and every case below would pass"
[ "$($AS systemctl --user is-active vigilance-logind.service 2>&1)" = active ] \
  || fail "vigilance's logind listener is not active for vig, so nothing is
waiting for Session.Lock and a silent 'no response' would look like a decline"

# --- PRIME, and assert the priming worked -----------------------------------
# The first close after the device first appears produces no lock (measured).
# Without this the first real case is testing a missed event, and "the machine
# did not move" is exactly what a passing lid-close-at-sleep looks like.
$AS "$V" force open >/dev/null 2>&1 || true
_p0=$(_vlog_at)
_close_lid
if [ "$(_vlog_at)" = "$_p0" ]; then
  # Expected on the first close; try once more before giving up.
  _p0=$(_vlog_at)
  _close_lid
fi
[ "$(_vlog_at)" != "$_p0" ] || fail "two lid closes produced NOTHING in
vigilance's log, so the chain from switch to ladder is not connected on this
substrate and nothing below would be a test of vigilance"

# --- 1. FAULT lid-close-at-open: it must DESCEND to lock --------------------
# The ordinary case, and the one the ladder should handle without drama: a lid
# close while the machine is awake is a request to secure the session.
$AS "$V" force open >/dev/null 2>&1 || true
[ "$(_depth_vig)" = open ] || fail "fixture: depth is '$(_depth_vig)', not open"
_a0=$(_vlog_at)
_close_lid
# ASSERTED ON THE EDGE, NOT THE RESTING DEPTH, and the difference is not
# pedantry. Measured here: the lid crossed `lock` correctly and two seconds
# later the machine was back at `open`, because the provider started a locker,
# the locker could not survive on a headless guest, and its
# ExecStopPost=`vigilant go open` unwound the ladder. THAT IS CORRECT -- it is
# the recovery locker-killed-while-locked exists to assert -- so demanding a
# resting depth of `lock` here would fail this cell over another cell's
# behaviour, and the log is the durable record of what the lid actually did.
printf '%s\n' "$(_vlog_since "$_a0")" | grep -q 'cross lock: open -> lock' \
  || fail "a REAL lid close at the open rung did not cross the lock edge. The
lid is a request to secure the session, and this is the one path a user notices
immediately. Log said:
$(_vlog_since "$_a0" | head -5)"

# --- 2. FAULT lid-close-at-sleep: it must NOT be RAISED ---------------------
# THE BUG ITSELF. `go` is declarative, so answering a security request from a
# DEEPER rung used to travel upward: lid shut, panel lit, thirty minutes, and
# nothing to bring it down because a lid switch is not seat input to the
# compositor so swayidle never saw a resume.
$AS "$V" force sleep >/dev/null 2>&1 || true
[ "$(_depth_vig)" = sleep ] \
  || fail "fixture: depth is '$(_depth_vig)', not sleep"
_b0=$(_vlog_at)
_close_lid
[ "$(_depth_vig)" = sleep ] || fail "A REAL LID CLOSE RAISED THE MACHINE from
sleep to '$(_depth_vig)'. That is the 5bea063 bug: the panel lights with the lid
shut, and a lid switch is not seat input, so nothing brings it back down. Log:
$(_vlog_since "$_b0" | head -4)"

# AND IT SAID SO. A security request that was refused must not vanish: the
# audit tier reconciles a lid event against this line, and without it every
# lid-close on a sleeping box reads as an unhandled event.
printf '%s\n' "$(_vlog_since "$_b0")" | grep -q 'deeper than' \
  || fail "the machine correctly stayed at sleep and never recorded WHY. A
declined security request that leaves no trace is indistinguishable from a lid
close nobody noticed. Log:
$(_vlog_since "$_b0" | head -4)"
printf '%s\n' "$(_vlog_since "$_b0")" | grep -q 'cross wake' \
  && fail "the log records crossing 'wake' from a lid close, which is the exact
ascent that lit the panel for thirty minutes" || :

pass
