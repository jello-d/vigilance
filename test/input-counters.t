#!/bin/sh
# test/input-counters.t - an idle clock from counters, with no daemon.
#
# The deadline that matters is expressed in IDLE time, and vigilant could not
# read idle time, so a whole tier was inert. Every alternative was measured and
# rejected: ext_idle_notify only fires after waiting the threshold out from
# registration; swayidle shares fate with the thing being watched; logind
# reports IdleHint=no here; evdev is root:input and a process that READS it is
# keylogger-shaped.
#
# Kernel counters carry COUNTS AND NOTHING ELSE, which makes the mechanism
# incapable of seeing what was typed rather than merely unwilling.
#
# BOTH SOURCES ARE PINNED HERE. Left to read the host, every case below would
# depend on whether the developer happened to touch the trackpoint mid-run,
# and this suite has now shipped that mistake three times (uptime, backlight,
# luminance). A clock test that reads the real clock is not a test.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init input-counters

HOOK=$HERE/libexec/hooks/input-counters
# NO `device` ENTRY UP FRONT. Creating it as a DIRECTORY means a later
# `ln -sfn` drops the symlink INSIDE it instead of replacing it, so the USB
# parent is never reached and the urbnum case passes on the i8042 counter
# alone, testing nothing it claims to. Caught by the case failing.
mkdir -p "$T/state" "$T/sys/input/input0" "$T/sys/input/input1"

_irq() {   # <count> -> a /proc/interrupts with that i8042 total
  printf '  1:  %s   0  IR-IO-APIC   1-edge   i8042\n' "$1" > "$T/interrupts"
}
_usb() {   # <count> -> a USB parent with that urbnum, reached from input1
  mkdir -p "$T/sys/usbdev"
  printf '%s\n' "$1" > "$T/sys/usbdev/urbnum"
  rm -rf "$T/sys/input/input1/device"
  ln -sfn "$T/sys/usbdev" "$T/sys/input/input1/device"
}
_run() {
  RC=0
  VIGILANCE_STATE_DIR="$T/state" VIGILANCE_PROC_INTERRUPTS="$T/interrupts" \
    VIGILANCE_SYS_INPUT="$T/sys/input" sh "$HOOK" >"$T/out" 2>>"$T/stderr" \
    || RC=$?
  # FIELD ONE, exactly as the runner takes it. The hook appends what it has
  # DEMONSTRATED (ceiling, age) after the answer, so a consumer reading the
  # whole line gets "0 ceiling=0 age=0" and dies on `[: Illegal number`. Taking
  # field 1 here is not a workaround: it asserts the contract every other
  # consumer uses.
  IDLE=$(head -1 "$T/out" 2>/dev/null | awk '{print $1}')
  DEMO=$(head -1 "$T/out" 2>/dev/null)
}
# TOLERANT BY ONE SECOND, because _age and the hook each call `date`
# separately and a second can tick between them. An exact match made this file
# fail about once a run: a flaky test is one people re-run until it is green,
# which is worse than no test.
_about() {   # expected actual what
  [ "$2" -ge "$1" ] && [ "$2" -le $(( $1 + 2 )) ] && return 0
  fail "$3 (expected about $1s, got $2s)"
}
_age() {   # seconds -> backdate the stored "last changed" timestamp
  # FIVE FIELDS, and the last two matter: the clock now refuses to credit a
  # stretch it did not WATCH, so a fixture that leaves the sample time unset
  # reads as a sampling gap and the hook correctly re-anchors instead of
  # reporting the interval. The fixture has to describe a clock that was
  # sampling all along, which is what the case means.
  _s=$(awk '{print $1}' "$T/state/input-counters")
  _m=$(awk '{print $3}' "$T/state/input-counters")
  _n=$(date +%s)
  printf '%s %s %s %s %s\n' "$_s" "$(( _n - $1 ))" "${_m:-0}" "$_n" \
    "$(( _n - $1 ))" > "$T/state/input-counters"
}

# --- 1. THE FIRST SAMPLE CANNOT KNOW ----------------------------------------
# Idle time is the interval since the counter last CHANGED, so with nothing to
# compare against there is no interval. Returning 0 here would mean "input one
# second ago" and would pin the clock from the very first pass.
_irq 1000
_run
[ "$RC" = 78 ] || fail "the first sample returned a verdict ($RC/$IDLE). A
counter on its own says nothing; only the interval between two does"

