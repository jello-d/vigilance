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

# --- 7. CAN AN OVERDUE EDGE BE DETECTED AT ALL? -----------------------------
# The deadline that matters is expressed in IDLE time, and vigilant could not
# read idle time, so `idle` was refused outright -- which made the SOON
# question unanswerable and a whole tier inert. A deadline nobody can measure
# is not a deadline, it is a sentence in a config file, and nothing said so.
_duehook() {   # edge name "<secs> <anchor>"
  mkdir -p "$VIGILANCE_HOOK_ROOT/$1.due.d"
  printf '#!/bin/sh\necho "%s"\n' "$3" > "$VIGILANCE_HOOK_ROOT/$1.due.d/$2"
  chmod +x "$VIGILANCE_HOOK_ROOT/$1.due.d/$2"
}
_idlesrc() {   # seconds | "" to remove | "na" to decline
  rm -rf "$VIGILANCE_HOOK_ROOT/idle.d"
  [ -n "$1" ] || return 0
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  if [ "$1" = na ]; then printf '#!/bin/sh\nexit 78\n' > "$_ISRC"
  else printf '#!/bin/sh\necho %s\n' "$1" > "$_ISRC"; fi
  chmod +x "$_ISRC"
}
_ISRC=$VIGILANCE_HOOK_ROOT/idle.d/10-src
go open

_duehook lock 10-idle "480 idle"
_idlesrc ""
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"NOTHING can measure it"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an idle-anchored deadline with no idle source was not reported as
unmeasurable. That is the live state of both boxes: a silently WEDGED idle
timer is running, correctly armed, logs no event for audit to reconcile, and
leaves the machine at a rung it genuinely matches -- so nothing in this suite
can see it, and it is the failure this package was created for" ;;
esac

# --- 8. wire an idle source and the deadline becomes measurable -------------
# A check whose remedy does not clear its own verdict is one you learn to
# scroll past; this suite has shipped that once already in the budget check.
_idlesrc 42
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"idle clock: 42s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a wired idle source was not reported as the clock" ;;
esac
case $(_section "$_out" deadlines) in
  *"NOTHING can measure it"*) fail "wiring an idle source did not clear the
unmeasurable finding" ;;
esac

# --- 8b. a source that DECLINES is not a clock ------------------------------
# 78 means "I cannot tell". Treating it as an answer would be the exact
# conflation the n/a contract exists to break -- and here the wrong answer is
# worse than usual, because a missing number read as 0 means "input one second
# ago", which silently resets every deadline forever.
_idlesrc na
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"NOTHING can measure it"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an idle source that DECLINED (78) was treated as a working clock" ;;
esac

# --- 8c. A NUMBER IS NOT A CAPABILITY --------------------------------------
# THE FALSE GREEN THIS CLOSES WAS LIVE ON A REAL BOX. Its keyboard reports to
# itself every 25s, so the idle clock reset before it could ever reach 60s --
# against deadlines of 480s and 600s. It still returned a NUMBER, and report
# stopped at "a clock answered" and called both measurable. The idle source had
# been recording the longest quiet stretch it ever saw for exactly this reason,
# and NOTHING READ IT: the tell existed only in that hook's comments. EVIDENCE
# OF A QUIET SEAT IS REQUIRED, and getting that wrong is a defect this check
# shipped with for an hour. A short ceiling on a machine somebody is USING is a
# person, not a fault, and the first version said "something talks to an input
# device on its own" about a laptop being typed on. The ladder supplies the
# missing evidence: reaching a DARK rung means the idle timer fired, so the seat
# WAS quiet for that long, and if the clock still never saw it the clock is
# blind.
_backdate() {   # rung seconds-ago
  printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/depth"
}
_duehook lock 10-idle "480 idle"
_idlesrc "42 ceiling=30 age=9999 recent=Drop_CSTM65:3"
_backdate sleep 9999
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"NEVER seen over 30s quiet"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a clock that watched 9999s and never observed more than 30s of quiet,
on a machine that has been at a DARK rung for 9999s, was still reported able to
measure a 480s deadline. The seat demonstrably WAS quiet and it was missed.
That is this project's signature false green: a green light meaning nobody can
check" ;;
esac
# ...AND AS A WARN, because the severity is what a consumer reads. An [OK] line
# with a caveat in its text is read as an OK.
printf '%s\n' "$_out" | grep -qE '^ *\[WARN\].*NEVER seen' \
  || fail "the finding was reported below WARN, so report still exits 0 and
