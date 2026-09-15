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

pass
