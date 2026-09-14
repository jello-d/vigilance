#!/bin/sh
# test/locker-up.t - the lock edge's missing verifier.
#
# THE FRAMEWORK'S RULE, applied to the actuator that matters most: for every
# hook that acts, a paired hook asserting it took effect. The lock provider
# brings a LOCKER up, and nothing asserted that it did. On a real box the `lock`
# edge had three verify hooks -- dpms, ddc-monitor, panel-backlight -- each one
# checks a PERIPHERAL. They assert the screen is lit. Not one asks whether the
# session is secured, which is the whole point of the edge.
#
# The consequence is at SUSPEND. lock-on-sleep.service is ordered
# Before=sleep.target and systemd really does wait for it, but a unit that
# reports success while no locker came up means the machine sleeps unlocked
# and calls it a clean crossing.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init locker-up

H=$HERE/libexec/vigilance/hooks/locker-up

_v() {   # <edge> <up|down> -> hook exit status
  _u=0; [ "$2" = up ] && _u=1
  VIGILANCE_KIND=verify VIGILANCE_LOCKER_UP=$_u "$H" "$1" 2>>"$T/stderr"
}

# --- a LOCKED rung with no locker is drift, and must FAIL ------------------
# The security-relevant direction: we believe the session is secured and it is
# not. Every rung at or below `lock` means locked.
for _e in lock sleep suspend; do
  if _v "$_e" down; then
    fail "locker-up passed at '$_e' with NO locker running. That is the machine
believing it is secured while it is not, which is the one thing this edge exists
to guarantee"
  fi
  _v "$_e" up || fail "locker-up failed at '$_e' with a locker running"
done

# --- and the opposite direction, which catches a missed unlock -------------
# A locker still up at `open` means an edge was missed: the session reports
# itself usable while a lock screen is in the way.
_v unlock down || fail "locker-up failed at 'unlock' with no locker (correct)"
if _v unlock up; then
  fail "locker-up passed at 'unlock' while a locker was STILL RUNNING; that is a
missed edge and report already treats it as one"
fi

# --- VERIFY-ONLY. It must never act. ---------------------------------------
# Wired into lock.d by mistake it has to be inert, not a second implementation
# of the provider. Asserted for the failing case specifically: if `act` were
# treated like `verify`, this would exit non-zero.
VIGILANCE_KIND=act VIGILANCE_LOCKER_UP=0 "$H" lock 2>>"$T/stderr" \
  || fail "locker-up acted (or failed) when asked to ACT; it is verify-only and
bringing a locker up belongs to the provider"

# --- NO OPINION about edges that imply nothing -----------------------------
VIGILANCE_KIND=verify VIGILANCE_LOCKER_UP=0 "$H" open 2>>"$T/stderr" \
  || fail "locker-up had an opinion about a non-edge"

# --- THROUGH THE RUNNER, which is how it will really be asked -------------
# `vigilant verify` resolves the edge from the CURRENT RUNG, so this also
# asserts the rung -> edge mapping is the one the hook expects. Asserted via
# expect_verify so the test and the production watchdog share a predicate.
# SYMLINKED, not copied: that is how setup.sh installs and how the live boxes
# wire every hook (/etc/vigilance/hooks/*.d/NN-name -> libexec/.../name).
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.verify.d" \
         "$VIGILANCE_HOOK_ROOT/unlock.verify.d"
ln -sf "$H" "$VIGILANCE_HOOK_ROOT/lock.verify.d/50-locker-up"
ln -sf "$H" "$VIGILANCE_HOOK_ROOT/unlock.verify.d/50-locker-up"

go lock
expect_depth lock
VIGILANCE_LOCKER_UP=1 expect_verify lock ok
VIGILANCE_LOCKER_UP=0 expect_verify lock fail

go open
expect_depth open
VIGILANCE_LOCKER_UP=0 expect_verify unlock ok
VIGILANCE_LOCKER_UP=1 expect_verify unlock fail

# --- report folds it in: a locked rung with no locker is a FAILURE --------
# The whole point of routing through the shared oracle is that `report` inherits
# the assertion without a second implementation.
go lock
_rep=$(VIGILANCE_LOCKER_UP=0 "$VIGILANT" report 2>&1) || true
case "$_rep" in
  *"[FAIL]"*) ;;
  *) printf '%s\n' "$_rep" >&2
     fail "report was clean at rung 'lock' with no locker running" ;;
esac

# --- THE SUSPEND UNIT ASKS THE QUESTION ------------------------------------
# A verifier nothing invokes is the dead tier this project keeps rediscovering.
# lock-on-sleep.service must actually run `verify` after crossing, or "the unit
# succeeded" still only means "the hooks returned 0".
_unit=$HERE/systemd/lock-on-sleep.service
# Matches the PLACEHOLDER, not a literal path: the units carry @VIGILANT@ now
# and the installer substitutes it, precisely so no unit hardcodes a prefix.
grep -qE '^ExecStartPost=.*(@VIGILANT@|vigilant) verify lock' "$_unit" \
  || fail "lock-on-sleep.service crosses the lock edge but never verifies it, so
a suspend can still report success while the session is not secured"
# ...and it must come AFTER the crossing, or it verifies the previous state.
awk '/^ExecStart=/{s=NR} /^ExecStartPost=/{p=NR}
     END{exit (s && p && p > s) ? 0 : 1}' "$_unit" \
  || fail "the verify does not follow the crossing in lock-on-sleep.service"

pass
