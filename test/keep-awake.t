#!/bin/sh
# test/keep-awake.t - the user holding the screen up, deliberately, for a while.
#
# WHAT IT MUST DO, each a separate way to get it wrong:
#
#   hold ONLY the idle timer's lock (src=idle) and blank (src=blank); a lid
#     close, a keybind and the system sleep lock go through
#   ALWAYS expire, and read a stamp further out than the maximum as OFF
#   on expiry, REPLAY what it held if the seat stayed idle the whole time,
#     because the idle timer fires each threshold once per idle stretch and
#     walking away during a keep-awake would otherwise never lock
#   replay NOTHING if the seat was used since, or if no clock can show it
#   make an overdue idle deadline read as held, not as a fault
#   satisfy the audit tier: a requested decline is not a missed edge
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init keep-awake

KA=$VIGILANCE_RUN_DIR/keep-awake
HELD=$VIGILANCE_RUN_DIR/keep-awake-held
_depth() { awk '{print $1}' "$VIGILANCE_RUN_DIR/depth" 2>/dev/null || true; }
_at() {   # <rung>
  printf '%s %s\n' "$1" "$(( $(date +%s) - 9999 ))" > "$VIGILANCE_RUN_DIR/depth"
}
_go() {   # <src> <state> [mode] -> prints rc
  _r=0
  env VIGILANCE_SOURCE="$1" "$VIGILANT" go "$2" ${3:+"$3"} \
    >/dev/null 2>>"$T/stderr" || _r=$?
  printf '%s' "$_r"
}
_idle() {   # <seconds>: an idle.d source answering this
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}
_reset() {
  rm -f "$KA" "$HELD" "$VIGILANCE_RUN_DIR/last-ascent"
  rm -rf "$VIGILANCE_HOOK_ROOT/idle.d" "$VIGILANCE_HOOK_ROOT/lock.due.d" \
    "$VIGILANCE_HOOK_ROOT/concur.d"
  printf '' > "$VIGILANCE_LOG"
  _at open
}

# --- 1. THE VERB: set, cycle, step, clamp, refuse ----------------------------
_reset
"$VIGILANT" keep-awake 1h > "$T/o"
case "$(cat "$T/o")" in "keep-awake: on, 3"[56][0-9][0-9]"s left") ;;
  *) fail "1h set: $(cat "$T/o")" ;; esac
_cyc() { "$VIGILANT" keep-awake cycle | sed 's/[0-9]*s left/Ns left/'; }
"$VIGILANT" keep-awake off > /dev/null
[ "$(_cyc)" = "keep-awake: on, Ns left" ] || fail "cycle from off is not on"
_l=$(cut -d' ' -f2 "$KA"); [ "$_l" = 3600 ] || fail "cycle from off set $_l"
_cyc > /dev/null; _l=$(cut -d' ' -f2 "$KA")
[ "$_l" = 7200 ] || fail "cycle from 1h set $_l, want 7200"
[ "$(_cyc)" = "keep-awake: off" ] || fail "cycle from 2h did not turn it off"
"$VIGILANT" keep-awake 5h > /dev/null
[ "$(cut -d' ' -f2 "$KA")" = 7200 ] || fail "5h was not clamped to the maximum"
"$VIGILANT" keep-awake less > /dev/null
_l=$("$VIGILANT" keep-awake status | sed -n 's/.*on, \([0-9]*\)s left.*/\1/p')
[ "${_l:-0}" -le 3600 ] && [ "${_l:-0}" -gt 3500 ] \
  || fail "less from 2h left '${_l:-off}', want about 3600"
_rc=0; "$VIGILANT" keep-awake soon > /dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a nonsense duration was accepted (rc=$_rc)"

# A stamp further out than the maximum is OFF, never a longer hold.
printf '%s 7200\n' "$(( $(date +%s) + 99999 ))" > "$KA"
[ "$("$VIGILANT" keep-awake status)" = "keep-awake: off" ] || fail "a stamp
past the maximum read as on; a stepped clock or a hand-edited file must fail
toward locking"

# --- 2. IT HOLDS THE IDLE TIMER'S TWO RUNGS, AND NOTHING ELSE ----------------
_reset
"$VIGILANT" keep-awake 1h > /dev/null
[ "$(_go idle lock atleast)" = 3 ] || fail "the idle lock went through with
keep-awake on"
[ "$(_depth)" = open ] || fail "the idle lock moved the rung: $(_depth)"
grep -q "keep-awake held lock: open, toward 'lock'" "$VIGILANCE_LOG" \
  || fail "the decline was not logged: $(cat "$VIGILANCE_LOG")"
