#!/bin/sh
# test/fault-locker.t - the locker is KILLED, and the ladder must notice.
#
# FAULT: locker-killed-while-locked. The first cell of test/faults, and the
# shape every other one should follow: inject a REAL fault into a REAL
# component, then assert the response the declaration promises. Not "it
# survived" -- a fault that produces no response is the finding.
#
# WHY THIS ONE FIRST. A locker dying is the failure mode with the worst
# consequence: the screen is unlocked and the ladder still believes it is at
# `lock`, so every tier that trusts the record agrees the session is secured
# while anyone can walk up to it. The provider arms a recovery for exactly this
# (ExecStopPost crosses `open` when the unit's cgroup empties, crash included)
# and NOTHING HAS EVER TESTED THAT IT FIRES -- lock-span.t asserts systemd runs
# the ExecStopPost, which is a different claim from the ladder following it.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-locker
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

wire lock ''      swaylock
wire lock .verify locker-up

# --- given: a genuinely locked machine --------------------------------------
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "go lock failed before the fault could be injected"
await 10 locker_up || fail "no locker came up, so there is nothing to kill"
[ "$(depth)" = lock ] || fail "depth is '$(depth)', not lock"

# --- when: the locker is killed outright ------------------------------------
# SIGKILL, not SIGTERM. A polite exit is the path that already works; the one
# that matters is the locker being destroyed without a chance to tidy up,
# because that is what a crash, an OOM kill or a compositor restart looks like.
_before=$(crossed unlock)
pkill -KILL -x swaylock || fail "pkill found no swaylock to kill"

# --- then: the ladder must come back to a rung that is TRUE -----------------
_open() { [ "$(depth)" = open ]; }
await 20 _open || fail "the locker was KILLED and the machine still records
depth='$(depth)'. The screen is unlocked and every tier that trusts the record
says the session is secured -- which is the worst failure this package has,
because nothing about it looks wrong"
[ "$(crossed unlock)" -gt "$_before" ] || fail "depth reached open without the
unlock edge being crossed. The rung is right and no hook ran, so anything that
restores on unlock did not"
locker_up && fail "a swaylock is still running after the kill"

# --- and: the wreckage must not outlive the fault ---------------------------
# A fault that leaves the machine reporting findings for ever is only half
# handled. This is where the stale-save class lived: an interrupted descent
# whose record survived and failed every later ascent.
_rep=$("$VIGILANT" report 2>&1) || true
_no_fail_in "$_rep" "recorded state" "after a killed locker the machine still
reports outstanding state. The fault is over; its wreckage should be too"

# ...and the machine must still be usable. A recovery that leaves the ladder
# unable to lock again has converted a transient fault into a permanent one.
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "the machine could not lock again after recovering from the kill"
await 10 locker_up || fail "the second lock crossed its edge but brought up no
locker; the recovery left the provider unable to work"

pass
