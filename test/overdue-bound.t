#!/bin/sh
# test/overdue-bound.t - an overdue edge is ACTED on after a bound, and the
# action is a re-arm rather than a forced descent.
#
# WHAT WAS MISSING, and it was live on manifestor 2026-10-09. A remote
# unlock/lock pair left the ladder at `lock` with swayidle's timeouts already
# spent, and swayidle re-arms only after a RESUME, which needs seat input a
# remote command does not supply. So the `sleep` edge could never fire, the
# detector reported it correctly for five passes running, and nothing acted:
# a static lock surface lit on an OLED for 23 minutes, ended only by an
# unrelated deploy. Reporting a fault to a human who is not at the machine is
# half a mechanism.
#
# WHY THE ACTION IS NOT `go sleep`. The ladder's own invariant is that nothing
# may enter a dark state unless its way back is armed, which is why `suspend`
# is NEVER_ENFORCED and why `_inhibit_escalate` refuses a deferred `sleep`
# outright. Forcing the dark edge here would break that in the one case it
# exists for: if the timer really is wedged, the way back is NOT armed and the
# screen is stranded dark. Re-arming the timer fixes the CAUSE and enters no
# rung at all, so case 2 asserts the ladder did not move.
#
# AND A LIT EDGE IS DIFFERENT, which is why case 3 exists. An overdue `lock`
# means the session is still open past its own deadline, and a re-arm alone
# would push that deadline out by its whole length again: a security
# regression dressed as a repair. `lock` is the one edge whose rung is a
# guarantee, so it is crossed directly, with the same verb and attribution the
# inhibit bound uses.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init overdue-bound

duehook() {   # <edge> <name> <stdout>
  _hd=$VIGILANCE_HOOK_ROOT/$1.due.d
  mkdir -p "$_hd"
  printf '#!/bin/sh\nprintf %s\n' "'$3'" > "$_hd/$2"
  chmod +x "$_hd/$2"
}

# THE ASCENT MARK GOES BACK WITH THE DEPTH, or the fixture models an impossible
# machine: entered this rung 9999s ago, yet something raised the ladder two
# seconds ago. An ascent is a CEILING on idle, so ageing only the depth record
# caps every idle reading near zero and no case here could fire.
_backdate() {   # <rung> <seconds ago>
  printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/depth"
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/last-ascent"
}

_idle() {   # <seconds>
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}

# AN INJECTED CLOCK, not a fixture standing in for one: the episode record is
# written by the supervision pass itself, so backdating it is the real
# mechanism with a different number in it. The THIRD field is last-seen, which
# is what the gap guard reads, so a case can model "nothing was watching" as
# well as "this has been true for a while".
_episode() {   # <edge> <since secs ago> [<last-seen secs ago>]
  _en=$(date +%s)
  printf '%s %s %s\n' "$1" "$((_en - $2))" "$((_en - ${3:-0}))" \
    > "$VIGILANCE_RUN_DIR/overdue-since"
}
_noepisode() {
  rm -f "$VIGILANCE_RUN_DIR/overdue-since" "$VIGILANCE_RUN_DIR/overdue-acted"
}
_acted() { [ -f "$VIGILANCE_RUN_DIR/overdue-acted" ]; }
_rung() { awk '{print $1}' "$VIGILANCE_RUN_DIR/depth" 2>/dev/null || true; }

mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$VIGILANCE_ALERT_KIND"\
 "$VIGILANCE_ALERT_MSG" >> "%s"\n' "$T/alerts" \
  > "$VIGILANCE_HOOK_ROOT/alert.d/90-sink"
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/90-sink"

# `printf '' >`, never `: >`: a redirection error on a POSIX SPECIAL BUILTIN
# makes the shell EXIT outright, and neither `if` nor set -e protects it.
_alerts() { printf '' > "$T/alerts"; }
_kinds() { cut -d' ' -f1 < "$T/alerts" | sort -u | tr '\n' ' '; }

