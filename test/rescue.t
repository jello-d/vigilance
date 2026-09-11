#!/bin/sh
# test/rescue.t - `vigilant report` and `vigilant rescue`.
#
# Both were absorbed from a host script, and the absorption is the thing under
# test. The host had reimplemented knowledge of the depth file, the hooks and
# the units from outside, and every probe that fell out of step did so SILENTLY
# -- a stale-save probe watched a path nothing had written since the refactor,
# and a swaylock signal became a lock-killer when the patch was retired.
#
# So the assertions here are mostly about structure: rescue records through
# report (so the two cannot drift), rescue actuates only through hooks (so
# there is one implementation, not two), and report tells drift from n/a.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init rescue

RESCUE_LOG=$T/rescue.log
export VIGILANCE_RESCUE_LOG=$RESCUE_LOG

# --- report: an empty verify tier is a WARN, never a pass -------------------
# It exits 0 (a box with no verifiers is not broken) but it must not read as
# green. This is the exact line that printed [OK] on a real machine for a week.
go open
_out=$("$VIGILANT" report 2>>"$T/stderr") || fail "report on a sane box failed"
case "$_out" in
  *"[WARN]"*"n/a"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "report did not WARN about an empty verify tier" ;;
esac
case "$_out" in
  *"depth=open"*) ;;
  *) fail "report did not state the recorded depth" ;;
esac

# --- report: a save file outstanding at a LIT rung is drift -----------------
# A hook saves the level it is about to dim FROM and removes it once restored.
# One still present at `open` means a descent dimmed something the ascent never
# put back, which is "the screen is dark and nothing will bring it back" as a
# fact on disk. It is the sharpest signal in the report and the host's version
# had been looking for it at a path nothing writes.
mkdir -p "$VIGILANCE_RUN_DIR/state/20-panel-backlight"
echo 260 > "$VIGILANCE_RUN_DIR/state/20-panel-backlight/level"
_out=$("$VIGILANT" report 2>>"$T/stderr") && fail "report passed with a stale
save at a lit rung"
case "$_out" in
  *"[FAIL]"*"outstanding at a lit rung"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "report did not flag the outstanding save" ;;
esac

# ...and the SAME file at a dark rung is expected, not drift. A verifier that
# cries wolf on a correct machine trains you to ignore the real one.
go sleep
_out=$("$VIGILANT" report 2>>"$T/stderr") || fail "report failed at rung sleep"
case "$_out" in
  *"saved levels held"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a save held while dark was reported as drift" ;;
esac
rm -rf "$VIGILANCE_RUN_DIR/state/20-panel-backlight"

# --- rescue RECORDS THROUGH REPORT ------------------------------------------
# Not a second set of probes. If rescue gathered its own facts they would drift
# from report's, and the rescue log is worthless the moment it stops holding
# what report would have shown.
: > "$RECORD"
go lock
"$VIGILANT" rescue >/dev/null 2>>"$T/stderr" || fail "rescue exited non-zero"
[ -f "$RESCUE_LOG" ] || fail "rescue wrote no evidence log"
for _marker in "=== vigilant rescue" "-- recorded state --" "-- coherence --" \
               "-- after recovery"; do
  grep -q -- "$_marker" "$RESCUE_LOG" \
    || fail "rescue log is missing '$_marker' (did it stop using report?)"
done

# BEFORE and AFTER, in that order. Recovering first would burn the only
# evidence an intermittent fault ever gives us.
_lineno() { grep -n -- "$1" "$RESCUE_LOG" | head -1 | cut -d: -f1; }
_before=$(_lineno "-- recorded state --")
_after=$(_lineno "-- after recovery")
[ "$_before" -lt "$_after" ] \
  || fail "rescue recovered before it recorded"

# --- rescue recovers THROUGH HOOKS, and lands at open -----------------------
# `force open` crosses every ascent edge, so anything the rescue should drive
# is a hook and exists once. The direct wlopm/DDC/kbd calls this replaced had
# become duplicates of the very hooks they shadowed.
expect_depth open
: > "$RECORD"
hook wake 10-relight
hook unlock 10-relight
go sleep
: > "$RECORD"
"$VIGILANT" rescue >/dev/null 2>>"$T/stderr" || fail "rescue failed"
expect_record "wake sleep 10-relight
unlock lock 10-relight"
expect_depth open

# --- rescue raises an ALERT, not an integrator's notifier -------------------
# A human pressing the panic key IS an intervention whether or not the recovery
# worked. Routing it through the alert tier is what stopped the host script
# hardcoding its own `intervention-required` binary.
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-catch" <<EOF
#!/bin/sh
printf '%s %s\n' "\$VIGILANCE_ALERT_KIND" "\$VIGILANCE_ALERT_MSG" \
  >> "$T/alerts"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-catch"
: > "$T/alerts"
"$VIGILANT" rescue >/dev/null 2>>"$T/stderr" || fail "rescue failed"
grep -q "^rescue " "$T/alerts" \
  || fail "rescue raised no alert through the alert tier"
grep -q "$RESCUE_LOG" "$T/alerts" \
  || fail "the alert does not carry the evidence path"

pass
