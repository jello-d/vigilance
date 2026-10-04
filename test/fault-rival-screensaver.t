#!/bin/sh
# test/fault-rival-screensaver.t - a rival that ANSWERS, which is the half the
# widening rests on and the half a fixture cannot establish.
#
# THE DISTINCTION FROM fault-rival-locker.t, which is the whole reason this is
# a second cell rather than a case in that one. There the rival is i3lock: a
# real foreign locker that answers NOTHING, so the only honest assertions are
# the preconditions and the recovery, and the detection signals are printed
# rather than asserted. Here the rival IMPLEMENTS the interface report now
# asks, so detection itself becomes assertable for the first time.
#
# WHY IT MATTERS MORE THAN AN EXTRA CASE. `_screensaver_active` was shipped
# with all three of its outcomes covered by `VIGILANCE_SCREENSAVER`, which is a
# knob holding MY model of a rival. That is exactly the shape this project has
# paid for repeatedly: the lock unit's state was modelled as a boolean, so the
# fixture could not express `activating`, which is precisely what the code also
# failed to consider, and both agreed while the live box failed. Worse here,
# because the design this replaced was retracted the same day for having a
# measured-false premise: logind's `LockedHint`, which NONE of the canonical
# rivals sets. A probe chosen from one measurement should not then be verified
# against an assumption.
#
# THE RIVAL IS A REAL PACKAGE, UNSTUBBED. A hand-written D-Bus service would be
# a fixture wearing a bus name, which is the thing being escaped. light-locker
# and xfce4-screensaver both carry GetActive/SetActive/ActiveChanged (measured
# over the real .deb payloads), and the xfce flavour pulls one of them through
# xfce4-session's Recommends, so the substrate supplies the subject.
#
# WHAT IS ASSERTED, and the spread is the point: all three outcomes of the probe
# against the SAME real implementation. A rival merely running must read as the
# idle pass, the same rival made active must WARN, and the rival going away must
# return to the cannot-tell pass. One real owner moving through every branch is
# a stronger claim than three fixture values, because the thing being tested is
# whether the probe reads a real implementation correctly.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"

session_init fault-rival-screensaver
require x11

# THE FIXTURE MUST NOT BE IN SCOPE HERE, and this is insurance rather than a
# fix: session_init does not export VIGILANCE_SCREENSAVER today (checked), but
# scenario_init DOES, and the equivalent trap has already been paid for once,
# when a new case in locker-up.t was short-circuited by an inherited
# VIGILANCE_LOCKER_UP it never mentioned. A cell whose whole subject is the
# REAL probe must not be reachable by the knob that replaces it.
unset VIGILANCE_SCREENSAVER

SS_NAME=org.freedesktop.ScreenSaver
SS_PATH=/org/freedesktop/ScreenSaver
RIVAL_DISPLAY=:98

# THE PROBE MUST SEE THE SAME BUS THE RIVAL JOINS, or this cell measures two
# unrelated things and reports the difference as a defect. Both sides use the
# user bus of whoever runs them, so it is pinned once here and printed, because
# "the rival was up and the probe saw nothing" has two causes and only one of
# them is interesting.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# `--acquired` and not the default list, for the same reason the probe itself
# uses it: the default includes ACTIVATABLE names, and a name that is merely
# activatable is not an owner. Reading one as an owner here would make the cell
# pass against a rival that never started. Defined ABOVE the cleanup because the
# cleanup calls it, and the cleanup runs before the rest of the file.
_owned_any() {
  busctl --user list --acquired --no-legend --no-pager 2>/dev/null \
    | awk '$1 ~ /[Ss]creen[Ss]aver/ { print $1 }' | head -1
}
_took_a_name() { [ -n "$(_owned_any)" ]; }

# Called FIRST as well as last, the convention this tier settled on: `fail`
# exits, so an end-of-file cleanup alone would leave a screensaver daemon owning
# the bus name for every later scenario in the boot, which would silently change
# what `report` says in all of them. Idempotent.
#
# NEVER `pkill -x` HERE, and this cost a run to learn: /proc/<pid>/comm is
# truncated to 15 bytes and `xfce4-screensaver` is 17, so an exact-name kill can
# NEVER match it. The cleanup silently did nothing, the rival kept answering,
# and the cell then failed about the PRODUCT while the product was right. Third
# instance of the comm-truncation trap in this project, and the first in my own
# cleanup rather than in a check. Matched on the full argv instead, anchored so
# the pattern cannot catch this test's own command line.
#
# AND THE NAME IS WATCHED, not the process: the only thing that matters is that
# nothing owns it when the next scenario runs, and the rival ships a D-Bus
# service file, so it is ACTIVATABLE and could come back if anything calls it.
_cleanup_rival() {
  for _r in light-locker xfce4-screensaver xscreensaver; do
    pkill -f "(^|/)$_r( |\$)" >/dev/null 2>&1 || true
  done
  _n=0
  while _took_a_name && [ "$_n" -lt 25 ]; do _n=$((_n + 1)); sleep 0.2; done
}

