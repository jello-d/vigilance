#!/bin/sh
# test/session-wayfire.t - the SELF-LIMIT, against the compositor production
# actually runs.
#
# THE GAP THIS CLOSES, and it is embarrassing to write down. The `wayfire`
# capability has been claimed by the guest since 2026-09-27 and REQUIRED BY
# NOTHING: `session_init` asks for `compositor`, which is satisfied by the sway
# that runs as root. So every session scenario in this suite has only ever run
# against sway, while both live boxes run Wayfire, and the founding failure of
# this whole package is Wayfire-specific ("it WEDGES on this Wayfire build").
# A capability that is claimed and required by nothing is a line of output that
# reads like coverage.
#
# WHAT IS ACTUALLY AT STAKE HERE. `sway-dpms` is wired in MACHINE scope, which
# means it is offered to the greeter AND to the user session alike, and in a
# Wayfire session powering an output off re-modesets and was observed to DESTROY
# VIEWS. The hook's own header rests the entire safety of that wiring on one
# sentence:
#
#     "SELF-LIMITING BY CONSTRUCTION. The gate is the tool: `swaymsg` can only
#      talk to sway, so in a Wayfire session it simply fails and this declines.
#      That is what makes the hook safe to wire in MACHINE scope ... There is no
#      host list to keep in sync and no way to get the answer wrong."
#
# THAT CLAIM HAS NEVER BEEN TESTED. It is the argument that permits the wiring,
# and it was reasoned rather than measured, which is the pattern behind most of
# the defects in these notes (the "silently ignores it" swaylock key, the
# "does not self-locate" claim, the black lock surface that did not exist).
#
# THE PAIR IS THE TEST, not either half. "It declines in Wayfire" passes just as
# well for a hook that declines everywhere, which is why case 4 drives the SAME
# hook at the SAME edge in root's sway and requires it to ACT. Same binary, same
# argument, two environments, opposite answers: that is a measurement of the
# GATE rather than of an outcome.
#
# AND THE PRECONDITION IS ASSERTED FIRST, because a decline has more than one
# cause. If wayfire were not up, or swaymsg were absent, the hook would decline
# for a reason that says nothing about Wayfire, and the case would pass for
# somebody else's reason. That is the shape this suite has shipped three times
# ("rc=127 wearing the costume of a declined hook").
#
# WHAT THIS TIER STILL CANNOT ANSWER, said here rather than discovered later:
# the guest's wayfire runs headless with `plugins = ` and has no views, so the
# destroy-views hazard itself is not reproduced. This asserts that the hook
# never gets far enough to try, which is the guarantee the wiring depends on.
#
# AND IT DELIBERATELY RUNS AS ROOT, NOT AS THE SESSION'S USER, which is the
# opposite of the obvious choice and is the stronger claim. Root can reach
# strictly more than vig can, so a decline under root cannot be caused by a
# permission vig lacks. The first version of this file did use `sudo -u vig`
# and FAILED with rc=2 and "cannot open .../hooks/sway-dpms: Permission
# denied": the guest installs from a checkout under /root, which vig cannot
# traverse. That is a real finding about machine-scope hook targets, it is
# already recorded, and test/probe/greeter-observe asks it on real hardware as
# the only uid that can answer it. It is NOT this question, and letting it
# share a case would mean a decline with two possible causes.
#
# THE GATE IS NOT THE UID, IT IS THE ENVIRONMENT: swaymsg finds sway through
# SWAYSOCK or by looking in XDG_RUNTIME_DIR, so a Wayfire session is modelled
# by vig's runtime dir with no sway IPC socket in it and no SWAYSOCK set. Both
# halves of that are asserted before anything is invoked.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-wayfire
require wayfire

PLUG=$PLUGINS/hooks
STATE=$T/state
mkdir -p "$STATE"
# THE INSTRUMENT MUST BE READABLE, or a decline below is about the filesystem.
# This is the assertion the first version of this file lacked, and it cost a
# whole VM run: `sh` cannot open a script it may not read, and its rc=2 is
# indistinguishable from a hook that died for its own reasons.
[ -r "$PLUG/sway-dpms" ] || fail "cannot read $PLUG/sway-dpms, so every
invocation below would fail on the filesystem rather than on the compositor"

