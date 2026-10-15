#!/bin/sh
# test/unnamed-bound.t - a deadline deferred by something that cannot be NAMED.
#
# THE GAP THIS CLOSES, and it was live on manifold 2026-10-14. There are three
# channels that hold an idle timer off and vigilance sees one and a half:
#
#   logind Inhibit what=idle      _idle_inhibited reads it, and can NAME the
#                                 holding process
#   org.freedesktop.ScreenSaver   an OWNER of the name can be queried
#   zwp_idle_inhibit_manager_v1   NOTHING can see it: a client-side Wayland
#                                 protocol with no introspection and no "is one
#                                 held" request at all
#
# A browser in a video call takes the third. So the counters read 1166s of idle
# while swayidle, which the compositor was telling the seat was ACTIVE,
# correctly never fired the 480s lock. With nothing asking, that read as a
# FAULT and the overdue escalation locked a screen somebody was working at.
#
# AND THE FIRST FIX WAS WRONG, which is why this tier exists in this shape
# rather than as an idle.d source. A source relaying the timer's view would be
# taken as the MINIMUM by _idle_secs, the deadline would never come due, and a
# LEAKED compositor inhibitor would then hold the session open indefinitely
# with nothing saying so: the silent false green this package exists to
# prevent, traded for the false positive it was meant to fix.
#
# SO THE DISAGREEMENT IS THE SIGNAL, and it takes the INHIBIT bounds rather
# than the overdue one. The two causes this cannot separate (a honoured
# compositor inhibitor, or a wedged timer) want the same response: not to
# interrupt a call early, and not to leave the session open for ever either.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init unnamed-bound

duehook() {   # <edge> <name> <stdout>
  _hd=$VIGILANCE_HOOK_ROOT/$1.due.d
  mkdir -p "$_hd"
  printf '#!/bin/sh\nprintf %s\n' "'$3'" > "$_hd/$2"
  chmod +x "$_hd/$2"
}

# A STUB TIER, because the framework half is what this file tests: the real
# hook is driven against real heartbeats in concur.t, and a fixture that
# modelled the heartbeat here would be testing my model of it twice.
concurhook() {   # <name> <rc> [sentence]
  mkdir -p "$VIGILANCE_HOOK_ROOT/concur.d"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "${3:-saw nothing}" "$2" \
    > "$VIGILANCE_HOOK_ROOT/concur.d/$1"
  chmod +x "$VIGILANCE_HOOK_ROOT/concur.d/$1"
}

# THE ASCENT MARK GOES BACK WITH THE DEPTH, or the fixture models an impossible
# machine: entered this rung 9999s ago, yet something raised the ladder two
# seconds ago. An ascent is a CEILING on idle, so ageing only the depth record
# caps every reading near zero and no case here could fire.
_backdate() {   # <rung> <seconds ago>
  printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/depth"
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/last-ascent"
}

_idle() {   # <seconds>
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}

# THE SPAN IS THE OVERDUE EPISODE'S, deliberately: it measures the same thing
# either way (how long this edge has been overdue by our clock) and only the
# RESPONSE differs. An injected clock rather than a fixture standing in for
# one, since the record is written by the supervision pass itself.
_episode() {   # <edge> <since secs ago>
  _en=$(date +%s)
  printf '%s %s %s\n' "$1" "$((_en - $2))" "$_en" \
    > "$VIGILANCE_RUN_DIR/overdue-since"
}
_noepisode() {
  rm -f "$VIGILANCE_RUN_DIR/overdue-since" "$VIGILANCE_RUN_DIR/overdue-acted"
}
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

_reset() {
  rm -rf "$VIGILANCE_HOOK_ROOT/lock.due.d" "$VIGILANCE_HOOK_ROOT/sleep.due.d" \
         "$VIGILANCE_HOOK_ROOT/concur.d"
  _noepisode
  rm -f "$VIGILANCE_RUN_DIR/inhibit-since" "$VIGILANCE_RUN_DIR/inhibit-clock"
  printf '' > "$VIGILANCE_LOG"
}

