#!/bin/sh
# test/fault-storm.t - a hundred lock requests at once.
#
# FAULT: lock-signal-storm.
#
# WHY A HUNDRED AND NOT TWO. Two concurrent requests is the case that
# shipped four times over three days, and it is covered: the crossing lock
# serialises them and the provider tolerates losing. A hundred asks a different
# question, and it is the one this package has got wrong repeatedly:
#
#   does the response scale with the CAUSE, or with the SYMPTOM?
#
# Every storm in this project's history was a mechanism responding per-event
# where it should have responded per-finding. A watchdog alert fired 45 times in
# 42 minutes about ONE unchanged condition, because its message embedded an
# elapsed time and so hashed as a fresh onset every pass. Before that, a
# persistent fault notified every minute until a live box had its supervision
# timer STOPPED BY HAND, after which every report was green because nothing was
# running. The storm is not the damage; the storm is what gets the detector
# switched off.
#
# SO THE CLAIM IS TWO-SIDED. One crossing, because the ladder is already there
# after the first; and no alert storm, because a hundred identical findings are
# one finding. A hundred crossings would also be "correct" by a narrow reading
# and would hammer the lock path.
#
# THE SIGNALS ARE REAL. `loginctl lock-session` against a session logind will
# actually lock, delivered to vigilance's own trigger unit, not the trigger
# invoked directly, which would test the ladder while skipping the listener that
# has to survive the burst.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-storm

BURST=${VIGILANCE_STORM_BURST:-100}

_cleanup() { lockable_stop; session_done; rm -rf "$T"; }
trap '_cleanup' EXIT INT TERM HUP

_log_at()    { wc -l < "$(lockable_log)" 2>/dev/null || echo 0; }
_log_since() {
  tail -n +$(( ${1:-0} + 1 )) "$(lockable_log)" 2>/dev/null || true
}

lockable_start
SID=$(lockable_id)
[ -n "${SID:-}" ] || fail "no lockable session id after lockable_start"

# --- given: awake, and an alert sink we can count ---------------------------
# The sink records the KIND, because the claim is about how many NOTIFICATIONS a
# hundred identical findings produce. Counting log lines instead would measure
# the record, which is deliberately never thinned.
_lh=$(getent passwd "$LOCKABLE_USER" | cut -d: -f6)
mkdir -p "$_lh/.config/vigilance/hooks/alert.d"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> %s\n' "$T/alerts" \
  > "$_lh/.config/vigilance/hooks/alert.d/10-sink"
chmod +x "$_lh/.config/vigilance/hooks/alert.d/10-sink"
chown -R "$LOCKABLE_USER" "$_lh/.config/vigilance" 2>/dev/null || true
: > "$T/alerts"
chmod 666 "$T/alerts" 2>/dev/null || true

lockable_as "$LOCKABLE_V" force open >/dev/null 2>&1 || true
[ "$(lockable_depth)" = open ] \
  || fail "fixture: depth is '$(lockable_depth)', not open"

# PRIME. logind does not act on the first lock request of a session's life in
# this guest (measured on the lid path: four events, two locks), so without this
# the burst's first signals are absorbed and the count is about the wrong thing.
lockable_as "$LOCKABLE_V" force open >/dev/null 2>&1 || true
_p=$(_log_at)
loginctl lock-session "$SID" >/dev/null 2>&1 || true
sleep 3
[ "$(_log_at)" != "$_p" ] || fail "a single lock-session produced NOTHING in
vigilance's log, so the listener is not receiving signals and a burst would
'pass' by being equally silent"

# --- THE BURST -------------------------------------------------------------
lockable_as "$LOCKABLE_V" force open >/dev/null 2>&1 || true
[ "$(lockable_depth)" = open ] || fail "fixture: not at open before the burst"
_b0=$(_log_at)
_n=0
while [ "$_n" -lt "$BURST" ]; do
  loginctl lock-session "$SID" >/dev/null 2>&1 || true
  _n=$((_n + 1))
