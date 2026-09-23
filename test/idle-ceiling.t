#!/bin/sh
# test/idle-ceiling.t - an ascent bounds the idle clock, and a bound is not a
# measurement.
#
# THE FALSE POSITIVES THIS ENCODES. The overdue detector compares a deadline
# expressed in IDLE time against a clock built from kernel input counters. Two
# things routinely raise the ladder without moving a counter:
#
#   a lid switch          not seat input to the compositor
#   an idle-unit restart  swayidle runs all pending resume commands on SIGTERM,
#                         which is documented behaviour and not a bug
#
# Either way swayidle rearms every timeout at that moment while our clock keeps
# counting from the last keystroke. Measured on manifold: a tackup run restarted
# the idle unit at 23:46:51, the shutdown resume crossed `wake`, and the
# detector then alerted once a minute that `sleep` was 3000s late. It fired at
# 23:56:52, exactly 600s after the restart, perfectly healthy. Nine alerts, all
# false, about a timer doing its job.
#
# So an ascent is a CEILING on idle time: whatever raised the machine is the
# most recent evidence of activity vigilant has, and it is the one evidence an
# input-counter clock can never be blind to.
#
# BUT A CEILING IS NOT A SOURCE. "Time since the last ascent" is an upper bound
# on idle, not a measurement of it, so it must never manufacture a number where
# no clock answered -- that would make `report` call a deadline measurable while
# nothing measures it, which is this project's signature false green.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init idle-ceiling

_source() {   # <seconds> | none | declines
  rm -rf "$VIGILANCE_HOOK_ROOT/idle.d"
  [ "$1" = none ] && return 0
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  case "$1" in
    # WIRED BUT UNABLE TO ANSWER: 78 is "I could not look", which on a box with
    # no countable input device is the honest and permanent answer. This is the
    # case the ceiling must not paper over, and it is NOT the same as having no
    # source at all -- with no hooks the aggregator returns before the ceiling
    # is ever reached, so a test using that path leaves the guard uncovered.
    # The mutation removing it survived exactly that way.
    declines) printf '#!/bin/sh\nexit 78\n' ;;
    *)        printf '#!/bin/sh\necho %s\n' "$1" ;;
  esac > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}
# Through `report`, not by poking the function: the whole point is that every
# consumer sees the corrected number, and report is the one that renders it.
_idle() {
  "$VIGILANT" report 2>/dev/null \
    | sed -n 's/.*idle clock: \([0-9]*\)s since last input.*/\1/p' | head -1
}
_mark=$VIGILANCE_RUN_DIR/last-ascent
_backdate() { printf '%s\n' "$(( $(date +%s) - $1 ))" > "$_mark"; }

# --- 1. WITH NO ASCENT RECORDED, THE SOURCE STANDS -------------------------
_source 900
rm -f "$_mark"
[ "$(_idle)" = 900 ] || fail "with no ascent on record the source's own number
must pass through untouched; got '$(_idle)'"

# --- 2. A RECENT ASCENT CAPS IT --------------------------------------------
# The live case. The clock says the seat has been quiet for 15 minutes; the
# ladder says something raised the machine 10 seconds ago. The ladder wins,
# because whatever raised it also restarted the deadline being judged.
_backdate 10
_got=$(_idle)
[ "$_got" -ge 10 ] && [ "$_got" -le 12 ] || fail "an ascent 10s ago did not cap
a source claiming 900s; got '$_got'. Every overdue alert in that 600s window is
about a timer that was rearmed and is going to fire on schedule"

# --- 3. AN OLD ASCENT CHANGES NOTHING --------------------------------------
# Or the ceiling is not a ceiling, it is a replacement, and a genuinely idle
# machine could never be found overdue at all.
_backdate 5000
[ "$(_idle)" = 900 ] || fail "an ascent 5000s ago overrode a source reporting
900s; got '$(_idle)'. The ceiling must only ever LOWER the answer"

# --- 4. A CEILING CANNOT SUPPLY AN ANSWER ----------------------------------
# THE ONE THAT MATTERS MOST, in both its forms. The deadline is unmeasurable
# and `report` must keep saying so; answering from the ascent alone would
# certify a measurable clock on a box that has none, which is this project's
# signature false green.
_no_number() {   # <why>
  _out=$("$VIGILANT" report 2>"$T/rep.err" || true)
  case "$_out" in
    *"idle clock:"*[0-9]"s since last input"*)
      printf '%s\n' "$_out" >&2
      fail "$1 the runner produced a number from the ascent record alone. A
bound is not a measurement, and reporting one as the other is how a deadline
nothing can measure gets certified as covered" ;;
  esac
  # AND IT MUST NOT GET THERE BY ACCIDENT. Comparing a number against an empty
  # string happens to fail, so dropping the "did anything answer?" guard gives
  # the right answer for the wrong reason -- while spraying `[: Illegal number`
  # at stderr on every pass of a minutely timer. A tool that emits raw shell
  # diagnostics is broken even when its output is correct, and this is the only
  # place the difference is observable.
  if grep -qiE "illegal number|integer expression|not found|unexpected" \
       "$T/rep.err" 2>/dev/null; then
    cat "$T/rep.err" >&2
    fail "$1 report emitted a shell diagnostic to stderr"
  fi
}
# A source that is WIRED and DECLINES. This is the branch the guard actually
# protects: with no hooks at all the aggregator returns before reaching it.
_source declines
_backdate 10
_no_number "with an idle source that DECLINED (78),"
# ...and with nothing wired either, which is the simpler half.
_source none
_backdate 10
_no_number "with NO idle source wired,"

# --- 5. A DESCENT IS NOT ACTIVITY ------------------------------------------
# Crossing `lock` because the seat went quiet is the OPPOSITE of evidence that
# somebody is there. If a descent refreshed the mark, the ceiling would reset
# on the very edge whose lateness the detector exists to find, and `sleep`
# could never be reported overdue.
_source 900
rm -f "$_mark"
go lock
go sleep
[ ! -e "$_mark" ] || fail "a DESCENT wrote the ascent mark. The ceiling would
then refresh on the way down and no descent could ever be found overdue"
[ "$(_idle)" = 900 ] || fail "a descent capped the idle clock; got '$(_idle)'"

# --- 6. ...AND AN ASCENT DOES -----------------------------------------------
# The precondition for all of the above: the mark has to actually be written by
# a real crossing, not only by this test's backdating helper.
go lock
[ -e "$_mark" ] || fail "an ascent did not record itself, so the ceiling can
only ever be exercised by a test that writes the file by hand"
_got=$(_idle)
[ "$_got" -ge 0 ] && [ "$_got" -le 3 ] || fail "a just-crossed ascent did not
cap the clock; got '$_got'"

pass
