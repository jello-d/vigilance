#!/bin/sh
# test/evdev-sample.t - the probe's instrument, proven where a human is not.
#
# WHY THIS EXISTS, and it is a direct consequence of wasting somebody's time.
# test/probe/evdev-idle-proof asks a question only a real machine can answer: do
# that box's REAL input devices chatter with nobody present? But it has to
# establish first that its instrument works at all, and the first live run
# failed exactly there and reported "evdev CANNOT see input this way here" -- a
# verdict about the kernel produced by a bug in the driver script.
#
#   14:25:26  uinject taps 40 keys
#   14:25:27  the sampler opens the device and waits 15s
#   14:25:42  polls: nothing arrived SINCE THE OPEN
#
# The stimulus landed before the measurement window opened, which the sampler's
# own header describes as the whole mechanism. So an operator sat off their
# keyboard for three minutes to measure my orchestration.
#
# THE SPLIT THAT FIXES IT: the positive and negative controls are about the
# EVDEV CORE, not about any particular box, and the guest has uinput and runs as
# root. So they are asserted here, on every VM run, and the handoff is left with
# the only question that genuinely needs real hardware.
#
# THE NEGATIVE CONTROL IS THE ONE THAT MATTERS, as it is there: whether a fresh
# open comes back NOT readable when nothing is arriving. If it were readable
# regardless, an idle clock built on this would answer "input just now" for ever
# -- indistinguishable from a working clock, which is the failure this package
# exists to prevent. And it is only meaningful while the device still EXISTS: a
# destroyed device is unreadable for the wrong reason, so that is asserted too.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init evdev-sample
require uinput

SAMPLER=$HERE/test/probe/evdev-sample
UINJECT=$HERE/test/uinject
[ -x "$SAMPLER" ] || fail "no sampler at $SAMPLER"
command -v python3 >/dev/null 2>&1 || fail "no python3"
[ -c /dev/uinput ] || modprobe uinput >/dev/null 2>&1 || true
[ -c /dev/uinput ] || fail "no /dev/uinput despite the uinput capability"

"$SAMPLER" --self-test >/dev/null 2>&1 \
  || fail "the sampler's own poll mechanics failed, so nothing below is about
evdev"

# --- one device across both controls ---------------------------------------
# ONE device, deliberately: the negative control's claim is about the SAME
# device falling silent, and a second one created fresh for it would be a
# different thing that had never emitted at all.
#
# TAP_DELAY puts the stimulus INSIDE the window that opens after it. The margins
# are wide on purpose; an earlier probe in this series ran a 4s wait against a
# 5s threshold and could support any conclusion at all.
WIN=${WIN:-8}
TAP_DELAY=${TAP_DELAY:-4}
HOLD=$(( TAP_DELAY + (WIN * 3) + 15 ))
python3 "$UINJECT" key 40 "$HOLD" "$TAP_DELAY" >"$T/uinject.out" 2>&1 &
UIPID=$!
trap 'kill "$UIPID" 2>/dev/null || true; rm -rf "$T"' EXIT INT TERM HUP
sleep 2

_hits() {   # file -> windows in which the synthetic device reported
  awk '/uinject-kbd/ { split($2, a, "/"); print a[1] + 0; exit }
       END { }' "$1"
}
_present() { grep -q 'uinject-kbd' "$1"; }

# --- 1. THE POSITIVE CONTROL: it can see input -----------------------------
"$SAMPLER" --windows 1 --seconds "$WIN" > "$T/active.out" 2>&1 \
  || fail "the sampler failed during the active window: $(cat "$T/active.out")"
_present "$T/active.out" || fail "the synthetic device was not even enumerated,
so this case is about a missing fixture rather than about evdev:
$(cat "$T/active.out")"
[ "$(_hits "$T/active.out")" = 1 ] || fail "THE SAMPLER SAW NO INPUT while a
device was actively emitting into the window. Either the open-wait-poll sequence
does not detect events on this kernel, or the stimulus fell outside the window
again -- and the second is what produced a live 'evdev cannot see input' verdict
that was really a driver bug. uinject said: $(cat "$T/uinject.out")
sample: $(grep uinject "$T/active.out")"

# --- 2. THE NEGATIVE CONTROL: it can see the ABSENCE of input --------------
# The taps are long over by now; the device is still alive because of the hold.
sleep 2
"$SAMPLER" --windows 2 --seconds "$WIN" > "$T/quiet.out" 2>&1 \
  || fail "the sampler failed during the quiet window: $(cat "$T/quiet.out")"
# THE PRECONDITION FIRST. A device that has been destroyed is "not readable" for
# a reason that has nothing to do with the per-client buffer, and asserting
# silence without this is the vacuous pass the hold exists to prevent.
_present "$T/quiet.out" || fail "the synthetic device was GONE during the quiet
window, so its silence means nothing: there was nothing left to read. The hold
($HOLD s) is too short for these window lengths"
[ "$(_hits "$T/quiet.out")" = 0 ] || fail "A FRESH OPEN CAME BACK READABLE with
nothing arriving ($(_hits "$T/quiet.out") of 2 windows). An idle clock built on
this would report 'input just now' for ever, which looks exactly like a working
clock and measures nothing. The per-client-buffer premise does not hold here:
$(grep uinject "$T/quiet.out")"

# --- 3. AND IT NEVER READ AN EVENT ----------------------------------------
# The property that makes this admissible at all. Asserted against the source
# rather than by inspection, because "we would never do that" is not a check,
# and the whole reason the counter sources are the default is that they are
# INCAPABLE of observing content rather than merely unwilling.
#
# SCOPED TO THE FD READ PRIMITIVES, and the first version was not. It also
# matched `fh.read()` -- which reads a device NAME out of sysfs, world-readable
# text with no event in it -- so it failed on correct code and called the
# product a keylogger. A check that fires on the safe construction is one that
# gets deleted along with the guarantee it was protecting.
#
# The device fds come from os.open, and os.read / readinto are the only ways to
# take bytes off one, so forbidding those is the whole surface.
grep -nE '\bos\.read\b|readinto' "$SAMPLER" \
  && fail "the sampler reads from a device fd. Reading evdev is keylogger-shaped
however well intentioned, and the poll-only construction is the only reason this
mechanism is admissible at all" || :
# ...AND THE GUARD IS NOT VACUOUS: it has to be able to see a read. A pattern
# that matched nothing would certify any future version, which is how a
# never-matching search string once let a mutation report a covered guard.
printf 'x = os.read(fd, 16)\n' > "$T/probe-with-read.py"
grep -qE '\bos\.read\b|readinto' "$T/probe-with-read.py" \
  || fail "the read-detection pattern cannot match an actual os.read call, so it
would pass a sampler that logged every keystroke"

pass "positive and negative controls, on a real kernel"
