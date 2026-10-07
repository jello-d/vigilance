#!/bin/sh
# test/inhibit-bound.t - a held idle inhibitor DEFERS an idle deadline, under a
# bound.
#
# THE DEFECT THIS CLOSES WAS LIVE, and this package caused it. swayidle-mgr
# arms a logind event so a held idle inhibitor is HONOURED, because a video
# call must not be cut off mid-sentence. That made it possible, for the first
# time, for an idle-anchored deadline to pass without its edge firing for a
# GOOD reason, and the overdue detector did not know the reason existed:
#
#   27 alerts across 93 minutes, 2026-10-06 10:40 to 12:13
#   the heartbeat silent 10:28:59 to 12:41:00, then healthy again
#   NRestarts=0: the same process throughout, so never a wedge
#
# The exclusion the detector ran asked vigilance's OWN block hooks, which
# cannot see logind, while the comment above it already named an idle inhibitor
# as the innocent explanation. A comment is not a delivery.
#
# AND THE BOUND IS WHY SUPPRESSION ALONE WOULD HAVE BEEN WRONG. A leaked
# inhibitor (a browser tab is the usual one) would then keep a laptop unlocked
# indefinitely with nothing saying so, which is the silent false green this
# package exists to prevent. So: silent below the report bound, a named finding
# at it, and the session secured anyway at the force bound if nobody said the
# hold was expected.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init inhibit-bound

duehook() {   # <edge> <name> <stdout>
  _hd=$VIGILANCE_HOOK_ROOT/$1.due.d
  mkdir -p "$_hd"
  printf '#!/bin/sh\nprintf %s\n' "'$3'" > "$_hd/$2"
  chmod +x "$_hd/$2"
}

# THE ASCENT MARK GOES BACK WITH THE DEPTH, or the fixture models an impossible
# machine: entered this rung 9999s ago, yet something raised the ladder two
# seconds ago. An ascent is a CEILING on idle time, so a fixture that ages only
# the depth record caps every idle reading at ~0 and no case here could fire.
_backdate() {   # <rung> <seconds ago>
  printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/depth"
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/last-ascent"
}

_idle() {   # <seconds>
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}

# AN INJECTED CLOCK, not a fixture standing in for one: the span is read from a
# file the supervision pass writes, so backdating that file is the real
# mechanism with a different number in it. Same move hook_throttle's stamp
# allows, and it is what keeps these cases free of sleeps.
#
# IT CLEARS THE CLOCK TOO, and that is not tidiness. The escalation span is the
# later of the hold and the last RESET, so after a force has fired (which
# resets the clock, deliberately, so the whole escalation does not re-run every
# minute) a bare backdate of the hold reads as a span of ~0. The first draft of
# this helper omitted that and case 6 failed with "idle inhibited 0s", which
# was the product being right and the fixture being incomplete.
_span() {   # <seconds ago>, or "" to clear the hold entirely
  rm -f "$VIGILANCE_RUN_DIR/inhibit-clock"
  if [ -z "$1" ]; then
    rm -f "$VIGILANCE_RUN_DIR/inhibit-since"
    return 0
  fi
  printf '%s\n' "$(( $(date +%s) - $1 ))" > "$VIGILANCE_RUN_DIR/inhibit-since"
}

mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$VIGILANCE_ALERT_KIND"\
 "$VIGILANCE_ALERT_MSG" >> "%s"\n' "$T/alerts" \
  > "$VIGILANCE_HOOK_ROOT/alert.d/90-sink"
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/90-sink"

_alerts() { : > "$T/alerts"; }
_kinds() { cut -d' ' -f1 < "$T/alerts" | sort -u | tr '\n' ' '; }

duehook lock 10-fake '480 idle'
_idle 600                    # past 480 + GRACE, so the edge IS due

# --- 1. NOT INHIBITED: the detector is untouched ----------------------------
# FIRST, because every case below weakens a finding, and a fix that simply
# switched the detector off would pass all of them. This is the half that says
# the mechanism still works.
_backdate open 9999
_span ''
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success on
a genuinely overdue edge with NO inhibitor held, so the deferral has switched
the overdue detector off entirely: $_out"
case "$(_kinds)" in
  *overdue*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an overdue edge with no inhibitor held raised no 'overdue' alert;
kinds were: $(_kinds)" ;;
esac

# --- 2. INHIBITED, UNDER THE REPORT BOUND: silent -------------------------
# The storm this closes. A call is not a fault, so there is no alert of ANY
# kind, and in particular not an overdue one.
_span 60
VIGILANCE_BLOCK_INHIBITED=idle; export VIGILANCE_BLOCK_INHIBITED
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "a deadline deferred by a held idle inhibitor, well under the report
bound, was reported as a finding: $_out"
[ ! -s "$T/alerts" ] || fail "a hold under the report bound raised an alert,
which is the 27-alerts-in-93-minutes storm this exists to stop:
$(cat "$T/alerts")"
case "$_out" in
  *deferred*) ;;
  *) fail "enforce did not SAY it was deferring; a silent skip is how a