_cleanup() {
  # ROOT'S SWAY IS LEFT LIT. Case 4 deliberately powers its outputs off, and a
  # scenario that exits with them off hands every later compositor scenario in
  # this boot a state it did not choose.
  swaymsg "output * dpms on" >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

# --- 1. LOCATE THE WAYFIRE SESSION, and prove it is one ---------------------
# Discovered rather than passed in: the guest exports nothing about vig to the
# scenarios, and a hardcoded uid would rot the first time the image changed.
_vuid=$(id -u vig 2>/dev/null) || fail "no vig account despite the wayfire
capability, so this scenario has no Wayfire session to test against"
_vrun=/run/user/$_vuid
_wl=$(ls "$_vrun"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1 || true)
[ -n "$_wl" ] || fail "no wayland socket in $_vrun. The wayfire capability was
claimed, so either the session died after the probe or the probe is wrong; and
without a compositor every decline below would be about its absence"

pgrep -u "$_vuid" -x wayfire >/dev/null 2>&1 || fail "the wayland socket in
$_vrun exists but no wayfire process owns it, so this is a stale socket rather
than a session"

# THE PRECONDITION THAT MAKES THE DECLINE MEAN SOMETHING. Two ways the case
# could pass for the wrong reason, both excluded here:
#
#   swaymsg ABSENT      the hook declines on `command -v`, which is a true
#                       decline about a missing tool and no statement at all
#                       about Wayfire.
#   A SWAY IPC SOCKET   in vig's runtime dir would let swaymsg connect, and
#                       then the hook would ACT in the Wayfire session, which
#                       is the hazard rather than the safety.
command -v swaymsg >/dev/null 2>&1 || fail "swaymsg is absent, so sway-dpms
would decline on the tool rather than on the compositor and case 3 would prove
nothing about Wayfire"
_ipc=$(ls "$_vrun"/sway-ipc.* 2>/dev/null | head -1 || true)
[ -z "$_ipc" ] || fail "there is a sway IPC socket in the WAYFIRE session's
runtime dir ($_ipc). swaymsg would reach it, so the gate this file exists to
verify is open and the hook could act where an output off destroys views"

# --- 2. THE WAYFIRE SESSION'S ENVIRONMENT, BUILT NOT INHERITED --------------
# `env -u SWAYSOCK` is the load-bearing word. This scenario's own environment
# HAS a live SWAYSOCK, pointing at root's sway, because the guest exports it so
# the compositor scenarios can work. Inheriting it would let swaymsg reach that
# compositor from inside what is supposed to be a Wayfire session, the hook
# would act, and the case would report the hazard as the safety.
_wfenv() {   # run the hook as a Wayfire session would see the world
  env -u SWAYSOCK -u I3SOCK XDG_RUNTIME_DIR="$_vrun" \
    WAYLAND_DISPLAY="$(basename "$_wl")" XDG_SESSION_TYPE=wayland \
    VIGILANCE_STATE_DIR="$STATE" VIGILANCE_KIND="${2:-act}" \
    sh "$PLUG/sway-dpms" "$1"
}

_swayoff() {   # how many of root's sway outputs are powered off
  swaymsg -t get_outputs 2>/dev/null | tr ',' '\n' \
    | awk '/"dpms"/ { if ($0 !~ /true/) n++ } END { print n + 0 }'
}

# --- 3. THE SELF-LIMIT: a dark edge in a Wayfire session must DECLINE -------
_before=$(_swayoff)
_rc=0
_wfenv sleep act >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 78 ] || fail "sway-dpms exited $_rc at a dark edge inside a REAL
Wayfire session. 78 is the only safe answer: 0 would claim it darkened a screen
it cannot reach, and 1 would raise a hook failure on every descent of every
Wayfire box the machine scope is wired on. The entire argument for wiring this
hook where a Wayfire session can see it is that it cannot act there:
$(cat "$T/out")"

