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

# ...and an idle lock OUTSIDE the cooldown is legitimate, so it proceeds.
VIGILANCE_PHANTOM_COOLDOWN=0 VIGILANCE_SOURCE=idle "$VIGILANT" go lock \
  2>>"$T/stderr" || fail "a legitimate idle lock was blocked"
expect_depth lock

pass
