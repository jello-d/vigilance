#!/bin/sh
# test/session-greeter.t - the greeter's SLEEP path, on a real compositor.
#
# THE OLDEST UNPAID DEBT IN THIS PROJECT. "The greeter sleep path has never
# been observed" has stood in the notes since 2026-09-19, when cccd6ca found a
# greeter with no way to go dark at all: its `sleep` edge runs MACHINE-scope
# hooks only, and every one either drove a peripheral the greeter does not have
# or lived in the user scope it does not have. The keyboard backlight went out
# and the screen stayed lit.
#
# `sway-dpms` was written to close that, and it has never run on a real
# compositor in a greeter-shaped context. greeter.t covers the SHAPE well in the
# stub tier (initialising at `lock`, an absent user tree, a machine-scope
# locker-up breaking it) with RECORDER hooks; nothing has ever driven the real
# hook set at that rung against a real sway.
#
# WHAT IS FAITHFUL HERE, AND WHAT IS NOT, because the difference bounds the
# claim:
#
#   faithful   no user hook tree at all (the greeter's defining absence), the
#              REAL shipped hooks in the machine scope wired as an integrator
#              wires them, a REAL sway answering swaymsg, and the rung
#              INITIALISED at `lock` rather than traversed to
#   NOT        the uid. This runs as the session tier's user, not _greetd, so it
#              says nothing about the separate finding that a machine-scope hook
#              target must be root-visible or the greeter cannot even see it.
#              And greetd is not in the loop: this exercises the greeter's HOOK
#              SET and CONTEXT, not greetd's session management.
#
# THE INSTRUMENT IS INDEPENDENT OF THE HOOK. Output dpms is read with swaymsg
# directly rather than by trusting sway-dpms's own verify, because a hook that
# both acts and reports on itself can be wrong in one direction and agree with
# itself. The hook's verify is asserted too, separately.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init session-greeter

require compositor
command -v swaymsg >/dev/null 2>&1 \
  || fail "no swaymsg despite the compositor capability; the greeter's only
darkening mechanism cannot be exercised and this scenario would prove nothing"
swaymsg -t get_version >/dev/null 2>&1 \
  || fail "swaymsg cannot reach sway (SWAYSOCK=${SWAYSOCK:-<unset>}). sway-dpms
declines 78 in that case, so every assertion below would pass against a hook
that never acted"

MACHINE=/etc/vigilance/hooks
GREETER_USER_TREE=$T/no-such-user-tree
_restore=

