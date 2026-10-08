#!/bin/sh
# test/fault-locker.t - the locker is KILLED, and the ladder must notice.
#
# FAULT: locker-killed-while-locked. The first cell of test/faults.rec, and the
# shape every other one should follow: inject a REAL fault into a REAL
# component, then assert the response the declaration promises. Not "it
# survived": a fault that produces no response is the finding.
#
# WHY THIS ONE FIRST. A locker dying is the failure mode with the worst
# consequence: the screen is unlocked and the ladder still believes it is at
# `lock`, so every tier that trusts the record agrees the session is secured
# while anyone can walk up to it. The provider arms a recovery for exactly this
# (ExecStopPost crosses `open` when the unit's cgroup empties, crash included)
# and NOTHING HAS EVER TESTED THAT IT FIRES: lock-span.t asserts systemd runs
# the ExecStopPost, which is a different claim from the ladder following it.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-locker
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

wire lock '' systemd-locker
wire lock .verify locker-up

# --- given: a genuinely locked machine --------------------------------------
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "go lock failed before the fault could be injected"
await 10 locker_up || fail "no locker came up, so there is nothing to kill"
[ "$(depth)" = lock ] || fail "depth is '$(depth)', not lock"

# --- when: the locker is killed outright ------------------------------------
# SIGKILL, not SIGTERM. A polite exit is the path that already works; the one
# that matters is the locker being destroyed without a chance to tidy up,
# because that is what a crash, an OOM kill or a compositor restart looks like.
_before=$(crossed unlock)
pkill -KILL -x swaylock || fail "pkill found no swaylock to kill"

# --- then: the ladder must follow the SPAN's end ----------------------------
# AND `open` IS NOT A CLAIM THAT THE SCREEN IS USABLE HERE, which this case
# used to assert in as many words ("the screen is unlocked"). It is not: a
# SIGKILLed locker sends no unlock_and_destroy, and ext-session-lock REQUIRES
# the compositor to keep the session locked in response, so the screen stays
# covered with no process anywhere. See THEORY.md, "A LOCK CAN OUTLIVE EVERY
# LOCKER".
#
# The assertion stands on the provider's actual design rather than on that
# false premise: the UNIT IS THE SPAN of the lock, so the span ending is the
# unlock edge whether or not the compositor released. What a ladder stuck at
# `lock` would cost is the restore hooks never running and a later
# `go lock atleast` declining from there, which is the 2026-10-04 shape.
_open() { [ "$(depth)" = open ]; }
await 20 _open || fail "the locker was KILLED and the machine still records
depth='$(depth)'. The span has ended, so the unlock edge is owed: without it
nothing that restores on unlock runs, and a later 'go lock atleast' declines
from '$(depth)' and locks nothing"
[ "$(crossed unlock)" -gt "$_before" ] || fail "depth reached open without the
unlock edge being crossed. The rung is right and no hook ran, so anything that
restores on unlock did not"
locker_up && fail "a swaylock is still running after the kill"

# --- and: the wreckage must not outlive the fault ---------------------------
# A fault that leaves the machine reporting findings for ever is only half
# handled. This is where the stale-save class lived: an interrupted descent
# whose record survived and failed every later ascent.
_rep=$("$VIGILANT" report 2>&1) || true
_no_fail_in "$_rep" "recorded state" "after a killed locker the machine still
reports outstanding state. The fault is over; its wreckage should be too"

# ...and the machine must still be usable. A recovery that leaves the ladder
# unable to lock again has converted a transient fault into a permanent one.
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "the machine could not lock again after recovering from the kill"
await 10 locker_up || fail "the second lock crossed its edge but brought up no
locker; the recovery left the provider unable to work"

# --- FAULT: locker-dies-before-committing -----------------------------------
# The other half of the same mechanism, and the WORSE half. Above, a locker that
# was up dies; here one never comes up at all. The distinction matters because
# the response differs: a dead locker must be RECOVERED from, but a locker that
# never committed must be REPORTED, loudly, or `go lock` returns success about a
# session nothing is guarding.
#
# THE LOCKER IS REAL, not a stub of one. VIGILANCE_LOCKER is a shipped knob
# precisely because the locker is the integrator's choice, so supplying one that
# exits non-zero is a real locker behaving badly rather than a fixture standing
# in for a machine. That is the line test/faults.rec draws: a device, a
# process, a filesystem or a clock may not be faked, and this fakes none.
session_reset
wire lock '' systemd-locker
wire lock .verify locker-up
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/deadlocker"
chmod +x "$T/bin/deadlocker"

_rc=0
VIGILANCE_LOCKER="$T/bin/deadlocker" PATH="$T/bin:$PATH" \
  "$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || _rc=$?

