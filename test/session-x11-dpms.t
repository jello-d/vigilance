#!/bin/sh
# test/session-x11-dpms.t - x11-dpms against a REAL DPMS, for the first time.
#
# THE GAP THIS CLOSES. `x11-dpms` shipped with its act and verify paths
# exercised nowhere: not on either live box, which are both Wayland, and not in
# the guest, where Xvfb is compiled WITHOUT the DPMS extension so the only
# branch reachable was the 78 decline. session-x11.t asserts exactly that
# decline, deliberately, and it stays: absent-is-not-disabled is a real case
# and Xvfb is a real server that has it. What it cannot do is prove the hook
# WORKS.
#
# WHAT IT TOOK, because two obvious substrates do not have DPMS at all:
#
#   Xvfb   +extension DPMS      "Server does not have the DPMS Extension"
#   Xephyr                      the same; nesting inherits nothing
#   Xorg + Driver "dummy"       (WW) DUMMY(0): Option "DPMS" is not used
#                               (II) Initializing extension DPMS
#   Xorg + modesetting on DRM   (**) modeset(0): DPMS enabled     <- this one
#
# The dummy pair is the instructive one: the EXTENSION initialises and no screen
# is DPMS-capable, so `xset q` prints no DPMS block and there is nothing to
# drive. THE DRIVER REGISTERS DPMS, not the server. qemu gives the guest a real
# /dev/dri/card0, so `modesetting` on it is a real DPMS backed by real DRM, and
# the harness claims the `x11dpms` capability only after watching a force
# off/on round-trip.
#
# DIRECT HOOK INVOCATION, as session-x11.t does. The question here is whether
# the HOOK works against a real server, and the ladder's own wiring is covered
# by other scenarios; putting this through a crossing would also fight whatever
# else is wired into the machine scope in this boot.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-x11-dpms
require x11dpms

DISPLAY=:98; export DISPLAY
PLUG=$PLUGINS/hooks
STATE=$T/state
mkdir -p "$STATE"
# NEVER THROTTLED HERE. `hook_throttle` would answer 75 (not due) on the second
# verify in the same hour and every case after the first would be asserting
# against a skip. A shipped knob, not a probe override.
VIGILANCE_PERIPHERAL_EVERY=0; export VIGILANCE_PERIPHERAL_EVERY

# THE SERVER IS LEFT ON AND ENABLED, whatever happens. A scenario that exits
# with DPMS off or disabled hands every later X11 scenario in this boot a server
# in a state it did not choose, and case 5 deliberately disables it.
_cleanup() {
  xset +dpms >/dev/null 2>&1 || true
  xset dpms force on >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

# READ THE SERVER DIRECTLY, never through the hook: a hook that both acts and
# reports on itself can be wrong and agree with itself.
_mon() { xset q 2>/dev/null | sed -n 's/.*Monitor is *//p' | head -1; }
_hook() {   # <edge> [kind] -> rc, output on $T/out
  _h_rc=0
  env VIGILANCE_STATE_DIR="$STATE" VIGILANCE_KIND="${2:-act}" \
    sh "$PLUG/x11-dpms" "$1" >"$T/out" 2>&1 || _h_rc=$?
  return "$_h_rc"
}

xset q >/dev/null 2>&1 || fail "no X server on $DISPLAY despite the x11dpms
capability, so nothing below is a measurement"
case "$(xset q | sed -n 's/.*DPMS is //p' | head -1)" in
  Enabled) ;;
  *) fail "DPMS is not Enabled on $DISPLAY at the start. The capability is
claimed only after a force off/on round-trip, so this is the substrate changing
under the scenario rather than the hook's doing" ;;
esac

# --- 1. THE ACT PATH, dark, against a real DPMS -----------------------------
xset dpms force on >/dev/null 2>&1 || true
[ "$(_mon)" = On ] || fail "fixture: the monitor is '$(_mon)' rather than On
before the descent, so a later Off would prove nothing"
_hook sleep || fail "the act path failed at a dark edge (rc above). This is the
first time it has run against a real DPMS anywhere: $(cat "$T/out")"
_m=$(_mon)
case "$_m" in
  Off|Standby|Suspend) ;;
  *) fail "after the dark edge the server reports 'Monitor is $_m'. The hook
