#!/bin/sh
# test/actuators.t - can the peripheral hooks actually WRITE their devices?
#
# Split out of rescue.t because it needs one capability the VM substrate cannot
# provide: being UNPRIVILEGED. The guest runs as root, and root ignores
# permission bits, so `chmod 0444` cannot make a node unwritable there. The VM
# tier caught that by failing this assertion, which is the integration value the
# two tiers exist for -- and declaring the need is better than a silent
# `[ "$(id -u)" != 0 ]` guard, because a skip nobody sees overstates coverage.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init actuators
require unprivileged

# --- an actuator that cannot be WRITTEN is drift, not silence ---------------
# hooklib DECLARES that the login user must be in `input` for brightnessctl to
# drive these nodes, and nothing checked it, so the requirement was a comment.
# On a real box the user was in none of input/video/i2c and every write was
# denied -- while hook_dark/hook_lit swallow brightnessctl failure by design
# (`|| true`), so vigilant logged clean crossings over hardware that never
# moved. Asserted-versus-actual drift in the actuators rather than the record,
# which is the one place this project had not been looking.
mkdir -p "$VIGILANCE_SYS_LEDS/tpacpi::kbd_backlight"
_node=$VIGILANCE_SYS_LEDS/tpacpi::kbd_backlight/brightness
echo 0 > "$_node"

chmod 0644 "$_node"
_out=$("$VIGILANT" report 2>>"$T/stderr") || true
case "$_out" in
  *"[OK]"*"actuator node(s) writable"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a writable actuator was not reported as OK" ;;
esac

# Read-only: exactly the manifestor state, where the user was in no group that
# could write and brightnessctl was denied.
chmod 0444 "$_node"
# Scoped to the SECTION, not to report's overall exit code. That code folds in
# machinery, which asks the real systemd about real units, so `report && fail`
# would pass for free on any host red for a reason this file never meant to
# test -- and would then keep passing with the actuator check deleted.
_out=$("$VIGILANT" report 2>>"$T/stderr") || true
_fail_in "$_out" actuators "an unwritable actuator node was not flagged. The
hooks that drive it swallow the denial by design, so nothing else in the system
would ever say the hardware is not moving"
case "$_out" in
  *"[FAIL]"*"NOT writable"*"silently no-op"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the actuators section flagged something, but not the unwritable node
in the terms a reader can act on" ;;
esac
# And it must name the remedy, or the reader goes source-diving for it.
case "$_out" in
  *"input"*) ;;
  *) fail "the unwritable-actuator report does not name the group needed" ;;
esac
chmod 0644 "$_node"

# A node that does NOT EXIST is n/a, not drift: a desktop has no panel
# backlight and no hook should care. Crying wolf there is what teaches you to
# ignore the line that matters.
rm -rf "$VIGILANCE_SYS_LEDS/tpacpi::kbd_backlight"
_out=$("$VIGILANT" report 2>>"$T/stderr") || true
_no_fail_in "$_out" actuators "an absent actuator was flagged as drift"
case "$_out" in
  *"no writable backlight or LED nodes"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an absent actuator was not reported as n/a" ;;
esac

pass
