#!/bin/sh
# test/fault-inhibit.t - the inhibit bound ACTS: a real logind inhibitor, a
# real idle clock, a real locker.
#
# WHY THIS CELL EXISTS. The bound's forcing half is the ONLY actuator in
# supervision, and `enforce`'s own forcing was retired partly for having never
# acted in production. Every proof of this one was an injected clock in the
# stub tier: the span backdated in a file, the locker a recorder. So the thing
# that can take the lock had never once run end to end.
#
# NOTHING HERE IS FAKED, which is the whole point and was the hard part:
#
#   the inhibitor   a real `systemd-inhibit --what=idle` against real logind
#   the idle clock  x11-idle, reading the real X server's own idle counter
#   the deadline    a due.d declaration, which is an integrator's to make
#   the bounds       knobs, likewise
#   the locker      the real provider starting a real transient unit
#
# THE IDLE CLOCK IS WHY THIS WAS NOT OBVIOUSLY BUILDABLE. The shipped source
# counts kernel interrupts and USB URBs, which this guest cannot do at all, so
# the overdue tier is structurally inert here and the escalation is only ever
# reached from the idle-anchored branch. Faking a clock is on this suite's own
# list of things that may never be faked. x11-idle is a real one, and the
# guest's X server has no input at all, so its idle time is genuinely large.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-inhibit
require x11 userbus

DISPLAY=:99; export DISPLAY

session_reset
wire lock '' systemd-locker          # a REAL locker, as a transient unit
wire_cross idle x11-idle             # a REAL idle clock

# THE DEADLINE IS A DECLARATION, not a fixture: a due.d hook printing seconds
# and an anchor is exactly the contract an integrator fills, and a short one is
# as legitimate as a long one. Five seconds keeps the cell to a few seconds of
# real waiting instead of the eight minutes this fleet declares.
mkdir -p "$HOOKS/lock.due.d"
printf '#!/bin/sh\nprintf %s\n' "'5 idle'" > "$HOOKS/lock.due.d/50-short"
chmod +x "$HOOKS/lock.due.d/50-short"

# GRACE EXISTS TO LET THE PRIMARY MECHANISM WIN THE RACE, and at its shipped
# 30s it would dominate a 5s deadline entirely. Narrowing it is configuration,
# and the knob is documented for exactly this.
VIGILANCE_GRACE=1; export VIGILANCE_GRACE
VIGILANCE_INHIBIT_REPORT=2; export VIGILANCE_INHIBIT_REPORT
VIGILANCE_INHIBIT_FORCE=6; export VIGILANCE_INHIBIT_FORCE

_hold=
_release() { [ -n "$_hold" ] && kill "$_hold" 2>/dev/null || true; _hold=; }
trap '_release' EXIT

_idle_now() { "$PLUGINS/hooks/x11-idle" 2>/dev/null | awk '{print $1}'; }

# THE SHIPPED READER, not a second copy. hook_idle_inhibited carries the
# three-answer contract, and asking logind a different way here would let the
# cell and the product disagree about whether a hold exists.
#
# FUNCTIONS, because `await` takes a COMMAND and not a string: handing it
# `'[ ... ]'` looks for a program of that name and times out into a failure
# about the product. That has cost this suite two debugging rounds.
. "$HOOKLIB"
_inhibited() { hook_idle_inhibited; }
_uninhibited() {   # rc 1 EXACTLY: "cannot tell" is not "released"
  _ui=0; hook_idle_inhibited || _ui=$?
  [ "$_ui" = 1 ]
}
_unwound() { [ "$(crossed unlock)" -ge 1 ]; }

# --- 0. THE PRECONDITION, or everything below passes for the wrong reason ----
# A fault that did not take makes every assertion after it meaningless, which
# is the rule `chmod a-w` as root taught these cells. Two halves: the clock has
# to answer, and it has to answer past the deadline.
_i=$(_idle_now)
case "${_i:-}" in
  ''|*[!0-9]*) fail "x11-idle did not answer a number, so there is no idle