# --- 2. AN UNCHANGED COUNTER IS IDLE TIME -----------------------------------
_age 300
_run
[ "$RC" = 0 ] || fail "an unchanged counter did not produce a reading"
_about 300 "$IDLE" "idle did not report the time since the counter moved"

# --- 3. A CHANGED COUNTER MEANS INPUT, AND RESETS THE CLOCK -----------------
_irq 1001
_run
[ "$IDLE" = 0 ] || fail "the counter moved and idle read '$IDLE'. Any movement
is input, and reporting anything but 0 would carry a stale interval forward"
_age 42
_run
_about 42 "$IDLE" "after a reset the clock restarted at the wrong point"

# --- 4. A QUIET PASS MUST NOT RESET THE CLOCK -------------------------------
# The subtle one. If a sample with no change rewrote the timestamp, every pass
# would measure only the gap since the previous pass and report ~60s forever,
# a clock that looks alive and can never reach a 480s deadline.
_age 500
_run; _about 500 "$IDLE" "setup for the quiet-pass case"
_run
[ "$IDLE" -ge 500 ] || fail "a second quiet pass reported '$IDLE', less than
the 500s already elapsed. The quiet path rewrote the timestamp, so the clock
can only ever measure the sampling interval"

# --- 5. A COUNTER THAT WENT BACKWARDS HAS RESET -----------------------------
# A replugged USB device or a reboot restarts urbnum. The old interval refers
# to a counter that no longer means the same thing, so it must be discarded
# rather than used to compute a number that looks plausible.
_irq 5
_run
[ "$IDLE" = 0 ] || fail "a counter that went BACKWARDS produced idle '$IDLE'.
That is a device replug or a reboot, not time passing"

# --- 6. USB urbnum COUNTS, AND A SHARED PARENT IS COUNTED ONCE --------------
# A keyboard exposes several input nodes that all resolve to ONE usb device.
# Summing per node would weight it several times, harmless for equality, but
# it would make the signature jump when a node appears, reading as input.
_irq 5
_usb 700
_run; _age 200; _run
_about 200 "$IDLE" "with a USB device present the clock stopped working"
_usb 701
_run
[ "$IDLE" = 0 ] || fail "a USB urbnum change was not seen as input. On a
desktop with no PS/2 port that is the ONLY signal there is"

# The same parent reached from a second input node must not change the sum.
_age 100
rm -rf "$T/sys/input/input0/device"
ln -sfn "$T/sys/usbdev" "$T/sys/input/input0/device"
_run
_about 100 "$IDLE" "a second input node pointing at the SAME usb device changed
the signature; counting one device twice makes a node appearing look like a
keypress"
rm -f "$T/sys/input/input0/device"

# --- 7. NOTHING TO COUNT IS NOT "IDLE FOREVER" ------------------------------
# A box with no countable device must decline. Returning a number would pin the
# clock and make `report` call the deadline measurable while nothing measures.
rm -rf "$T/sys/input/input1/device" "$T/sys/usbdev" "$T/state"
mkdir -p "$T/state"
printf '  0:  99  0  IR-IO-APIC  timer\n' > "$T/interrupts"
_run
[ "$RC" = 78 ] || fail "with no i8042 and no USB input device the hook returned
$RC/'$IDLE' instead of declining. A clock that reads zero devices and answers
anyway is the false green this whole suite exists to prevent"

# --- 8. THE CEILING RECORDS WHAT THE CLOCK COULD EVER SEE -------------------
# Measured on manifestor: a QMK keyboard emits a burst every 40-60s with nobody
# present, so the clock there resets constantly and can never observe the 480s
# a lock deadline needs. It would still return a NUMBER, and `report` would
# call the deadline measurable while it was structurally unreachable.
#
# NO QUIET SAMPLE between the backdate and the change, deliberately. The quiet
# path ALSO raises the ceiling, so a sequence that passes through it leaves the
# activity path untested: a mutation deleting that update survived exactly
# this file until the case was tightened.
rm -rf "$T/state"; mkdir -p "$T/state"
_irq 1000; _run          # first sample
_age 250                 # 250s elapse with no sample at all
_irq 1001; _run          # the next sample sees activity, and ONLY this path
                         # can have recorded the interval that just ended
