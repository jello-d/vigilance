#!/bin/sh
# test/fuzz.t - random ladder sequences, checked against the invariants.
#
# WHY THIS AND NOT ANOTHER SCENARIO. Every defect the box found and the tests
# did not had one shape: the MODEL was incomplete exactly where an external
# actor touched the state. The lid that lit the screen, swayidle running its
# pending resume on SIGTERM, the recheck judging a half-finished crossing, the
# second lock request arriving in the same second. A scenario asserts against a
# model, so it can only ever contain sequences somebody thought of. A FUZZER
# NEEDS NO MODEL: it produces sequences nobody thought of and asks only whether
# the invariants still hold.
#
# REPRODUCIBILITY IS THE WHOLE DESIGN, because a fuzzer that cannot reproduce
# its own failure is worse than none: it reports something alarming and
# unactionable, and gets switched off. So the sequence is DERIVED from a seed by
# an LCG in shell arithmetic rather than drawn from $RANDOM or awk's srand,
# which differ between implementations. Same seed, same sequence, on any box.
#
# AND IT BISECTS. A failure at step 400 is a curiosity; the shortest failing
# PREFIX is a bug report. On any violation this replays prefixes to find the
# smallest one that still fails, and prints the two numbers that reproduce it.
#
# DETERMINISTIC BY DEFAULT, deliberately. The suite runs a fixed seed and a
# modest length, so this is a regression test rather than a slot machine: a
# flaky test is one people re-run until it goes green. Set the seed and the
# length to explore:
#
#     VIGILANCE_FUZZ_SEED=12345 VIGILANCE_FUZZ_STEPS=5000 sh test/fuzz.t
#
# THE STUB TIER IS THE RIGHT SUBSTRATE. What is under test is the ladder's own
# bookkeeping, not a device, and thousands of steps have to cost seconds. The
# session tier would be honest and far too slow to fuzz.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init fuzz

SEED=${VIGILANCE_FUZZ_SEED:-20260930}
STEPS=${VIGILANCE_FUZZ_STEPS:-240}
RUNG_RE='^(open|lock|sleep|suspend)$'

# --- the generator ----------------------------------------------------------
# An LCG, in shell arithmetic so it is exactly reproducible. The constants are
# the classic glibc ones; the quality does not matter here, only that the
# sequence is the same everywhere and covers the alphabet.
_rand() {   # <state> -> next state on stdout
  echo $(( ($1 * 1103515245 + 12345) % 2147483648 ))
}
# THE ALPHABET. Every entry is a legal, well-formed request: the point is not to
# test argument parsing (cli.t owns that) but to interleave legal operations in
# orders nobody wrote down. Faults are IN the alphabet, because the defects this
# exists for all involved something going wrong mid-sequence.
_OPS='go-open go-lock go-sleep go-suspend
atleast-lock atleast-sleep
only-lock only-open
force-open force-lock
rescue verify enforce
report plan audit due status
fault-fail fault-decline fault-block fault-clear'
_nops=$(printf '%s\n' $_OPS | grep -c .)

# GENERATED ONCE, into a file, which is both the O(n) fix and the artefact a
# failure needs to print. Deriving each step on demand re-ran the LCG from the
# seed every time, making a run quadratic: unnoticeable at 240 steps and 12.5
# million shell iterations at 5000, which is the length this exists to allow.
SEQ=$T/sequence
_gen() {
  : > "$SEQ"
  _g_s=$SEED
  _g_i=1
  while [ "$_g_i" -le "$STEPS" ]; do
    _g_s=$(_rand "$_g_s")
    printf '%s %s\n' "$_g_i" \
      "$(printf '%s\n' $_OPS | sed -n "$(( (_g_s % _nops) + 1 ))p")" >> "$SEQ"
    _g_i=$((_g_i + 1))
  done
}

# --- the machine under test -------------------------------------------------
_depth_now() { "$VIGILANT" status 2>/dev/null | awk '/^depth:/ {print $2}'; }
_rank() {   # a rung's depth, so "never shallower" is comparable
  case "$1" in open) echo 0 ;; lock) echo 1 ;; sleep) echo 2 ;;
    suspend) echo 3 ;; *) echo -1 ;; esac
}