# NO LOGIND INHIBITOR UNLESS A CASE ASKS FOR ONE. Pinned rather than left to
# the environment, because an inherited value would silently route every case
# below through the NAMED tier instead, which returns before any of this.
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED

# --- 1. NOTHING WIRED CHANGES NOTHING ---------------------------------------
# FIRST, because it is what makes this tier safe to add at all: a box with no
# concur.d source must behave exactly as it did before, or wiring a tier would
# change the behaviour of every integration that cannot answer for itself.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success on
a genuinely overdue edge: $_out"
case "$(_kinds)" in
  *overdue*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no concur.d wired the overdue finding disappeared. Nothing to
ask and cannot tell are the same answer, and both must leave this exactly as it
was. kinds: $(_kinds)" ;;
esac
case "$(_kinds)" in
  *unnamed*) fail "an unnameable deferral was reported with no concur.d source
wired, so the tier invented a verdict from an absence: $(_kinds)" ;;
esac
case "$(cat "$T/alerts")" in
  *"Either its timer is not working"*) ;;
  *) fail "with nothing able to settle the cause, the overdue alert must keep
naming BOTH: $(cat "$T/alerts")" ;;
esac

# --- 2. DOES NOT CONCUR, under the bounds: a silent deferral ---------------
# A call is not a fault, so there is no alert and no accusation. The START is
# logged once, because the audit tier reads this file and three hours of
# nothing at all is not a forensic record.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") || fail "a deferral under both
bounds reported a finding; under the bounds it is the mechanism working: $_out"
case "$(_kinds)" in
  '') ;;
  *) fail "a deferral under both bounds raised alerts: $(_kinds). That is the
cry-wolf shape this escalation exists to avoid" ;;
esac
grep -q 'deferred by something that cannot be named' "$VIGILANCE_LOG" \
  || fail "the start of an unnameable deferral was not recorded, so the log
says nothing at all for the hours before the report bound and the audit tier
reads this file: $(cat "$VIGILANCE_LOG")"
case "$_out" in
  *"has seen none of the 900s"*) ;;
  *) fail "the pass did not say what it observed: $_out" ;;
esac

# --- 3. PAST THE REPORT BOUND: reported, with the source's own sentence -----
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_episode lock 11000
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "a deferral past the report
bound reported no finding: $_out"
case "$(_kinds)" in
  *unnamed-held*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "past the report bound nothing raised an 'unnamed-held' alert, so a
hold nobody can name goes on for ever unreported: $(_kinds)" ;;
esac
# THE SOURCE'S SENTENCE TRAVELS, because it is the only part that says what was
# actually OBSERVED, and a bare duration sends the reader hunting.
case "$(cat "$T/alerts")" in
  *"the timer saw none of it"*) ;;
  *) fail "the alert dropped the source's own account of what it saw, leaving a
duration and no evidence: $(cat "$T/alerts")" ;;
esac
case "$(cat "$T/alerts")" in
  *"timer reset"*) ;;
  *) fail "the alert does not name the veto, so a human told their call is
being counted has no way to say it is expected: $(cat "$T/alerts")" ;;
esac
grep -q 'UNNAMED-HELD' "$VIGILANCE_LOG" || fail "no UNNAMED-HELD record"

# --- 4. PAST THE FORCE BOUND: the session is secured, attributably ---------
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_episode lock 15000
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "the force bound reported no
finding: $_out"
[ "$(_rung)" = lock ] || fail "a deferral past the force bound left the machine
at '$(_rung)'. An unnameable hold is exactly as dangerous as a leaked logind
one, and the whole point of a bound is that it is reached"
grep -q 'src=unnamed-bound' "$VIGILANCE_LOG" || fail "the forced lock is not
attributed in the log, so it reads as an unexplained crossing and that cost
this fleet a day of investigation once:
$(grep 'cross lock' "$VIGILANCE_LOG" || true)"
case "$(_kinds)" in
  *unnamed-forced*) ;;
  *) fail "the forced lock raised no 'unnamed-forced' alert: $(_kinds)" ;;
