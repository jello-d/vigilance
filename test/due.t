#!/bin/sh
# test/due.t - the `due` tier and the supervision loop.
#
# This is the SECOND PILLAR, and it was designed, enumerated in KINDS, and then
# read by nothing for the whole refactor. "The edge should have fired by now and
# did not" was the one silent-failure class with no detector, and the suite
# history is the argument: a swayidle that ran happily for weeks while silently
# not firing cost a monitor two days of being dark behind a green light.
#
# What is under test is mostly POLICY, so it is pinned hard: grace must let the
# primary mechanism win, a block must stop enforcement, forcing must be opt-in,
# and `suspend` must never be an enforcement target.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init due

# A due hook prints SECONDS on stdout. Anything else means "no opinion".
duehook() {   # <edge> <name> <stdout>
  _hd=$VIGILANCE_HOOK_ROOT/$1.due.d
  mkdir -p "$_hd"
  printf '#!/bin/sh\nprintf %s\n' "'$3'" > "$_hd/$2"
  chmod +x "$_hd/$2"
}

# --- no due hook means NOTHING is enforced ----------------------------------
# An absent deadline is not a deadline of zero. Treating it as one would make
# every edge instantly overdue on a box that declared nothing, which is the
# most destructive possible reading of silence.
go lock
_out=$("$VIGILANT" due 2>>"$T/stderr") || fail "due errored with no hooks"
case "$_out" in
  *"n/a"*"no due hook"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an absent deadline was not reported n/a" ;;
esac
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "enforce acted with no declared deadline"

# --- GRACE lets the primary mechanism win the race --------------------------
# vigilant is the backstop, not the timer. Acting on the tie would make it
# compete with the mechanism it is supervising.
duehook sleep 10-fake 600
_out=$("$VIGILANT" due 2>>"$T/stderr")
case "$_out" in
  *"600s after 'lock'"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "due did not report the hook's deadline" ;;
esac
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "enforce fired while still inside the deadline"

