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
# depend on whether the developer happened to touch the trackpoint mid-run --
# and this suite has now shipped that mistake three times (uptime, backlight,
# luminance). A clock test that reads the real clock is not a test.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init input-counters

HOOK=$HERE/libexec/vigilance/hooks/input-counters
# NO `device` ENTRY UP FRONT. Creating it as a DIRECTORY means a later
# `ln -sfn` drops the symlink INSIDE it instead of replacing it, so the USB
# parent is never reached and the urbnum case passes on the i8042 counter
# alone -- testing nothing it claims to. Caught by the case failing.
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
  IDLE=$(cat "$T/out" 2>/dev/null)
}
# TOLERANT BY ONE SECOND, because _age and the hook each call `date`
# separately and a second can tick between them. An exact match made this file
# fail about once a run -- a flaky test is one people re-run until it is green,
# which is worse than no test.
_about() {   # expected actual what
  [ "$2" -ge "$1" ] && [ "$2" -le $(( $1 + 2 )) ] && return 0
  fail "$3 (expected about $1s, got $2s)"
}
_age() {   # seconds -> backdate the stored "last changed" timestamp
  _s=$(awk '{print $1}' "$T/state/input-counters")
  _m=$(awk '{print $3}' "$T/state/input-counters")
  printf '%s %s %s\n' "$_s" "$(( $(date +%s) - $1 ))" "${_m:-0}" \
    > "$T/state/input-counters"
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
# would measure only the gap since the previous pass and report ~60s forever --
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
# Summing per node would weight it several times -- harmless for equality, but
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
# activity path untested -- a mutation deleting that update survived exactly
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

pass
