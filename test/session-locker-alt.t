#!/bin/sh
# test/session-locker-alt.t - a REAL locker that is not swaylock.
#
# THE DOCUMENTED CONFIGURATION NOTHING HAD EVER EXECUTED. The man page names it
# outright: an X11 box is
#
#     VIGILANCE_LOCKER=i3lock VIGILANCE_LOCKER_ARGV=-n
#     VIGILANCE_LOCKER_TYPE=simple
#
# and the only test mentioning i3lock writes its OWN stub over the real binary
# (`printf '#!/bin/sh\nexit 0\n'`) and asserts that the three knobs reach
# systemd-run's argv. That is a claim about PLUMBING and says so. What no test
# anywhere asserted is whether a real alternative locker COMES UP under those
# settings, whether the verifier then finds it, or whether the unlock tears it
# down. i3lock has been installed in this guest's package list the whole time,
# exercised by nothing: shipped and wired by nobody, which is the shape this
# project keeps finding.
#
# WHY THAT GAP IS THE INTERESTING ONE. These three knobs exist for exactly one
# audience, an integrator whose stack is not this fleet's, and they were written
# while COSTING X11 support rather than while running it. A public repo's
# extension point that has never been used is a promise, not a feature.
#
# AND THE KNOBS ARE A CHAIN, which is why only an end-to-end run can judge them.
# The NAME decides what to exec, ARGV decides whether it daemonises, and TYPE
# asserts that it does. Get the last one wrong for a foreground locker and
# systemd-run waits for a fork that never comes: the provider reports failure
# about a screen that is actually locked, or the hook's bound kills it. Each
# knob is plausible on its own and only the combination is right or wrong.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-locker-alt
require x11locker

LOCKER=i3lock
DISPLAY=:98; export DISPLAY

# THE TRANSIENT UNIT INHERITS THE USER MANAGER'S ENVIRONMENT, NOT THIS SHELL'S,
# which is a dependency this suite paid to discover: the provider starts the
# locker through `systemd-run --user`, so without DISPLAY imported there the
# locker cannot reach the X server and every lock fails with nothing but "could
# not start screen-lock.service". It is documented for WAYLAND_DISPLAY; this is
# the first time anything has exercised it for a SECOND variable, and a real
# session does the same import at login.
systemctl --user import-environment DISPLAY >/dev/null 2>&1 \
  || fail "could not import DISPLAY into the user manager, so the locker the
provider starts could not reach the X server and this scenario would be
measuring that rather than the knobs"

_alt_up() { pgrep -x "$LOCKER" >/dev/null 2>&1; }
_alt_gone() { ! _alt_up; }

# NOT `locker_up` FROM session_lib: that one asks about swaylock BY NAME, which
# is correct for every other scenario here and is exactly the assumption under
# test. Asking it would make this file pass by measuring the absence of a locker
# nobody asked for.
_cleanup_alt() {
  systemctl --user stop screen-lock.service >/dev/null 2>&1 || true
  pkill -x "$LOCKER" >/dev/null 2>&1 || true
  await 10 _alt_gone || true
}
_cleanup_alt

wire lock '' systemd-locker
# THE PROVIDER FILE IS `systemd-locker` NOW, named for the mechanism rather
# than for one locker, since this file is the proof it starts any. Done as the
# cross-repo change it is, shaped like hooklib.sh: tackup resolves the provider
# under EITHER name first (_provider_path), so no deploy order can leave
# `lock.d/10-swaylock` dangling, which would not fail but would make the lock
# provider cease to EXIST. The WIRED name is unchanged and still accurate: it
# is the integrator's label for what it wired on a box that runs swaylock.

VIGILANCE_LOCKER=$LOCKER; export VIGILANCE_LOCKER
VIGILANCE_LOCKER_ARGV=-n; export VIGILANCE_LOCKER_ARGV
VIGILANCE_LOCKER_TYPE=simple; export VIGILANCE_LOCKER_TYPE

# THE FOURTH KNOB, which this scenario is the reason for. i3lock checks
# WAYLAND_DISPLAY and refuses REGARDLESS of DISPLAY, and the unit inherits it
# from the manager because a Wayland session is told to import it there.
# Measured before the knob existed:
#
#   Started screen-lock.service - [systemd-run] /usr/bin/i3lock -n
#   i3lock: i3lock is a program for X11 and does not work on Wayland
#
# so the man page's own X11 example could not work on any box that had ever run
# a Wayland session. SETTING a variable was always possible by importing it into
# the manager, as DISPLAY is above; REMOVING one for a single unit had no
# mechanism at all, which is the asymmetry the knob closes.
VIGILANCE_LOCKER_UNSETENV=WAYLAND_DISPLAY
export VIGILANCE_LOCKER_UNSETENV

