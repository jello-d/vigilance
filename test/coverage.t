#!/bin/sh
# test/coverage.t - an edge that ACTS and cannot be CHECKED.
#
# THE GAP, found live on both boxes. `resume` fires four actuators and has no
# verify tier at all, and `vigilant verify resume` reported SUCCESS for it.
#
# Two separate faults met there, and both are the same shape as everything else
# in this suite:
#
#   THE EDGE-LEVEL n/a HOLE. The not-applicable contract was closed at the HOOK
#   level -- a hook declines with 78 and the runner counts it apart -- and left
#   open at the EDGE level. Every wired hook declining is a FAIL; NO hook being
#   wired returned 0. Identical epistemic state, opposite verdict.
#
#   THE QUESTION WAS NEVER ASKED. `verify` and the standing recheck only ever
#   ask about the rung the machine is at NOW. An edge with no verifier is
#   therefore invisible until the machine happens to be there -- for `resume`,
#   after an S3 cycle, which is the one moment nobody is watching.
#
# So the coverage check is STATIC and asks about every edge regardless of where
# the machine is. That is what makes it able to see an edge you are not on.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init coverage

_report() { "$VIGILANT" report 2>>"$T/stderr" || true; }

# --- 1. an acting edge with no verify tier is NAMED -------------------------
hook sleep 10-act
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'sleep'"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an edge with actuators and no verify tier was not reported. It
drives hardware and then asks nobody whether it worked, which is precisely the
state 'resume' was in on both live boxes while every tier showed green" ;;
esac

# The COUNT is part of the finding: "acts with nothing checking it" is a
# different size of problem at one hook than at seven.
case $(_section "$_out" coverage) in
  *"(1 hooks)"*) ;;
  *) fail "the coverage finding did not say how many actuators run unchecked" ;;
esac

# --- 2. wire a verifier and the finding CLEARS ------------------------------
# A check whose remedy does not move its own verdict is one you learn to
# scroll past -- this suite has shipped that mistake once already, in the edge
# budget, where the fix it recommended could never clear it.
hook sleep.verify 10-confirm
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'sleep'"*) printf '%s\n' "$_out" >&2
     fail "wiring a verify hook did not clear the coverage finding" ;;
esac
_no_fail_in "$_out" coverage "a fully covered box reported a coverage FAIL"

# --- 3. an edge that acts on NOTHING is not a finding -----------------------
# Only edges with actuators can be uncovered. Flagging every edge with an empty
# verify tier would fire on a stock install with nothing wired at all, and a
# warning that is always on is how a report stops being read.
rm -rf "$VIGILANCE_HOOK_ROOT/sleep.d" "$VIGILANCE_HOOK_ROOT/sleep.verify.d"
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'sleep'"*) fail "an edge with NO actuators was reported as uncovered. There
is nothing to check there, so this would fire on a stock install and be
switched off within a day -- taking the real finding with it" ;;
esac

# --- 4. MACHINE scope counts, because that is all a greeter has -------------
# Reading only the user scope would report every greeter edge as uncovered and
# miss a machine-scope actuator that genuinely has no verifier.
mkdir -p "$VIGILANCE_MACHINE_HOOKS/wake.d"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_MACHINE_HOOKS/wake.d/10-mach"
chmod +x "$VIGILANCE_MACHINE_HOOKS/wake.d/10-mach"
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'wake'"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a MACHINE-scope actuator with no verify tier was not reported. That
is the only scope a greeter has, so missing it means the coverage check is
blind on exactly the session nobody is present to watch" ;;
esac

# ...and a verifier in EITHER scope covers it. The scopes are one hook set at
# run time, so counting them separately would demand a verifier in each.
mkdir -p "$VIGILANCE_HOOK_ROOT/wake.verify.d"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/wake.verify.d/10-usr"
chmod +x "$VIGILANCE_HOOK_ROOT/wake.verify.d/10-usr"
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'wake'"*) fail "a user-scope verifier did not cover a machine-scope
actuator. The two scopes are one hook set when an edge runs, so demanding a
verifier in each would report a correctly covered edge as a gap" ;;
esac

# --- 5. a NON-EXECUTABLE hook does not count as coverage --------------------
# _hooks_in lists only executables, so a chmod-less verify hook never runs. If
# the coverage count disagreed with the runner, it would certify an edge as
# checked that the runner skips entirely.
rm -f "$VIGILANCE_HOOK_ROOT/wake.verify.d/10-usr"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/wake.verify.d/10-inert"
chmod -x "$VIGILANCE_HOOK_ROOT/wake.verify.d/10-inert"
_out=$(_report)
case $(_section "$_out" coverage) in
  *"'wake'"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a NON-EXECUTABLE verify hook was counted as coverage. The runner
lists only executables, so this certifies an edge as checked that nothing will
ever check -- and a chmod is exactly what gets lost in a copy or a sweep" ;;
esac

# --- 6. it is a WARN, not a FAIL -------------------------------------------
# Severity, scoped to the LINE. A shell glob spans newlines, so matching
# [WARN] and the edge name against the whole section would pass on an
# unrelated warning elsewhere plus the word 'wake' later -- this suite has
# shipped that exact mistake once, in the budget check.
_line=$(printf '%s\n' "$_out" | grep "edge 'wake'" | head -1)
case "$_line" in
  *"[WARN]"*) ;;
  *) printf 'got: %s\n' "$_line" >&2
     fail "the coverage finding was not a WARN. It is a WIRING gap, not a
machine fault: the hardware may be perfectly fine and nobody has asked. Raising
it to FAIL would turn every partially-wired box red and train the reader to
ignore the section" ;;
esac

pass
