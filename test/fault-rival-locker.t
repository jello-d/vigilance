#!/bin/sh
# test/fault-rival-locker.t - a locker vigilance did NOT start, and was never
# told about, holds the screen while the ladder records `open`.
#
# THE FAULT, and it is the one the integrator population hits first. Everything
# meaning "secure this session" is supposed to collapse onto `go lock atleast`,
# so tackup's own config test asserts the keybind crosses the EDGE rather than
# calling a locker directly: "a locker started behind vigilant's back locks the
# screen while the depth record never learns". That guard covers OUR keybind. It
# cannot cover a THIRD PARTY, and a desktop environment ships several: the xfce
# flavour alone pulls light-locker, xfce4-screensaver, xscreensaver and
# mate-screensaver through xfce4-session's Recommends, and xss-lock plus i3lock
# is the same thing assembled by hand.
#
# WHY IT IS THE SECURITY-CRITICAL DIRECTION. With the screen covered and the
# record reading `open`, every tier that trusts the record agrees the session is
# unlocked: the ladder will not refuse a descent, audit reconciles nothing, and
# the standing recheck judges `open` and is satisfied. The record is BEHIND the
# world, which is this package's signature failure, arriving from outside rather
# than from our own code.
#
# THE RIVAL IS REAL, NOT A STUB. i3lock on the guest's real Xorg (:98), started
# by this scenario rather than by the provider, and with VIGILANCE_LOCKER left
# at its default so the rival is genuinely FOREIGN. That last part is what makes
# this a different subject from session-locker-alt.t, which drives the same
# binary as vigilance's OWN configured locker: there the name is known and the
# unit is ours, here neither is true.
#
# WHAT THIS SUBSTRATE CANNOT MODEL, said rather than left to be discovered: the
# rival holds :98 while the provider's swaylock covers the WAYLAND compositor,
# so the two never contend for one display here. "One gesture starts two
# lockers" is therefore a separate cell and not this one. What is faithful is
# the DESYNC, which needs only a locker process vigilance did not start.
#
# MEASURE-FIRST, DELIBERATELY. The assertions below are the preconditions and
# the recovery, which are certain. What a rival SHOULD produce is the open
# question, so every signal that could answer "is the session locked" is
# PRINTED: the fix gets chosen from the measurement rather than from reasoning
# about the mechanism, which is the sequence this project has learned costs
# least.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"

session_init fault-rival-locker
require x11locker

RIVAL=i3lock
RIVAL_DISPLAY=:98

# Called FIRST as well as last, the convention session-locker-alt.t set: `fail`
# exits, so an end-of-file cleanup alone would leave the rival holding :98 for
# every later scenario in the boot. Idempotent.
_cleanup_rival() {
  pkill -x "$RIVAL" >/dev/null 2>&1 || true
  _n=0
  while pgrep -x "$RIVAL" >/dev/null 2>&1 && [ "$_n" -lt 20 ]; do
    _n=$((_n + 1)); sleep 0.2
  done
}
_rival_up() { pgrep -x "$RIVAL" >/dev/null 2>&1; }
_rival_down() { ! pgrep -x "$RIVAL" >/dev/null 2>&1; }

_cleanup_rival
session_reset

# The hook set an integrator wires for this question. locker-up belongs in
# EVERY tier at or below `lock`, and at `unlock` it is the half that asserts a
# locker is NOT up, which is the claim a rival falsifies.
wire lock .verify locker-up
wire unlock .verify locker-up

# --- 1. the baseline is CLEAN before the fault -------------------------------
# Otherwise "the verify failed" is already true for an unrelated reason, which
# is the hook-failure.t lesson: assert the precondition, not just the outcome.
[ "$(depth)" = open ] || fail "precondition: expected depth 'open', got
'$(depth)'"
_rival_down || fail "precondition: a $RIVAL was already running before the
fault was injected, so nothing below would be attributable"

if ! "$VIGILANT" verify unlock >/tmp/rival-base.out 2>&1; then
  fail "precondition: verify unlock FAILED before the rival existed, so this
scenario cannot attribute anything to the fault:
$(cat /tmp/rival-base.out)"
fi

# --- 2. inject the rival, and PROVE it took ---------------------------------
env -u WAYLAND_DISPLAY DISPLAY="$RIVAL_DISPLAY" "$RIVAL" -n \
  >/tmp/rival-locker.out 2>&1 &

if ! await 15 _rival_up; then
  fail "the fault did not take: $RIVAL never came up on $RIVAL_DISPLAY, so
every assertion after this would pass for the wrong reason:
$(cat /tmp/rival-locker.out 2>/dev/null)"
fi