_apply() {   # <op> -> rc in $RC
  RC=0
  case "$1" in
    go-open)       "$VIGILANT" go open      >>"$T/out" 2>>"$T/err" || RC=$? ;;
    go-lock)       "$VIGILANT" go lock      >>"$T/out" 2>>"$T/err" || RC=$? ;;
    go-sleep)      "$VIGILANT" go sleep     >>"$T/out" 2>>"$T/err" || RC=$? ;;
    go-suspend)    "$VIGILANT" go suspend   >>"$T/out" 2>>"$T/err" || RC=$? ;;
    atleast-lock)  "$VIGILANT" go lock atleast \
                     >>"$T/out" 2>>"$T/err" || RC=$? ;;
    atleast-sleep) "$VIGILANT" go sleep atleast \
                     >>"$T/out" 2>>"$T/err" || RC=$? ;;
    force-open)    "$VIGILANT" force open   >>"$T/out" 2>>"$T/err" || RC=$? ;;
    force-lock)    "$VIGILANT" force lock   >>"$T/out" 2>>"$T/err" || RC=$? ;;
    rescue)        "$VIGILANT" rescue       >>"$T/out" 2>>"$T/err" || RC=$? ;;
    verify)        "$VIGILANT" verify       >>"$T/out" 2>>"$T/err" || RC=$? ;;
    enforce)       "$VIGILANT" enforce      >>"$T/out" 2>>"$T/err" || RC=$? ;;
    only-lock)     "$VIGILANT" only lock    >>"$T/out" 2>>"$T/err" || RC=$? ;;
    only-open)     "$VIGILANT" only open    >>"$T/out" 2>>"$T/err" || RC=$? ;;
    # THE READ-ONLY VERBS, which are not here for coverage. `report` has twice
    # read state it did not write and called it a finding: an idle clock's
    # snapshot became "saved levels outstanding" and earned a permanent FAIL at
    # every lit rung, then a throttle stamp nearly did it again. Random state is
    # what finds that class. They must also leave the ladder ALONE, which the
    # oracle checks.
    # REPORT'S CODE IS DISCARDED, and that is not a workaround. It folds NINE
    # sections, several of which read the real host, so branching on it asserts
    # something partly about the machine running the suite: it passes for free
    # wherever the host is already red and keeps passing with the check it
    # claims to cover deleted. hermetic.t ratchets exactly this and caught this
    # line, which is the fifth time this project has paid for that conflation
    # and the first time a guard stopped it. The depth invariant below still
    # applies.
    report)        "$VIGILANT" report       >>"$T/out" 2>>"$T/err" || true ;;
    plan)          "$VIGILANT" plan         >>"$T/out" 2>>"$T/err" || RC=$? ;;
    audit)         "$VIGILANT" audit        >>"$T/out" 2>>"$T/err" || RC=$? ;;
    due)           "$VIGILANT" due          >>"$T/out" 2>>"$T/err" || RC=$? ;;
    status)        "$VIGILANT" status       >>"$T/out" 2>>"$T/err" || RC=$? ;;
    # THE FAULTS ARE REAL HOOKS, not a knob: a hook that exits 1 IS a failing
    # hook, and one that exits 78 IS a declining one. Nothing is pretended at.
    fault-fail)
      mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
      printf '#!/bin/sh\nexit 1\n' \
        > "$VIGILANCE_HOOK_ROOT/lock.d/90-fuzz-fail"
      chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/90-fuzz-fail" ;;
    fault-decline)
      mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.verify.d"
      printf '#!/bin/sh\nexit 78\n' \
        > "$VIGILANCE_HOOK_ROOT/sleep.verify.d/90-fuzz-na"
      chmod +x "$VIGILANCE_HOOK_ROOT/sleep.verify.d/90-fuzz-na" ;;
    fault-block)
      # ON EVERY EDGE, ascents included, which is the shape that once made the
      # panic key refusable. exit 10 is the block vocabulary.
      for _fb in lock sleep unlock wake; do
        mkdir -p "$VIGILANCE_HOOK_ROOT/$_fb.block.d"
        printf '#!/bin/sh\nexit 10\n' \
          > "$VIGILANCE_HOOK_ROOT/$_fb.block.d/90-fuzz-block"
        chmod +x "$VIGILANCE_HOOK_ROOT/$_fb.block.d/90-fuzz-block"
      done ;;
    fault-clear)
      rm -f "$VIGILANCE_HOOK_ROOT/lock.d/90-fuzz-fail" \
            "$VIGILANCE_HOOK_ROOT/sleep.verify.d/90-fuzz-na"
      for _fb in lock sleep unlock wake; do
        rm -f "$VIGILANCE_HOOK_ROOT/$_fb.block.d/90-fuzz-block"
      done ;;
  esac
}

