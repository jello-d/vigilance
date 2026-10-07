#!/bin/sh
# test/idle-inhibit.t - "is idle inhibited right now", asked of logind.
#
# WHY THE QUESTION EXISTS AT ALL. swayidle-mgr arms a logind event so that a
# held idle inhibitor is honoured: a video call must not be cut off
# mid-sentence. The consequence is that a held inhibitor suppresses every one
# of the idle timer's timeouts, the heartbeat included, so an idle deadline can
# pass for a GOOD reason and the timer can be silent while perfectly healthy.
#
# Neither of those was possible before that arm, which is why nothing asked.
# On the first full day after it landed the overdue detector fired 27 times
# across 93 minutes about a call behaving exactly as asked, and the heartbeat
# log shows the mechanism rather than a guess: silent 10:28:59 to 12:41:00,
# then recovered with NRestarts=0, so the same process was healthy throughout.
# A wedge needs intervention; a released inhibitor heals itself.
#
# ONE CASE TABLE, TWO IMPLEMENTATIONS. The rule lives in hook_lib for hooks and
# in bin/vigilant for the runner, because a hook cannot source the runner and
# the runner must not source the hook author's API. Two implementations of one
# rule is the shape this package paid to delete once, so the table drives BOTH,
# exactly as proc-identity.t and level-rules.t do.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init idle-inhibit
. "$HERE/lib/hook_lib"

# --- 1. THE RUNNER'S TWIN, extracted rather than reimplemented ---------------
# bin/vigilant cannot be sourced: it is a command with a dispatcher and
# top-level work. BOTH functions have to come out, because _idle_inhibited
# answers through _trig_blocked and lifting one would test a stub of the other.
#
# THE EXTRACTION IS ASSERTED BEFORE ANY CASE RUNS. An extraction that silently
# grabbed the wrong lines turns every row below into a statement about nothing,
# and level-rules.t paid for exactly that: a table that had never run looked
# like nine broken rules.
RUNNER_FN=$T/runner-fns
awk '
  /^_trig_blocked\(\) \{/    { f = 1 }
  /^_idle_inhibited\(\) \{/  { f = 1 }
  f                          { print }
  f && /^\}/                 { f = 0 }
' "$HERE/bin/vigilant" > "$RUNNER_FN"

dash -n "$RUNNER_FN" 2>/dev/null || fail "the functions lifted out of
bin/vigilant do not parse, so the extraction is broken rather than the code:
$(cat "$RUNNER_FN")"
# DELIBERATELY NOT PINNING THE FIELD MATCH ITSELF. An earlier draft also
# required ':idle:' here, and a mutation turning the field match into a
# substring match then failed THIS assertion rather than the row written to
# catch it: a defect in the subject reported as a broken harness, which sends
# the reader to the wrong file. The lift is proven by the function names and
# the read; how the value is matched is section 2's job to judge.
for _need in '_trig_blocked()' '_idle_inhibited()' 'BlockInhibited'; do
  grep -qF "$_need" "$RUNNER_FN" || fail "the extraction from bin/vigilant is
missing '$_need', so it did not lift the functions under test. The
BlockInhibited read IS the subject: without it these cases would certify an
implementation that is not the shipped one"
done

_drive() {   # <hooklib|runner> <BlockInhibited value>
  VIGILANCE_BLOCK_INHIBITED=$2
  export VIGILANCE_BLOCK_INHIBITED
  case $1 in
    hooklib) hook_idle_inhibited ;;
    runner)  ( . "$RUNNER_FN"; _idle_inhibited ) ;;
  esac
}

# --- 2. ONE TABLE, BOTH IMPLEMENTATIONS -------------------------------------
# want / value / why the row is here. A whitespace table cannot carry an empty
# value, so the two empty forms are section 3.
#
# THE SUBSTRING ROWS ARE THE DISCRIMINATING ONES. An unanchored match on the
# whole value calls idlewhatever and handle-idle-key inhibited, and the second
# is the forward-looking half: no handler logind defines TODAY contains "idle",
# which is exactly why a substring match would pass review now and break on the
# first one that does.
#
# NO BACKTICKS IN THIS BLOCK. It is a double-quoted string, so a backtick is
# command substitution and dash -n cannot see it; the first draft of this file
# quoted busctl's output that way and would have RUN it.
CASES="
yes idle                            a real block inhibitor, as measured
yes sleep:idle                      idle last in the list
yes idle:sleep                      idle first in the list
yes sleep:idle:handle-lid-switch    idle in the middle
no  sleep                           a different handler entirely
no  handle-lid-switch               what a lid inhibitor holds
no  idlewhatever                    SUBSTRING TRAP: a prefix of a longer word
no  notidle                         SUBSTRING TRAP: a suffix of a longer word
no  handle-idle-key                 a future handler CONTAINING idle
"

