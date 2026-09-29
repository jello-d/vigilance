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
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-lid

# THE PLUMBING IS SHARED (test/session_lib), because all three preconditions
# above are easy to get subtly wrong and a wrong one does not fail loudly: the
# signal simply never arrives, and "the machine did not move" is exactly what a
# passing lid-close-at-sleep looks like.
_cleanup() { lockable_stop; session_done; rm -rf "$T"; }
trap '_cleanup' EXIT INT TERM HUP

_vlog_at()    { wc -l < "$(lockable_log)" 2>/dev/null || echo 0; }
_vlog_since() {
  tail -n +$(( ${1:-0} + 1 )) "$(lockable_log)" 2>/dev/null || true
}
# The switch is a STATE, not an edge, so the device must stay alive across the
# measurement. uinject's own header says so and my first version ignored it: it
# held the lid 4s and asserted at 8s, against a lid already released.
_close_lid() {
  python3 "$HERE/test/uinject" lid close 14 >/dev/null 2>&1 &
  _cl=$!
  sleep 8
  kill "$_cl" 2>/dev/null || true
  wait "$_cl" 2>/dev/null || true
}

command -v python3 >/dev/null 2>&1 \
  || fail "no python3, so uinject cannot synthesise a lid switch and every case
below would assert against an event that never happened"
[ -c /dev/uinput ] || modprobe uinput >/dev/null 2>&1 || true
[ -c /dev/uinput ] || fail "no /dev/uinput; the lid cannot be injected here"
lockable_start

# --- PRIME, and assert the priming worked -----------------------------------
# The first close after the device first appears produces no lock (measured).
# Without this the first real case is testing a missed event, and "the machine
# did not move" is exactly what a passing lid-close-at-sleep looks like.
lockable_as "$LOCKABLE_V" force open >/dev/null 2>&1 || true
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
lockable_as "$LOCKABLE_V" force open >/dev/null 2>&1 || true
[ "$(lockable_depth)" = open ] \
  || fail "fixture: depth is '$(lockable_depth)', not open"
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
lockable_as "$LOCKABLE_V" force sleep >/dev/null 2>&1 || true
[ "$(lockable_depth)" = sleep ] \
  || fail "fixture: depth is '$(lockable_depth)', not sleep"
_b0=$(_vlog_at)
_close_lid
[ "$(lockable_depth)" = sleep ] || fail "A REAL LID CLOSE RAISED THE MACHINE
from sleep to '$(lockable_depth)'. That is the 5bea063 bug: the panel lights
with the lid shut, and a lid switch is not seat input, so nothing brings it
back down. Log:
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
