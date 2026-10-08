#!/bin/sh
# test/session-x11.t - the X11 plugins against a REAL X server.
#
# WHAT A SECOND PLATFORM IS FOR, and this file is the evidence rather than the
# argument. Three defects came out of adding X11, and none of them needed X11 to
# be RUNNING:
#
#   VIGILANCE_LOCKER was a half promise: the name was a knob while `-f` and
#   Type=forking were not, both swaylock's;
#   the integrator's argv helper handed a swaylock config file to whatever
#   locker it was given;
#   and the idle contract had never had to say what a MISSING `ceiling=` means,
#   because with one source in existence "unimplemented" and "unbounded" were
#   the same silence.
#
# Then the real server found a fourth, on the first run: Xvfb reports NO DPMS
# block at all, even started with `+extension DPMS`, and the hook's first
# version read that as "disabled" and FAILED every dark edge. Absent is not
# disabled, and no amount of stubbing would have said so, because the fixture
# was written by the same person as the hook.
#
# SO WHAT THIS ASSERTS IS WHAT THE SUBSTRATE CAN ACTUALLY DO: idle time from the
# X server, a capture from the root window, and a dpms hook that DECLINES
# honestly where the extension is absent. A scenario that demanded a working
# DPMS here would be asserting against a fixture again.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-x11
require x11

DISPLAY=:99; export DISPLAY
PLUG=$PLUGINS/hooks

# --- 1. THE IDLE SOURCE RUNS FOR REAL, AND CORRECTLY REFUSES ---------------
# THE FIRST REAL idle.d SOURCE THIS SUITE HAS EVER RUN, and what it does on
# this server is decline. That is the right answer, and finding out why was
# worth more than the three assertions this case used to make.
#
# MEASURED, after five guest rounds of guessing: this server's idle counter is
# reset by READING it.
#
#     spaced: 3008 2975 2980     reads three seconds apart
#     rapid:  1 0 0 1            reads back to back
#
# It reports the interval since the PREVIOUS READER rather than since input,
# which is consistent with a display that has no input devices at all. A
# supervision pass reads this source three times (judge, settle, and the one
# that decides), so the deciding read could never see more than the gap since
# the second, and an idle-anchored deadline would be permanently not due.
#
# AND IT WOULD HAVE READ AS A FALSE GREEN, which is why the hook now refuses:
# `report` takes the ceiling the hook emits (the server's 600s screensaver
# timeout) and calls a 480s deadline MEASURABLE, while the readable value is
# always about zero. Answering what we got would mean answering ~0, which
# means "input one second ago", which silently resets every deadline for ever.
#
# THE DECLINE HAS TO BE ATTRIBUTABLE, or this case passes for any of four
# unrelated reasons (no xprintidle, no DISPLAY, an unreachable server, a
# non-numeric answer). So the precondition establishes that the tool IS present
# and DOES answer, and the message is required to name the counter.
command -v xprintidle >/dev/null 2>&1 || fail "no xprintidle here, so a decline
below would be about the missing tool rather than about the server's counter"
[ -n "${DISPLAY:-}" ] || fail "no DISPLAY, same reason"
_raw=$(xprintidle 2>/dev/null) || fail "xprintidle cannot reach $DISPLAY, so a
decline below would be the substrate rather than the finding"
case "${_raw:-}" in
  ''|*[!0-9]*) fail "xprintidle answered '${_raw:-}', not a number, so the
decline below would be the parse guard rather than the counter check" ;;
esac

_irc=0
_iout=$("$PLUG/x11-idle" 2>&1) || _irc=$?
[ "$_irc" = 78 ] || fail "x11-idle returned $_irc against a server whose
counter is reset by reading it, answering '$_iout'. A source that cannot
measure must say 78: zero is the single most dangerous wrong answer here,
because it means input one second ago"
case "$_iout" in
  *"reset by READING"*) ;;
  *) fail "the decline did not name the counter, so a reader cannot tell it
from the three other reasons this hook declines for: $_iout" ;;
esac

# --- 2. AND THE UNIT AND CAP ARE COVERED WHERE THEY CAN BE ----------------
# Deliberately NOT here any more. Seconds-not-milliseconds and the `ceiling=`
# emission were asserted against this server until it turned out to be
# unreadable, and a server that declines can prove neither. test/x11.t drives
# both through a stub, in both the timeout-600 and timeout-0 directions, and a
# scenario that pretended to cover them would be asserting against a server it
# cannot configure.
# --- 4. THE LUMA PROBE CAPTURES THROUGH import -----------------------------
# `grim` cannot see an X server and `import` cannot see a Wayland output, so the
# grabber is the platform and the MEASUREMENT is not. This is the only place the
# X11 branch of hook_screen_luma runs for real.
_ans=$(env -u WAYLAND_DISPLAY sh -c \
  '. "$1"; hook_screen_luma' _ "$HOOKLIB")