_max=$(awk '{print $3}' "$T/state/input-counters")
_about 250 "$_max" "the ceiling did not record the quiet stretch that just
ended; without it a clock chattered by a self-reporting device looks identical
to one on a genuinely busy machine"

# ...and the QUIET path raises it too, or a clock that has never yet been
# interrupted would report a ceiling of 0 while happily counting upward.
_age 900; _run
_max=$(awk '{print $3}' "$T/state/input-counters")
_about 900 "$_max" "a long quiet stretch did not raise the ceiling"

# --- SEVERAL SOURCES: THE MINIMUM WINS -------------------------------------
# Not a property of this hook but of the runner that aggregates idle.d, and it
# is asserted here because this is the file that has a working source to pair
# one against. Sources should agree; when they do not, the one reporting the
# LEAST idle saw input most recently, and believing it is what stops a stale
# source manufacturing a false overdue against a machine somebody is at.
#
# The MAXIMUM would be the dangerous read: it reports a busy machine as long
# idle, which is exactly the cry-wolf the whole idle anchor was refused for.
_H=$T/aggr; mkdir -p "$_H/idle.d" "$T/aggrun"
printf '#!/bin/sh\necho 900\n' > "$_H/idle.d/10-stale"
printf '#!/bin/sh\necho 5\n'   > "$_H/idle.d/20-fresh"
chmod +x "$_H/idle.d/10-stale" "$_H/idle.d/20-fresh"
_agg=$(VIGILANCE_HOOK_ROOT="$_H" VIGILANCE_MACHINE_HOOKS="$T/none" \
       VIGILANCE_RUN_DIR="$T/aggrun" VIGILANCE_LOG="$T/aggr.log" \
       "$HERE/bin/vigilant" report 2>/dev/null \
       | sed -n 's/.*idle clock: \([0-9]*\)s since last input.*/\1/p' | head -1)
[ "$_agg" = 5 ] || fail "with two idle sources reporting 900s and 5s, the
runner used '$_agg'. The MINIMUM must win: the source that saw input most
recently is the one that keeps a stale reading from declaring a machine
somebody is sitting at overdue for a lock"

# --- A GAP IN SAMPLING IS NOT A QUIET SEAT ---------------------------------
# THE DEFECT THIS CATCHES WAS FOUND ON A LIVE BOX, and it disarmed the one
# signal that makes this clock honest. The ceiling read 241310s (67 HOURS)
# while the counter was in fact moving every 25 seconds, because the interval is
# wall time between SAMPLES and the sampler had not run for most of it. A
# high-water mark never comes down, so one gap certifies the clock for ever.
#
# Consequence, measured: `report` called a 480s and a 600s deadline "measurable"
# on a box whose clock could not witness 60s.
rm -f "$T/state/input-counters"; _irq 500
_run; _run                                  # establish a watching clock
_n=$(date +%s)
_s=$(awk '{print $1}' "$T/state/input-counters")
# A clock that last SAMPLED an hour ago, counter unchanged since.
printf '%s %s %s %s %s\n' "$_s" "$(( _n - 3600 ))" 0 "$(( _n - 3600 ))" \
  "$(( _n - 7200 ))" > "$T/state/input-counters"
_run
[ "$IDLE" = 0 ] || fail "after an hour with NOTHING SAMPLING, the clock reported
${IDLE}s of idle. It cannot vouch for a stretch it did not watch, and reporting
that interval is what inflated a live ceiling to 67 hours. Activity is the safe
direction: it suppresses a finding rather than inventing one."
grep -q 'not watching' "$T/stderr" || fail "the clock re-anchored without saying
why. A number that quietly changed meaning is worse than a loud one."
_c=$(awk '{print $3}' "$T/state/input-counters")
[ "$_c" = 0 ] || fail "the ceiling survived a gap it cannot vouch for (got $_c).
A high-water mark never falls on its own, so an artifact would certify the clock
for ever; dropping it is what makes this self-healing on an existing box."
# AND THE REPORTED ONE, not only the stored one. The corpus caught this: the
# stored ceiling was a literal 0 while the ANSWER printed the variable, so a
# mutation defeating the reset left the state correct and handed report the
# stale 67-hour value for a pass. Report reads the ANSWER, so that is what has
# to be asserted: the state file is not the consumer.
case "$DEMO" in
  *"ceiling=0 "*|*"ceiling=0") ;;
  *) fail "after a gap the clock still REPORTED a ceiling it cannot vouch for,
