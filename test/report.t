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
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
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
# is empty and every hook runs unbounded again: the guarantee silently absent
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
# The crossing machinery hardcodes no mechanism: measured, zero references
# across all nine of its functions, but the OBSERVABILITY did, and that is
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

# NAMED BUT NOT RUNNING IS A FAILURE, and it is the other half of the
# idle-timer-killed cell. The watchdog deliberately DECLINES when the timer is
# absent: it is not its finding, and two tiers accusing in different words
# teaches a reader to discount both, so if report is silent here as well then
# nothing on the box reports a dead idle timer at all. That is the founding
# failure of this package, undetected.
#
# A SESSION IS ASSERTED, not assumed. The finding is correctly withheld with no
# session: report once declared FAIL over a greeter-only box doing exactly the
# right thing, so the guard is deliberate and this case must not read as a
# licence to remove it. `_r_session` is overridable for precisely this, so both
# branches are reachable from a test rather than only the substrate's own.
_out=$(VIGILANCE_SESSION=7 VIGILANCE_IDLE_PROCESS=nosuchidled \
       VIGILANCE_IDLE_UNIT=nosuchidled.service "$VIGILANT" report 2>&1 || true)
case $(_sect "$_out") in
  *"nosuchidled NOT running"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a NAMED idle daemon that is not running was not reported. The
watchdog declines in that case on purpose, so report is the only tier that can
say it, and a box whose idle timer died would be told nothing at all" ;;
esac
# AND AS A FAIL, not an aside. The severity is what report's exit status is made
# of, and a supervision timer reads the status and nothing else: the same
# reason `verify` had to stop returning 0 for "nothing was checked".
printf '%s\n' "$_out" | grep -q '^ *\[FAIL\].*nosuchidled' \
  || fail "a dead idle timer was mentioned but not as a FAIL, so report still
exits 0 and anything reading only the status is told the box is healthy:
$(printf '%s\n' "$_out" | grep -i nosuchidled | head -2)"
# ...AND WITHHELD WITH NO SESSION, which is the guard that case exists beside.
# Without this the fix for the above is "always FAIL", which cries wolf on every
# greeter-only and headless machine.
_out=$(VIGILANCE_SESSION= VIGILANCE_IDLE_PROCESS=nosuchidled \
       VIGILANCE_IDLE_UNIT=nosuchidled.service "$VIGILANT" report 2>&1 || true)
case $(_sect "$_out") in
  *"NOT running"*) printf '%s\n' "$_out" >&2
     fail "with NO session, report still accused a missing idle timer. There
is nothing to idle in, so the finding is not real, and this exact FAIL once
landed on a greeter-only box that was behaving correctly" ;;
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
# made a correct VM fail the case: the exact "one exit code for nine
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

# --- the UNIT SET is DECLARED, not assumed -----------------------------------
# Five unit names were LITERAL in `_rep_machinery`, each one `_r_bad` when
# absent, and `_r_bad` sets RRC=1. So an integrator who wires a subset got up to
# five permanent FAILs and a permanently non-zero report about a correctly
# working machine, which is how a report stops being read. Not theoretical: this
# project's OWN guest is such an integration. It installs in user mode and
# deliberately does not place the two SYSTEM units, says so with a WARN of its
# own, and machinery has been red about it on every run, which five tests work
# around by refusing to read report's status.
#
# THE SAME FUNCTION ALREADY HAD THE HONEST PATTERN for the idle timer
# (VIGILANCE_IDLE_PROCESS empty means "this box declares none"), applied to the
# process and not to the units. The asymmetry was the tell.
#
# SEVERITY ASSERTED PER LINE, via grep, never against the whole section: a
# shell glob spans newlines, so a `*'[FAIL]'*audit*` pattern would happily match
# a FAIL on one line and the word on another. That has bitten here before.

# 1. DECLARED BUT MISSING IS STILL A FAILURE. The declaration must not become a
# way to be told nothing: a name that is wired and absent is the original
# finding and has to survive the change.
_out=$(VIGILANCE_SESSION=7 VIGILANCE_AUDIT_UNIT=vig-no-such.timer \
       "$VIGILANT" report 2>&1 || true)
# THE SEVERITY IS PART OF THE CLAIM, so the marker is in the pattern. A first
# version of this grepped the TEXT alone, and a mutation downgrading `_r_bad` to
# `_r_info` SURVIVED it: the sentence was identical and only the marker moved,
# which is a report that mentions a dead unit without failing about it. Caught
# by disbelieving a survival rather than by the test.
if ! _sect "$_out" \
     | grep -qE '^ *\[FAIL\].*vig-no-such\.timer declared but NOT active'; then
  printf '%s\n' "$_out" >&2
  fail "a DECLARED unit that is absent must still FAIL, and must name itself.
Otherwise declaring a unit buys nothing and the original check is gone"
fi

# 2. DECLARED NONE MUST NEVER BE A FAILURE, which is the whole point, and this
# assertion is substrate-independent: whether the box HAS the unit decides WARN
# against INFO, and neither is a FAIL.
_out=$(VIGILANCE_SESSION=7 VIGILANCE_AUDIT_UNIT= "$VIGILANT" report 2>&1 \
       || true)
if _sect "$_out" | grep -qE '^ *\[FAIL\].*(audit|forensic)'; then
  printf '%s\n' "$_out" >&2
  fail "with the audit timer DECLARED NONE, machinery still FAILED about it. A
box that does not wire a unit is not a broken box, and a permanently non-zero
report is one nobody reads"
fi