clock here and the escalation can never be reached: got '${_i:-}'" ;;
esac
[ "$_i" -gt 6 ] || fail "the X server reports only ${_i}s idle, under the 5s
deadline plus 1s grace, so the edge is not due and nothing below is a
statement about the bound"

"$VIGILANT" go open >/dev/null 2>&1 || true

# --- 1. A HELD INHIBITOR DEFERS, SILENTLY, under the report bound -----------
systemd-inhibit --what=idle --who=vig-cell --why='a real hold' sleep 120 &
_hold=$!
await 10 _inhibited || fail "logind did not report the idle inhibitor this
cell holds, so the hold never took and the deferral below would be about
nothing"

LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$VIGILANT" enforce >/dev/null 2>&1 || true
[ "$(crossed lock)" = 0 ] || fail "the first pass under the report bound
crossed the lock edge. A call is not a fault, and acting inside the bound is
the whole thing the gap between the bounds exists to prevent"
said 'OVERDUE' && fail "a deadline deferred by a real held inhibitor was
reported OVERDUE, which is the 27-alerts-in-93-minutes storm on real
components rather than against a fixture"

# --- 2. PAST THE FORCE BOUND IT ACTS, and the crossing is attributable ------
# THE SPAN IS REAL TIME HERE: the supervision pass opened it on the call above,
# so waiting is the only way past the bound. That is the cost of the cell and
# the reason the bounds are seconds rather than hours.
sleep 8
LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$VIGILANT" enforce >/dev/null 2>&1 || true
[ "$(crossed lock)" -ge 1 ] || fail "past the force bound, with the seat
genuinely idle and a real inhibitor held, the session was NOT secured. This is
the one actuator in supervision and it has never run outside a stub tier:
$(logsince)"
said 'src=inhibit-bound' || fail "the forced lock crossed the edge without
naming itself, so the one crossing nobody will expect is the one nothing
attributes: $(logsince)"

# AND THE REAL LOCKER ACTUALLY RAN, which is what the stub tier cannot show.
# A headless guest's locker cannot survive, so its exit drives the provider's
# ExecStopPost and the ladder follows back out: that UNWIND is the proof the
# transient unit genuinely started, and it is why this asserts an EDGE rather
# than a resting depth. Three other cells in this tier carry the same note.
await 20 _unwound || fail "no locker ever came up: the ladder recorded 'lock'
and nothing unwound it, so the provider did not start a real unit. The force
would then be recording a lock that never happened: $(logsince)"

# --- 3. A RESET STOPS IT HAPPENING AGAIN -----------------------------------
# The escalation is interruptible, and that is what makes the force safe. Here
# against the real clock rather than a backdated file.
"$VIGILANT" go open >/dev/null 2>&1 || true
"$VIGILANT" timer reset >/dev/null 2>&1 \
  || fail "timer reset failed while a real inhibitor was held"
LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$VIGILANT" enforce >/dev/null 2>&1 || true
[ "$(crossed lock)" = 0 ] || fail "a reset hold was forced to lock anyway,
which is the one thing the reset exists to prevent: $(logsince)"

# --- 4. AND RELEASING IT RESTORES THE DETECTOR -----------------------------
# Otherwise the fix is indistinguishable from having switched the overdue tier
# off, which is the trade every guard in this suite has to be checked against.
_release
await 10 _uninhibited || fail "the inhibitor did not release, so the case
below cannot tell a restored detector from a suppressed one"
LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$VIGILANT" enforce >/dev/null 2>&1 || true
said 'OVERDUE' || fail "with the hold released and the seat still idle past
the deadline, the overdue detector stayed silent. The deferral has switched it
off rather than deferring it: $(logsince)"

pass "a real logind inhibitor deferred a real idle deadline, the bound secured\
 the session with a real locker and said src=inhibit-bound, a reset stopped a\
 second one, and releasing it restored the detector"