whatever it stored: '$DEMO'. report reads this line, so a stale ceiling here
certifies a deadline as measurable for a pass." ;;
esac

# --- AND A PRE-UPGRADE STATE FILE IS A GAP BY CONSTRUCTION -----------------
# Three fields is what every box wrote before this, so a poisoned ceiling is
# discarded exactly once, on the first run after deploy, with no migration step.
rm -f "$T/state/input-counters"; _irq 500
_run; _run
printf '%s %s %s\n' "$(awk '{print $1}' "$T/state/input-counters")" \
  "$(( $(date +%s) - 3600 ))" 241310 > "$T/state/input-counters"
_run
[ "$IDLE" = 0 ] || fail "a three-field state file was read as a watching clock"
[ "$(awk '{print $3}' "$T/state/input-counters")" = 0 ] \
  || fail "the 67-hour ceiling from a pre-upgrade state file was kept"

# --- WHAT IT DEMONSTRATED IS REPORTED, not merely recorded -----------------
# The ceiling was written and read by NOTHING: report decided "measurable" on
# "a number came back", so the tell existed only in this hook's comments. It is
# on the answer line now, after field 1 so no consumer changes.
rm -f "$T/state/input-counters"; _irq 500
_run; _age 40; _run
case "$DEMO" in
  *ceiling=*age=*) ;;
  *) fail "the answer does not carry what the clock has demonstrated, so report
cannot tell a clock that could witness a deadline from one that never has:
'$DEMO'" ;;
esac
[ "$IDLE" -ge 40 ] || fail "field 1 stopped being the idle seconds: '$DEMO'"

# --- IT NAMES THE DEVICE THAT MOVED ----------------------------------------
# WHY A NAME AT ALL: report used to conclude "something talks to an input device
# on its own" by elimination, which is true, unactionable and unable to say
# which, and the operator's only remedy is AT the device. The counters already
# know per device; only the attribution was missing.
#
# CONTENT-FREE, so this needs no privilege and nothing to opt into. A count
# carries no scancode, button or coordinate. The alternative considered was an
# evdev source and it cannot work: a hook observes only during its own bounded
# window, and sampled observation cannot prove absence BETWEEN samples, so it
# would over-report idle: the one unsafe direction for a clock gating an
# alert.
rm -f "$T/state/input-counters" "$T/state/input-counters.devices"
_irq 500; _usb 100
# AFTER _usb, which is what creates the directory. Writing it first failed
# silently behind a `|| true` and the label fell back to the basename, the
# tolerant-write habit hiding a fixture bug, which is why the assertion names
# the expected label rather than just checking that SOMETHING was named.
printf 'Test_Keyboard\n' > "$T/sys/usbdev/product"
_run; _run
_usb 106                            # ONLY the USB device moves
_run
case "$DEMO" in
  *recent=Test_Keyboard:*) ;;
  *) fail "the source did not name the device that moved: '$DEMO'. Without a
name the finding is 'something on this machine reports to itself', which the
operator cannot act on" ;;
esac
case "$DEMO" in
  *recent=i8042*) fail "it named a device that did NOT move: '$DEMO'. The
binding device is the one holding the clock down, and naming the wrong one sends
the operator to the wrong hardware" ;;
esac

# AND THE OTHER WAY ROUND, or "always name the USB one" passes the case above. A
# REAL GAP FIRST: both devices moved within the same second above, so both read
# "0 seconds ago" and which one is named is a coin toss on file order. That is
# fine behaviour, either is the binding device, but it is not a test, so the
# case makes the ages actually differ.
sleep 2
_irq 511                            # only i8042 moves now
_run
case "$DEMO" in
  *recent=i8042:*) ;;
  *) fail "with only i8042 moving it was not named: '$DEMO'" ;;
