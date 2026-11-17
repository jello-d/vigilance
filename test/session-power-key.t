#!/bin/sh
# test/session-power-key.t - a REAL power key, through real acpid, lights the
# seat user's dark display.
#
# THE CHAIN NO STUB CAN STAND IN FOR:
#
#   a KEY_POWER from an input device       uinject, through the kernel
#   acpid reads it and reports button/power  the real daemon, not a fixture
#   the rendered rule matches and runs     /etc/acpi/events, as root
#   the trigger finds seat0's user         real logind
#   that user's ladder crosses `wake`      their own log, labelled power-key
#
# power-key.t holds each link down on its own; this is the only place they are
# joined, and the place that decides whether the event string acpid really
# emits is the one the rule's regex was written against.
#
# FROM `open` A PRESS MUST DO NOTHING, asserted here as well as there: a power
# key that locked a machine in use would be the bug this feature most needs to
# be unable to have, and only here is it the real daemon pressing.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-power-key

RULE=/etc/acpi/events/vigilance-power-key
_cleanup() {
  rm -f "$RULE"
  systemctl stop acpid.service >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

command -v python3 >/dev/null 2>&1 \
  || fail "no python3, so uinject cannot synthesise a power key"
[ -c /dev/uinput ] || modprobe uinput >/dev/null 2>&1 || true
[ -c /dev/uinput ] || fail "no /dev/uinput; the power key cannot be injected"
command -v acpid >/dev/null 2>&1 \
  || fail "no acpid in the guest image, which test/vm/run's PKGS installs"
[ -x "$LOCKABLE_V" ] || fail "no published vigilant at $LOCKABLE_V. The rule
must point into the SHARED tree, which the seat's user can read"
[ -x /opt/vigilance/libexec/triggers/power-key ] || fail "the published tree
has no triggers/power-key, so the rendered rule would run nothing"

# WHOSE SEAT. The trigger wakes seat0's ACTIVE session, so the test reads the
# same thing rather than assuming which account that is.
_sid=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null || true)
# A HEADLESS GUEST CAN HAVE A SEAT SESSION THAT IS NOT ACTIVE: greetd's session
# sits on seat0 while the foreground VT has none. On real hardware the session
# being looked at IS the active one, so make the guest match rather than
# teaching the trigger to wake a session nobody can see.
if [ -z "$_sid" ]; then
  _cand=$(loginctl list-sessions --no-legend 2>/dev/null \
    | awk '$4 == "seat0" { print $1; exit }')
  if [ -n "$_cand" ]; then
    loginctl activate "$_cand" >/dev/null 2>&1 || true
    sleep 1
    _sid=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null \
      || true)
  fi
fi
[ -n "$_sid" ] || fail "seat0 has no active session, so a press has no ladder
to wake and every assertion below would pass with nothing having run:
$(loginctl list-sessions --no-legend 2>&1 | head -8)"
LOCKABLE_USER=$(loginctl show-session "$_sid" -p Name --value)
_class=$(loginctl show-session "$_sid" -p Class --value)
case "$_class" in user|greeter) ;; *)
  fail "seat0's active session $_sid ($LOCKABLE_USER) is class '$_class',
which the trigger deliberately leaves alone" ;;
esac

# THE RULE, rendered exactly as an integrator renders it, then acpid started
# so it is loaded (acpid reads rules at start and on SIGHUP only).
mkdir -p /etc/acpi/events
sed "s#@PLUGINS@#/opt/vigilance/libexec#g" "$HERE/acpi/vigilance-power-key" \
  > "$RULE" || fail "could not render the acpid rule"
systemctl restart acpid.service >/dev/null 2>&1 || true
_i=0
while [ "$(systemctl is-active acpid.service 2>/dev/null)" != active ] \
      && [ "$_i" -lt 20 ]; do
  sleep 0.25; _i=$((_i + 1))
done
[ "$(systemctl is-active acpid.service 2>/dev/null)" = active ] \
  || fail "acpid did not start with the rule in place:
$(journalctl -u acpid.service -n 10 --no-pager 2>&1)"

# THE CHECK, against the real daemon and journal: this is where "armed" means
# what it says rather than what a stub was told to answer.
_chk=$(env PREFIX="$T/pfx" XDG_BIN_HOME="$T/pfx/bin" \
  XDG_DATA_HOME="$T/pfx/share" XDG_CONFIG_HOME="$T/pfx/cfg" NO_COLOR=1 \
  sh "$HERE/setup.sh" check 2>&1 | grep 'power key' || true)
printf '%s\n' "$_chk" | grep -q '\[OK\].*armed' || fail "with the rule placed
and acpid started after it, setup.sh check did not call the power key armed:
$_chk"

_vlog() { lockable_log; }
_vlog_at() { wc -l < "$(_vlog)" 2>/dev/null || echo 0; }
_vlog_since() { tail -n +$(( ${1:-0} + 1 )) "$(_vlog)" 2>/dev/null || true; }
_press() {
  python3 "$HERE/test/uinject" power 3 2 >/dev/null 2>&1 || true
}
# The wake is detached from acpid's action, so give it a moment to land.
_await_wake() {   # <log line count before the press>
  _w=0
  while [ "$_w" -lt 40 ]; do
    if _vlog_since "$1" | grep -q 'src=power-key'; then return 0; fi
    sleep 0.25; _w=$((_w + 1))
  done
  return 1
}

# --- 1. FROM `sleep` A PRESS LIGHTS THE DISPLAY -----------------------------
lockable_as env VIGILANCE_SOURCE=manual "$LOCKABLE_V" force sleep \
  >/dev/null 2>&1 || true
[ "$(lockable_depth)" = sleep ] || fail "precondition: could not put
$LOCKABLE_USER's ladder at sleep (it reads '$(lockable_depth)')"
_p0=$(_vlog_at)
_press
_await_wake "$_p0" || fail "a power key pressed at the sleep rung produced no
power-key crossing in $LOCKABLE_USER's log.
--- that log since the press ---
$(_vlog_since "$_p0")
--- acpid ---
$(journalctl -u acpid.service -n 15 --no-pager 2>&1)"
_vlog_since "$_p0" | grep -q 'cross wake: sleep -> lock src=power-key' \
  || fail "the press crossed something other than wake into lock:
$(_vlog_since "$_p0")"
[ "$(lockable_depth)" = lock ] || fail "after the press the ladder reads
'$(lockable_depth)', not lock: lit and still secured"

# --- 2. FROM `open` A PRESS DOES NOTHING -------------------------------------
# Past the trigger's debounce window, so this is a real second press.
lockable_as env VIGILANCE_SOURCE=manual "$LOCKABLE_V" force open \
  >/dev/null 2>&1 || true
[ "$(lockable_depth)" = open ] || fail "precondition: could not put the
ladder at open"
sleep 3
_p1=$(_vlog_at)
_press
sleep 4
if _vlog_since "$_p1" | grep -q 'cross '; then
  fail "a power key pressed at the open rung CROSSED an edge, so a press can
change a machine in use:
$(_vlog_since "$_p1")"
fi
[ "$(lockable_depth)" = open ] || fail "a press at open left the ladder at
'$(lockable_depth)'"

pass "a real KEY_POWER through acpid wakes $LOCKABLE_USER from sleep, and\
 changes nothing from open"