anything reading the status is told the deadline is covered:
$(printf '%s\n' "$_out" | grep -i 'never seen' | head -2)"

# ...AND IT NAMES THE DEVICE. "Something talks to an input device on its own" is
# true, unactionable and unable to say which -- and the remedy is AT the device,
# so a finding that cannot name it asks the operator to search their own
# machine.
case $(_section "$_out" deadlines) in
  *"Drop_CSTM65:3 moved while the seat was quiet"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the finding did not name the device the source reported as holding
the clock down. Naming a gap without saying where it is invites the reader to
discount the whole tier" ;;
esac

# ...AND IT DOES NOT ASSERT WHICH CAUSE. The first version said the device
# "reports to itself", and that was WRONG on the box it was written for: the
# supervision pass runs verify, a wired hook there queries that very keyboard
# over raw HID, and the keyboard answered because it was ASKED. Measured, 6 URBs
# three seconds after every pass. A finding that names a hardware cause sends
# the operator to reflash a device that is behaving correctly.
case $(_section "$_out" deadlines) in
  *"either it reports to itself, or something here talks to it"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the finding asserted ONE cause for the device's traffic. The counter
cannot tell a self-reporting device from one this machine talks to, our own
verify tier included, so stating either as fact is a diagnosis the evidence
does not support" ;;
esac

# AND IT SAYS SO WHEN NOTHING NAMED ONE, rather than inventing a culprit or
# silently dropping the sentence. A source predating this field reports no
# `recent=` at all, and that must read as "no source named it".
_idlesrc "42 ceiling=30 age=9999"
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"no source named it"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no device named, the finding did not say so. A sentence that
just stops is read as a missing word rather than as missing evidence" ;;
esac

# --- 8c-bis. A MACHINE IN USE IS NOT A BROKEN CLOCK ------------------------
# THE DEFECT 8c's FIRST VERSION SHIPPED. With the same short ceiling and the
# same long watch, but the machine at a LIT rung -- somebody is using it --
# there is no evidence the seat was ever quiet, so there is nothing to have
# missed. Observed live: [WARN] "the clock has NEVER seen over 518s quiet in
# 819s of watching: something talks to an input device on its own", about a
# laptop being typed on. A wrong cause is worse than no cause, and a warning
# that is always on is how a report stops being read.
_backdate open 9999
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"NEVER seen"*) printf '%s\n' "$_out" >&2
     fail "a short ceiling on a machine at a LIT rung was reported as a broken
clock. Nobody has shown the seat was quiet, so the resets are most likely a
person; blaming a self-reporting device is a diagnosis the evidence does not
support" ;;
esac
case $(_section "$_out" deadlines) in
  *"NOT YET SHOWN"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no evidence either way the deadline was not reported as
undemonstrated" ;;
esac

# --- 8d. BUT A YOUNG CLOCK IS NOT A BROKEN ONE -----------------------------
# The guard that keeps 8c from crying wolf on every freshly booted machine: a
# ceiling below the deadline means nothing until the clock has been watching
# long enough to have seen such a stretch. Without this the fix for 8c is "warn
# whenever the ceiling is short", which is red on every reboot -- and a warning
# that is always on is how a report stops being read.
_idlesrc "42 ceiling=30 age=100"
# the ladder evidence IS present; it is the CLOCK that is young
_backdate sleep 9999
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"NOT YET SHOWN"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a clock watching for only 100s was judged against a 480s deadline
it has not had the chance to observe" ;;
esac
case $(_section "$_out" deadlines) in
  *"NEVER seen"*) fail "a young clock was accused of being unable to measure" ;;
esac

# --- 8e. AND A CLOCK THAT HAS DEMONSTRATED IT IS BELIEVED -------------------
# The other direction, or "always warn" passes 8c while lying about every
# correctly-working box.
_idlesrc "42 ceiling=600 age=9999"
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"480s idle-anchored, measurable"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a clock that HAS observed 600s of quiet was not credited with being
able to measure a 480s deadline" ;;
esac

# --- 9. a RUNG-anchored deadline never needed a clock -----------------------
_idlesrc ""
_duehook lock 10-idle "100 rung"
_out=$(_report)
case $(_section "$_out" deadlines) in
  *"100s rung-anchored, measurable"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a rung-anchored deadline was not reported measurable. It needs no
idle clock at all, so reporting it as unmeasurable would be crying wolf" ;;
esac

pass