# WHAT THE NEXT CASE MUST NOT INHERIT. The due hooks go because a case for a
# different edge would otherwise be answered by the previous one's deadline,
# and the log goes because two cases grep it for a line the other could have
# written: an assertion satisfied by its neighbour is the trap this suite has
# paid for repeatedly.
_reset() {
  rm -rf "$VIGILANCE_HOOK_ROOT/lock.due.d" "$VIGILANCE_HOOK_ROOT/sleep.due.d"
  _noepisode
  printf '' > "$VIGILANCE_LOG"
}

# NO INHIBITOR ANYWHERE IN THIS FILE: a held one is a DEFERRAL and belongs to
# inhibit-bound.t, and it returns before any of this runs. Pinned explicitly
# rather than left to the environment, because an inherited value would make
# every case below silently exercise the other tier.
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED

# --- 1. UNDER THE BOUND: reported, and nothing is touched -------------------
# FIRST, because every case after this one makes the tier act, and a change
# that simply acted on sight would pass all of them while turning a
# first-pass blip into a unit restart.
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_noepisode
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success on
a genuinely overdue edge, so the detector itself has stopped working: $_out"
case "$(_kinds)" in
  *overdue*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a freshly overdue edge raised no 'overdue' alert.
kinds: $(_kinds)" ;;
esac
_acted && fail "the tier ACTED on the first pass that saw the fault. The bound
exists so a transient cause clears itself: a released inhibitor and a reset
clock both end the episode on their own, and acting immediately would restart
a unit over a blip"
case "$(_kinds)" in
  *acted*|*wedged*|*rearm*) fail "an act was reported under the bound:
$(_kinds)" ;;
esac

# --- 2. PAST THE BOUND, A DARK EDGE: re-armed and NOT descended -------------
# THE LOAD-BEARING ASSERTION OF THIS FILE is the rung. `sleep` is dark, so the
# edge must NOT be crossed however overdue it is; the ladder's invariant says
# a forced descent there arms no way back, and the one scenario this helps is
# precisely the one where the timer cannot bring it back.
#
# The re-arm FAILS here, deterministically, because scenario_lib pins
# VIGILANCE_IDLE_UNIT to a name that cannot resolve so no test can restart the
# developer's own idle timer. That is the honest branch to assert in a sandbox:
# the act was attempted, it is reported, and it did not silently claim success.
_episode sleep 1200
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success
while acting on an overdue edge: $_out"
[ "$(_rung)" = lock ] || fail "the ladder moved to '$(_rung)' on an overdue
DARK edge. A forced descent into a dark rung arms no way back, which is why
suspend is NEVER_ENFORCED and why a deferred sleep is never acted on. On a
genuinely wedged timer this would strand the screen dark"
_acted || fail "the bound passed and nothing recorded that an act was spent,
so the next pass would act again, and a restart every minute resets the
deadlines every minute: a box whose lock deadline is perpetually reset never
locks at all"
case "$(_kinds)" in
  *overdue-rearm-failed*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the re-arm could not work and nothing said so. A re-arm that
silently did not happen is the false green this whole tier exists to refuse;
kinds: $(_kinds)" ;;
esac
# AND IT MUST NOT CLAIM THE SESSION WAS SECURED, which is where the `lock`
# literal earns its keep. Dropping that guard cannot be caught on the rung: a
# dark-edge overdue is only ever reached FROM `lock`, since the edge below
# `sleep` is never enforced, and a lock crossing there is a no-op. What it
# would corrupt is the ACCOUNT of what happened, so that is what is asserted,
# exactly as inhibit-bound.t does for the same literal.
case "$(cat "$T/alerts")" in
  *"secured first"*) fail "a DARK edge's escalation reported that it had
secured the session. Nothing was locked and nothing needed to be, and an act
that misdescribes itself sends a reader to the wrong mechanism:
$(cat "$T/alerts")" ;;
esac