# --- 1. THE DOCUMENTED CONFIGURATION ACTUALLY LOCKS -------------------------
"$VIGILANT" go lock >>"$T/out" 2>>"$T/err" \
  || fail "the documented X11 configuration failed to cross the lock edge.
This is the man page's own example, so a reader following it gets an unlocked
screen and a failed unit:
$(tail -5 "$T/err" 2>/dev/null)
$(journalctl --user -u screen-lock.service -n 10 --no-pager 2>/dev/null)"

await 15 _alt_up || fail "the lock edge reported SUCCESS and no $LOCKER is
running. That is the worst available outcome: a provider that returns 0 while
the session is not secured, which is what lock-on-sleep.service believes before
letting the box suspend. Unit state:
$(systemctl --user is-active screen-lock.service 2>&1)
$(journalctl --user -u screen-lock.service -n 10 --no-pager 2>/dev/null)"

[ "$(depth)" = lock ] || fail "a real alternative locker came up but the ladder
records '$(depth)' rather than 'lock'"

# --- 2. AND THE VERIFIER FINDS IT, which is a separate claim ----------------
# `locker-up` asks systemd about the unit FIRST and falls back to the process
# name, so a locker started under a substituted name has to be found by one of
# those two. Nothing had ever checked that the fallback reaches a locker that is
# not swaylock, and the whole point of the knob is that it can be.
wire lock .verify locker-up
_v=$("$VIGILANT" verify lock 2>&1) || _vrc=$?
case "$_v" in
  *'NOTHING CHECKED'*)
    fail "the verify tier DECLINED on a box with a real locker up. 'I could not
look' reading as a pass is the conflation 78 exists to break, and here it would
certify an alternative locker that nothing had confirmed:
$_v" ;;
esac
[ "${_vrc:-0}" = 0 ] || fail "verify FAILED at rung 'lock' with a real $LOCKER
running. The verifier cannot see a locker that is not swaylock, so an integrator
on a substituted locker gets an alert on the security edge every minute about a
screen that is correctly locked:
$_v"

# --- 3. THE LOCKER DRIVES THE UNLOCK, NOT THE LADDER ------------------------
# MY FIRST VERSION OF THIS CASE ASSERTED A DEFECT, and the guest refused it:
# `go open` and then `i3lock SURVIVED the unlock edge`. The product was right
# and the assertion was wrong, in the direction that matters most.
#
# `vigilant go open` RECORDS a rung; it does not kill the locker, and it must
# not. The locker is what authenticates, so a ladder command that tore it down
# would be an unlock with no password: a security hole, demanded by a test. The
# provider says so in its own header, where `unlock detection -> ExecStopPost`
# is listed as a thing it deliberately does NOT do by hand.
#
# So the real chain is the other way round: the locker exits, its unit's cgroup
# empties, ExecStopPost runs `vigilant go open`, and the LADDER FOLLOWS. That is
# what to assert, and for a substituted locker nothing ever had: `fault-locker`
# drives it for swaylock only.
#
# SIGTERM RATHER THAN SIGKILL, because this models the AUTHENTICATED exit, which
# is a clean one. fault-locker owns the violent path and says why.
_alt_pid=$(pgrep -x "$LOCKER" | head -1)
[ -n "${_alt_pid:-}" ] || fail "no $LOCKER pid to terminate, so the teardown
chain below would be asserting against an already-empty unit"
kill -TERM "$_alt_pid" 2>/dev/null || true

await 20 _alt_gone || fail "$LOCKER ignored SIGTERM, so this case cannot say
anything about the teardown chain"
# AND THE LADDER FOLLOWED, which is the actual claim. The locker exiting has to
# reach the ladder through the unit's ExecStopPost, or the machine sits at
# 'lock' with nothing locking it: the record ahead of the world, which every
# tier that trusts the record would then agree with.
#
# A FUNCTION, because `await` takes a COMMAND. Handing it a string makes it
# look for a program of that name and time out into a failure about the
# product: a trap already in these notes, which I walked into writing this.
_at_open() { [ "$(depth)" = open ]; }
await 20 _at_open || true
[ "$(depth)" = open ] || fail "the locker exited and the ladder stayed at
'$(depth)'. ExecStopPost is the ONLY thing that detects an unlock here, since
the locker authenticates and vigilant never kills it, so a substituted locker
whose unit does not run it leaves the ladder claiming a lock that is gone:
$(journalctl --user -u screen-lock.service -n 10 --no-pager 2>/dev/null)"

