#!/bin/sh
# test/block.t - the block hook kind, and the phantom guard built on it.
#
# Two properties, and the SAFETY DIRECTION of each is the point.
#
# FAIL OPEN. Only an explicit exit 10 blocks; a block hook that errors, or is
# absent, or returns anything else, ALLOWS. Suppressing a lock is a security
# failure (the screen stays unlocked); allowing a redundant one is merely
# noise. A broken hook must therefore never be able to stop a lock.
#
# NOTHING HAPPENS ON A BLOCK. block.d runs BEFORE the depth is committed and
# before any actuator sees the edge, so a blocked crossing leaves the machine
# exactly where it was and reports exit 3 (refused), not 1 (degraded). A unit
# receiving 3 knows the state did not move.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init block

VIGILANCE_LOG=$T/vigilant.log
export VIGILANCE_LOG

hook lock 10-act

# --- exit 10 blocks: nothing runs, nothing moves, exit 3 --------------------
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.block.d"
cat > "$VIGILANCE_HOOK_ROOT/lock.block.d/10-veto" <<'EOF'
#!/bin/sh
echo "because I said so"
exit 10
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/lock.block.d/10-veto"

go lock
expect_rc 3                                  # refused, NOT degraded
expect_depth open                            # nothing moved
expect_record ""                             # no actuator ran
expect_stderr "BLOCKED lock by 10-veto: because I said so"

# --- a BROKEN block hook fails OPEN ----------------------------------------
# The direction that matters: a hook that errors must not be able to suppress
# a lock. It is logged, loudly, and the edge proceeds.
printf '#!/bin/sh\nexit 1\n' > "$VIGILANCE_HOOK_ROOT/lock.block.d/10-veto"
go lock
expect_rc 0
expect_depth lock
expect_stderr "block hook 10-veto errored (rc=1); ALLOWING"

# --- the phantom guard: scoped to the idle source --------------------------
rm -f "$VIGILANCE_HOOK_ROOT/lock.block.d/10-veto"
ln -sf "$HERE/libexec/vigilance/hooks/phantom-guard" \
  "$VIGILANCE_HOOK_ROOT/lock.block.d/10-phantom"
VIGILANCE_RUN_DIR=$VIGILANCE_RUN_DIR
export VIGILANCE_RUN_DIR

go open                                      # we are now at `open`, just now

# An idle-sourced lock immediately after an unlock IS swayidle's re-fire.
VIGILANCE_SOURCE=idle "$VIGILANT" go lock 2>>"$T/stderr" && _rc=0 || _rc=$?
[ "$_rc" = 3 ] || fail "phantom idle-lock was not blocked (rc=$_rc)"
expect_depth open

# ...but the SAME timing from any other source must go straight through.
# Gating suspend or a lid close would leave the box asleep UNLOCKED, which is
# the one failure this guard must never cause.
for _src in logind suspend manual lid; do
  VIGILANCE_SOURCE=$_src "$VIGILANT" go lock 2>>"$T/stderr" || \
    fail "phantom guard wrongly blocked source '$_src'"
  expect_depth lock
  "$VIGILANT" go open >/dev/null 2>&1
done

# ...and A DEPTH RECORD FROM THE FUTURE MUST NOT BLOCK ANYTHING.
#
# A wall clock is not monotonic. An NTP step, an RTC left in local time after a
# dual boot, or a VM restore makes `now - entered_at` NEGATIVE -- and a negative
# satisfies `-lt $COOLDOWN`, so the guard blocked EVERY idle lock for as long as
# the skew lasted and said so in words that give it away: "idle-lock -3600s
# after unlock". Measured, not feared, and the screen never locked.
#
# This is the one hook whose whole job is to suppress locks, so a wrong answer
# is a security failure rather than noise. Allowing is what every other unknown
# in that hook already gets.
printf '%s %s\n' open "$(( $(date +%s) + 3600 ))" > "$VIGILANCE_RUN_DIR/depth"
VIGILANCE_SOURCE=idle "$VIGILANT" go lock 2>>"$T/stderr" \
  || fail "with the depth record stamped an hour AHEAD, an idle lock was