# --- 3. PAST THE BOUND, THE LIT EDGE: the session IS secured ----------------
# The asymmetry, and the reason it is not one rule. Waiting is not free on
# `lock`: the session is open past its own deadline, so a re-arm alone would
# grant it another full deadline's grace.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 600
_episode lock 1200
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success
while securing an overdue lock: $_out"
[ "$(_rung)" = lock ] || fail "an overdue 'lock' edge past the bound left the
machine at '$(_rung)'. This is the one edge whose rung is a guarantee and the
one this may drive directly; leaving it open is the founding failure of this
package reached through the mechanism meant to prevent it"
# AND THE CROSSING MUST BE ATTRIBUTABLE, because an unexplained lock cost this
# fleet a day of investigation once, and the whole point of the source field
# is that the answer is written down where it is known.
grep -q 'src=overdue-bound' "$VIGILANCE_LOG" || fail "the forced lock is not
attributed in the log, so it reads as an unexplained crossing:
$(grep 'cross lock' "$VIGILANCE_LOG" || true)"

# --- 4. A SECOND MISS IS A WEDGE, and is NOT retried ------------------------
# THE NEW DIAGNOSTIC, and the part worth having beyond the repair. A timer that
# had merely spent its armed timeouts comes back when restarted; one still
# silent afterwards is WEDGED, which is the founding failure of this package
# and which nothing here could distinguish from the other case before.
#
# SELF-CONTAINED, AND IT HAD TO BECOME SO. Written as a continuation of case 3
# it failed with "sleep has no declared deadline", because that case's act
# MOVED THE RUNG, so the next pass is asking about the edge below the new one.
# The product was right and the fixture was reading as though a pass asks the
# same question twice. A dark edge is used here for the same reason: its act
# leaves the ladder where it was, so two passes really do ask one question.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_episode sleep 1200
"$VIGILANT" enforce >>"$T/out" 2>>"$T/stderr" || true
_acted || fail "the first pass did not spend this episode's act, so case 4
cannot tell a second attempt from a first"
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success on
a still-overdue edge: $_out"
case "$(_kinds)" in
  *overdue-wedged*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a second miss after the act was reported as an ordinary overdue, so
the one fact this escalation can establish that nothing else could (that the
timer is WEDGED and not merely spent) is thrown away; kinds: $(_kinds)" ;;
esac
case "$(_kinds)" in
  *overdue-acted*|*overdue-rearm-failed*)
    fail "the tier acted a SECOND time in one episode: $(_kinds)" ;;
esac

# --- 5. A GAP RE-ANCHORS, because nothing was watching ----------------------
# The supervision timer does not fire in S3, so without this a suspend
# spanning an episode is credited as time overdue and the bound fires the
# instant the box comes back. That is exactly what the watchdog was counting
# as silence until 2026-10-07, measured there as 15941s of S3 inside a 16045s
# "silence", so it is a trap this package has already paid for once.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_episode sleep 99999 9999        # overdue for ages, LAST SEEN ages ago too
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success:
$_out"
_acted && fail "an episode nothing had watched for 9999s was credited in full
and the bound fired at once. A span may only count intervals a pass was there
to see, which is the same rule the idle clock's MAXGAP enforces"
grep -q 're-anchoring' "$VIGILANCE_LOG" || fail "the gap was not reported. A
span silently restarting is indistinguishable from one that never accumulated"

# --- 6. THE EPISODE ENDS when the edge stops being overdue ------------------
# So a later fault earns its own single action rather than inheriting a spent
# one, which would leave the NEXT real wedge acted on by nothing.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_episode sleep 1200
_alerts
"$VIGILANT" enforce >>"$T/out" 2>>"$T/stderr" || true
_acted || fail "the act was not recorded, so case 6 cannot show it being
cleared"
_idle 10                          # the seat is busy again: not overdue
"$VIGILANT" enforce >>"$T/out" 2>>"$T/stderr" || true
_acted && fail "the episode ended and the spent-act marker survived it, so the
next genuine wedge would be reported as already-acted-upon and nothing would
try to repair it"
[ -f "$VIGILANCE_RUN_DIR/overdue-since" ] && fail "the episode record outlived
the fault, so the next one would inherit its age and act immediately"