# The ladder genuinely still records `open`: the rival crossed no edge.
[ "$(depth)" = open ] || fail "the rival crossed an edge it has no way to
cross: depth is now '$(depth)'"
[ "$(crossed lock)" = 0 ] || fail "a 'lock' edge was crossed, so this is not
the behind-the-back case the cell exists for"

# --- 3. THE MEASUREMENT: what can see it, and what cannot -------------------
# Printed rather than asserted. Each line is a candidate answer to "is the
# session locked", and which of them can see a foreign locker is exactly the
# fact that decides whether this is a defect with a fix or a limit to state.
# NOT MEASURED HERE, and the reason is the scenario's own context rather than
# the signal's worth: logind's LockedHint is the obvious cheap cross-check, and
# this tier runs as ROOT with no graphical session, so the hint belongs to a
# session nothing here locks. Reading it would print a field whose label did not
# match what it answers, which is the wrong-diagnosis fault one layer out.
echo "--- signals while a FOREIGN locker holds the screen, depth=open ---"

# GUARDED. An unguarded capture of a verify that is ALLOWED to fail aborts the
# file under `set -e`, with no output and no name: the trap this suite has paid
# for five times, most recently in a test written the same day as its fix.
_vrc=0
"$VIGILANT" verify unlock >/tmp/rival-verify.out 2>&1 || _vrc=$?
echo "verify unlock            rc=$_vrc"
sed 's/^/    /' /tmp/rival-verify.out

# report's own exit code folds nine sections, so it is discarded and the
# OWNING section is read instead. Fifth time this suite has paid for that.
"$VIGILANT" report >/tmp/rival-report.out 2>&1 || true
echo "report coherence section:"
awk '/coherence/,/^$/' /tmp/rival-report.out | sed 's/^/    /'

echo "our unit:                $(systemctl --user is-active \
  screen-lock.service 2>/dev/null || true)"
echo "configured locker name:  ${VIGILANCE_LOCKER:-swaylock}"
# `|| true`, NOT `|| echo 0`: pgrep -c prints 0 and EXITS 1 on no match
# (measured), so the obvious fallback appends a second zero and the field
# becomes the two-line string "0\n0". Same shape as the grep -c defect the
# crash tier paid for.
echo "rival process name:      $RIVAL  (running: $(pgrep -xc "$RIVAL" \
  2>/dev/null || true))"
echo "--- end signals ---"

# THE ONE DETECTION-SHAPED ASSERTION THIS CELL CAN HONESTLY MAKE. Not "the
# rival was detected": enumerating every locker is not a capability anyone has,
# and a test demanding one would be demanding a defect's opposite rather than a
# behaviour. What IS assertable is that the claim matches the evidence, with a
# real foreign locker present on real components, which is the half that was
# measured as wrong here on 2026-10-03 and fixed in the same change.
if grep -q 'matches an unlocked session' /tmp/rival-report.out; then
  fail "with a REAL foreign locker holding the screen, report still claims the
SESSION is unlocked. Its evidence is our own unit plus one configured process
name, so this line cannot be about the session:
$(awk '/coherence/,/^$/' /tmp/rival-report.out)"
fi

# --- 4. RECOVERY: the ladder is not wedged by a rival -----------------------
# The one response this cell can be certain of. Whatever vigilance can or
# cannot SEE, a rival must not leave the ladder unable to secure the session:
# that would convert a coexistence problem into a permanent one.
_cleanup_rival
_rival_down || fail "could not remove the rival, so recovery is unmeasurable"

# ASSERTED ON THE EDGE, NEVER ON A RESTING LOCKER, and this is the third
# scenario in this tier to need that: fault-lid case 1 and fault-storm both
# carry the same note. A headless guest's locker cannot survive, so its
# ExecStopPost unwinds the ladder seconds later and a poll for a live swaylock
# fails over ANOTHER cell's subject (locker-killed-while-locked). The durable
# record that the session was secured is the CROSSING.
_relocked() { [ "$(crossed lock)" -ge 1 ]; }

"$VIGILANT" go lock atleast >/tmp/rival-relock.out 2>&1 || true
if ! await 15 _relocked; then
  fail "after a rival came and went the ladder could not cross 'lock': a
transient coexistence fault has become a permanent one. go lock said:
$(cat /tmp/rival-relock.out)"
fi

session_reset
_cleanup_rival

# THE DETECTION HALF IS DELIBERATELY NOT ASSERTED YET, and the reason is a rule
# rather than laziness: the measurement above says nothing notices, so an
# assertion written today would either demand a defect (banned here) or demand
# a capability nobody has decided is feasible. It gains that assertion when the
# product decision lands; until then this cell holds down the recovery and
# PRINTS the evidence, which is what made the finding attributable at all.
pass "fault-rival-locker: a foreign locker leaves the ladder able to cross\
 'lock' again; detection is MEASURED above and nothing notices"
