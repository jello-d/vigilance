#!/bin/sh
# test/session-ladder.t - the real hooks, driven by the real daemons.
#
# THE FIRST SCENARIO IN THE SESSION TIER, and its job is the question no other
# tier asks: with the shipped hook set actually WIRED and the real swayidle
# actually RUNNING, does the ladder behave?
#
# Every case here corresponds to a defect that reached a live box and that both
# existing tiers passed straight through, because both replace the hooks with
# recorders and neither runs a daemon.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init session-ladder
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

# A REPRESENTATIVE INTEGRATION, not tackup's. This package ships its hooks
# unwired by design and the integrator decides the wiring, so the tier cannot
# claim to test THE wiring -- only that the shipped hooks work when wired in a
# reasonable way. The set is chosen from where the defects were: the lock
# provider, the thing that verifies it, the idle clock and the watchdog.
wire lock ''        swaylock
wire lock   .verify locker-up
wire unlock .verify locker-up
wire sleep  .verify locker-up
wire_cross idle     input-counters
wire_cross watchdog swayidle-watchdog

# --- 1. THE REAL HOOK SET MUST NOT MANUFACTURE FINDINGS --------------------
# The cheapest case and one of the most valuable. `report` scanned every file
# any hook kept in its state dir and called it an unrestored brightness save,
# so the first STATEFUL hook -- the idle clock -- earned a permanent FAIL at
# every lit rung. Nothing caught it, because no tier ever had two real hooks
# keeping state at the same time.
#
# Run the clock twice: the first sample has nothing to compare against, so a
# one-shot run never reaches the state-keeping path at all.
#
# SCOPED TO THE SECTIONS THE HOOKS OWN. My first draft took report's whole
# exit status and the VM failed it immediately -- on `machinery`, which reads
# the guest's real systemd and legitimately reports units this substrate never
# enables. That is the fourth time this suite has paid for "one exit code for
# nine sections", and the first thing the new tier did was charge me for it
# again.
"$VIGILANT" report >/dev/null 2>&1 || true
"$VIGILANT" report >/dev/null 2>&1 || true
_rep=$("$VIGILANT" report 2>&1) || true
_no_fail_in "$_rep" "recorded state" "the shipped hook set, wired and run
twice, left state that report reads as an unrestored save. That is the exact
shape of the bug the first stateful hook caused: a permanent FAIL at every lit
rung, on two live boxes, that no tier could see because none ever had two real
hooks keeping state at once"
_no_fail_in "$_rep" actuators "the shipped hooks reported an actuator failure
on an idle open machine"

# --- 2. A REAL LOCK, THROUGH THE REAL PROVIDER -----------------------------
# `go lock` must start a genuine swaylock and `verify lock` must confirm it.
# The stub tier asserts a recorder ran; this asserts a locker EXISTS.
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "go lock failed with the real provider: $(tail -3 "$T/stderr")"
await 10 locker_up || fail "go lock returned success and no swaylock is
running. That is the provider reporting a lock it did not achieve, which is
the single failure this package exists to prevent"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after go lock"
"$VIGILANT" verify lock >>"$T/out" 2>>"$T/stderr" \
  || fail "verify lock FAILED against a genuinely running locker"

# --- 3. A SECURITY REQUEST FROM A DEEPER RUNG MUST NOT RAISE ---------------
# THE LID BUG, end to end and for real. logind emits Session.Lock on lid-close,
# and answering it with a plain `go lock` from `sleep` crossed `wake` and lit
# the panel, with nothing to bring it back down. Two existing tiers passed the
# whole time; the box did not.
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" || true
[ "$(depth)" = sleep ] || fail "could not reach the sleep rung"
_before=$(crossed wake)
"$VIGILANT" go lock atleast >>"$T/out" 2>>"$T/stderr" \
  || fail "the atleast form failed outright"
[ "$(depth)" = sleep ] || fail "a lock request RAISED the machine from 'sleep'
to '$(depth)'. On a lid-close that lights the panel with the lid shut, and
nothing lowers it again because the idle timer has already spent its timeout"
[ "$(crossed wake)" = "$_before" ] || fail "the declined lock request crossed
the wake edge anyway"

# --- 4. TWO LOCK REQUESTS AT ONCE, AGAINST THE REAL PROVIDER ---------------
# cross-lock.t proves the mechanism with recorders. This proves it where it
# actually failed four times: both requests reach a real systemd-run, one is
# refused with "unit already exists", and neither may report failure.
session_reset
wire lock '' swaylock
_before=$(crossed lock)
( "$VIGILANT" go lock >>"$T/a.out" 2>&1; echo "$?" > "$T/a.rc" ) &
( "$VIGILANT" go lock >>"$T/b.out" 2>&1; echo "$?" > "$T/b.rc" ) &
wait
_ra=$(cat "$T/a.rc" 2>/dev/null || echo ?)
_rb=$(cat "$T/b.rc" 2>/dev/null || echo ?)
[ "$_ra" = 0 ] && [ "$_rb" = 0 ] || fail "two concurrent lock requests returned
$_ra and $_rb against the REAL provider. Losing a race is not failing, and this
alerted on the most security-critical edge four times on a live box"
await 10 locker_up || fail "neither concurrent request left a locker running"
[ "$(( $(crossed lock) - _before ))" -le 1 ] || fail "two requests produced
$(( $(crossed lock) - _before )) crossings of the lock edge; the crossing lock
did not serialise them"

pass
