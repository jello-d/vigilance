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

# --- FORCING IS OPT-IN ------------------------------------------------------
# The plan's own safety constraint: never force a descent without a reliable
# ascent. vigilant cannot see input while locked, so a forced blank could land
# mid-password. Report is the default until an ascent is proven on the box.
_backdate lock 700
VIGILANCE_ENFORCE=force "$VIGILANT" enforce >/dev/null 2>>"$T/stderr" \
  || fail "the force policy did not cross the edge"
expect_depth sleep

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
_out=$(VIGILANCE_ENFORCE=force "$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "a blocked enforcement should hold off, not fail"
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
_out=$(VIGILANCE_ENFORCE=force "$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "enforce errored at rung sleep"
case "$_out" in
  *"nothing below 'sleep' is an enforcement target"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "enforce treated 'suspend' as a target; it must never force a power
transition, nor set peripherals for an S3 that is not happening" ;;
esac
expect_depth sleep

# --- an IDLE-ANCHORED deadline is reported but NEVER enforced ---------------
# The first cut had no anchor, so every deadline was measured from rung entry.
# But swayidle's timers start at the last INPUT, which vigilant cannot observe
# (logind gives IdleHint=no and IdleSinceHint=0 on this stack). On a machine
# being actively typed on, `lock` read 1616s OVERDUE and the enforce timer would
# have alerted every minute, forever, about nothing.
#
# So an idle anchor is reported and deliberately not acted on. This is the
# cry-wolf failure this project keeps having to unlearn, caught on a live box.
: > "$RECORD"
go open
rm -f "$VIGILANCE_HOOK_ROOT"/lock.due.d/* 2>/dev/null || true
duehook lock 10-idle "480 idle"
_backdate open 9999
_out=$("$VIGILANT" due 2>>"$T/stderr")
case "$_out" in
  *"NOT enforceable"*) ;;
  *) printf '%s
' "$_out" >&2
     fail "an idle-anchored deadline was not flagged unenforceable" ;;
esac
_out=$(VIGILANCE_ENFORCE=force "$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "enforce reported drift for an idle-anchored deadline 9999s past its
nominal time; it cannot know whether the machine was busy"
case "$_out" in
  *"idle-anchored"*) ;;
  *) printf '%s
' "$_out" >&2; fail "enforce did not say why it declined" ;;
esac
expect_depth open          # and it must NOT have crossed, even under force

# ONE idle hook is enough to make the whole deadline unenforceable: we cannot
# tell a busy machine from an idle one, so acting on the rung-anchored sibling
# would still be a guess.
duehook lock 20-rung "600 rung"
_out=$(VIGILANCE_ENFORCE=force "$VIGILANT" enforce 2>>"$T/stderr") \
  || fail "a rung-anchored sibling re-enabled enforcement"
case "$_out" in
  *"idle-anchored"*) ;;
  *) fail "mixing anchors lost the idle veto" ;;
esac
expect_depth open
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
