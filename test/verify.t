#!/bin/sh
# test/verify.t - the verify tier, and the false green it used to be.
#
# `vigilant verify` returned 0 with ZERO verify hooks installed. "Clean" meant
# "nothing was asked" and read exactly like "everything checked out" -- to
# vigilance-report, to a systemd timer, and to a human. That is the failure
# this project exists to catch, reproduced inside the thing built to catch it,
# and it printed a green line on manifestor for a week.
#
# So: an empty tier says n/a EXPLICITLY, and a populated one actually catches
# the drift it claims to.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init verify

# --- an empty tier must NOT read as a pass ----------------------------------
_out=$("$VIGILANT" verify 2>>"$T/stderr") || fail "empty verify exited non-zero"
case "$_out" in
  *"n/a"*"nothing was checked"*) ;;
  *) printf 'got: %s\n' "$_out" >&2
     fail "an empty verify tier did not announce itself as n/a" ;;
esac

# Exit stays 0: a box with no verify hooks is not BROKEN, and a timer must not
# alarm. The honesty lives in the output, not the status.
[ -n "$_out" ] || fail "empty verify said nothing at all"

# --- a populated tier reports per edge --------------------------------------
hook lock 10-act
hook lock.verify 10-confirm
go lock
_out=$("$VIGILANT" verify lock 2>>"$T/stderr") || fail "verify lock failed"
case "$_out" in
  *"verify lock: ok"*) ;;
  *) fail "a populated verify tier did not report the edge" ;;
esac

# --- and it CATCHES drift, which is the whole point -------------------------
hook lock.verify 20-cannot-confirm 4
_out=$("$VIGILANT" verify lock 2>>"$T/stderr") && fail "verify passed on drift"
case "$_out" in
  *"verify lock: FAIL"*) ;;
  *) fail "a failing verify hook did not report FAIL" ;;
esac

# --- VIGILANCE_KIND lets one plugin serve both kinds ------------------------
# Without it a hook cannot tell "do it" from "check it": the edge is the same
# string either way. This is what lets ddc-monitor share its bus discovery
# between acting and verifying instead of duplicating it in a second file.
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.d" "$VIGILANCE_HOOK_ROOT/sleep.verify.d"
cat > "$T/dual" <<EOF
#!/bin/sh
printf '%s:%s\n' "\$VIGILANCE_EDGE" "\$VIGILANCE_KIND" >> "$T/kinds"
exit 0
EOF
chmod +x "$T/dual"
ln -sf "$T/dual" "$VIGILANCE_HOOK_ROOT/sleep.d/50-dual"
ln -sf "$T/dual" "$VIGILANCE_HOOK_ROOT/sleep.verify.d/50-dual"
: > "$T/kinds"

go sleep
"$VIGILANT" verify sleep >/dev/null 2>>"$T/stderr" || fail "verify sleep failed"
_got=$(cat "$T/kinds")
[ "$_got" = "sleep:act
sleep:verify" ] || { printf 'got: %s\n' "$_got" >&2
  fail "the same plugin was not told which kind it was invoked as"; }

# --- verify defaults to the CURRENT rung, not every edge ---------------------
# Checking every edge asserts mutually exclusive things at once: at `open` it
# demanded the monitor be BOTH lit (unlock) and dark (sleep). On manifestor
# that made a healthy awake machine report drift AND raise an alert, which is
# the cry-wolf failure the alert design explicitly set out to avoid.
: > "$RECORD"
go open
hook unlock.verify 10-lit
hook sleep.verify  10-dark
_out=$("$VIGILANT" verify 2>>"$T/stderr") || fail "verify failed at rung open"
case "$_out" in
  *"verify unlock: ok"*) ;;
  *) printf 'got: %s\n' "$_out" >&2
     fail "at rung open, verify did not check the unlock edge" ;;
esac
case "$_out" in
  *sleep*) fail "at rung open, verify checked the SLEEP edge (a dark
assertion on an awake machine)" ;;
esac

# ...and at a dark rung it checks that rung's assertion instead.
go sleep
_out=$("$VIGILANT" verify 2>>"$T/stderr") || fail "verify failed at rung sleep"
case "$_out" in
  *"verify sleep: ok"*) ;;
  *) fail "at rung sleep, verify did not check the sleep edge" ;;
esac

# An explicit edge is still checkable, which is what a scenario needs.
"$VIGILANT" verify unlock >/dev/null 2>>"$T/stderr" \
  || fail "an explicitly named edge is no longer verifiable"

# --- the n/a message must NAME the edge -------------------------------------
# "no verify hooks installed" is a claim about the whole tier, and it was wrong:
# a box with sleep and wake verifiers sitting at rung `open` got it, and the
# report above turned that into [FAIL] NO verify hooks installed. Three were
# installed. The unanswered question has to identify itself.
: > "$RECORD"
go open
rm -rf "$VIGILANCE_HOOK_ROOT/unlock.verify.d"
_out=$("$VIGILANT" verify 2>>"$T/stderr")
case "$_out" in
  *"n/a"*unlock*) ;;
  *) printf 'got: %s\n' "$_out" >&2
     fail "an n/a verify did not name the edge it could not check" ;;
esac

# --- hook_intent is KIND-AWARE on the lit edges ------------------------------
# lock and unlock must not ACT on brightness (locking leaves the screen on, and
# wake already re-lit it; re-asserting would stomp a level set by hand), but the
# lit assertion at those rungs is real and is the blackout check. One edge, two
# answers, decided by VIGILANCE_KIND -- so pin both directions.
. "$(dirname "$0")/../libexec/vigilance/hooklib.sh"
for _e in lock unlock; do
  _a=$(VIGILANCE_KIND=act    hook_intent "$_e")
  _v=$(VIGILANCE_KIND=verify hook_intent "$_e")
  [ "$_a" = none ] || fail "$_e ACTS on brightness ($_a); it must not"
  [ "$_v" = lit ]  || fail "$_e does not VERIFY lit ($_v); the rung is lit"
done
# And the edges that act must not have been disturbed by that change.
for _pair in "sleep dark" "suspend dark" "resume dark" "wake lit"; do
  set -- $_pair
  _g=$(VIGILANCE_KIND=act hook_intent "$1")
  [ "$_g" = "$2" ] || fail "intent($1) is now '$_g', expected '$2'"
done

pass
