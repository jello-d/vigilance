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
  # Sandbox the MACHINE root too. Without this a real /etc/vigilance/hooks on
  # the developer's box would leak into every scenario, which is the same
  # class of reach-into-the-running-system the brightnessctl guard exists for.
  export VIGILANCE_MACHINE_HOOKS="$T/machine-hooks"
  mkdir -p "$VIGILANCE_MACHINE_HOOKS"
  # Sandbox the SYSFS roots `report` reads. Otherwise a scenario asserts on
  # whatever the developer's laptop is doing: report at rung `sleep` read the
  # real backlight, found it lit, and failed a correct test. Same family as the
  # brightnessctl leak -- a test must not depend on the running system's
  # hardware, let alone touch it.
  export VIGILANCE_SYS_BACKLIGHT="$T/sys/backlight"
  export VIGILANCE_SYS_DRM="$T/sys/drm"
  export VIGILANCE_SYS_LEDS="$T/sys/leds"
  # And the LOCKER probe. Without this a scenario's verdict depends on whether
  # the DEVELOPER's screen is locked while the suite runs -- which failed here
  # exactly that way, reading a real swaylock from inside a sandbox. Default to
  # "no locker"; a scenario that cares sets it per call.
  export VIGILANCE_LOCKER_UP=0
  # And the IDLE ARGV source. Unset, report pgreps for a real swayidle and reads
  # the DEVELOPER's live timer: both a reach into the running system and a
  # verdict that changes depending on their session. Point it at a file that
  # does not exist: the check then has nothing to read and says nothing, and a
  # scenario that cares writes the file itself.
  export VIGILANCE_IDLE_CMDLINE=$T/no-swayidle
  # And the SESSION probe, for the same reason and a sharper one: the two
  # substrates genuinely differ. The developer's box has a graphical session;
  # the VM guest has none, so `loginctl` there answers "No sessions". A scenario
  # that read the live answer passed in the stub tier and failed in the VM on a
  # difference it was not testing. Default to "a session exists" (the ordinary
  # case); the scenario that tests the no-session path sets it empty per call.
  export VIGILANCE_SESSION=1
  # ALERT DEDUP OFF IN SCENARIOS. Production suppresses a repeat of the SAME
  # alert within a cooldown, so a notifier does not fire every minute about an
  # unchanged fact. That is time-dependent behaviour, and a test asserting "this
  # raised an alert" would pass or fail depending on what an EARLIER case in the
  # same file happened to raise -- a test whose verdict depends on its
  # neighbours is not a test. Scenarios see every alert; test/standing-recheck.t
  # turns the cooldown back on where the dedup itself is the subject.
  export VIGILANCE_ALERT_COOLDOWN=0
  # And the SLEEP UNIT'S BUDGET, which the edge-budget check compares the hook
  # count against. Unset, it asks the real systemd what lock-on-sleep's
  # TimeoutStartSec is -- a host read, and one that is absent entirely on a box
  # where the unit was never installed, so the check would silently do nothing
  # in the stub tier and something else again in the VM. Pinned to the value the
  # shipped unit carries, so the arithmetic is the thing under test.
  export VIGILANCE_SLEEP_BUDGET=25s
  mkdir -p "$VIGILANCE_SYS_BACKLIGHT" "$VIGILANCE_SYS_DRM" \
    "$VIGILANCE_SYS_LEDS"
  RECORD=$T/record
  : > "$RECORD"
  mkdir -p "$VIGILANCE_HOOK_ROOT" "$VIGILANCE_RUN_DIR"
  SKIPPED=0
}

# `require` lives in lib.sh: the SESSION tier needs it too and does not want
# scenario.sh's recorder setup, so it is a harness primitive rather than a
# scenario one. Kept here as a pointer so nobody re-adds a second copy.

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
# hook installs into the USER scope; mhook into the MACHINE scope. Both record
# their scope so a scenario can assert the layering order.
mhook() {   # <edge> <name> [rc]
  _hd=$VIGILANCE_MACHINE_HOOKS/$1.d
  mkdir -p "$_hd"
  cat > "$_hd/$2" <<EOF
#!/bin/sh
printf '%s %s %s\n' "\$VIGILANCE_EDGE" "\$VIGILANCE_FROM" "M:$2" >> "$RECORD"
exit ${3:-0}
EOF
  chmod +x "$_hd/$2"
}

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
  # stderr goes to the capture file, as it does for go/force: `status` can warn
  # (a bad VIGILANCE_INITIAL_DEPTH, say), and a scenario must be able to assert
  # on that rather than have it leak to the terminal.
  _got=$("$VIGILANT" status 2>>"$T/stderr" | awk '/^depth:/ {print $2}')
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

# `_section`, `_no_fail_in` and `_fail_in` live in lib.sh: reading a report
# section is something the SESSION tier does too, and a second copy of the
# rule they encode is exactly the drift they exist to prevent.

# expect_verify <edge> <ok|fail>: assert THROUGH the product's own verifier.
# Scenarios must prefer this over poking at files: it is what keeps the suite
# and the production watchdog from drifting apart, because both call the same
# predicate.
# STDOUT goes to the capture file too, not the terminal. `verify` prints its own
# verdict ("verify lock: FAIL"), and an EXPECTED failure printed to the screen
# made a green run look like it had two failures in it -- a suite whose passing
# output contains the word FAIL trains you not to read it.
expect_verify() {   # <edge> <ok|fail>
  _vrc=0
  "$VIGILANT" verify "$1" >>"$T/verify.out" 2>>"$T/stderr" || _vrc=1
  case "$2" in
    ok)   [ "$_vrc" = 0 ] || fail "verify $1: want ok, got fail" ;;
    fail) [ "$_vrc" = 1 ] || fail "verify $1: want fail, got ok" ;;
    *) fail "expect_verify: bad expectation '$2'" ;;
  esac
}
