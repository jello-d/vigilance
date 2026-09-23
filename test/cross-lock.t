#!/bin/sh
# test/cross-lock.t - one crossing at a time, and it can never block a lock.
#
# THE ROOT RACE. `cmd_go` is a read-modify-write over shared state --
#
#     read depth  ->  choose the edges  ->  commit depth  ->  actuate
#
# -- and nothing serialised it, so two `vigilant go lock` processes both read
# `open`, both compute the same path, and both run the entire act tier at once.
# Measured on manifold: the Super+L binding fired twice, `cross lock: open ->
# lock` was logged twice in one second, and BOTH the locker provider and the
# mute hook failed because neither survived being run against itself.
#
# Every concurrency defect in this package so far has been a symptom of that
# one absence, and each was patched at its own site. This asserts the mechanism
# instead: one writer, so the duplicates never happen rather than being
# tolerated.
#
# THE FAIL-OPEN CASES MATTER MORE THAN THE EXCLUSION, and they are the majority
# of this file. A mutex on the lock path that can wedge is far worse than the
# race it replaces, because the race's worst outcome is a spurious alert and a
# wedge's worst outcome is a machine that will not lock.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init cross-lock

LOCK=$VIGILANCE_RUN_DIR/crossing.lock
_crossings() {
  grep -c "cross lock: open -> lock" "$T/vigilant.log" 2>/dev/null || echo 0
}

# A hook slow enough that concurrent callers genuinely overlap. Without it the
# processes serialise by luck and the file asserts nothing -- the same mistake
# that made a first attempt to reproduce the mute-on-lock race find nothing in
# eight trials.
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
cat > "$VIGILANCE_HOOK_ROOT/lock.d/10-slow" <<EOF
#!/bin/sh
echo "ran \$\$" >> $T/ran
sleep 2
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/10-slow"

# --- 1. FOUR CONCURRENT REQUESTS, ONE CROSSING ------------------------------
# The whole point. The losers wait, re-read the depth, find the work already
# done and become "already at 'lock'; nothing to do" -- so the act tier runs
# ONCE, not four times.
#
# THE WAIT IS EXPLICIT AND GENEROUS HERE, because this case is about EXCLUSION
# and the next one is about the fail-open timeout. At the default the two
# properties overlap: a 2s hook against a 2s wait had losers timing out and
# crossing anyway, so the first draft of this case measured the fallback while
# claiming to measure the lock. One assertion, one property.
true > "$T/ran"
for _i in 1 2 3 4; do
  ( VIGILANCE_CROSS_WAIT=10 "$VIGILANT" go lock \
      >>"$T/out" 2>>"$T/stderr"; echo "$?" >> "$T/rcs" ) &
done
wait
_n=$(_crossings)
[ "$_n" = 1 ] || fail "four concurrent 'go lock' produced $_n crossings of the
lock edge. Each one runs the whole act tier, and neither the locker provider
nor the mute hook survives being run against itself -- which is exactly the
pair that failed on a live box"
_ran=$(wc -l < "$T/ran" | tr -d ' ')
[ "$_ran" = 1 ] || fail "the act tier ran $_ran times for one edge"
_rcs=$(sort -u "$T/rcs" | tr -d '\n')
[ "$_rcs" = 0 ] || fail "a concurrent request exited non-zero ($_rcs). Losing a
race is not failing: the machine reached the rung that was asked for"
[ ! -e "$LOCK" ] || fail "the crossing lock was left behind. Stale-breaking
hides this from every other case here -- the next crossing still happens, it
just pays a full wait and a break first, for ever"

# BECAUSE THE MECHANISM IS FAIL-OPEN, THE OUTCOME CANNOT DISCRIMINATE ITS
# PATHS. Every route below ends in a crossing by design, so asserting "it
# crossed" passes with the exclusion, the stale-break and the re-entrancy check
# all deleted. Four mutations survived this file that way. Only the RECORD
# separates them, which is what those log lines are for.
_said() { grep -q "$1" "$T/vigilant.log"; }