[ "$(_go blank sleep)" = 3 ] || fail "the blank went through with keep-awake on"
[ "$(_depth)" = open ] || fail "the blank moved the rung: $(_depth)"
grep -q "^sleep " "$HELD" || fail "a blank from open was recorded by the edge
it stopped at, not by what it asked for, so the expiry could not replay it:
$(cat "$HELD")"
for _s in logind manual suspend unset; do
  _at open
  [ "$(_go "$_s" lock atleast)" = 0 ] || fail "src=$_s was held by keep-awake.
Only the idle timer's requests may be: a lid close must still lock"
  [ "$(_depth)" = lock ] || fail "src=$_s did not reach lock"
done

# --- 3. EXPIRY REPLAYS WHAT IT HELD, IF THE SEAT STAYED IDLE -----------------
_reset
printf 'sleep %s blank\nlock %s idle\n' "$(( $(date +%s) - 300 ))" \
  "$(( $(date +%s) - 400 ))" > "$HELD"
printf '%s 3600\n' "$(( $(date +%s) - 5 ))" > "$KA"      # expired
_idle 1000
"$VIGILANT" enforce > /dev/null 2>&1 || true
[ "$(_depth)" = sleep ] || fail "on expiry with the seat idle past both
requests, the deepest held one was not replayed (rung $(_depth)). Walking away
during a keep-awake must still lock: $(cat "$VIGILANCE_LOG")"
grep -q 'src=keep-awake-expired' "$VIGILANCE_LOG" || fail "the replay was not
attributed: $(cat "$VIGILANCE_LOG")"
[ ! -e "$KA" ] && [ ! -e "$HELD" ] || fail "expiry left its records behind"

# ...and nothing, if the seat was used after it was asked.
_reset
printf 'lock %s idle\n' "$(( $(date +%s) - 600 ))" > "$HELD"
printf '%s 3600\n' "$(( $(date +%s) - 5 ))" > "$KA"
_idle 30
"$VIGILANT" enforce > /dev/null 2>&1 || true
[ "$(_depth)" = open ] || fail "the seat was used 30s ago, after the held
request, and the expiry locked anyway (rung $(_depth))"
grep -q 'the seat was used since' "$VIGILANCE_LOG" || fail "a skipped replay
did not say why: $(cat "$VIGILANCE_LOG")"

# ...and nothing, if no clock can show the seat stayed idle.
_reset
printf 'lock %s idle\n' "$(( $(date +%s) - 600 ))" > "$HELD"
"$VIGILANT" keep-awake off > /dev/null
[ "$(_depth)" = open ] || fail "with no idle clock the expiry replayed anyway"
grep -q 'no idle clock' "$VIGILANCE_LOG" || fail "a replay skipped for want of
a clock did not say so"

# --- 4. AN OVERDUE IDLE DEADLINE IS HELD, NOT A FAULT -------------------------
_reset
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.due.d" "$VIGILANCE_HOOK_ROOT/concur.d"
printf '#!/bin/sh\necho "480 idle"\n' > "$VIGILANCE_HOOK_ROOT/lock.due.d/10-d"
printf '#!/bin/sh\necho "saw it"\nexit 0\n' \
  > "$VIGILANCE_HOOK_ROOT/concur.d/10-c"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.due.d/10-d" \
  "$VIGILANCE_HOOK_ROOT/concur.d/10-c"
_idle 900
"$VIGILANT" keep-awake 1h > /dev/null
_out=$("$VIGILANT" enforce 2>&1 || true)
case "$_out" in *"held by keep-awake"*) ;;
  *) fail "an overdue idle lock under keep-awake was not reported as held by
it: $_out" ;; esac
grep -qE 'OVERDUE|ALERT' "$VIGILANCE_LOG" && fail "keep-awake's own hold was
reported as a fault; the idle timer fired and was declined on request:
$(cat "$VIGILANCE_LOG")"

# --- 5. THE AUDIT TIER RECONCILES A REQUESTED DECLINE -------------------------
_reset
"$VIGILANT" keep-awake 1h > /dev/null
_go idle lock atleast > /dev/null
_now=$(date +%s)
mkdir -p "$VIGILANCE_HOOK_ROOT/audit.d"
printf '#!/bin/sh\necho "%s lock idle-lock"\n' "$_now" \
  > "$VIGILANCE_HOOK_ROOT/audit.d/10-a"
chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/10-a"
_out=$("$VIGILANT" audit 2>&1 || true)
case "$_out" in *MISS*|*missed*)
  fail "a lock keep-awake held on request was counted as missed: $_out" ;; esac
rm -rf "$VIGILANCE_HOOK_ROOT/audit.d"

pass "holds only the idle lock and blank, always expires, replays what it held\
 only if the seat stayed idle, defers overdue, and reconciles in audit"