esac

# --- 5. A DARK EDGE IS NEVER DESCENDED INTO --------------------------------
# The ladder's own invariant, and the same guard the named route relies on: a
# forced descent into a dark rung arms no way back, which is why `suspend` is
# NEVER_ENFORCED. Asserted on the ACCOUNT as well as the rung, because a dark
# overdue is only ever reached FROM `lock`, where a lock crossing is a no-op
# and so cannot discriminate.
_reset
duehook sleep 10-fake '600 idle'
_backdate lock 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_episode sleep 99999
_alerts
_out=$("$VIGILANT" enforce 2>&1) || true
[ "$(_rung)" = lock ] || fail "the ladder moved to '$(_rung)' on an unnameable
deferral of a DARK edge. Nothing may enter a dark state unless its way back is
armed, and here the thing that would bring it back is what is not working"
case "$(cat "$T/alerts")" in
  *"securing the session now"*) fail "a DARK edge's deferral reported that it
had secured the session. Nothing was locked and nothing needed to be, and an
act that misdescribes itself sends a reader to the wrong mechanism:
$(cat "$T/alerts")" ;;
esac

# --- 6. CONCURS: the overdue finding becomes TRUE and SPECIFIC --------------
# The other half of the tier, and the reason it is worth asking even when the
# answer is yes. A concurrence means the timer observed the idleness and still
# did not act, which names the half that broke: the tick arm works and the
# acting arm does not. That is the 2026-09-12 outage, where a running timer was
# armed with a path that had been swept out from under it.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 0
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "a concurring overdue edge
reported success: $_out"
case "$(_kinds)" in
  *overdue*) ;;
  *) fail "a concurrence must still leave the OVERDUE finding, because the
deadline really was missed: $(_kinds)" ;;
esac
case "$(_kinds)" in
  *unnamed*) fail "a concurrence was routed to the deferral escalation. The
timer SAW the idleness, so this is a fault and not a deferral: $(_kinds)" ;;
esac
case "$(cat "$T/alerts")" in
  *"DID observe the seat go idle"*) ;;
  *) fail "with a concurrence the alert must say so, because that is what
makes 'the timer is alive and its acting arm is broken' a TRUE sentence rather
than one of two guesses: $(cat "$T/alerts")" ;;
esac
case "$(cat "$T/alerts")" in
  *"Either its timer is not working"*) fail "the alert hedged between two
causes while a source had just settled which one it was. Naming a cause only as
precisely as the evidence allows cuts BOTH ways: $(cat "$T/alerts")" ;;
esac

# --- 7. CANNOT TELL leaves it exactly as it was ----------------------------
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 78
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success
with a declining concur source: $_out"
case "$(_kinds)" in
  *unnamed*) fail "a DECLINED answer was treated as a disagreement, so a tier
that could not look deferred a real deadline: $(_kinds)" ;;
esac
case "$(cat "$T/alerts")" in
  *"Either its timer is not working"*) ;;
  *) fail "a declining source must leave the hedged wording, because nothing
settled the cause: $(cat "$T/alerts")" ;;
esac

# --- 8. ONE CONCURRENCE IS ENOUGH -----------------------------------------
# A source that CAN see the timer observe idleness settles it; one that cannot
# must not overrule it. Same rule as the cursor tier, for the same reason, and
# asserted because the obvious alternative (any disagreement wins) is the one
# that would defer a real fault.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-no 1 'this one saw nothing'
concurhook 30-yes 0
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") || true
case "$(_kinds)" in
  *unnamed*) fail "one source disagreeing outvoted another that positively
observed the timer seeing idle. Absence of observation is weaker evidence than
observation: $(_kinds)" ;;
esac