# 1 IS THE WHOLE POINT: "crossed, but a hook failed". 0 would tell
# lock-on-sleep.service that the box is safe to suspend, and it reads nothing
# but the status.
[ "$_rc" = 1 ] || fail "a locker that exits non-zero gave rc=$_rc from go lock.
1 means 'crossed but a hook failed'; 0 tells the suspend unit the session is
secured and the box sleeps UNLOCKED, which is the founding failure of this
package"
locker_up && fail "a locker is running after one that exits 1"
said "HOOK FAILED" || fail "the provider could not bring a locker up and nothing
was logged. Silence here is the false green: the edge is recorded, no locker
exists, and every tier that trusts the record says the session is secured"

# AND THE VERIFY TIER MUST AGREE. The record and the machine disagree at this
# moment by design, so the tier whose job is to notice that has to.
_vrc=0
"$VIGILANT" verify lock >>"$T/out" 2>>"$T/stderr" || _vrc=$?
[ "$_vrc" != 0 ] || fail "verify lock reported success with no locker running.
That is the exact claim lock-on-sleep.service checks as ExecStartPost before
allowing a suspend"

# --- A LOCKER THAT EXITS ZERO, which is the one above's dangerous twin -------
# THE DIFFERENCE IS THE STATUS AND IT CHANGES EVERYTHING. A locker exiting 1
# fails its unit, and systemd carries that back; a locker exiting ZERO looks
# like a clean start to everything except whatever asks afterwards.
#
# AND IT IS NOT A CONTRIVANCE. It is the shape an integrator on a desktop
# environment reaches for FIRST: `xfce4-screensaver-command --lock` and its
# GNOME equivalent ask a running daemon to lock and exit immediately, by design.
# A `VIGILANCE_LOCKER` pointing at one of those is a reasonable thing to try,
# which is precisely why the refusal has to be deliberate and legible.
#
# WHY REFUSING IS RIGHT, and the reason is about TRACKING rather than about the
# screen. This provider's design is that the UNIT IS THE SPAN of the lock and
# ExecStopPost is how an unlock is detected, so a locker that does not outlive
# its own lock makes the ladder record `open` while the display is covered: the
# record BEHIND the world, which every tier that trusts the record then agrees
# with. A loud wrong beats a silent one.
session_reset
wire lock '' systemd-locker
wire lock .verify locker-up
printf '#!/bin/sh\nexit 0\n' > "$T/bin/delegatinglocker"
chmod +x "$T/bin/delegatinglocker"

# BOTH TYPES, because they are caught by different code and an integrator can
# set either. Under `forking` systemd itself notices (it waits for a fork that
# never comes); under `simple` nothing is established at all and the provider's
# own survival confirm is the only thing that can see it. Asserting one would
# leave the other free to report a successful lock.
for _ty in simple forking; do
  session_reset
  wire lock '' systemd-locker
  wire lock .verify locker-up
  _zrc=0
  VIGILANCE_LOCKER="$T/bin/delegatinglocker" VIGILANCE_LOCKER_TYPE="$_ty" \
    VIGILANCE_LOCKER_ARGV= PATH="$T/bin:$PATH" \
    "$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || _zrc=$?
  [ "$_zrc" != 0 ] || fail "with Type=$_ty a locker that exits 0 immediately
reported a SUCCESSFUL lock. Nothing is holding a lock, the unit is gone, and
lock-on-sleep.service reads nothing but this status before letting the box
suspend. That is the founding failure of this package, reached by a locker that
behaved politely"
done

# AND THE MESSAGE MUST NOT GUESS AT THE SCREEN. The provider cannot tell a
# locker that failed on startup from one that locked and exited, so claiming
# either is a confidently actionable lie. The first version of this code said
# "so the screen is NOT locked", which is false for exactly the delegating case
# above, and sends a reader to debug a lock that is working.
_msg=$(cat "$T/stderr" 2>/dev/null || true)
case "$_msg" in
  *'must hold the lock for its own lifetime'*) ;;
  *) fail "the refusal does not name the REQUIREMENT it is enforcing. An
integrator whose locker delegates needs to be told that this provider needs the
locker to outlive its lock; without it the message is just a failure:
$_msg" ;;
esac
case "$_msg" in
  *'screen is NOT locked.'*) fail "the refusal asserts the screen is not locked.
The provider cannot know that: a delegating locker leaves the screen COVERED and
its unit dead, so this is the confidently-wrong diagnosis that the
WAYLAND_DISPLAY message three screens away already exists to avoid:
$_msg" ;;
esac

pass "killed mid-lock, exits 1, and exits 0 under both unit types"