[ -n "$_ans" ] || fail "the luma probe returned NOTHING against a live X server.
The probe found import capturing the root window, so either the grabber choice
is not reaching the X11 branch or the capture itself failed"

# THE ANSWER IS TWO FIELDS NOW, mean then `peak=`, and this case asserted the
# whole string was a number. It duly failed on '0 peak=0', with a message
# confidently blaming the grabber choice: a wrong diagnosis that would have sent
# a reader to the WAYLAND_DISPLAY tie-break, which was working perfectly. The
# lesson this file already carries about instruments, charged to its own text.
_luma=${_ans%% *}
case "$_luma" in
  ''|*[!0-9.e+-]*) fail "the MEAN field of '$_ans' is not a number, so the
measurement is wrong before any threshold is applied" ;;
esac
# AND IT IS IN RANGE. `%[fx:mean]` is normalised 0..1, and a value outside that
# was once the first clue that a reading had been truncated by a grep: the
# instrument, not the screen.
awk -v v="$_luma" 'BEGIN { exit !(v + 0 >= 0 && v + 0 <= 1) }' \
  || fail "luma $_luma is outside the 0..1 that fx:mean is defined on, so the
measurement is wrong before any threshold is applied"

# THE PEAK MUST BE THERE, AND ON THIS PATH THAT IS THE ONLY PLACE IT IS PROVEN.
# A mean cannot see a small bright region: a white cursor on a black surface
# lifts it 22x less than the dark threshold, so the peak is what makes "nothing
# is emitting" answerable at all. The stub tier supplies it through an override,
# which short-circuits the pipeline, so only a real capture shows that
# ImageMagick actually produces it.
_peak=$(env -u WAYLAND_DISPLAY sh -c \
  '. "$1"; hook_luma_peak "$2"' _ "$HOOKLIB" "$_ans")
case "${_peak:-}" in
  ''|*[!0-9.e+-]*) fail "the real X11 capture produced no usable peak
(answer '$_ans'). Without one screen-dark cannot ask whether ANYTHING is
emitting and falls back to the mean, which certifies a cursor on a black
surface as dark" ;;
esac
awk -v v="$_peak" 'BEGIN { exit !(v + 0 >= 0 && v + 0 <= 1) }' \
  || fail "peak $_peak is outside the 0..1 fx:maxima is defined on"
# AND THE PEAK IS NEVER BELOW THE MEAN, which is what a maximum means. Cheap,
# and it is the one assertion that catches the two statistics being swapped:
# both are plausible numbers in range, so no bounds check could tell.
awk -v m="$_luma" -v p="$_peak" 'BEGIN { exit !(p + 0 >= m + 0) }' \
  || fail "the peak ($_peak) is BELOW the mean ($_luma), which no maximum can
be. The two statistics are swapped, and both being in range is exactly why
nothing else here would notice"

# --- 5. x11-dpms DECLINES HONESTLY WHERE THE EXTENSION IS ABSENT ----------
# THE FOURTH FINDING, asserted here because the stub tier cannot produce a real
# server that lacks a real extension. 78 rather than 1: there is nothing to
# enable and no remedy to name, so a failure would be a permanent false alarm.
#
# IT ASKS THE SERVER FIRST, so this case cannot pass for the wrong reason: if
# Xvfb ever grows DPMS the precondition fails loudly instead of the scenario
# silently asserting the wrong branch.
if xset q 2>/dev/null | grep -q 'DPMS is '; then
  fail "this X server DOES report a DPMS block, so the decline asserted below
would be about something else. Teach this case the working path instead,
that is a better problem to have"
fi
_rc=0
env VIGILANCE_STATE_DIR="$T/state" sh "$PLUG/x11-dpms" sleep \
  >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "against a server with no DPMS extension the hook
returned $_rc, not 78. Absent is not disabled, and the difference is a failed
edge on every single sleep"
_rc=0
env VIGILANCE_STATE_DIR="$T/state" sh "$PLUG/x11-dpms" wake \
  >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "the lit edge returned $_rc, not 78"

# --- 6. AND THE RUNNER COUNTS THAT AS "NOTHING CHECKED", not as clean -----
# The whole point of 78. A verify tier where every hook declines must not read
# as a verified machine, which is the defect that let a lit wallpaper sit on
# an OLED behind a green report.
mkdir -p "$HOOKS/sleep.verify.d"
ln -sf "$PLUG/x11-dpms" "$HOOKS/sleep.verify.d/90-x11-dpms"
_out=$("$VIGILANT" verify sleep 2>&1) || true
rm -f "$HOOKS/sleep.verify.d/90-x11-dpms"
case "$_out" in
  *"NOTHING CHECKED"*|*"n/a"*) ;;
  *) fail "a verify tier in which the only hook DECLINED reported:
$_out
'I could not look' must never read as 'I looked and it is fine'" ;;
esac

pass "x11-idle ${_i1}s -> ${_i2}s, luma $_luma, dpms declined honestly"