# --- 1b. THE FIRST CROSSING AFTER A BOOT MUST NOT PAY THE WAIT --------------
# cmd_go creates the runtime dir, but the lock is claimed BEFORE that, so with
# no runtime dir the claim failed with ENOENT, the wait ran out, and the edge
# crossed unserialised -- once per boot, on every box, logging "crossing
# anyway" as though something were wrong. Measured at 2s before the fix.
_boot=$T/boot
VIGILANCE_RUN_DIR=$_boot/run VIGILANCE_LOG=$_boot/log \
  VIGILANCE_HOOK_ROOT=$_boot/h VIGILANCE_MACHINE_HOOKS=$_boot/m \
  "$VIGILANT" go lock >/dev/null 2>&1 || true
grep -q "crossing anyway" "$_boot/log" 2>/dev/null && fail "the first crossing
with no runtime dir fell back to crossing unserialised. Every box would do this
on every boot, and the log line would send a reader looking for a contention
problem that does not exist"

# --- 2. A STALE LOCK IS BROKEN, NOT OBEYED ----------------------------------
# THE FAILURE THAT WOULD BE WORSE THAN THE RACE. vigilant killed mid-crossing
# (systemd reaping lock-on-sleep on its 25s timeout is the realistic case)
# leaves the lock file behind. If that stopped the next lock, the cure would
# have created a machine that cannot lock.
"$VIGILANT" go open >/dev/null 2>&1
printf '999999 %s\n' "$(date +%s)" > "$LOCK"   # a pid that is not running
true > "$T/vigilant.log"
"$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || fail "a stale lock made the
crossing fail outright"
[ "$(_crossings)" = 1 ] || fail "a lock left behind by a dead process blocked
the next crossing. A mutex that can prevent a lock is worse than the race"
_said "breaking a crossing lock" || fail "a lock held by a DEAD process was not
broken. It was waited out and then crossed anyway, which reaches the same rung
by the wrong route: every crossing on a box with a leaked lock would stall for
the whole wait, and the exclusion would be off the whole time"
_said "crossing anyway" && fail "the stale lock was waited out rather than
broken"

# --- 3. A LIVE HOLDER DOES NOT BLOCK FOREVER EITHER -------------------------
# Even an honest holder that outlives the wait must not stop us: we cross
# anyway. The worst case is the OLD behaviour, so this can only be better.
"$VIGILANT" go open >/dev/null 2>&1
sleep 600 & _holder=$!
printf '%s %s\n' "$_holder" "$(date +%s)" > "$LOCK"
true > "$T/vigilant.log"
VIGILANCE_CROSS_WAIT=1 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" \
  || fail "a live lock holder made the crossing fail"
[ "$(_crossings)" = 1 ] || fail "a live holder blocked the crossing past the
wait. FAIL-OPEN is the rule: cross anyway and say so"
grep -q "crossing anyway" "$T/vigilant.log" || fail "the crossing went
unserialised and said nothing about it. Falling back is acceptable; doing it
silently is not"
kill "$_holder" 2>/dev/null || true
rm -f "$LOCK"

# --- 4. THE PANIC KEY DOES NOT QUEUE AT ALL ---------------------------------
# `rescue` is pressed blind by someone who cannot see the screen. It sets the
# wait to zero, so even a healthy holder costs it nothing.
sleep 600 & _holder=$!
printf '%s %s\n' "$_holder" "$(date +%s)" > "$LOCK"
_t0=$(date +%s)
"$VIGILANT" rescue >/dev/null 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _t0 ))
[ "$_el" -le 3 ] || fail "rescue waited ${_el}s behind a crossing lock. The
panic key must not queue; it is the last resort on a machine that is already
misbehaving"
expect_depth open
kill "$_holder" 2>/dev/null || true
rm -f "$LOCK"

