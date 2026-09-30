#!/bin/sh
# test/soak.t - what accumulates when the ladder is crossed over and over.
#
# EVERY ACCUMULATION BUG THIS PROJECT HAS HAD WAS FOUND IN PRODUCTION, never by
# a test: the watchdog alert that notified 45 times in 42 minutes because its
# message counted upward and defeated its own dedup key; a save file written
# once and then outliving the fix that would have prevented it, failing every
# wake for days; a daemon's argv drifting from the code on disk. All three are
# the same shape: correct once, wrong after the hundredth time.
#
# A SLOPE, NOT AN ENDURANCE RUN, and that is the whole design. "A thousand
# cycles and see if it falls over" needs a thousand cycles AND a failure big
# enough to notice; measuring the state after N and again after M catches a leak
# of ONE FILE PER CROSSING in forty, deterministically, in seconds. The same
# reasoning as perf.t: assert the thing that scales, not the total.
#
# SOAK_CYCLES raises it for a real endurance run (the fault matrix declares a
# thousand; at ~80ms a cycle that is about eighty seconds).
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init soak

CYCLES=${SOAK_CYCLES:-40}
_n1=$(( CYCLES / 4 ))
_n2=$(( CYCLES - _n1 ))

# <count> [max rc] -> cross lock/unlock that many times.
#
# THE MAX RC IS NOT DECORATION. With a deliberately failing hook a crossing
# returns 1: "it moved, and something is broken", which is the state phase 3
# is about. The first version treated that as fatal and stopped after ONE cycle,
# and the log-growth precondition below is what caught it: 3 records where 30
# crossings were claimed. An accumulation test that silently stops accumulating
# is the emptiest possible pass.
_cycle() {
  _c_max=${2:-0}
  _c_i=0
  while [ "$_c_i" -lt "$1" ]; do
    for _c_v in lock open; do
      _c_rc=0
      "$VIGILANT" go "$_c_v" >/dev/null 2>>"$T/stderr" || _c_rc=$?
      [ "$_c_rc" -le "$_c_max" ] || return "$_c_rc"
    done
    _c_i=$((_c_i + 1))
  done
}

