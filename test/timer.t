#!/bin/sh
# test/timer.t - `vigilant timer`: what is counting, and how long is left.
#
# WHY THE VERB EXISTS. These countdowns had no home. The inhibit hold was
# visible nowhere at all, and "when will it lock" needed `due` plus arithmetic.
# It is also the question an operator asks the moment a toast says the session
# will be secured in an hour, so the answer has to be one command.
#
# THE LOAD-BEARING ASSERTION IS THE FIRST ONE: nothing here counts on its own.
# A supervision pass samples these clocks, so on a box whose timer has died
# every number is the last thing anyone measured, frozen, and printing it as a
# countdown would mislead in the reassuring direction. That is this package's
# signature failure, so the view has to say which it is before it says anything
# else.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init timer

_t() { "$VIGILANT" timer 2>>"$T/stderr"; }

# --- 1. THE SUBCOMMAND CONTRACT ---------------------------------------------
# AN UNRECOGNISED QUALIFIER IS A USAGE ERROR, never something to drop. The `go`
# arm learned this the hard way: it ignored everything after the state, so a
# caller asking for a safety mode silently got the default. A verb that can be
# misspelt into a no-op is worse than one that does not exist, because the
# operator believes it worked.
_rc=0; "$VIGILANT" timer frobnicate >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown 'timer' subcommand exited $_rc, not 2. A
qualifier that can be misspelt into the default view is how a reset silently
does not happen"

# AND THE RENAMED VERB POINTS HERE rather than failing as unknown. `ack`
# shipped for a few hours, and a notification delivered before the rename names
# it in its text; a toast can sit in a tray for days, so somebody will type it.
_rc=0; _out=$("$VIGILANT" ack 2>&1) || _rc=$?
[ "$_rc" = 2 ] || fail "'ack' exited $_rc; a retired verb must fail loudly,
which is the whole lesson of the 'check' stub that was aliased to 'status'"
case "$_out" in
  *"timer reset"*) ;;
  *) fail "'ack' did not name its replacement, so a reader holding an old
notification is told only that they are wrong: $_out" ;;
esac

# --- 2. NO STAMP IS "UNKNOWN", NOT "NOTHING IS ADVANCING" -------------------
# Those differ for exactly one deploy window: a box running the previous
# version advances these clocks and writes no stamp, so claiming nothing is
# advancing would confidently deny a supervision pass that is plainly working.
# The first draft said "never, so nothing below is advancing yet".
rm -f "$VIGILANCE_RUN_DIR/last-pass"
case "$(_t)" in
  *UNKNOWN*) ;;
  *) printf '%s\n' "$(_t)" >&2
     fail "with no pass stamp the view must say the state is UNKNOWN. Either
alternative is a claim it cannot support" ;;
esac

# --- 3. A STALE STAMP SAYS THE COUNTDOWNS ARE FROZEN ------------------------
# The whole reason the view leads with this. A number that is not advancing,
# printed as "secure in 5400s", is the reassuring direction.
printf '%s\n' "$(( $(date +%s) - 9000 ))" > "$VIGILANCE_RUN_DIR/last-pass"
case "$(_t)" in
  *FROZEN*) ;;
  *) printf '%s\n' "$(_t)" >&2
     fail "a supervision pass 9000s stale must be reported as FROZEN; without
it every countdown below reads as live" ;;
esac

# ...and a RECENT one does not cry wolf, or the warning is permanently on and
# the view stops being read, which is how a live box once had its enforce timer
# stopped by hand.
printf '%s\n' "$(date +%s)" > "$VIGILANCE_RUN_DIR/last-pass"
case "$(_t)" in
  *FROZEN*) printf '%s\n' "$(_t)" >&2
     fail "a pass that ran just now was reported as FROZEN" ;;
esac

# --- 4. NO HOLD SAYS SO, and names no countdown ----------------------------
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED
rm -f "$VIGILANCE_RUN_DIR/inhibit-since" "$VIGILANCE_RUN_DIR/inhibit-clock"
_o=$(_t)
case "$_o" in
  *"none held"*) ;;
  *) printf '%s\n' "$_o" >&2; fail "with no inhibitor held the view must say
so plainly" ;;
esac
case "$_o" in
  *secure:*) printf '%s\n' "$_o" >&2
     fail "a bound was counted down with no hold to count. There is nothing
deferred, so a 'secure in Ns' line there is a countdown to nothing" ;;
esac

# --- 5. A HELD INHIBITOR: the hold, the holder, and BOTH bounds ------------
# AN INJECTED CLOCK, not a fixture standing in for one: the span is read from
# the file the supervision pass writes, so backdating it is the real mechanism
# with a different number in it.
printf '%s\n' "$(( $(date +%s) - 9000 ))" > "$VIGILANCE_RUN_DIR/inhibit-since"
VIGILANCE_INHIBIT_REPORT=10800; export VIGILANCE_INHIBIT_REPORT
VIGILANCE_INHIBIT_FORCE=14400; export VIGILANCE_INHIBIT_FORCE
_o=$(_t)
case "$_o" in
  *HELD*9000s*) ;;
  *) printf '%s\n' "$_o" >&2; fail "the view did not report the hold and its