_cleanup() {
  # EVERY WIRE THIS TEST MADE, removed. The machine scope is SHARED with the
  # guest's other scenarios and with the integrator's own wiring, so leaving
  # hooks behind would change what every later test runs.
  for _p in $_restore; do rm -f "$_p" 2>/dev/null || true; done
  swaymsg "output * dpms on" >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

_mwire() {   # <edge> <tier> <hook> <order>
  _md=$MACHINE/$1$2.d
  mkdir -p "$_md"
  [ -f "$PLUGINS/hooks/$3" ] || fail "no shipped hook named '$3'"
  ln -sf "$PLUGINS/hooks/$3" "$_md/$4-$3"
  _restore="$_restore $_md/$4-$3"
}

# THE REAL WIRING, in the order a real box has it: sway-dpms at 05 so it runs
# first, exactly as /etc/vigilance/hooks/sleep.d does on manifold.
_mwire sleep ''       sway-dpms 05
_mwire sleep .verify  sway-dpms 05
_mwire wake  ''       sway-dpms 05
_mwire wake  .verify  sway-dpms 05

_dpms() {   # -> on|off|unknown, read INDEPENDENTLY of the hook
  swaymsg -t get_outputs 2>/dev/null | tr ',' '\n' \
    | awk '/"dpms"/ { print ($0 ~ /true/) ? "on" : "off"; exit }'
}

# --- given: a greeter, which means it BEGINS at `lock` ----------------------
# Not traversed to. A greeter IS the locked state, so initialising there is the
# whole point: traversing open -> lock would fire lock.d and its provider would
# try to raise a lock screen over a session that already is one.
rm -f "${VIGILANCE_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/vigilance}/depth" \
  2>/dev/null || true
VIGILANCE_HOOK_ROOT=$GREETER_USER_TREE
VIGILANCE_MACHINE_HOOKS=$MACHINE
VIGILANCE_INITIAL_DEPTH=lock
export VIGILANCE_HOOK_ROOT VIGILANCE_MACHINE_HOOKS VIGILANCE_INITIAL_DEPTH

[ ! -d "$GREETER_USER_TREE" ] || fail "fixture: the user tree exists, so this is
not a greeter. The absence IS the greeter's configuration"
[ "$(depth)" = lock ] || fail "a greeter did not begin at the lock rung; it
reports '$(depth)'. Everything below assumes a one-edge descent from there"

swaymsg "output * dpms on" >/dev/null 2>&1 || true
[ "$(_dpms)" = on ] || fail "fixture: the output is not on before the descent,
so a subsequent 'off' would prove nothing"

# --- 1. THE GREETER'S SCREEN ACTUALLY GOES DARK ----------------------------
# The finding cccd6ca fixed, observed for the first time. Before sway-dpms the
# only visible effect of a greeter's sleep edge was the keyboard backlight going
# out; the screen stayed lit on a machine with nobody at it.
_rc=0
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 0 ] || fail "a greeter's sleep edge exited $_rc with only machine
hooks wired. A greeter has no user scope, and that absence must not be an error"
[ "$(depth)" = sleep ] || fail "depth is '$(depth)' after a greeter's descent"
[ "$(_dpms)" = off ] || fail "THE GREETER'S SCREEN DID NOT GO DARK. Read from
sway directly rather than from the hook: dpms reports '$(_dpms)'. This is the
session nobody is present to notice, so nothing else would ever have said so"

# --- 2. AND IT IS VERIFIED, not merely acted on ----------------------------
# The question that matters more than the act: a greeter's machine-only hook set
# could act correctly and be checked by NOTHING, which is the shape of nearly
# every defect in this project. Exit 78 here would mean "every wired hook
# declined", and the n/a contract makes that a failure rather than a pass.
_vout=$("$VIGILANT" verify sleep 2>&1) || _vrc=$?
case "$_vout" in
  *"NOTHING CHECKED"*)
    printf '%s\n' "$_vout" >&2
    fail "a greeter's sleep edge was verified by NOTHING. Every machine-scope
hook declined, so the rung is a claim nobody checked -- on the one session with
no human to notice" ;;
esac
[ "${_vrc:-0}" = 0 ] || { printf '%s\n' "$_vout" >&2
  fail "verify sleep failed for a greeter at rc=${_vrc:-0}"; }
case "$_vout" in
  *"ok"*) ;;
  *) printf '%s\n' "$_vout" >&2
     fail "verify produced no positive verdict: '$_vout'" ;;
esac

# --- 3. AND THE GREETER COMES BACK UP --------------------------------------
# A greeter that cannot un-darken is a machine that looks dead to whoever walks
# up to it, and there is no user session to rescue it from.
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "a greeter could not ascend from sleep with only machine hooks"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after a greeter's ascent"
[ "$(_dpms)" = on ] || fail "the greeter's screen stayed DARK after the ascent
(dpms '$(_dpms)'). Nobody is logged in to notice, and there is no user-scope
hook to restore it"

# --- 4. AND THE ABSENT USER TREE IS NEVER AN ERROR -------------------------
# Restating greeter.t's claim against the REAL hook set rather than recorders:
# every command a supervision timer runs must tolerate having no user scope, or
# the greeter's own monitoring is what breaks.
for _c in status hooks plan report due; do
  _crc=0
  "$VIGILANT" "$_c" >/dev/null 2>>"$T/stderr" || _crc=$?
  # `report` and `due` legitimately report findings on this substrate, so only
  # a CRASH is a failure: 2 is usage, and above 3 is not a verdict at all.
  case "$_crc" in
    0|1|3|78) ;;
    *) fail "'$_c' exited $_crc with no user hook tree. That is the greeter's
normal state, not an error, and a supervision pass that dies on it leaves the
greeter unmonitored" ;;
  esac
done

pass