_getactive() {
  timeout 3 busctl --user call "$SS_NAME" "$SS_PATH" "$SS_NAME" \
    GetActive 2>&1 || true
}

_coh() {   # the coherence section only, for EVIDENCE in a failure message
  "$VIGILANT" report 2>/dev/null \
    | awk '/^-- coherence --$/ { f = 1; next } /^-- / { f = 0 } f' || true
}

# AND THE ONE LINE THE ASSERTIONS MATCH ON, which is a correctness requirement
# rather than tidiness. A SHELL GLOB SPANS NEWLINES, so a `case` over the whole
# section matches a marker from ANY line in it: the first version of this cell
# failed claiming "a screensaver merely running made coherence warn" when the
# [WARN] it had found was an unrelated neighbour ("verify: n/a for edge
# 'unlock'") and the rung line was a perfectly correct [OK]. That trap is
# already recorded in these notes from a severity assertion two weeks ago, and
# this cell paid for it again. Scope a severity assertion to the LINE.
_cohdepth() {   # the coherence line about rung `open`, and nothing else
  _coh | grep -E "depth (says )?'open'" | head -1
}

_cleanup_rival
trap _cleanup_rival EXIT

# --- 1. THE LADDER IS AT `open`, WHICH IS THE ONLY RUNG THAT ASKS ------------
# The probe is consulted nowhere else, and for a measured reason: every route
# to `sleep` crosses `lock` on the way, so a screensaver being active at a dark
# rung is coherent rather than a desync. A cell that drifted off `open` would
# assert nothing while still passing.
"$VIGILANT" go open >/dev/null 2>&1 || true
[ "$(depth)" = open ] || fail "the ladder is at '$(depth)', not 'open', so the
rung that consults the screensaver probe is not the one under test"

# --- 2. THE RIVAL, AND IT MUST ACQUIRE THE NAME ------------------------------
# PRINTED BEFORE ANY VERDICT. Three things can go wrong between "the package is
# installed" and "the probe can ask it", and the bare precondition sentence
# cannot say which: the binary may be absent, it may start and exit, or it may
# start and never take the name. Each needs a different answer from whoever
# reads this, so the evidence goes out first.
# THE RIVAL NEEDS A SESSION ID, which is a fact about the rival and was learned
# by running it: light-locker asks logind for the session of its own pid, and
# this tier is root with no graphical session, so it exited with
#
#   ERROR: session_id is not set, is /proc mounted with hidepid>0?
#
# Its own message names the way out ("Falling back to XDG_SESSION_ID
# environment variable"), so it is handed one. THAT IS NOT FAKING ANYTHING
# UNDER TEST: a real desktop session exports XDG_SESSION_ID, so this supplies
# the environment the rival would have in production and nothing more. The
# SEATED session is preferred, because a seatless manager session is the one
# logind will not lock and picking it was a defect in `logind-hint` once.
_ssid=$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk '$4 != "" && $4 != "-" { print $1; exit }')
[ -n "$_ssid" ] || _ssid=$(loginctl list-sessions --no-legend 2>/dev/null \
                           | awk '{ print $1; exit }')
[ -z "$_ssid" ] || export XDG_SESSION_ID=$_ssid

echo "--- the rival, before any assertion ---"
echo "bus:        $DBUS_SESSION_BUS_ADDRESS"
echo "display:    $RIVAL_DISPLAY"
echo "session:    ${XDG_SESSION_ID:-<none; the rival may refuse to start>}"
_cands=
for _r in light-locker xfce4-screensaver xscreensaver; do
  if command -v "$_r" >/dev/null 2>&1; then
    _cands="$_cands $_r"
    echo "installed:  $_r ($(command -v "$_r"))"
  else
    echo "absent:     $_r"
  fi
done

if [ -z "$_cands" ]; then
  # DEMONSTRATED, which is what the skip contract requires: every candidate was
  # looked for by name and none exists, so there is no rival to test and
  # nothing below would be a statement about vigilance.
  skip_now a-screensaver-rival "no package implementing $SS_NAME is installed\
 here (looked for light-locker, xfce4-screensaver and xscreensaver), so there\
 is no real implementation of the interface to ask. The lean flavour is this\
 case; the xfce flavour pulls one through xfce4-session's Recommends"
fi