# AND IT MUST NOT HAVE ACTED SOMEWHERE ELSE, which is the half an exit status
# cannot answer. root's sway is live and reachable from this guest, so if
# swaymsg found ANY compositor it would be that one: its outputs going dark is
# the signature of a hook that crossed a session boundary.
_after=$(_swayoff)
[ "$_after" = "$_before" ] || fail "sway-dpms declined 78 in the Wayfire
session and root's sway now reports $_after outputs off (was $_before). It
reached a compositor it was never invoked for, so the decline was about the
wrong thing and the gate leaks across sessions"

# --- 3b. WHICH TERM GATES IT, measured rather than assumed -------------------
# Case 3 changes two things at once (no SWAYSOCK, and a runtime dir with no
# sway IPC in it), so on its own it cannot say which one held the gate shut.
# Putting root's SWAYSOCK back while KEEPING the Wayfire runtime dir isolates
# that, and the answer is a real caveat for an integrator rather than a defect:
# the self-limit holds because a Wayfire session does not export a SWAYSOCK, so
# anything that exported one into such a session would open the gate. Worth
# knowing, and it is the strongest available evidence that `env -u SWAYSOCK`
# above is load-bearing rather than decorative.
if [ -n "${SWAYSOCK:-}" ]; then
  _lrc=0
  env XDG_RUNTIME_DIR="$_vrun" VIGILANCE_STATE_DIR="$STATE" \
    VIGILANCE_KIND=act sh "$PLUG/sway-dpms" sleep >"$T/out3" 2>&1 || _lrc=$?
  [ "$_lrc" = 0 ] || fail "with root's SWAYSOCK restored the hook still exited
$_lrc, so case 3's decline cannot be attributed to the absent socket and the
gate's mechanism is not what this file claims: $(cat "$T/out3")"
  _leak=$(_swayoff)
  [ "$_leak" != 0 ] || fail "the hook returned 0 with a reachable SWAYSOCK and
no output went dark, so nothing here distinguishes acting from declining"
else
  echo "  (3b skipped: this scenario has no SWAYSOCK to leak)"
fi

# --- 4. THE DISCRIMINATING HALF: the same hook DOES act where sway is -------
# WITHOUT THIS THE FILE IS VACUOUS. A hook that declined unconditionally, or one
# broken in any way at all, passes case 3 perfectly. The claim is that the TOOL
# is the gate, and a gate is only demonstrated by driving it both ways.
swaymsg "output * dpms on" >/dev/null 2>&1 || fail "fixture: could not relight
root's sway outputs, so the acting half has nothing to change"
[ "$(_swayoff)" = 0 ] || fail "fixture: root's sway still reports outputs off
before the acting case"
_arc=0
env VIGILANCE_STATE_DIR="$STATE" VIGILANCE_KIND=act \
  sh "$PLUG/sway-dpms" sleep >"$T/out2" 2>&1 || _arc=$?
[ "$_arc" = 0 ] || fail "the SAME hook at the SAME edge failed in root's sway
session (rc=$_arc), so case 3's decline cannot be attributed to Wayfire: a hook
that is simply broken declines everywhere: $(cat "$T/out2")"
[ "$(_swayoff)" != 0 ] || fail "sway-dpms returned 0 in a sway session and no
output reports dpms off. A silent no-op reporting success is the defect shape
this suite has caught twice, and here it would also make case 3 meaningless"

# --- 5. THE SESSION SURVIVED BEING PROBED -----------------------------------
# Cheap, and it is the thing later scenarios in this boot depend on: fault-lid
# and fault-storm both need a lockable vig session, and a probe that killed it
# would make their failures look like their own.
pgrep -u "$_vuid" -x wayfire >/dev/null 2>&1 || fail "wayfire is NO LONGER
running after this scenario. Whatever did that, every later scenario needing
the vig session will now fail for a cause that is not theirs"

pass "the gate is the tool: declined 78 under wayfire, acted under sway"
