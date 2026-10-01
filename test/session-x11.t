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

# --- 1. THE IDLE SOURCE ANSWERS, AND THE ANSWER GROWS ----------------------
# THE FIRST REAL idle.d SOURCE THIS SUITE HAS EVER RUN. The shipped one counts
# kernel interrupts and USB URBs, which this guest cannot do at all (no
# countable input device), so the overdue tier has been structurally inert here
# since the VM existed.
#
# THE SCREENSAVER IS THE HAZARD IN THIS CASE, and it is measured rather than
# assumed away. The X server resets its idle counter when the saver activates,
# which this scenario found the hard way (306s, then 2s three seconds later), so
# a reading taken across that boundary proves nothing.
#
# `xset s <n>` DOES NOT TAKE ON THIS SERVER, asserted below rather than hoped
# for, because the first version of this case set 3600 and then asserted against
# 90, and got 600 both times. So the window is chosen to be far shorter than
# whatever the server reports, which is a claim about three seconds rather than
# about the saver.
SS=$(xset q 2>/dev/null | sed -n 's/^ *timeout: *\([0-9][0-9]*\).*/\1/p' \
     | head -1)
case "${SS:-}" in
  ''|*[!0-9]*) fail "the server reports no screensaver timeout, so neither the
cap below nor the safety of this three-second window can be established" ;;
esac
[ "$SS" -eq 0 ] || [ "$SS" -gt 30 ] || fail "the screensaver timeout is ${SS}s,
which is inside the window this case measures across: the counter would reset
mid-case and the growth assertion would be about the saver, not the clock"
_i1=$("$PLUG/x11-idle" | awk '{print $1}') || fail "x11-idle declined against a
live X server. The probe found xprintidle answering, so this is the hook and not
the substrate"
case "$_i1" in
  ''|*[!0-9]*) fail "x11-idle printed '$_i1', which is not a number of seconds.
A source that cannot answer must exit 78 rather than print something
unparseable" ;;
esac
sleep 3
_i2=$("$PLUG/x11-idle" | awk '{print $1}') || fail "x11-idle declined on its
second call"
[ "$_i2" -ge "$_i1" ] || fail "idle time went BACKWARDS across three seconds of
doing nothing: ${_i1}s then ${_i2}s, with the screensaver pushed out to an hour.
A clock that can do that satisfies every overdue comparison in the package"
[ "$_i2" -ge 2 ] || fail "after 3 seconds of a seat nobody touched, the X server
reported ${_i2}s idle. Either the conversion is wrong (it reports milliseconds)
or something is resetting the clock; both make a deadline unmeasurable"

# --- 2. AND IT IS SECONDS, NOT MILLISECONDS -------------------------------
# The unit mismatch is the one bug in that file that INVENTS a finding: a
# thousand-fold overstatement is a false overdue on a machine in use, and false
# overdue alerts are the documented reason a live box had its supervision timer
# stopped by hand. Three seconds of real time bounds it at both ends.
[ "$_i2" -lt 100 ] || fail "three seconds of idle read as ${_i2}s, so the
milliseconds are being reported as seconds"

# --- 3. THE CAP IS REPORTED, and it is the server's own -------------------
# The finding this scenario produced on its first run. A source that answers a
# number while being structurally unable to witness the deadline is this
# project's signature false green, and `ceiling=` is the field that breaks it.
# THE EXPECTED VALUE COMES FROM THE SERVER, not from something this file tried
# to set. Asserting a number we chose would test `xset s`, which does not work
# here; asserting the SERVER's number tests the only thing that matters: that
# the hook and the server agree about what can be witnessed.
_ans=$("$PLUG/x11-idle")
if [ "$SS" -gt 0 ]; then
  case "$_ans" in
    *"ceiling=$SS age=$SS"*) ;;
    *) fail "the server's screensaver timeout is ${SS}s and the source answered
'$_ans'. It must report that cap: XScreenSaverQueryInfo restarts when the saver
activates, so any deadline past ${SS}s is unwitnessable here and report would
otherwise call it measurable" ;;
  esac
else
  case "$_ans" in
    *ceiling=*) fail "the screensaver is DISABLED on this server and the source
still qualified its answer ('$_ans'); a cap that does not exist must not be
reported" ;;
  esac
fi
# BOTH BRANCHES EXIST BECAUSE ONLY ONE CAN RUN HERE, and the stub tier covers
# the other: test/x11.t drives a fixture through timeout 600 and timeout 0. A
# scenario that pretended to cover both would be asserting against a server it
# could not configure.

# --- 4. THE LUMA PROBE CAPTURES THROUGH import -----------------------------
# `grim` cannot see an X server and `import` cannot see a Wayland output, so the
# grabber is the platform and the MEASUREMENT is not. This is the only place the
# X11 branch of hook_screen_luma runs for real.
_ans=$(env -u WAYLAND_DISPLAY sh -c \
  '. "$1"/hook_lib; hook_screen_luma' _ "$PLUGINS")
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
  '. "$1"/hook_lib; hook_luma_peak "$2"' _ "$PLUGINS" "$_ans")
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