# --- 7. 0 DISABLES THE ACT and leaves the report exactly as it was ----------
# How "tell me but never touch it" stays reachable as configuration instead of
# as a fork of this logic.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_episode sleep 99999
_alerts
VIGILANCE_OVERDUE_ACT=0 "$VIGILANT" enforce >>"$T/out" 2>>"$T/stderr" \
  && fail "enforce reported success on an overdue edge with the act disabled"
case "$(_kinds)" in
  *overdue*) ;;
  *) fail "disabling the act also disabled the REPORT, which is the behaviour
that existed before any of this: $(_kinds)" ;;
esac
_acted && fail "the act ran with VIGILANCE_OVERDUE_ACT=0"
case "$(_kinds)" in
  *acted*|*wedged*|*rearm*) fail "an act was reported with the bound disabled:
$(_kinds)" ;;
esac

# --- 8. THE VIEW SHOWS IT, because a cadence nobody can see becomes never ---
# `enforce` prints into a journal nobody reads on a desktop; the thing a human
# actually runs is `timer`. Shipping a bound with no way to watch it count is
# the mistake the peripheral cadence made once, where a throttle worked
# perfectly and said nothing, so `report` had to grow a section to see it.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 700
_episode sleep 300
printf '%s\n' "$(date +%s)" > "$VIGILANCE_RUN_DIR/last-pass"
_tv=$("$VIGILANT" timer 2>>"$T/stderr")
case "$_tv" in
  *"overdue:"*) ;;
  *) fail "an overdue episode is invisible in the one view a human runs:
$_tv" ;;
esac
case "$_tv" in
  *"act:"*) ;;
  *) fail "the view shows the episode without saying what happens at the
bound, so the act arrives as a thing done TO an operator rather than one they
could see coming: $_tv" ;;
esac
# AND A SPENT ACT MUST READ DIFFERENTLY, or the view counts down to a repair
# that is never coming.
printf '%s\n' "$(date +%s)" > "$VIGILANCE_RUN_DIR/overdue-acted"
_tv=$("$VIGILANT" timer 2>>"$T/stderr")
case "$_tv" in
  *spent*) ;;
  *) fail "with this episode's act already spent the view still counts down to
it, promising a repair that will not come: $_tv" ;;
esac

# AND ON A HEALTHY BOX IT MUST BE SILENT, which caught a real defect the moment
# it was run: with no episode there is no record, and `read ... < "$FILE"
# 2>/dev/null` still writes to the REAL stderr, because redirections are
# processed left to right and the failing open happens before the suppression
# applies. Every `vigilant timer` printed "cannot open ...: No such file" while
# otherwise working perfectly, in the one view a human runs most. Found by
# reading the output rather than by any check, which is the second time in a
# day; asserted now so the next edit to that reader cannot bring it back.
_noepisode
_terr=$T/timer.err
_tv=$("$VIGILANT" timer 2>"$_terr")
if [ -s "$_terr" ]; then
  fail "timer wrote to stderr on a box with no overdue episode, which is the
ordinary state of every healthy machine: $(cat "$_terr")"
fi
case "$_tv" in
  *overdue:*) fail "the view reports an overdue episode where there is no
record of one: $_tv" ;;
esac

pass "reported under the bound, a dark edge re-armed and never descended into,\
 the lit edge secured and attributed, a second miss called a WEDGE and not\
 retried, a gap re-anchored, the episode cleared, 0 disabling the act,\
 and the view showing the episode and its bound"