# --- the oracle -------------------------------------------------------------
# Each check names the invariant it is about, because a fuzzer's output is only
# as useful as its ability to say WHICH belief just broke.
VIOL=
_check() {   # <op> <depth before>
  _c_op=$1; _c_before=$2
  _c_now=$(_depth_now)

  # THE RECORD ON DISK IS WELL-FORMED, read from the FILE rather than from
  # `status`. The first version of this check asked the runner for its depth and
  # was therefore unfalsifiable: `_depth` VALIDATES the record and falls back to
  # `open` with a note naming the corruption, so a deliberately corrupted file
  # still produced a perfectly good rung and the check could never fire. Proven
  # by planting one and watching nothing happen, which is how a vacuous
  # assertion is supposed to be found.
  #
  # The claim worth making is that the RUNNER never writes a bad record, and the
  # file is where that is visible: `<rung> <epoch>`.
  if [ -f "$VIGILANCE_RUN_DIR/depth" ]; then
    _c_r=$(awk 'NR == 1 { print $1 }' "$VIGILANCE_RUN_DIR/depth" 2>/dev/null)
    _c_t=$(awk 'NR == 1 { print $2 }' "$VIGILANCE_RUN_DIR/depth" 2>/dev/null)
    case "$_c_r" in
      open|lock|sleep|suspend) ;;
      *) VIOL="the depth RECORD holds '$_c_r', which is not a rung"; return 1 ;;
    esac
    case "$_c_t" in
      ''|*[!0-9]*) VIOL="the depth record's timestamp is '$_c_t'"; return 1 ;;
    esac
    if [ "$_c_t" -gt "$(( $(date +%s) + 5 ))" ]; then
      VIOL="the depth record is stamped in the FUTURE ($_c_t)"; return 1
    fi
  fi
  # ...and the runner's own answer is still a rung, which is a different claim:
  # that the validation and the fallback agree on the vocabulary.
  case "$_c_now" in
    open|lock|sleep|suspend) ;;
    *) VIOL="status reported depth '$_c_now', which is not a rung"; return 1 ;;
  esac

  # A WELL-FORMED REQUEST NEVER EXITS 2. Usage is for a caller that got the
  # command wrong, and every operation here is legal by construction, so a 2 is
  # the runner falling over. This is the check that would have caught sway-dpms
  # dying on an unset variable in its own error message.
  case "$RC" in
    0|1|3|10|75|78) ;;
    2) VIOL="'$_c_op' exited 2 (usage) on a well-formed request"; return 1 ;;
    *) VIOL="'$_c_op' exited $RC, which is outside the documented set"
       return 1 ;;
  esac

  # A LOCK REQUEST MAY DEEPEN, NEVER RAISE (invariant 3). The lid-close defect
  # in one line: `go lock` from `sleep` crossed `wake` and LIT the panel.
  case "$_c_op" in
    atleast-*)
      if [ "$(_rank "$_c_now")" -lt "$(_rank "$_c_before")" ]; then
        VIOL="$_c_op RAISED the machine from $_c_before to $_c_now"
        return 1
      fi ;;
  esac

  # AN OFFLINE VERB LEAVES THE LADDER ALONE. `plan` polluting the record would
  # be a bug in its own right: the audit tier reconciles that log, so a
  # reporting command that writes a crossing into it manufactures history. Cheap
  # to state and it makes the read-only verbs worth having in the alphabet at
  # all.
  case "$_c_op" in
    report|plan|audit|due|status)
      if [ "$_c_now" != "$_c_before" ]; then
        VIOL="the offline verb '$_c_op' moved the machine from $_c_before to
$_c_now"
        return 1
      fi ;;
  esac

  # THE PANIC KEY ALWAYS WORKS (invariant 7). A block hook once made `rescue`
  # return 3 with the machine still dark, which was a supported configuration.
  case "$_c_op" in
    rescue)
      if [ "$_c_now" != open ]; then
        VIOL="rescue left the machine at $_c_now rather than open"
        return 1
      fi ;;
  esac

  # NO CROSSING LOCK OUTLIVES A COMPLETED CROSSING (invariant 8). A leak here is
  # silent and switches off the only tier that watches a settled machine.
  if [ -e "$VIGILANCE_RUN_DIR/crossing.lock" ]; then
    VIOL="a crossing lock outlived '$_c_op'"
    return 1
  fi

  # NOTHING ACCUMULATES PER CROSSING (invariant 28). soak.t asserts this as a
  # slope over a uniform cycle; here the interleaving is random, which is the
  # case a fixed cycle cannot reach. The ceiling is generous because the bound
  # that matters is "does not grow with the number of operations".
  _c_n=$(find "$VIGILANCE_RUN_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_c_n:-0}" -gt 40 ]; then
    VIOL="the runtime dir holds $_c_n files after '$_c_op'; something is kept