# --- 9. A NAMEABLE HOLD TAKES PRECEDENCE ----------------------------------
# Where logind CAN name the holder the named route owns the finding, because
# its message can point at a process and this one cannot. Two tiers reporting
# one hold in different words is how a reader learns to discount both.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
printf '%s\n' "$(( $(date +%s) - 11000 ))" > "$VIGILANCE_RUN_DIR/inhibit-since"
_alerts
VIGILANCE_BLOCK_INHIBITED='s "idle"' "$VIGILANT" enforce >>"$T/out" \
  2>>"$T/stderr" || true
case "$(_kinds)" in
  *inhibit-held*) ;;
  *) fail "with a logind inhibitor held the NAMED route must own the finding,
since only it can point at a process: $(_kinds)" ;;
esac
case "$(_kinds)" in
  *unnamed*) fail "both routes reported the same hold, in different words,
which teaches a reader to discount both: $(_kinds)" ;;
esac

# --- 10. THE RESET VETOES IT, with no logind inhibitor held ---------------
# THE ONE ROUTE A HUMAN COULD NOT OTHERWISE VETO. `timer reset` used to refuse
# outright when logind reported nothing held, which is exactly the state a
# compositor-level inhibitor produces, so the escalation that most needs an
# acknowledgement was the one that could not take one.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_episode lock 11000
_out=$("$VIGILANT" timer reset 2>>"$T/stderr") \
  || fail "'timer reset' refused an unnameable deferral, so the only route a
human cannot see the holder of is also the only one they cannot veto: $_out"
[ -f "$VIGILANCE_RUN_DIR/inhibit-clock" ] \
  || fail "the reset recorded no clock, so the bound still applies and the
operator believes otherwise"
# AND THE SPAN RESTARTS, or the acknowledgement bought nothing.
_alerts
_out=$("$VIGILANT" enforce 2>>"$T/stderr") || true
case "$(_kinds)" in
  *unnamed-held*) fail "the escalation reported again immediately after a
reset, so the acknowledgement did not restart the clock: $(_kinds)" ;;
esac

# --- 11. THE VIEW SHOWS WHICH ESCALATION IS ACTUALLY COUNTING -------------
# A cadence nobody can see becomes never. And the overdue act's countdown must
# NOT be shown here: it is not what is coming, so displaying it would count
# down to something that will never happen.
_reset
duehook lock 10-fake '480 idle'
_backdate open 9999
_idle 900
concurhook 20-c 1 'the timer saw none of it'
_episode lock 11000
printf '%s\n' "$(date +%s)" > "$VIGILANCE_RUN_DIR/last-pass"
_tv=$("$VIGILANT" timer 2>>"$T/stderr")
case "$_tv" in
  *"deferred:"*) ;;
  *) fail "an unnameable deferral is invisible in the one view a human runs:
$_tv" ;;
esac
case "$_tv" in
  *"secure:"*) ;;
  *) fail "the view shows the deferral without saying what happens at the
bound, so the forced lock arrives as a thing done TO an operator rather than
one they could see coming: $_tv" ;;
esac
case "$_tv" in
  *"act:"*) fail "the view counted down the OVERDUE act during a deferral that
is not routed to it, which is a countdown to something that will never
happen: $_tv" ;;
esac
# AND THE INHIBIT LINE MUST NOT CONTRADICT IT. Written "none held, so no
# deadline is deferred" it sat one line above a `deferred:` line reporting a
# hold logind cannot see.
case "$_tv" in
  *"no deadline is deferred"*) fail "the view claims no deadline is deferred
one line above reporting a deferral: $_tv" ;;
esac

pass "nothing wired changes nothing, a silent deferral under the bounds with\
 its start recorded, reported past the report bound with the source's own\
 sentence and the veto named, the session secured attributably past the force\
 bound, a dark edge never descended into, a concurrence making the overdue\
 finding true and specific, cannot-tell left alone, one concurrence enough, a\
 nameable hold taking precedence, the reset vetoing it, and the view showing\
 which escalation counts"