# --- 5. A HOOK CALLING BACK IN MUST NOT WAIT FOR ITS OWN PARENT -------------
# Re-entrancy. The lock is held for the whole command, so a hook that invokes
# `vigilant` would deadlock against itself until the wait expired -- turning
# every such crossing into a multi-second stall that only shows up in
# production.
"$VIGILANT" go open >/dev/null 2>&1
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/10-slow"
cat > "$VIGILANCE_HOOK_ROOT/lock.d/10-reenter" <<EOF
#!/bin/sh
"$VIGILANT" status > $T/nested 2>&1
"$VIGILANT" go lock >> $T/nested 2>&1
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/10-reenter"
true > "$T/vigilant.log"
_t0=$(date +%s)
"$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _t0 ))
[ "$_el" -le 3 ] || fail "a hook that called back into 'vigilant go' waited
${_el}s for the lock its own parent was holding"
_said "crossing anyway" && fail "a hook calling back into 'vigilant go' did not
recognise its own ancestor's lock: it waited the whole timeout and then crossed
UNSERIALISED. The wait is short enough that a clock assertion alone passes
either way, which is how the first version of the token -- comparing the
holder's pid against the child's own \$\$, so it could never match -- shipped
without firing once"

# --- 5b. A FRESH CLAIM IS NOT A DEAD HOLDER --------------------------------
# The lock is created and then written, so a reader can catch it empty. Calling
# that brand-new holder dead STEALS the lock, which is the original race
# rebuilt inside the thing meant to prevent it. Age separates the two, and
# again only the record shows which path was taken.
"$VIGILANT" go open >/dev/null 2>&1
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/10-reenter"
true > "$LOCK"                       # created, not yet written: pid unknown
true > "$T/vigilant.log"
VIGILANCE_CROSS_WAIT=1 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || true
_said "breaking a crossing lock" && fail "a lock file with no pid yet was
treated as a dead holder and broken. That is a claim microseconds old, and
stealing it puts two writers in the critical section -- exactly the race this
mechanism exists to remove"
_said "crossing anyway" || fail "fixture: the fresh-claim case did not reach
the fail-open path, so it proved nothing"
rm -f "$LOCK"

# --- 6. THE RATCHET: NOTHING MAY BYPASS THE LOCK ---------------------------
# What makes the mechanism a MECHANISM rather than another patched site. The
# exclusion is only complete while the chokepoint holds:
#
#   _set_depth and the act-tier _run_hooks are called from _cross_one ALONE
#   _cross_one is called from _cmd_go ALONE
#   cmd_go wraps _cmd_go in the lock
#
# A future path that commits a depth or actuates an edge from somewhere else
# would be unserialised, and every case above would still pass -- which is how
# a proof by construction quietly becomes a proof of nothing.
V=$HERE/bin/vigilant
# LITERAL MATCHING, THROUGH ENVIRON. `awk -v` expands backslash escapes in the
# assignment and `$0 ~ pat` is a regex, so `_run_hooks "$1" "$2" ||` arrived as
# an alternation that matched every line -- the first run of this ratchet named
# eighty functions. Same trap the mutation driver already paid for; ENVIRON
# does no processing and index() is a substring.
_callers() {   # <literal> -> the functions containing it
  PAT=$1 awk '
    /^[a-z_]+\(\) \{/ { fn = $1; sub(/\(\)$/, "", fn); next }   # a definition
    /^ *#/ { next }                                             # a comment
    index($0, ENVIRON["PAT"]) { if (fn != "") print fn }' "$V" | sort -u
}
_want() {   # <what> <literal> <expected-callers>
  _got=$(_callers "$2" | tr '\n' ' ' | sed 's/ $//')
  [ "$_got" = "$3" ] || fail "$1 is reached from [$_got], expected [$3].
Every actuation must funnel through the function cmd_go wraps in the crossing
lock; a second entry point is an unserialised crossing, and nothing else in
this file would notice it"
}
_want "_set_depth"        '_set_depth "'              "_cross_one"
_want "the act tier"      '_run_hooks "$1" "$2" ||'   "_cross_one"
_want "_cross_one"        '_cross_one "'              "_cmd_go"
_want "the crossing lock" '_crossing_begin'           "cmd_go"

pass