# FED FROM A FILE, NOT A PIPE. A `while read` on the right of a pipe runs in a
# SUBSHELL, so a counter incremented inside it never reaches the caller: the
# trap that once defeated a timeout bound here. The redirect keeps the loop in
# this shell, which also lets `fail` behave like it does everywhere else.
printf '%s\n' "$CASES" > "$T/cases"
_rows=0
while read -r _want _val _why; do
  [ -n "${_want:-}" ] || continue
  for _impl in hooklib runner; do
    _rc=0; _drive "$_impl" "$_val" || _rc=$?
    case "$_want:$_rc" in
      yes:0|no:1) ;;
      yes:*) fail "$_impl: BlockInhibited='$_val' must read as INHIBITED
(rc 0) and read rc=$_rc. $_why" ;;
      no:*)  fail "$_impl: BlockInhibited='$_val' must read as NOT inhibited
(rc 1) and read rc=$_rc. $_why" ;;
    esac
  done
  _rows=$((_rows + 1))
done < "$T/cases"

# A DENOMINATOR. A table that silently matched nothing would print a green
# line, which is the same bargain test/faults.rec and session-repeat.t take.
[ "$_rows" -eq 9 ] || fail "the case table ran $_rows rows, expected 9; the
table did not parse, so nothing above is a statement about this code"

# --- 3. THE EMPTY FORMS, and busctl's own wrapping --------------------------
# busctl prints the type sigil and the quotes, so the runner's real input is
# the WRAPPED form while the override above is bare. Both must read the same,
# or the table certifies a parse the shipped path never takes.
for _impl in hooklib runner; do
  _rc=0; _drive "$_impl" '' || _rc=$?
  [ "$_rc" = 1 ] || fail "$_impl: an EMPTY BlockInhibited means nothing is
inhibited (rc 1), got rc=$_rc"

  _rc=0; _drive "$_impl" 's ""' || _rc=$?
  [ "$_rc" = 1 ] || fail "$_impl: busctl's wrapping of nothing must read as NOT
inhibited (rc 1), got rc=$_rc"

  _rc=0; _drive "$_impl" 's "idle"' || _rc=$?
  [ "$_rc" = 0 ] || fail "$_impl: busctl's own output form must read as
INHIBITED (rc 0), got rc=$_rc. This is the form the shipped path actually
receives; the bare values in the table are the test override"

  _rc=0; _drive "$_impl" 's "sleep:idle"' || _rc=$?
  [ "$_rc" = 0 ] || fail "$_impl: the wrapped multi-field form must read as
INHIBITED (rc 0), got rc=$_rc"
done

# --- 4. CANNOT TELL IS NOT "NOT INHIBITED" ----------------------------------
# The whole n/a contract in one assertion. logind answering "nothing" and
# busctl being unable to ask arrive as the same empty string, and they are
# opposite findings: only a definite NO may let a detector proceed, because
# treating an unreadable bus as "nothing is inhibited" is the reassuring
# direction, and that is verbatim the defect that made the lock provider blame
# WAYLAND_DISPLAY for a dead user bus.
mkdir -p "$T/minbin"

# SOURCED FIRST, THEN PATH NARROWED. Narrowing before the source would leave
# `sh` and `env` unresolvable, and rc=127 then wears the costume of a verdict:
# the trap this suite has hit three times. Nothing external is needed after the
# source, so the window where PATH is bare is exactly the call under test.
#
# `unset` IS LOAD-BEARING, inside the subshell so it cannot leak out. The
# override is tested with `+x`, so an EMPTY but SET value still takes the
# override path and section 2 above leaves one set. Merely not passing a value
# is not enough, which is the trap that bit locker-up.t while the comment about
# it was being written.
_absent() {   # <hooklib|runner>
  case $1 in
    hooklib) ( . "$HERE/lib/hook_lib"
               unset VIGILANCE_BLOCK_INHIBITED
               PATH=$T/minbin; export PATH
               hook_idle_inhibited ) ;;
    runner)  ( . "$RUNNER_FN"
               unset VIGILANCE_BLOCK_INHIBITED
               PATH=$T/minbin; export PATH
               _idle_inhibited ) ;;
  esac
}

for _impl in hooklib runner; do
  _rc=0; _absent "$_impl" || _rc=$?
  [ "$_rc" = 2 ] || fail "$_impl: with no busctl on PATH the answer is CANNOT
TELL (rc 2), got rc=$_rc. rc 1 there would be an unreadable bus reported as
'nothing is inhibited', which is the reassuring direction and the one this
contract exists to forbid"
done

# A busctl that EXISTS and FAILS is the sharper half: absence is already
# handled by `command -v`, and the interesting branch is the one that can be
# asked and cannot answer. That is the branch the triggers work found broken,
# where a pipeline's status hid the failure.
printf '#!/bin/sh\nexit 1\n' > "$T/minbin/busctl"
chmod +x "$T/minbin/busctl"
for _impl in hooklib runner; do
  _rc=0; _absent "$_impl" || _rc=$?
  [ "$_rc" = 2 ] || fail "$_impl: a busctl that RUNS and FAILS is CANNOT TELL
(rc 2), got rc=$_rc. Read as rc 1 this is a failed query reported as
'nothing is inhibited'"
done

pass "9 rows x 2 implementations, busctl's own wrapping, and an unreadable\
 bus reported as cannot-tell rather than as not-inhibited"