esac

# --- OUR OWN PASS IS NOT SEAT INPUT ----------------------------------------
# THE DEFECT THIS CLOSES WAS SELF-INFLICTED AND LIVE. A counter clock reads the
# URB count of every input device, and the supervision pass generates traffic on
# one: the standing recheck runs `verify`, a wired hook there queries the
# keyboard over raw HID, and the keyboard answers because it was ASKED.
# Measured, 6 URBs three to four seconds after every pass, once a minute, for
# ever. So the clock could never accumulate idle past one interval, and report
# concluded the deadlines were unmeasurable while telling the operator to fix
# their device.
#
# THE FIX IS A PHASE, not a heuristic. The pass takes its reading BEFORE any
# hook runs, then tells the sources to re-baseline afterwards, so the window
# each one judges is the one in which vigilance did nothing at all.
rm -f "$T/state/input-counters" "$T/state/input-counters.devices"
_irq 1000
_run; _run
_before=$IDLE

# A GAP BEFORE THE SETTLE, so a wrongly-stamped timestamp is off by MORE than
# the one second of tolerance the `date` skew needs. Without it the mutation
# that stamps during the settle pass shifted the age by exactly 1s and survived:
# the tolerance swallowed the whole defect.
sleep 3
# OUR traffic, then a settle: the baseline moves, the verdict does not.
_irq 1006
RC=0 IDLE=
VIGILANCE_STATE_DIR="$T/state" VIGILANCE_PROC_INTERRUPTS="$T/interrupts" \
  VIGILANCE_SYS_INPUT="$T/sys/input" VIGILANCE_IDLE_PHASE=settle \
  sh "$HOOK" >"$T/out" 2>>"$T/stderr" || RC=$?
[ "$RC" = 78 ] || fail "a settle pass answered with rc=$RC. It takes a reading
and judges nothing, so an idle time reported there would be measured against a
baseline that is about to change"
[ ! -s "$T/out" ] || fail "a settle pass printed an answer: '$(cat "$T/out")'"

sleep 2
_run
[ "$IDLE" -gt "$_before" ] || fail "OUR OWN TRAFFIC RESET THE CLOCK (idle was
${_before}s, now ${IDLE}s). The supervision pass talks to input devices, so
counting that as seat input pins the clock at one interval for ever:
exactly what shipped, and what made report blame a keyboard for
answering a question vigilance asked it."

# AND THE ATTRIBUTION TOO, which the first version of this fix left fooled: it
# skipped the settle pass entirely, so the stored counts stayed at their
# pre-pass values and the NEXT pass read our own traffic as a device moving,
# naming the very keyboard we had talked to. ASSERTED AGAINST THE CLOCK, not
# against a magic number. The first version looked for `recent=i8042:0` and a
# mutation removing the settle guard SURVIVED it: stamping during the settle
# pass leaves the age at ~2s rather than 0, so the symptom I checked for only
# appears at one timing. The invariant is that the named device cannot have
# moved more recently than the clock's own last change, since both are measured
# from the same event.
_rage=$(printf '%s' "$DEMO" | sed -n 's/.*recent=[^:]*:\([0-9][0-9]*\).*/\1/p')
[ -n "$_rage" ] || fail "no device age to check in '$DEMO'"
[ "$_rage" -ge "$(( IDLE - 1 ))" ] || fail "the named device is younger than the
clock's own idle time (device ${_rage}s, idle ${IDLE}s): '$DEMO'. Both are
measured from the last genuine change, so a device stamped during OUR pass reads
as having moved more recently than anything actually did, and report NAMES the
device from this field, so it would still point at the one we queried"

# ...AND A REAL CHANGE BETWEEN PASSES STILL RESETS IT, or the fix is "ignore
# everything", which passes every case above and switches the clock off.
_irq 2000
_run
[ "$IDLE" = 0 ] || fail "a real counter change between passes did not reset the
clock (idle ${IDLE}s). Only traffic DURING our own pass is ours"
case "$DEMO" in
  *recent=i8042:0*) ;;
  *) fail "a real change did not stamp the device that moved: '$DEMO'" ;;
esac

pass