done
# Let the listener drain. The burst is issued as fast as loginctl can send it;
# the responses are serialised by the crossing lock, so draining takes longer
# than sending.
sleep 12

# --- 1. THE BURST IS COLLAPSED ---------------------------------------------
# NOT "exactly one crossing", and the reason is a substrate fact rather than a
# concession. On a headless guest the provider starts a locker, the locker
# cannot survive, and its ExecStopPost unwinds the ladder to `open`, so a later
# request in the burst legitimately crosses again. Measured: 5 crossings for 100
# requests. Demanding one would fail this cell over locker-killed-while-locked
# working exactly as designed, which is another cell's subject.
#
# What IS the claim, and what a broken serialisation would look like:
#
#   ~100 crossings   the crossing lock is not holding, and the whole act tier
#                    runs a hundred times on the security path
#   0 crossings       a storm became a reason to ignore the request
#   most requests recognised as already-there, a handful of crossings
#
_crossed=$(_log_since "$_b0" | grep -c 'cross lock: open -> lock' || true)
_already=$(_log_since "$_b0" | grep -c "already at 'lock'" || true)
_counts="crossings=$_crossed already-there=$_already of $BURST requests"

[ "$_crossed" -ge 1 ] || fail "a burst of $BURST lock requests crossed the lock
edge ZERO times ($_counts). The first request must still act: a storm is not a
reason to ignore the thing being asked for"

# AN ORDER OF MAGNITUDE, which is what serialisation buys. Generous headroom
# over the 5 observed, because the locker churn is substrate-dependent and a
# threshold tuned to one measurement is a threshold that flakes.
[ "$_crossed" -le 20 ] || fail "a burst of $BURST lock requests crossed the lock
edge $_crossed times ($_counts). The crossing lock is meant to collapse
concurrent requests into one traversal; at this rate the entire act tier is
re-running on the security path for every signal that arrives"

# --- 2. AND NO ALERT STORM -------------------------------------------------
# A hundred identical findings are ONE finding. This is the assertion that the
# dedup holds under load rather than merely in principle, and the failure it
# guards has cost this project a switched-off supervision timer once already.
_alerts=$(grep -c . "$T/alerts" 2>/dev/null || true)
[ "${_alerts:-0}" -le 3 ] || fail "a burst of $BURST lock requests produced
$_alerts notifications ($_counts). A hundred identical findings are one finding
told a hundred times, and a notifier like that is one people silence, and
the supervision timer goes with it"

# --- 3. AND THE MECHANISM STILL SECURES THE SESSION ------------------------
# TWO CLAIMS IN ONE REQUEST, and it took two wrong assertions to get here.
#
# FIRST I COUNTED "already at 'lock'" lines, expecting the later requests to be
# recognised as redundant, and measured ZERO of them: crossings=5,
# already-there=0, of 100. The other 95 never reached the ladder at all, being
# absorbed at the signal layer before `vigilant` runs. Fine behaviour, useless
# assertion: absorbed-upstream and died-halfway-through look identical from the
# log, and telling those apart is the whole point of a storm cell.
#
# THEN I ASSERTED THE RESTING DEPTH, and it reads `open`: on a headless guest
# the locker cannot survive, so its ExecStopPost=`vigilant go open` unwinds the
# ladder seconds later. That is correct, locker-killed-while-locked working
# as designed, and fault-lid case 1 already carries the same note.
#
# So ask for ONE MORE LOCK and require it to cross the edge. A listener dying
# partway through the burst answers nothing; a mechanism that learned to ignore
# requests under load answers nothing; and the answer being a `lock` CROSSING is
# the durable record that the session was secured.
_s1=$(_log_at)
loginctl lock-session "$SID" >/dev/null 2>&1 || true
sleep 6
printf '%s\n' "$(_log_since "$_s1")" | grep -q 'cross lock: .* -> lock' \
  || fail "after a burst of $BURST the next lock request secured NOTHING
($_counts). Log since:
$(_log_since "$_s1" | head -5)
A low crossing count during the burst is only good news if the mechanism is
still alive afterwards, and every one of those signals asked for the session to
be secured"

pass