# AND THE CROSSING IS ATTRIBUTED, which only a real unit can show. The label
# rides `--setenv` on the transient unit, so it reaches ExecStopPost through
# the unit's Environment rather than through any caller's: nothing in the stub
# tier can establish that, because there is no unit there to carry it.
#
# IT MATTERS MORE HERE THAN ANYWHERE. This is the ONLY route to an unlock
# (nothing watches for one), so an unattributed `cross unlock` cannot be told
# from a deliberate `go open`, and the question a reader brings to the log is
# exactly which of the two it was.
_ulog=$(logsince | grep 'cross unlock' | tail -1)
case "${_ulog:-}" in
  *"src=locker-exit"*) ;;
  *) fail "the unlock crossing was not attributed to the locker's exit:
'${_ulog:-<no cross unlock record at all>}'. The label travels on the unit, so
this failing means --setenv did not reach ExecStopPost, and every unlock on a
real box is then indistinguishable from a deliberate 'go open'" ;;
esac

# --- 4. THE WRONG TYPE MUST NOT READ AS A LOCK ------------------------------
# THE HAZARD THE KNOB EXISTS FOR, and the half that makes the other three more
# than a happy path. `Type=forking` asserts the locker DETACHES; i3lock with -n
# does not, so systemd-run waits for a fork that never comes. The documented
# consequence is that the provider reports failure about a screen that IS
# locked, or the per-hook bound kills it mid-wait.
#
# EITHER OUTCOME IS ACCEPTABLE AND SILENCE IS NOT. What must never happen is
# rc=0 with no locker, because that is the combination lock-on-sleep believes.
# So this asserts the DISJUNCTION rather than picking one, which is the honest
# shape when the substrate decides which of two correct answers you get.
_cleanup_alt
VIGILANCE_LOCKER_TYPE=forking; export VIGILANCE_LOCKER_TYPE
_frc=0
"$VIGILANT" go lock >>"$T/out" 2>>"$T/err" || _frc=$?
if [ "$_frc" = 0 ] && ! _alt_up; then
  fail "with Type=forking and a FOREGROUND locker the crossing returned 0 and
no locker is running. That is the exact false green this knob was added to
prevent: systemd-run waits for a fork that never comes, and reporting success
for it means lock-on-sleep lets the box suspend unlocked"
fi
_cleanup_alt
VIGILANCE_LOCKER_TYPE=simple; export VIGILANCE_LOCKER_TYPE

# --- 5. AND THE DEFAULT IS UNCHANGED ----------------------------------------
# A substituted locker must not have taught the provider anything. The knobs are
# read per invocation, so an integrator's setting cannot leak into a shipped
# box, and this is the cheapest assertion that the chain has no memory.
#
# ALL FOUR, AND I LEAKED THE FOURTH. The first version unset three and left
# VIGILANCE_LOCKER_UNSETENV exported, so the SHIPPED swaylock was started with
# `UnsetEnvironment=WAYLAND_DISPLAY` and could not reach the compositor. The
# case failed, correctly, about my own leak: the thing it is written to catch,
# one layer out. A list that has to be kept in step with a chain of knobs is
# itself the hazard, so it is derived rather than retyped.
for _k in LOCKER LOCKER_ARGV LOCKER_TYPE LOCKER_UNSETENV; do
  unset "VIGILANCE_$_k"
done
_drc=0
"$VIGILANT" go lock >>"$T/out" 2>>"$T/err" || _drc=$?
await 15 locker_up || fail "with the knobs unset the provider did not bring the
SHIPPED locker up (rc=$_drc). A substitution must not change what a default box
does:
$(journalctl --user -u screen-lock.service -n 10 --no-pager 2>/dev/null)"
"$VIGILANT" go open >>"$T/out" 2>>"$T/err" || true
_cleanup_alt

pass "a real i3lock locks, verifies, tears down; wrong Type is not a lock"