per operation rather than replaced"
    return 1
  fi

  # ONE RECORD IS ONE LINE. The log's own contract, and the audit tier parses
  # this file BY LINE: untimestamped debris once made a reader report a
  # notification storm that was not happening.
  if [ -f "$VIGILANCE_LOG" ]; then
    _bad=$(awk '!/^[0-9]{4}-[0-9]{2}-[0-9]{2}T/ { print NR; exit }' \
             "$VIGILANCE_LOG" 2>/dev/null || true)
    if [ -n "$_bad" ]; then
      VIOL="log line $_bad does not begin with a timestamp: $(sed -n \
        "${_bad}p" "$VIGILANCE_LOG")"
      return 1
    fi
  fi
  return 0
}

# --- replay, which is what makes a failure reportable -----------------------
# Runs the first N steps from a CLEAN state. Used once for the real run and then
# repeatedly by the bisect, so it must leave nothing behind.
_replay() {   # <steps> -> 0 if every invariant held
  rm -rf "$VIGILANCE_RUN_DIR" "$VIGILANCE_HOOK_ROOT" "$VIGILANCE_LOG"
  mkdir -p "$VIGILANCE_RUN_DIR" "$VIGILANCE_HOOK_ROOT"
  VIOL=; FAILED_AT=; FAILED_OP=
  while read -r _r_i _r_op; do
    [ "$_r_i" -le "$1" ] || break
    _r_before=$(_depth_now)
    _apply "$_r_op"
    if ! _check "$_r_op" "$_r_before"; then
      FAILED_AT=$_r_i; FAILED_OP=$_r_op
      return 1
    fi
  done < "$SEQ"
  return 0
}

_gen
if _replay "$STEPS"; then
  # LIVENESS, asserted once at the end: whatever the sequence did, the ladder
  # must still be able to secure the machine. A fuzzer that only checks for
  # crashes would pass a machine that had quietly stopped locking.
  # THE PLANTED FAULTS ARE CLEARED FIRST, because "can the ladder still lock" is
  # a question about the LADDER and not about a hook this file deliberately
  # broke. Leaving one wired makes the answer be about the fault.
  _apply fault-clear
  "$VIGILANT" rescue >>"$T/out" 2>>"$T/err" || true
  # AND THE ASSERTION IS THE DEPTH, NOT THE EXIT CODE. My first version failed
  # here at 2000 steps and the product was right: with a failing hook in lock.d,
  # `go lock` returns 1 while the depth reaches `lock`, because rc=1 from the
  # runner means "it moved and a hook failed". Measured, not reasoned about.
  # Reading rc as "did the lock happen" is the conflation this suite keeps
  # paying for, and it produced a confident false finding in the one file
  # written to find real ones.
  "$VIGILANT" go lock >>"$T/out" 2>>"$T/err" || true
  if [ "$(_depth_now)" != lock ]; then
    fail "after $STEPS random operations (seed $SEED) the ladder could no longer
reach the lock rung: depth is '$(_depth_now)'. Reproduce with:
  VIGILANCE_FUZZ_SEED=$SEED VIGILANCE_FUZZ_STEPS=$STEPS sh test/fuzz.t"
  fi
  pass "$STEPS ops, seed $SEED, all invariants held"
  # `pass` PRINTS, it does not exit, and every other test in this suite calls it
  # as its last statement. Here the failure report follows, so falling through
  # reached it with no failure to report and died on an unset variable.
  exit 0
fi

# --- a failure, bisected ----------------------------------------------------
_broke_at=$FAILED_AT
_broke_op=$FAILED_OP
_broke_why=$VIOL
_lo=1
_hi=$_broke_at
while [ "$_lo" -lt "$_hi" ]; do
  _mid=$(( (_lo + _hi) / 2 ))
  if _replay "$_mid"; then _lo=$((_mid + 1)); else _hi=$_mid; fi
done
# Re-run the shortest failing prefix so the reported reason is that one's, not
# the long run's: a different invariant may break first in a shorter sequence.
_replay "$_hi" || true

fail "an invariant broke under random operation (seed $SEED).

  first seen at step $_broke_at ($_broke_op): $_broke_why
  SHORTEST failing prefix: $_hi steps, reason: ${VIOL:-$_broke_why}

REPRODUCE, deterministically, on any box:
  VIGILANCE_FUZZ_SEED=$SEED VIGILANCE_FUZZ_STEPS=$_hi sh test/fuzz.t

THE SEQUENCE up to the failure:
$(head -n "$_hi" "$SEQ")

depth now: $(_depth_now)
last log lines:
$(tail -5 "$VIGILANCE_LOG" 2>/dev/null || true)"