deferral becomes indistinguishable from a detector that stopped running.
Output was: $_out" ;;
esac

# --- 3. CANNOT TELL DOES NOT DEFER ------------------------------------------
# The whole n/a contract, at the one site where getting it wrong is worst: an
# unreadable bus must not read as "an inhibitor is held", because that would
# silently switch off the tier that watches the lock. logind answering
# "nothing" and busctl being unable to answer arrive as the same empty string.
mkdir -p "$T/stub"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/busctl"
chmod +x "$T/stub/busctl"
_span ''
_alerts
_out=$(PATH=$T/stub:$PATH; export PATH
       unset VIGILANCE_BLOCK_INHIBITED
       "$VIGILANT" enforce 2>>"$T/stderr") && fail "with busctl FAILING,
enforce treated the deadline as deferred; an unreadable bus must leave the
detector exactly as it was: $_out"
case "$(_kinds)" in
  *overdue*) ;;
  *) fail "a failing busctl suppressed the overdue finding; kinds: $(_kinds)" ;;
esac

# --- 4. AT THE REPORT BOUND: a named finding, and how to answer it ----------
VIGILANCE_BLOCK_INHIBITED=idle; export VIGILANCE_BLOCK_INHIBITED
VIGILANCE_INHIBIT_FORCE=99999; export VIGILANCE_INHIBIT_FORCE
_span 11000                  # past the 10800s default report bound
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "a hold past the report
bound was not reported at all: $_out"
case "$(_kinds)" in
  *inhibit-held*) ;;
  *) fail "a hold past the report bound raised no 'inhibit-held' alert;
kinds: $(_kinds)" ;;
esac
# THE REMEDY HAS TO BE IN THE MESSAGE. A finding an operator cannot act on is
# the shape this project already rejected once ("something talks to an input
# device on its own": true, unactionable).
grep -q 'vigilant ack' "$T/alerts" || fail "the report does not name the verb
that answers it, so the operator is told a duration and nothing else:
$(cat "$T/alerts")"
grep -q 'cross lock' "$VIGILANCE_LOG" 2>/dev/null && fail "the REPORT bound
locked the screen; only the force bound may act, or the hour between them
buys nothing"

# --- 5. AT THE FORCE BOUND: the session is secured, and attributably --------
unset VIGILANCE_INHIBIT_FORCE
_span 15000                  # past the 14400s default force bound
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "a hold past the force
bound did not report: $_out"
case "$(_kinds)" in
  *inhibit-forced*) ;;
  *) fail "a hold past the force bound raised no 'inhibit-forced' alert, so
either it did not act or it reported as though it had not; kinds: $(_kinds)" ;;
esac
# ATTRIBUTABLE, which is the whole point of the src field: an unexplained lock
# cost this fleet a day of investigation. A forced lock that cannot be told
# from a keybind press would rebuild exactly that.
grep -q 'cross lock: open -> lock src=inhibit-bound' "$VIGILANCE_LOG" \
  || fail "the forced lock did not cross the edge with src=inhibit-bound, so
the one crossing nobody will expect is the one nothing attributes:
$(grep 'cross' "$VIGILANCE_LOG" 2>/dev/null || echo '(no crossings logged)')"

# --- 5b. AND IT ACTS ONCE, not every minute --------------------------------
# The force resets the escalation clock BECAUSE it acted. Without that the
# whole escalation re-runs on every pass while the hold continues, which is the
# storm shape this package keeps paying for; with it, a leaked inhibitor that
# survives the lock produces its next finding a report-bound later.
#
# FOUND BY A FIXTURE BUG RATHER THAN BY DESIGN: the `_span` helper did not
# clear the clock, so the next case read a span of ~0 and failed. That was the
# product being right, and nothing was asserting it.
# AND THE OBVIOUS ASSERTIONS HERE ARE VACUOUS, which the corpus caught: the
# first draft checked for another `cross lock` and another inhibit-forced
# alert, and `inhibit-force-resets-the-clock` SURVIVED both. The force has just
# taken the machine to `lock`, so the next edge is `sleep` and the dark-rung
# refusal above declines it whatever the clock says. What the reset uniquely
# buys is SILENCE on the next pass, so that is the claim, and it needs a
# `sleep` deadline to exist for the pass to reach the decision at all.
duehook sleep 10-fake '600 idle'
_idle 700
_alerts
: > "$VIGILANCE_LOG"
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "the pass straight after a forced lock reported a finding again. The
force resets the escalation clock BECAUSE it acted, so the next pass is
silent; without it the escalation repeats for as long as the hold lasts, which
is the storm shape this package keeps paying for"
[ ! -s "$T/alerts" ] || fail "the pass after a forced lock alerted again:
$(cat "$T/alerts")"