# Still inside GRACE, just past the deadline: must NOT act.
_backdate() { printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" \
  > "$VIGILANCE_RUN_DIR/depth"; }
_backdate lock 610
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "enforce fired 610s into a 600s deadline; GRACE is 30s, so the
primary mechanism had not yet lost the race"

# --- past deadline + grace: OVERDUE -----------------------------------------
_backdate lock 700
_out=$("$VIGILANT" enforce 2>>"$T/stderr") && fail "enforce reported success on
an overdue edge; overdue must be a non-zero verdict"
case "$_out" in
  *"OVERDUE"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "an overdue edge was not announced" ;;
esac
expect_depth lock          # reported, NOT crossed

# ...and it ALERTS, because a mechanism that stopped working is exactly what a
# human needs told. This is the charter's goal; forcing is convenience on top.
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-catch" <<EOF
#!/bin/sh
printf '%s %s\n' "\$VIGILANCE_ALERT_KIND" "\$VIGILANCE_ALERT_MSG" >> "$T/alerts"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-catch"
: > "$T/alerts"
_backdate lock 700
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
grep -q "^overdue " "$T/alerts" || fail "an overdue edge raised no alert"

# --- ENFORCE NEVER CROSSES AN EDGE ------------------------------------------
# Forcing is RETIRED (2026-09-20), and this is the mechanical form of that --
# the same shape as dpms.t asserting no edge ever issues `wlopm --off`, because
# a capitalised warning in a comment is not a guarantee.
#
# WHY IT WENT. It was unreachable by construction: only two edges are targets,
# `sleep` was refused outright (a forced descent into a dark rung arms no way
# back), and `lock` was refused because its deadline is idle-anchored. The
# intersection of forceable and measurable was empty, so it was tested code
# that could never run in production. And it had been superseded without
# anyone noticing -- every failure it would have acted on is now caught closer
# to the cause, leaving one sliver (the idle timer alive, armed, and silently
# not firing) that wants DETECTING rather than forcing.
#
# THE STALE-ENVIRONMENT CASE IS THE POINT. A box that once set
# VIGILANCE_ENFORCE=force in a unit or a shell profile must not keep acting on
# it: a retired knob that still works somewhere is worse than one that never
# existed, because nobody is looking for it any more.
duehook lock 10-rung "100 rung"
_backdate open 900
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  && fail "enforce reported success on an OVERDUE edge. Overdue is a finding,
so it must be reported as one"
expect_depth open
case "$_out" in
  *OVERDUE*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "enforce did not report the edge overdue" ;;
esac

# The DARK direction too, and from the rung where it is the next target.
_backdate lock 700
go lock
_backdate lock 700
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
expect_depth lock          # NOT sleep: nothing may descend into a dark rung
go open
rm -f "$VIGILANCE_HOOK_ROOT"/lock.due.d/10-rung

# --- a BLOCK stops enforcement ----------------------------------------------
# An idle inhibitor or a fullscreen video is the mechanism behaving CORRECTLY.
# Forcing through that would be vigilant fighting a healthy system.
: > "$RECORD"
go lock
duehook sleep 10-fake 600
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.block.d"
printf '#!/bin/sh\necho "inhibited"\nexit 10\n' \
  > "$VIGILANCE_HOOK_ROOT/sleep.block.d/10-inhibit"
chmod +x "$VIGILANCE_HOOK_ROOT/sleep.block.d/10-inhibit"
_backdate lock 700
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "a blocked enforcement should hold off, not fail"
# Must be the BLOCK that stopped it, not the dark-rung refusal: both would leave
# the depth alone, so assert on the reason.
case "$_out" in
  *"blocked"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "a block was not reported" ;;
esac
expect_depth lock          # held off even under the force policy
rm -f "$VIGILANCE_HOOK_ROOT/sleep.block.d/10-inhibit"

# --- `suspend` is NEVER an enforcement target -------------------------------
# Forcing it would fire suspend.d without the machine actually suspending,
# leaving peripherals configured for S3 on a box that is awake. And vigilant
# initiating a real power transition would mean competing with the trust root
# instead of riding it, which this design refuses on principle.
duehook suspend 10-fake 10
_backdate sleep 9999
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "enforce errored at rung sleep"
case "$_out" in
  *"nothing below 'sleep' is an enforcement target"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "enforce treated 'suspend' as a target; it must never force a power
transition, nor set peripherals for an S3 that is not happening" ;;
esac
expect_depth sleep

# --- an IDLE-ANCHORED deadline needs an IDLE CLOCK --------------------------
# The first cut had no anchor, so every deadline was measured from rung entry.
# But swayidle's timers start at the last INPUT, which vigilant could not
# observe (logind gives IdleHint=no and IdleSinceHint=0 on this stack). On a
# machine being actively typed on, `lock` read 1616s OVERDUE and the enforce
# timer would have alerted every minute, forever, about nothing.
#
# So an idle anchor was refused outright -- and refusing it made the SOON
# question unanswerable, which left a whole tier inert. The answer is not to
# guess, it is to MEASURE: an `idle.d` source reports seconds since last input,
# and only when one exists does the deadline become a claim rather than a hope.
: > "$RECORD"
go open
rm -f "$VIGILANCE_HOOK_ROOT"/lock.due.d/* 2>/dev/null || true
duehook lock 10-idle "480 idle"
_backdate open 9999
_idle() {   # seconds | "" to remove | "na" to decline
  rm -rf "$VIGILANCE_HOOK_ROOT/idle.d"
  [ -n "$1" ] || return 0
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  if [ "$1" = na ]; then
    printf '#!/bin/sh\nexit 78\n' > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  else
    printf '#!/bin/sh\necho %s\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  fi
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}

# NO CLOCK: declines, exactly as before. 9999s at the rung says nothing about
# whether anyone was sitting there.
_idle ""
_out=$("$VIGILANT" due 2>>"$T/stderr")
case "$_out" in
  *"NOT enforceable"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an idle-anchored deadline was not flagged unenforceable" ;;
esac
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "enforce reported drift for an idle-anchored deadline with no clock;
it cannot know whether the machine was busy"
expect_depth open

# A CLOCK THAT SAYS THE SEAT IS BUSY: still not overdue, however long the rung
# has been held. This is the cry-wolf case, and it is the one that matters --
# 10s of idle against a 480s deadline on a machine somebody is using.
_idle 10
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "a machine idle for only 10s against a 480s deadline was reported
overdue. That is someone sitting at the keyboard, and alerting on it every
minute is how the enforce timer got stopped by hand once already"
expect_depth open

# A CLOCK THAT SAYS THE SEAT IS QUIET PAST THE DEADLINE: overdue, at last.
# THE FINDING THIS TIER EXISTS FOR. A wedged idle timer is running, correctly
# armed and silent: it passes the argv check, logs no event for audit to
# reconcile, and leaves the machine at a rung it genuinely matches. Nothing
# else in this suite can see it, and it is the failure that created this
# package -- "it WEDGES on this Wayfire build".
_idle 900
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  && fail "the seat was idle 900s against a 480s deadline and the edge had not
fired, and enforce reported success. A silently wedged idle timer is the one
failure nothing else here can see"
case "$_out" in
  *OVERDUE*) ;;
  *) printf '%s\n' "$_out" >&2; fail "enforce did not name it OVERDUE" ;;
esac
expect_depth open          # DETECTED, never acted on: forcing is retired

# ...and a source that DECLINES is not a clock. 78 means "I cannot tell", and
# reading it as a number would mean 0 -- "input one second ago" -- which is the
# single most dangerous wrong answer here: it silently resets every deadline
# forever and reports a healthy machine.
_idle na
_out=$("$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "an idle source that DECLINED (78) was treated as a working clock"
rm -rf "$VIGILANCE_HOOK_ROOT/idle.d"
rm -f "$VIGILANCE_HOOK_ROOT"/lock.due.d/*

# --- MAX across hooks, not first or min -------------------------------------
# The latest claimed deadline is the only one nobody can call premature.
: > "$RECORD"
go open
go lock
duehook sleep 10-short 100
duehook sleep 20-long 900
_out=$("$VIGILANT" due 2>>"$T/stderr")
case "$_out" in
  *"900s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "due did not take the MAX of its hooks' deadlines" ;;
esac

# A hook that prints junk has NO OPINION and must not poison the max.
duehook sleep 30-junk "not-a-number"
_out=$("$VIGILANT" due 2>>"$T/stderr")
case "$_out" in
  *"900s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a non-numeric due hook changed the deadline" ;;
esac

pass