returned 0, so it believes it acted; the monitor disagrees, which is exactly the
asserted-versus-actual gap this package exists to find" ;;
esac

# --- 2. THE VERIFY PATH AGREES, and it really looked ------------------------
# rc 0 is not enough on its own: 75 (not due) and 78 (n/a) are also not
# failures, and either would mean the tier never asked the server. The throttle
# is off above, so a 75 here would be a bug in its own right.
# `$?` AFTER AN `|| fail` IS THE LIST'S STATUS, not the command's, so a second
# check reading it here could only ever see 0: a vacuous assertion of the kind
# this suite has shipped three times. The `|| fail` is the whole check.
_hook sleep verify || fail "the verify tier disagreed with the act tier it just
followed, at a dark rung with the monitor reading '$(_mon)': $(cat "$T/out")"

# --- 3. IT CATCHES DRIFT, which is the whole point of a readback -------------
# Behind vigilance's back, exactly as a competing actuator or a stray xset would
# do it. Without this the verify could be a constant and nothing would tell.
xset dpms force on >/dev/null 2>&1 || true
[ "$(_mon)" = On ] || fail "fixture: could not relight the monitor, so the drift
case has no drift in it"
_drc=0
_hook sleep verify || _drc=$?
[ "$_drc" = 1 ] || fail "the monitor was forced back On at a dark rung and the
verify exited $_drc. A readback that cannot report drift is a decoration:
$(cat "$T/out")"
grep -q 'monitor is On' "$T/out" || fail "the verify failed without naming what
it read. 'drift' alone sends a reader hunting; the state is the diagnosis:
$(cat "$T/out")"

# --- 4. AND THE LIT DIRECTION, act and verify -------------------------------
_hook wake || fail "the act path failed at a lit edge: $(cat "$T/out")"
[ "$(_mon)" = On ] || fail "after the lit edge the monitor reads '$(_mon)'"
_hook wake verify || fail "the lit verify disagreed with the lit act:
$(cat "$T/out")"

# --- 5. DISABLED AT THE SERVER IS A REFUSAL, not a no-op --------------------
# THE BRANCH NO SUBSTRATE COULD REACH BEFORE. Xvfb gives "absent", which is 78;
# only a server that HAS DPMS can have it switched off. With DPMS disabled,
# `xset dpms force off` returns 0 and the screen stays lit, so treating it as
# success would be a clean crossing over a lit screen: the exact shape this
# package exists to refuse. A dark rung must REFUSE and say how to fix it.
xset -dpms >/dev/null 2>&1 || fail "could not disable DPMS, so case 5 cannot
distinguish disabled from absent"
case "$(xset q | sed -n 's/.*DPMS is //p' | head -1)" in
  Disabled) ;;
  *) fail "asked the server to disable DPMS and it still reports
'$(xset q | sed -n 's/.*DPMS is //p' | head -1)'" ;;
esac
_rrc=0
_hook sleep || _rrc=$?
[ "$_rrc" = 1 ] || fail "with DPMS DISABLED at the server, the dark edge exited
$_rrc. 1 is the refusal: 0 would be a clean crossing over a screen that cannot
go dark, and 78 would say 'not applicable here' about a server that has the
extension and merely has it switched off: $(cat "$T/out")"
grep -q 'xset +dpms' "$T/out" || fail "the refusal does not name the remedy. The
operator's fix is one command and the message is the only place it appears:
$(cat "$T/out")"
# A LIT RUNG IS NOT BLOCKED BY IT, and that asymmetry is deliberate: with DPMS
# off the screen is already on, which is what the ascent wants, and refusing
# would fail every wake on a box that simply does not use DPMS.
_lrc=0
_hook wake || _lrc=$?
[ "$_lrc" = 78 ] || fail "with DPMS disabled the LIT edge exited $_lrc rather
than declining 78. Refusing an ascent is how a machine gets stranded dark, and
the screen is already in the state the ascent wants: $(cat "$T/out")"

pass "real DPMS: dark -> $_m, drift caught, lit restored, disabled refused"