# THE LOG IS EXPECTED TO GROW: it is the record, and the audit tier reads
# it, so it is excluded here and asserted separately below. Everything else
# under the runtime dir is bookkeeping about NOW, and a count that tracks
# the number of crossings means something is being kept that should have
# been replaced.
_state_files() {
  find "$VIGILANCE_RUN_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

# --- 1. STATE DOES NOT GROW WITH CROSSINGS ---------------------------------
_cycle "$_n1" || fail "a crossing failed during the first $_n1 cycles:
$(tail -3 "$T/stderr" 2>/dev/null)"
_f1=$(_state_files)
_cycle "$_n2" || fail "a crossing failed during the next $_n2 cycles"
_f2=$(_state_files)
[ "$_f1" = "$_f2" ] || fail "the runtime dir held $_f1 files after $_n1 cycles
and $_f2 after $(( _n1 + _n2 )). Something is kept per crossing rather than
replaced, which on a box that crosses ~28 edges a day is a slow leak nobody
would connect to locking. Files now:
$(find "$VIGILANCE_RUN_DIR" -type f | sed "s|$VIGILANCE_RUN_DIR/||" | head -20)"

# ...AND THE LOG DID GROW, which is the precondition for the assertion above
# meaning anything: if the crossings were being skipped, the state would also
# hold still and this file would pass having tested nothing.
_lines=$(wc -l < "$VIGILANCE_LOG" 2>/dev/null || echo 0)
[ "$_lines" -ge "$(( _n1 + _n2 ))" ] || fail "the log holds $_lines records for
$(( _n1 + _n2 )) cycles, so the crossings above did not happen and nothing here
is a measurement"

# --- 2. NO LEAKED CROSSING LOCK -------------------------------------------
# The lock is fail-open, so a leak does not stop the machine: it silently stops
# the standing recheck from judging it (a marker younger than CROSSING_MAX is
# believed), which is the one tier watching a settled machine.
[ ! -e "$VIGILANCE_RUN_DIR/crossing.lock" ] || fail "a crossing lock outlived
$(( _n1 + _n2 )) completed crossings. It is fail-open so nothing stalls, but the
standing recheck believes a marker while its writer is alive and young, so the
tier that watches a machine between edges quietly stops"

# --- 3. A PERSISTENT FAULT DOES NOT STORM, AND IS STILL RECORDED ----------
# The dedup key is a cksum of kind + message, so ONE fault must cost ONE key
# file however often it recurs. The watchdog storm (45 notifications in 42
# minutes) was exactly this: a message that counted upward, hashing fresh every
# pass.
#
# THE COOLDOWN IS TURNED BACK ON for this case. scenario_init sets it to 0 so
# that tests asserting "this raised an alert" cannot be broken by their
# neighbours; here the dedup IS the subject.
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d" "$VIGILANCE_HOOK_ROOT/lock.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-sink" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> $T/notified
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-sink"
# A FIXED message, because a duration in it would be a different finding every
# time, which is the bug, not the test.
printf '#!/bin/sh\necho "the peripheral is wrong"\nexit 1\n' \
  > "$VIGILANCE_HOOK_ROOT/lock.d/90-broken"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/90-broken"
: > "$T/notified"
_before=$(wc -l < "$VIGILANCE_LOG")
# EXPORTED AND PUT BACK, not prefixed: an env assignment on a shell FUNCTION
# leaks into the rest of the file, which would leave the final case asserting
# against a cooldown its neighbours set.
VIGILANCE_ALERT_COOLDOWN=3600; export VIGILANCE_ALERT_COOLDOWN
_cycle "$_n2" 1 || fail "a faulting crossing returned $?, and 1 is expected here
(it moved, a hook failed); anything else means it did not cross at all"
VIGILANCE_ALERT_COOLDOWN=0; export VIGILANCE_ALERT_COOLDOWN
_notified=$(wc -l < "$T/notified" | tr -d ' ')
_keys=$(find "$VIGILANCE_RUN_DIR/alerts" -type f 2>/dev/null \
        | wc -l | tr -d ' ')
[ "$_notified" -le 2 ] || fail "one unchanging fault notified $_notified times
across $_n2 crossings. That is the storm dedup exists to prevent, and it has a
cost this project has already paid: a live box had its supervision timer stopped
BY HAND to quiet one, and then stayed stopped with every later report green"
[ "$_keys" -le 2 ] || fail "$_keys dedup keys for ONE repeated fault. A key per
occurrence is a file leak AND a broken dedup: the shape of a message with a
measurement in it, which hashes fresh every pass"
# THE LOG IS NEVER SUPPRESSED, which is the other half and the one that makes
# throttling honest: the audit tier reads this file to say how long a fault
# lasted, and a thinned record would understate it.
_after=$(wc -l < "$VIGILANCE_LOG")
[ "$(( _after - _before ))" -ge "$_n2" ] || fail "the log gained
$(( _after - _before )) records across $_n2 faulting crossings. Throttling is a
courtesy to the human and must never be a gap in the record"

# --- 4. AND THE LADDER STILL WORKS -----------------------------------------
# An accumulation test that ends with a machine that cannot lock has found
# something, and one that never checks would not notice.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/90-broken"
"$VIGILANT" go lock >/dev/null 2>>"$T/stderr" \
  || fail "after $(( _n1 + _n2 * 2 )) crossings the ladder could not lock"
expect_depth lock

# ONE LINE, because test/run reads the verdict from the LAST line: a wrapped
# `pass` message reported NO VERDICT for a file whose every assertion had held.
_tot=$(( _n1 + _n2 * 2 ))
pass "$_tot crossings, state flat at $_f2 files, $_notified alerts, $_keys key"