# ANY ScreenSaver NAME COUNTS, and finding out which is the point rather than a
# convenience. xfce4-screensaver ships
# /usr/share/dbus-1/services/org.xfce.ScreenSaver.service, so it owns
# `org.xfce.ScreenSaver` while implementing the FREEDESKTOP interface
# (GetActive/SetActive/ActiveChanged). Measured: starting it acquired no
# org.freedesktop.ScreenSaver at all.
#
# SO THE DEFAULT NAME MISSES THIS RIVAL, and that is a real statement about the
# probe's reach rather than a wrinkle in the test: on an xfce box the integrator
# has to set VIGILANCE_SCREENSAVER_NAME, which is why that knob exists. This
# cell therefore discovers the name, points the probe at it, and so exercises
# the knob and the rival together.
RIVAL=
for _r in $_cands; do
  # `env -u WAYLAND_DISPLAY` IS LOAD-BEARING, and measured rather than
  # defensive. This tier exports WAYLAND_DISPLAY for the compositor, and a
  # GTK rival finding it selects the Wayland backend and refuses outright:
  #
  #   xfce4-screensaver-WARNING **: Unsupported windowing environment
  #
  # Exactly the trap session-locker-alt.t paid for with i3lock, whose own
  # refusal message named the cause in one line. An X11 rival has to be given
  # an X11-only environment or it never reaches the bus at all.
  env -u WAYLAND_DISPLAY DISPLAY=$RIVAL_DISPLAY "$_r" >/tmp/rival-ss.out 2>&1 &
  _rpid=$!
  if await 15 _took_a_name; then RIVAL=$_r; break; fi
  echo "did NOT take any ScreenSaver name: $_r"
  # THE ACQUIRED LIST IS THE EVIDENCE. Without it a silent rival gives no cause
  # at all, which is what the previous run produced: the Wayland fix removed the
  # warning and left nothing to read, so the next step was a guess. Printing
  # what the bus actually holds removes the guessing.
  sed 's/^/    /' /tmp/rival-ss.out | head -6
  echo "    bus names held (any owner): $(busctl --user list --acquired \
    --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\n' ' ' \
    | cut -c1-200)"
  kill "$_rpid" >/dev/null 2>&1 || true
  pkill -x "$_r" >/dev/null 2>&1 || true
done

if [ -z "$RIVAL" ]; then
  # ALSO DEMONSTRATED, and a different finding from the one above: the package
  # IS here and did not become an owner. That is a fact about the rival rather
  # than about vigilance, so it declines rather than failing, and it prints
  # what each candidate said so the next run does not have to re-derive it.
  # THE CAUSE IS NAMED FROM THE RIVAL'S OWN OUTPUT, printed above, rather than
  # guessed at. The first version of this message blamed lightdm, which was a
  # confident wrong diagnosis: the measured blocker was a missing logind
  # session_id, and a reader sent to install a display manager would have been
  # chasing the wrong thing entirely.
  skip_now a-screensaver-owner "a rival is installed but none ACQUIRED\
 $SS_NAME; its own output is above and names the cause. This is a property of\
 the rival in this context, not a verdict about the probe, so the cell declines\
 rather than failing"
fi
# POINT THE PROBE AT WHAT THE RIVAL ACTUALLY OWNS, through the shipped knob
# rather than by reaching into the runner. If the rival took the default name
# this changes nothing; if it took the xfce one, this is the integrator's own
# remedy being exercised, and the probe is still doing the real work.
_held=$(_owned_any)
if [ "$_held" != "$SS_NAME" ]; then
  echo "NOTE:       the rival owns $_held, NOT the default $SS_NAME, so the"
  echo "            probe is pointed at it through VIGILANCE_SCREENSAVER_NAME"
  echo "            (which is what an xfce integrator has to do)"
  SS_NAME=$_held
  SS_PATH=/$(printf '%s' "$SS_NAME" | tr . /)
  export VIGILANCE_SCREENSAVER_NAME=$SS_NAME
fi
echo "ACQUIRED:   $SS_NAME by $RIVAL"
echo "GetActive:  $(_getactive)"
echo "--- end rival ---"

# --- 3. A RIVAL MERELY RUNNING IS THE IDLE PASS ------------------------------
# The outcome almost every reader on such a desktop sees, and it has to stay
# quiet or the widening cries wolf on every box that merely HAS a screensaver.
# Asserted against a real GetActive rather than a knob, which is this cell's
# whole purpose: the fixture agreed with its author by construction.
_o=$(_cohdepth)
case "$_o" in
  *'[OK]'*"$SS_NAME"*idle*) ;;
  *'[WARN]'*)
    fail "a screensaver that is merely RUNNING made coherence warn. That fires
on every desktop with a screensaver installed and nothing wrong, which is how a
report stops being read:
$_o
--- the whole section ---
$(_coh)" ;;
  *) fail "with a real owner of $SS_NAME answering GetActive=false, coherence
