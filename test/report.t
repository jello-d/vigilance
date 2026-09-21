#!/bin/sh
# test/report.t - the OUTWARD half of playing nice with stock mechanisms.
#
# vigilant must hardcode NO assumption about who wants to be told a state
# changed. logind's SetLockedHint, a status bar, an indicator: all of them are
# report hooks, none of them are known to vigilant. This pins the mechanism
# that makes that possible.
#
# The subtle property is the EXIT CODE CARVE-OUT. A report hook failing means
# the world was not told; it does NOT mean the machine is in the wrong state.
# The non-zero exit codes are a contract consumed by systemd units, and a unit
# must not restart or alarm because logind was momentarily busy. So a failing
# reporter is LOUD in the log and INVISIBLE in the exit status, which is the
# one place this suite deliberately separates "noisy" from "failed".
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init report

hook lock        10-act
hook lock.report 10-tell
hook lock.report 20-tell

# --- reporters fire AFTER the actuators, so they state what is now true -----
go lock
expect_rc 0
expect_depth lock
expect_record "lock open 10-act
lock open 10-tell
lock open 20-tell"

# --- a failing reporter is LOUD but does not fail the crossing --------------
: > "$RECORD"
go open                        # back to the top, then re-arm with a bad one
hook lock.report 30-broken 7
: > "$RECORD"
go lock
expect_rc 0                                  # NOT 1: the state is correct
expect_stderr "HOOK FAILED (rc=7): lock.report 30-broken"
expect_depth lock

# ...whereas a failing ACTUATOR still degrades the crossing, so the carve-out
# is scoped to reporting and has not leaked into the state path.
: > "$RECORD"
go open
hook lock 20-badact 5
: > "$RECORD"
go lock
expect_rc 1
expect_stderr "HOOK FAILED (rc=5): lock 20-badact"

# --- every edge can report, not just the descent ----------------------------
: > "$RECORD"
hook unlock.report 10-tell
go open
expect_rc 0
expect_depth open
expect_record "unlock lock 10-tell"

# --- A MISSING timeout(1) is a DEGRADED guarantee, and must be said ---------
# The hook bound is implemented with timeout(1). On a box without it, HOOK_TMO
# is empty and every hook runs unbounded again -- the guarantee silently absent
# rather than merely unavailable. That is this project's whole subject: a thing
# that cannot do its job reporting nothing at all.
#
# Tested with a PATH that genuinely lacks it (a symlink farm minus timeout)
# rather than by stubbing the probe, so what is asserted is the real resolution.
mkdir -p "$T/nb"
ln -s /usr/bin/* "$T/nb/" 2>/dev/null || true
rm -f "$T/nb/timeout"
[ ! -e "$T/nb/timeout" ] || fail "the fixture still has timeout(1) on PATH, so
the assertion below is not testing the absent case"

_out=$(PATH="$T/nb" "$VIGILANT" report 2>&1) || true
case "$_out" in
  *"hooks run UNBOUNDED"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "report said nothing about timeout(1) being absent. The hook bound is
silently gone on that box: a hook that hangs blocks every later hook on its
edge, including the lock provider, and nothing anywhere says the guarantee is
not in force" ;;
esac

# ...and an EXPLICIT opt-out is quiet. VIGILANCE_HOOK_TIMEOUT=0 also leaves
# hooks unbounded, but that is someone debugging a hook on purpose, and warning
# about a state the operator just asked for is how a report earns being ignored.
_out=$(VIGILANCE_HOOK_TIMEOUT=0 "$VIGILANT" report 2>&1) || true
case "$_out" in
  *"hooks run UNBOUNDED"*)
    fail "report warned about unbounded hooks when the operator had explicitly
set VIGILANCE_HOOK_TIMEOUT=0. Crying wolf about a deliberately chosen state is
what teaches a reader to skip the line that matters" ;;
esac

# --- THE IDLE TIMER IS A MECHANISM, AND report MUST NOT KNOW WHICH ----------
# The crossing machinery hardcodes no mechanism -- measured, zero references
# across all nine of its functions -- but the OBSERVABILITY did, and that is
# the worse half of the two. Swap swayidle for xidlehook or hypridle and the
# machine locks perfectly while report says "swayidle NOT running: nothing will
# lock on idle": a false FAIL about a healthy box, from the tier whose whole
# job is not doing that.
_sect() { printf '%s\n' "$1" | sed -n '/-- machinery --/,/^-- /p'; }

_out=$(VIGILANCE_IDLE_PROCESS=hypridle VIGILANCE_IDLE_UNIT=hypridle.service \
       "$VIGILANT" report 2>&1 || true)
case $(_sect "$_out") in
  *hypridle*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with a different idle daemon named, report never mentioned it. The
name is a mechanism and belongs to the integrator, not to the runner" ;;
esac
case $(_sect "$_out") in
  *swayidle*) fail "report still named swayidle after the idle daemon was
dialled to something else. A box running a different timer would be told its
healthy machine has nothing locking on idle" ;;
esac

# DECLARED ABSENT is not BROKEN. A greeter-only box or a kiosk has no idle
# timer at all, and red is the wrong answer for a deliberate configuration.
_out=$(VIGILANCE_IDLE_PROCESS= VIGILANCE_IDLE_UNIT= "$VIGILANT" report 2>&1 \
       || true)
case $(_sect "$_out") in
  *"idle timer n/a"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a box declaring NO idle timer was not reported as n/a. Empty means
'this machine has none', and answering FAIL there makes the knob unusable" ;;
esac
# SCOPED TO THE IDLE LINES, not to the whole section. `machinery` reads the
# real systemd, so in a VM its units are legitimately not enabled and it
# carries FAILs that have nothing to do with this. Asserting on the section
# made a correct VM fail the case -- the exact "one exit code for nine
# sections" trap this suite has already paid for twice.
_idl=$(printf '%s\n' "$_out" | grep -i "idle timer" || true)
case "$_idl" in
  *"[FAIL]"*) printf '%s\n' "$_idl" >&2
     fail "declaring NO idle timer produced a FAIL on the idle line itself" ;;
esac

# ...and the DEFAULT is unchanged, or every existing box changes behaviour on
# upgrade. The knob is for people who need it, not a migration.
_out=$("$VIGILANT" report 2>&1 || true)
case $(_sect "$_out") in
  *swayidle*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the default stopped naming swayidle; the dial must not change what
an unconfigured box reports" ;;
esac

pass