# 3. AND IT MUST SAY WHICH, rather than going quiet. Silence would make
# "declare it absent" the way to switch a check off, so the undeclared-but-
# INSTALLED direction is a WARN naming the unit, and the genuinely-absent one is
# an INFO saying the box declares none. That two-way shape is the one
# `_common.md` prescribes where a declaration replaces an artifact that used to
# be both the declaration and the deployment.
# THE RELATION, NOT EITHER BRANCH, and that distinction is the whole assertion.
# A first version accepted a WARN *or* an INFO so as to read the same on every
# substrate, and a mutation downgrading the WARN to the absent-INFO SURVIVED it:
# the two are precisely what must not be confused, since reporting "declares
# none" about a unit that IS installed is how declaring one absent becomes the
# way to silence a real finding.
#
# So the test asks the SAME question the product asks and requires the answers
# to correspond. That is substrate-INDEPENDENT as a relation while still being
# exact on each substrate, which is the opposite of a verdict that differs by
# substrate: here the box decides which branch, and the test knows which to
# demand.
if systemctl --user cat vigilance-audit.timer >/dev/null 2>&1; then
  _want='\[WARN\].*is installed on this box but DECLARED NONE'
  _why="the audit timer IS installed here, so DECLARED NONE has to WARN and
name it: a unit nothing checks is the drift a declaration introduces"
else
  _want='\[--\].*declares none'
  _why="the audit timer is genuinely absent here, so DECLARED NONE has to read
as an INFO rather than a warning about a unit that was never wired"
fi
if ! _sect "$_out" | grep -qE "^ *$_want"; then
  printf '%s\n' "$_out" >&2
  fail "$_why"
fi

# --- coherence must not call it DARK HARDWARE having looked at nothing -------
# MEASURED BEFORE IT WAS FIXED: with an empty backlight root at rung `sleep` the
# loop body never ran, `_lit` stayed empty, and the section printed
#
#   [OK]   depth 'sleep' matches dark hardware
#
# having examined no device at all. That is manifestor's permanent state, an
# external OLED with no sysfs backlight, so report had been certifying "dark
# hardware" there on every pass from an absence of evidence. "I could not look"
# laundered into "I looked and it is fine", in the section a human reads.
#
# THREE OUTCOMES, AND ONLY ONE IS A PASS. All three are asserted because the
# obvious wrong fix is to warn in the no-device case, which would fire forever
# on every desktop, and the other wrong fix is to go quiet, which hides the lit
# backlight this section exists to catch.
_coh() {   # <backlight-root> -> the coherence section only
  VIGILANCE_SYS_BACKLIGHT="$1" "$VIGILANT" report 2>/dev/null \
    | awk '/^-- coherence --$/ { f = 1; next } /^-- / { f = 0 } f' || true
}
go sleep
mkdir -p "$T/bl-none" "$T/bl-dark/p0" "$T/bl-lit/p0"
printf '400\n' > "$T/bl-dark/p0/max_brightness"
printf '5\n'   > "$T/bl-dark/p0/actual_brightness"
printf '400\n' > "$T/bl-lit/p0/max_brightness"
printf '300\n' > "$T/bl-lit/p0/actual_brightness"

_o=$(_coh "$T/bl-none")
case "$_o" in
  *'no backlight device here'*) ;;
  *) fail "with NO backlight device, coherence must say sysfs cannot answer
rather than render an empty scan as confirmation:
$_o" ;;
esac
case "$_o" in
  *'[OK]'*dark*) fail "coherence claimed dark hardware with no device to read.
It checked nothing, and nothing is not evidence:
$_o" ;;
esac
case "$_o" in
  *'[WARN]'*backlight*|*'[FAIL]'*backlight*)
    fail "the no-device case WARNED. Every desktop with an external monitor is
in this state permanently, and a warning that is always on is how a report stops
being read:
$_o" ;;
esac

_o=$(_coh "$T/bl-dark")
case "$_o" in
  *'[OK]'*'dark backlight'*) ;;
  *) fail "a backlight present and at 5/400 is a real power state and must read
as a pass, QUALIFIED as being about the backlight rather than about the panel in
general:
$_o" ;;
esac

_o=$(_coh "$T/bl-lit")
case "$_o" in
  *'[FAIL]'*'still lit'*) ;;
  *) fail "a backlight at 300/400 at rung 'sleep' is the original finding and
must still FAIL. The no-device carve-out must not have swallowed it:
$_o" ;;
esac

# --- and the SAME over-claim at the other end of the ladder ------------------
# At rung `open` the pass read "depth 'open' matches an unlocked session", which
# is a claim about the whole session drawn from `_r_locker_up`: our own unit and
# ONE process name from a knob. MEASURED 2026-10-03 against real components, a
# foreign i3lock holding the screen with the record at `open`, where that line
# read [OK] and the verify tier reported "ok (1 checked)".
#
# NOT WIDENED, so this is not a detection test: enumerating every locker is not
# a capability anyone has. What is asserted is that the CLAIM matches the
# EVIDENCE, which is the same fix the dark-hardware cases above got.
go open
_o=$(_coh "$T/bl-none")
case "$_o" in
  *'matches an unlocked session'*)
    fail "coherence still claims the SESSION is unlocked. Its evidence is our
own unit plus one configured process name, so it cannot see a locker vigilance
did not start, and a foreign locker leaves this line reading [OK]:
$_o" ;;
esac
case "$_o" in
  *'[OK]'*"no locker of ours"*'not visible to this check'*) ;;
  *) fail "the bounded pass must still SAY what it checked and what it cannot
see. Deleting the over-claim without naming the bound would leave a reader with
no idea the check is our-locker-shaped:
$_o" ;;
esac

pass "reporters, the rc carve-out, coherence's three dark outcomes, and the\
 bounded claim at 'open'"
