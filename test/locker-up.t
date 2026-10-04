#!/bin/sh
# test/locker-up.t - the lock edge's missing verifier.
#
# THE FRAMEWORK'S RULE, applied to the actuator that matters most: for every
# hook that acts, a paired hook asserting it took effect. The lock provider
# brings a LOCKER up, and nothing asserted that it did. On a real box the `lock`
# edge had three verify hooks (dpms, ddc-monitor, panel-backlight) each one
# checks a PERIPHERAL. They assert the screen is lit. Not one asks whether the
# session is secured, which is the whole point of the edge.
#
# The consequence is at SUSPEND. lock-on-sleep.service is ordered
# Before=sleep.target and systemd really does wait for it, but a unit that
# reports success while no locker came up means the machine sleeps unlocked
# and calls it a clean crossing.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init locker-up

H=$HERE/libexec/hooks/locker-up

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
#
# AND IT MUST NOT PIN AN EDGE. This asked for `verify lock` until ExecStart
# gained `atleast`, which may leave the machine at `sleep` rather than raising
# it. `verify lock` there runs the lock rung's tier, whose peripheral hooks
# assert the screen is LIT, so a correctly dark box would fail this unit and
# alert, moments before suspending. Bare `verify` asks about the rung the
# machine is actually at, and the lock claim survives because `locker-up`
# belongs in every verify tier at or below `lock`.
grep -qE '^ExecStartPost=.*(@VIGILANT@|vigilant) verify[[:space:]]*$' "$_unit" \
  || fail "lock-on-sleep.service must run a bare 'verify' after crossing. Either
it never verifies at all, so a suspend can report success while the session is
not secured, or it pins an edge, which asks the wrong rung's question whenever
ExecStart declines to raise a machine that was already deeper"
# ...and it must come AFTER the crossing, or it verifies the previous state.
awk '/^ExecStart=/{s=NR} /^ExecStartPost=/{p=NR}
     END{exit (s && p && p > s) ? 0 : 1}' "$_unit" \
  || fail "the verify does not follow the crossing in lock-on-sleep.service"

# --- THE REAL PROBE, which every case above short-circuits ------------------
# EVERY CASE SO FAR SETS VIGILANCE_LOCKER_UP, and that knob replaces the probe
# outright. So the code that actually decides whether the session is secured
# was exercised by NOTHING in this file, in the hook whose entire job is that
# question. The same trap the triggers section nearly shipped with: an override
# short-circuits the thing it stands in for.
#
# AND IT HELD A DEFECT. The probe was `pgrep -x "$LOCKER"`, which is wrong twice
# for a name from a knob: comm is truncated to 15 bytes by the kernel, so an
# exact match on a longer name NEVER succeeds, and the pattern is an ERE, so
# `.*` matches every process. The first makes this hook FAIL on a correctly
# locked box once a minute; the second makes it pass with nothing locking.
#
# A REAL PROCESS, under a TEST-UNIQUE NAME. A fixture called `swaylock` would
# find the DEVELOPER'S real locker on a desktop and the absent case would pass
# for the wrong reason, which is the substrate-reading mistake this suite has
# paid for three times.
_LN=vig-lu-screensaver          # 20 bytes: comm holds only vig-lu-screensa
cat > "$T/$_LN" <<'TEMPLATE'
#!/bin/sh
: > "$0.ready"
_i=0
while [ "$_i" -lt 600 ]; do _i=$((_i + 1)); sleep 0.1; done
TEMPLATE
chmod +x "$T/$_LN"
"$T/$_LN" &
_LPID=$!
_i=0
while [ ! -f "$T/$_LN.ready" ] && [ "$_i" -lt 80 ]; do _i=$((_i + 1)); sleep 0.1
done
[ -f "$T/$_LN.ready" ] || fail "the locker fixture never became ready, so the
cases below would be about a process that is not running"

# THE UNIT MUST NOT ANSWER FIRST. `_up` tries systemd before the process name,
# so a stray screen-lock.service would decide this and the probe under test
# would never run. Pointing the unit name at one that cannot exist leaves the
# process probe as the only thing that can answer.
# `env -u` IS LOAD-BEARING: scenario_init EXPORTS VIGILANCE_LOCKER_UP=0 for the
# whole file, so merely not passing it leaves the probe short-circuited and
# every case below reads "no locker". Walked into while writing the comment
# above it, which is the argument for having the comment.
_p() {   # <name> <edge> -> hook exit status, REAL probe
  env -u VIGILANCE_LOCKER_UP VIGILANCE_KIND=verify \
    VIGILANCE_LOCK_UNIT=vig-no-such-unit.service \
    VIGILANCE_LOCKER="$1" "$H" "$2" 2>>"$T/stderr"
}

_p "$_LN" lock || fail "with a process named $_LN running, the REAL probe must
see the session as locked. comm holds only the first 15 bytes, so an exact match
on the full name finds nothing and this verifier FAILS on a correctly locked
box, once a minute, raising an alert on the security edge every time"

# THE DISCRIMINATING HALF. 'running' and 'not running' must come out opposite on
# the same machine, or a probe stuck on either answer passes one of them: at
# `unlock` the session must be UNLOCKED, so a live locker is a failure.
_p "$_LN" unlock && fail "at 'unlock' with a locker running the probe must
FAIL. Passing here means it cannot see the process at all, and the case above
then passed for some other reason"

# AN OVER-WIDE PATTERN MUST NOT SATISFY IT, which is the false-green direction
# and the one that matters: `pgrep -x '.*'` matches every process on the box, so
# the verifier would report a secured session with no locker anywhere.
_p '.*' lock && fail "the probe accepted '.*' as a running locker. As an ERE
that matches EVERY process, so this hook would certify the session as secured on
a machine with nothing locking it: the one answer here that must never be wrong"
_p 'definitely-no-such-locker' lock && fail "the probe claimed a locker named
'definitely-no-such-locker' was running"

kill "$_LPID" 2>/dev/null || true
wait "$_LPID" 2>/dev/null || true

pass