blocked. A backward clock step then suppresses idle locking entirely: the guard
that exists to stop a redundant lock stops every lock, and silently"
expect_depth lock
"$VIGILANT" go open >/dev/null 2>&1

# ...and an idle lock OUTSIDE the cooldown is legitimate, so it proceeds.
go open
VIGILANCE_PHANTOM_COOLDOWN=0 VIGILANCE_SOURCE=idle "$VIGILANT" go lock \
  2>>"$T/stderr" || fail "a legitimate idle lock was blocked"
expect_depth lock

# --- THE DIRECTION ASYMMETRY: a descent may be refused, an ascent may not ----
# Found by auditing cmd_rescue rather than by a failing test, then MEASURED
# before the fix: a hook in wake.block.d made `vigilant force open` AND
# `vigilant rescue` both return 3 with the machine still recorded at `sleep`.
#
# That is the panic key -- bound to a bare unmodified key, pressed BLIND by
# someone who cannot see the screen -- disabled by a plugin. "The screen is dark
# and nothing will bring it back" was a supported configuration.
#
# Nothing is lost by refusing it. This edge performs no authentication (swaylock
# does), so blocking `unlock` never kept anyone out; it only suppressed the
# RECORD and the restore hooks, desyncing the file from a machine the user has
# already unlocked.
go sleep
expect_depth sleep
mkdir -p "$VIGILANCE_HOOK_ROOT/wake.block.d"
printf '#!/bin/sh\necho veto\nexit 10\n' \
  > "$VIGILANCE_HOOK_ROOT/wake.block.d/10-veto"
chmod +x "$VIGILANCE_HOOK_ROOT/wake.block.d/10-veto"

"$VIGILANT" go open >/dev/null 2>>"$T/stderr" \
  || fail "an ordinary ASCENT was refused by a block hook. The machine is left
in a dark rung with its only way out vetoed"
expect_depth open

# ...and the panic path specifically, because that is the one that matters most
# and it reaches the runner by a different route (force, not go).
go sleep
_rc=0
VIGILANCE_RESCUE_LOG=$T/rescue.log \
  "$VIGILANT" rescue >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 0 ] || fail "'rescue' returned $_rc with a block hook wired on an
ascent edge. The panic key is the last resort and a plugin could veto it"
expect_depth open

# --- a DESCENT block still works, which is the tier's actual purpose --------
# Without this the fix could have been "ignore the block tier", which would
# delete the phantom guard above and every inhibitor with it.
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.block.d"
printf '#!/bin/sh\necho veto\nexit 10\n' \
  > "$VIGILANCE_HOOK_ROOT/sleep.block.d/10-veto"
chmod +x "$VIGILANCE_HOOK_ROOT/sleep.block.d/10-veto"
_rc=0
"$VIGILANT" go sleep >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 3 ] || fail "a DESCENT block returned $_rc, not 3 (refused). The
asymmetry must remove the ascent veto WITHOUT disarming the tier's real job"
expect_depth lock

# --- and the ignored hook is REPORTED, not silently dropped ----------------
# Silently ignoring it leaves the operator believing a veto is armed that does
# nothing, which is this project's signature failure wearing the fix's clothes.
_out=$("$VIGILANT" report 2>>"$T/stderr") || true
case "$_out" in
  *"ASCENT edge, IGNORED"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a block hook wired on an ascent edge is ignored by the runner and
NOT mentioned by report. The operator believes a veto is armed that does
nothing, and nothing anywhere says otherwise" ;;
esac
# It is a WARN, not a FAIL: the wiring is wrong but the machine is safe, and
# nothing here should make an otherwise-healthy report red.
_no_fail_in "$_out" wiring "an ignored ascent block was raised as a FAIL; the
machine is in its correct state, so this is a wiring warning"

pass