# --- 6. AND IT REFUSES A DARK RUNG -----------------------------------------
# The ladder's own invariant: a forced descent into a dark rung arms no way
# back, which is why `suspend` is NEVER_ENFORCED. A bound that forced `sleep`
# would take the panel down on a timer, so the dark edge is REPORTED forever
# and never acted on.
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_span 15000
_alerts
: > "$VIGILANCE_LOG"
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "the dark edge did not
report: $_out"
grep -q 'cross sleep' "$VIGILANCE_LOG" 2>/dev/null && fail "the force bound
crossed a DARK edge. Nothing may enter a dark rung on a timer: that is the
invariant suspend is excluded for, and the panel has no armed way back"
case "$(_kinds)" in
  *inhibit-held*) ;;
  *) fail "the dark edge past the force bound must still be REPORTED rather
than silently tolerated; kinds: $(_kinds)" ;;
esac

# --- 7. ack RESETS THE CLOCK ------------------------------------------------
# The escalation is interruptible, and that is what makes the force safe: a
# call somebody is attending can say so. Without this the bound is a blind
# timer and the user's objection to one would be right.
_backdate open 9999
_idle 600
_span 15000
_alerts
: > "$VIGILANCE_LOG"
"$VIGILANT" ack >/dev/null 2>>"$T/stderr" || fail "ack failed while an
inhibitor was held"
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "enforce still reported a finding after the hold was acknowledged,
so the ack bought nothing: $_out"
[ ! -s "$T/alerts" ] || fail "an acknowledged hold still alerted:
$(cat "$T/alerts")"
grep -q 'cross lock' "$VIGILANCE_LOG" 2>/dev/null && fail "an acknowledged
hold was still forced to lock, which is the one thing ack exists to prevent"

# --- 8. RELEASE ENDS THE SPAN ----------------------------------------------
# A span is a claim about an UNBROKEN hold. Carrying one across a release would
# let the next call inherit three hours of someone else's.
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED
: > "$VIGILANCE_LOG"
_out=$("$VIGILANT" enforce 2>>"$T/stderr") || true
[ ! -f "$VIGILANCE_RUN_DIR/inhibit-since" ] || fail "the span outlived the
hold, so the next inhibitor would start life already past a bound"
[ ! -f "$VIGILANCE_RUN_DIR/inhibit-clock" ] || fail "the escalation clock
outlived the hold, so the NEXT hold's first report would come early"
grep -q 'idle inhibit released' "$VIGILANCE_LOG" 2>/dev/null \
  || fail "the release left no record; the hold's start and end are the whole
forensic story, since the per-pass deferral is deliberately not logged"

# --- 9. BOTH BOUNDS AT 0 DISABLE THEM --------------------------------------
# So "report but never act" and "trust the inhibitor completely" are reachable
# as CONFIGURATION rather than as forks of this logic. An operator who wants
# the Zoom case silent forever is entitled to it.
VIGILANCE_BLOCK_INHIBITED=idle; export VIGILANCE_BLOCK_INHIBITED
VIGILANCE_INHIBIT_REPORT=0; export VIGILANCE_INHIBIT_REPORT
VIGILANCE_INHIBIT_FORCE=0; export VIGILANCE_INHIBIT_FORCE
_span 999999
_alerts
: > "$VIGILANCE_LOG"
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "with both bounds disabled a hold of any length is simply honoured,
and enforce reported a finding anyway"
[ ! -s "$T/alerts" ] || fail "a disabled report bound still alerted:
$(cat "$T/alerts")"
grep -q 'cross lock' "$VIGILANCE_LOG" 2>/dev/null && fail "a disabled force
bound still locked the screen"
unset VIGILANCE_INHIBIT_REPORT VIGILANCE_INHIBIT_FORCE

# --- 10. THE REPORT IS DEDUP-SAFE ------------------------------------------
# A MESSAGE THAT COUNTS UPWARD DEFEATS ITS OWN DEDUP: the key is the message
# text, so an embedded elapsed time hashes as a fresh onset on every pass, and
# that produced a 45-notification storm here once. `_alert_repeat` normalises
# digit-runs followed by `s` out of the key, which is why the duration is
# written as `Ns` and not as "3.0 hours".
#
# COOLDOWN RESTORED FOR THIS CASE ONLY. scenario_init zeroes it so neighbouring
# cases do not suppress each other's alerts, so a storm test with it zeroed
# would measure nothing.
VIGILANCE_ALERT_COOLDOWN=3600; export VIGILANCE_ALERT_COOLDOWN
_alerts
_span 11000
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
_span 11100       # a later pass: same finding, a bigger number
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
_span 11200
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
_n=$(grep -c '^inhibit-held ' "$T/alerts" || true)
[ "$_n" -le 1 ] || fail "three passes over one unchanging hold produced $_n
notifications. The duration in the message is defeating its own dedup key,
which is exactly the storm _alert_repeat was written to prevent"
VIGILANCE_ALERT_COOLDOWN=0; export VIGILANCE_ALERT_COOLDOWN

pass "deferred under the bound, overdue still fires uninhibited, cannot-tell\
 does not defer, report names the remedy, force crosses lock attributably and\
 refuses a dark rung, ack resets, release clears, 0 disables, dedup holds"