age, which is the question the verb exists to answer" ;;
esac
# THE ARITHMETIC IS THE POINT, so it is asserted rather than eyeballed: a view
# that printed the bound instead of the remainder would look identical at a
# glance and be useless.
case "$_o" in
  *"report: in 1800s"*) ;;
  *) printf '%s\n' "$_o" >&2; fail "9000s into a 10800s report bound leaves
1800s, and the view did not say so. Printing the BOUND rather than the
remainder reads the same and answers a different question" ;;
esac
case "$_o" in
  *"secure: in 5400s"*) ;;
  *) printf '%s\n' "$_o" >&2; fail "9000s into a 14400s force bound leaves
5400s, and the view did not say so" ;;
esac
# AND THE REMEDY IS IN THE VIEW, because an operator reading a countdown to a
# forced lock needs the way to stop it without going to the man page.
case "$_o" in
  *"timer reset"*) ;;
  *) printf '%s\n' "$_o" >&2; fail "the view counts down to a forced lock and
does not name the command that defers it" ;;
esac

# --- 6. A RESET MOVES THE REMAINDER, not the hold --------------------------
# The two numbers are different and the view shows both: the hold keeps
# counting (it has not ended) while the escalation restarts. Showing only the
# hold would make the bounds look wrong after a reset.
VIGILANCE_BLOCK_INHIBITED=idle; export VIGILANCE_BLOCK_INHIBITED
"$VIGILANT" timer reset >/dev/null 2>>"$T/stderr" \
  || fail "timer reset failed while an inhibitor was held"
_o=$(_t)
case "$_o" in
  *HELD*9000s*) ;;
  *) printf '%s\n' "$_o" >&2; fail "the reset ended the HOLD as well as the
escalation. The hold is logind's to end, not ours: a reset says 'this is
expected', not 'this is over'" ;;
esac
# THE PROPERTY, NOT THE DIGITS. The first draft matched "in 108" and failed on
# "in 10799s": a second elapses between the reset and the view, so pinning the
# leading digits asserts the clock's resolution rather than its behaviour.
_rem=$(printf '%s\n' "$_o" | sed -n 's/^  report: in \([0-9]*\)s$/\1/p')
case "${_rem:-}" in
  ''|*[!0-9]*) printf '%s\n' "$_o" >&2
    fail "could not read a report remainder out of the view at all" ;;
esac
[ "$_rem" -ge 10000 ] || fail "after a reset the report bound must count from
NOW, so the remainder is nearly the whole 10800s bound; it read ${_rem}s, which
means the view is reading the HOLD rather than the escalation clock"

# --- 7. A DISABLED BOUND SAYS DISABLED ------------------------------------
# Either knob at 0 is a supported configuration ("report but never act", and
# "trust the inhibitor completely"), so the view must not print a countdown
# for a bound that will never arrive.
VIGILANCE_INHIBIT_FORCE=0; export VIGILANCE_INHIBIT_FORCE
_o=$(_t)
case "$_o" in
  *"secure: disabled"*) ;;
  *) printf '%s\n' "$_o" >&2; fail "with the force bound disabled the view
must say so rather than counting down to something that cannot happen" ;;
esac
VIGILANCE_INHIBIT_FORCE=14400; export VIGILANCE_INHIBIT_FORCE

# --- 8. AN OFFLINE VERB LEAVES THE LADDER ALONE ---------------------------
# `timer` is a view. If it crossed an edge, or wrote a crossing into the log,
# it would manufacture history for the audit tier to reconcile, which is
# THEORY.md's rule for `plan`, `report` and `due` and applies here for the same
# reason. The depth and the log are the two things that would show it.
_d0=$("$VIGILANT" status 2>/dev/null | sed -n 's/^depth: *//p')
_l0=$(wc -c < "$VIGILANCE_LOG" 2>/dev/null || echo 0)
_t >/dev/null
_d1=$("$VIGILANT" status 2>/dev/null | sed -n 's/^depth: *//p')
_l1=$(wc -c < "$VIGILANCE_LOG" 2>/dev/null || echo 0)
[ "$_d0" = "$_d1" ] || fail "the view MOVED the ladder: '$_d0' became '$_d1'"
[ "$_l0" = "$_l1" ] || fail "the view wrote $(( _l1 - _l0 )) bytes to the edge
log. A read-only verb that writes there manufactures history for the audit
tier to reconcile against"

pass "the subcommand contract, ack points here, no stamp is UNKNOWN, a stale\
 pass is FROZEN, both bounds counted and a reset moves only the escalation,\
 disabled says disabled, and the view leaves the ladder alone"