did not report the idle pass that names what answered:
$_o
--- the whole section ---
$(_coh)
GetActive said: $(_getactive)" ;;
esac

# --- 4. THE SAME RIVAL, MADE ACTIVE, MUST WARN -------------------------------
# THE ASSERTION THIS CELL EXISTS FOR. Until now the WARN path had been driven
# only through VIGILANCE_SCREENSAVER=active, which is a value I chose; this
# drives a real implementation into a real active state and asks report.
#
# SetActive IS THE RIVAL'S OWN INTERFACE, not a poke at its internals: the same
# method an application calls to ask the screensaver to engage, so this is the
# ordinary way that state is reached rather than a contrivance.
timeout 5 busctl --user call "$SS_NAME" "$SS_PATH" "$SS_NAME" \
  SetActive b true >/dev/null 2>&1 || true
_active() { case $(_getactive) in *'b true'*) return 0 ;; esac; return 1; }
if ! await 10 _active; then
  # NOT A FAILURE OF VIGILANCE, and saying so is the difference between a
  # finding and noise: the rival declined to go active, so the branch cannot be
  # reached on this substrate and the cell must not claim it was.
  skip_now a-screensaver-activating "$RIVAL owns $SS_NAME but would not report\
 ACTIVE after SetActive true (GetActive: $(_getactive)), so the finding branch\
 is unreachable here. The idle and no-owner outcomes above did run"
fi
_o=$(_cohdepth)
case "$_o" in
  *'[WARN]'*ACTIVE*'behind the world'*) ;;
  *'[FAIL]'*)
    fail "a foreign screensaver was reported as a FAIL. _r_bad sets RRC=1, so
every box whose desktop raises its own screensaver with this ladder at 'open'
would report non-zero for ever:
$_o
--- the whole section ---
$(_coh)" ;;
  *) fail "A REAL rival owns $SS_NAME and reports the screen ACTIVE with the
ladder at 'open', and coherence did not say so. That is the entire gap the
widening was built to close, and the fixture-driven case in report.t passes
while this does not, which is the fixture agreeing with its author:
$_o
--- the whole section ---
$(_coh)
GetActive said: $(_getactive)" ;;
esac

# --- 5. AND IT MUST GO QUIET AGAIN -------------------------------------------
# A finding that cannot clear is indistinguishable from a stuck check, and this
# one is read by a human on every report. Driven by the rival's own interface
# again rather than by killing it, so the only thing that changed is the state
# the probe asks about.
timeout 5 busctl --user call "$SS_NAME" "$SS_PATH" "$SS_NAME" \
  SetActive b false >/dev/null 2>&1 || true
_idle() { case $(_getactive) in *'b false'*) return 0 ;; esac; return 1; }
if await 10 _idle; then
  _o=$(_cohdepth)
  case "$_o" in
    *'[WARN]'*) fail "the rival returned to idle and coherence still warns. A
finding that outlives its cause is a stuck check, and it trains a reader to
discount the one that matters:
$_o
--- the whole section ---
$(_coh)" ;;
  esac
fi

# --- 6. THE RIVAL GONE IS THE CANNOT-TELL PASS, NOT A CLEAN BILL ------------
# The third outcome, and the one every box in this fleet produces. It must keep
# NAMING what it cannot see: reading an absent owner as "unlocked" is the
# could-not-look conflation the whole section was corrected for.
_cleanup_rival
_o=$(_cohdepth)
case "$_o" in
  *'[OK]'*'nothing owns'*'not visible here'*) ;;
  *) fail "with the rival gone and nothing owning $SS_NAME, coherence must say
so and keep naming the bound rather than certifying the session:
$_o
--- the whole section ---
$(_coh)" ;;
esac

# --- 7. RECOVERY: the ladder still works afterwards --------------------------
# The convention every cell in this tier carries, because a recovery that
# leaves the ladder unable to lock has converted a transient fault into a
# permanent one. ASSERTED ON THE EDGE, never on the resting depth: a headless
# guest's locker cannot survive, its ExecStopPost unwinds the ladder seconds
# later, and three scenarios here have already had to learn that.
_relocked() { [ "$(crossed lock)" -ge 1 ]; }
"$VIGILANT" go lock atleast >/tmp/rival-ss-relock.out 2>&1 || true
if ! await 15 _relocked; then
  fail "after a rival screensaver came and went, the ladder could not cross
'lock'. A transient rival must not leave the machine unlockable:
$(sed 's/^/    /' /tmp/rival-ss-relock.out)"
fi

pass "a REAL $SS_NAME owner ($RIVAL) through all three probe outcomes, and the\
 ladder still locks"
