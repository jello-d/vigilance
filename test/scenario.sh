# test/scenario.sh - the SHARED vocabulary for vigilance scenarios.
#
# Scenarios live once, in test/scenarios/, and are executed by TWO substrates:
#
#   test/run     STUB substrate: fast, no root, no systemd
#   test/vm/run  VM substrate:   root, real systemd + logind + suspend
#
# The integration between the tiers matters more than either tier. This cycle
# proved why: modules/tests/lock was GREEN the entire time ~/bin/panel-power
# did not exist. The tests tested the CODE; every bug was in the WIRING. Two
# tiers that do not share a definition of correctness give two ways to be
# confidently wrong. So the scenarios and their assertions are written ONCE and
# both substrates run them unchanged.
#
# THE RULE THAT MAKES IT HONEST: the stub substrate stubs ACTUATORS, never the
# TRUST ROOT. Hardware (ddcutil, brightnessctl, qmk) is replaced by recorder
# hooks. systemd, logind and suspend are NEVER stubbed, because a stubbed
# `systemctl` LIES, and a lying stub is exactly how a green test coexisted with
# a broken box. A scenario needing them declares `require systemd` and is
# SKIPPED VISIBLY in the stub substrate.
#
# A skip is never silent. test/run prints a coverage summary, so a green stub
# run can never be mistaken for full coverage. That is the same false
# confidence that let lock-watch sit dead for 74,309 restarts.

# scenario_init <name>: private HOME-ish scratch, an empty hook tree, and a
# recorder. Confines everything to $T; nothing outside it is written.
scenario_init() {   # <name>
  harness_init "$1"
  VIGILANT=$HERE/bin/vigilant
  export VIGILANCE_HOOK_ROOT="$T/hooks"
  export VIGILANCE_RUN_DIR="$T/run"
  # Sandbox the LOG too. Without this every scenario appends to the real
  # ~/.local/state/vigilance.log, polluting the operator's record with test
  # traffic. Same family as the brightnessctl leak in hooks.t: a test that
  # writes outside its temp dir is reaching into the running system.
  export VIGILANCE_LOG="$T/vigilant.log"
  RECORD=$T/record
  : > "$RECORD"
  mkdir -p "$VIGILANCE_HOOK_ROOT" "$VIGILANCE_RUN_DIR"
  SKIPPED=0
}

# require <capability>: declare a substrate need. The stub substrate cannot
# provide systemd/logind/suspend/hardware, so it SKIPS and says so. The VM
# substrate sets SCENARIO_CAPS to the list it can honour.
require() {   # <capability>...
  for _c in "$@"; do
    case " ${SCENARIO_CAPS:-} " in
      *" $_c "*) ;;
      *) printf 'skip %s (needs %s)\n' "$TEST_NAME" "$_c"; SKIPPED=1; exit 0 ;;
    esac
  done
}

# scenario_suspend: a REAL suspend/resume cycle, supplied by the substrate.
# There is deliberately no fallback: a faked suspend proves nothing about
# whether tmpfs survived, and a stub that pretends is precisely the lying stub
# this suite refuses to have. A scenario reaching here without `require
# suspend` is a bug in the scenario, so say so rather than quietly continuing.
scenario_suspend() {
  if [ -z "${SCENARIO_SUSPEND_CMD:-}" ]; then
    fail "scenario_suspend: no substrate (missing 'require suspend'?)"
  fi
  ${SCENARIO_SUSPEND_CMD} || fail "suspend cycle failed"
}

# hook <edge> <name> [rc]: install a RECORDER hook. It appends the edge, the
# rung being left, and its own name, so ordering and FROM are assertable
# without any hardware. `rc` makes it fail, to drive the loud-failure path.
hook() {   # <edge> <name> [rc]
  _hd=$VIGILANCE_HOOK_ROOT/$1.d
  mkdir -p "$_hd"
  cat > "$_hd/$2" <<EOF
#!/bin/sh
printf '%s %s %s\n' "\$VIGILANCE_EDGE" "\$VIGILANCE_FROM" "$2" >> "$RECORD"
[ -d "\$VIGILANCE_STATE_DIR" ] || { echo "no state dir" >&2; exit 90; }
exit ${3:-0}
EOF
  chmod +x "$_hd/$2"
}

# go <state> / force <state>: the action under test. Records the runner's own
# exit status so a scenario can assert a LOUD failure rather than a silent one,
# and so the 1-vs-3 contract (degraded vs refused) is actually exercised.
go() {   # <state>
  CROSS_RC=0
  "$VIGILANT" go "$1" 2>>"$T/stderr" || CROSS_RC=$?
}
force() {   # <state>
  CROSS_RC=0
  "$VIGILANT" force "$1" 2>>"$T/stderr" || CROSS_RC=$?
}
only() {   # <state>
  CROSS_RC=0
  "$VIGILANT" only "$1" 2>>"$T/stderr" || CROSS_RC=$?
}

expect_depth() {   # <rung>
  _got=$("$VIGILANT" status | awk '/^depth:/ {print $2}')
  [ "$_got" = "$1" ] || fail "depth: want '$1', got '$_got'"
}

expect_rc() {   # <rc>
  [ "$CROSS_RC" = "$1" ] || fail "exit: want $1, got $CROSS_RC"
}

# expect_record: the full recorder transcript, newline separated, in order.
# Asserting the ORDER is the point: descent runs 10->90, ascent 90->10.
expect_record() {   # <expected-transcript>
  _got=$(cat "$RECORD")
  if [ "$_got" != "$1" ]; then
    printf 'record mismatch\n--- want ---\n%s\n--- got ---\n%s\n' \
      "$1" "$_got" >&2
    fail "record"
  fi
}

expect_stderr() {   # <substring>
  grep -q -- "$1" "$T/stderr" 2>/dev/null \
    || fail "stderr did not mention '$1'"
}

# expect_verify <edge> <ok|fail>: assert THROUGH the product's own verifier.
# Scenarios must prefer this over poking at files: it is what keeps the suite
# and the production watchdog from drifting apart, because both call the same
# predicate.
expect_verify() {   # <edge> <ok|fail>
  _vrc=0
  "$VIGILANT" verify "$1" 2>>"$T/stderr" || _vrc=1
  case "$2" in
    ok)   [ "$_vrc" = 0 ] || fail "verify $1: want ok, got fail" ;;
    fail) [ "$_vrc" = 1 ] || fail "verify $1: want fail, got ok" ;;
    *) fail "expect_verify: bad expectation '$2'" ;;
  esac
}
