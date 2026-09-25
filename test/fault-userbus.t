#!/bin/sh
# test/fault-userbus.t - the user bus dies, so no transient unit can start.
#
# FAULT: user-bus-killed.
#
# WHY IT MATTERS MORE NOW THAT THE REPO IS PUBLIC. Everything about the lock
# depends on a per-user systemd bus: the provider starts swaylock as a transient
# `--user` unit, locker-up asks systemd whether it is active, and the whole
# design deliberately leans on systemd as its trust root. A reader on a stack
# where that bus is absent or dead is the most likely outside integrator to hit
# trouble, and the question is not whether the lock works (it cannot) but
# whether vigilance SAYS SO or quietly reports a locked session.
#
# THE FALSE GREEN IS THE FAILURE. `go lock` returning 0 here would tell
# lock-on-sleep.service the session is secured, and that unit reads nothing but
# the exit status before letting the box suspend.
#
# THE USER MANAGER IS REALLY STOPPED, not simulated. The faults file forbids
# faking a process, and DBUS_SESSION_BUS_ADDRESS trickery would be exactly that.
#
# MY FIRST INJECTION WAS WRONG AND THE PRECONDITION CAUGHT IT. Stopping
# `dbus.socket` does NOT stop `systemd-run --user`: it reaches the user MANAGER,
# and the socket is re-activatable on demand anyway, so the probe below found
# the bus perfectly usable and the scenario refused to run. That is the
# assert-the-precondition rule paying for itself -- without it, every assertion
# here would have passed against a machine with nothing wrong.
#
# IT RESTORES THE BUS IN THE TRAP, on an abort too: this scenario shares
# a boot with every other one, and a guest with no user bus fails each of them
# afterwards in a way that looks like their own bug.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-userbus

BUS_DOWN=0
_restore_bus() {
  [ "$BUS_DOWN" = 1 ] || return 0
  systemctl start "user@$(id -u).service" >/dev/null 2>&1 || true
  # The manager takes a moment to accept connections again, and everything after
  # this point is about whether the ladder RECOVERS, so waiting is part of the
  # restore rather than part of a test.
  _rb=0
  while [ "$_rb" -lt 30 ]; do
    if systemctl --user show -p Version >/dev/null 2>&1; then break; fi
    sleep 0.5; _rb=$((_rb + 1))
  done
  # AND RE-IMPORT THE ENVIRONMENT, because a restarted user manager loses it.
  # That is not a harness convenience: it IS the documented --user dependency,
  # which is that a transient unit inherits the MANAGER's environment and not
  # its caller's. A real session imports WAYLAND_DISPLAY at login, so a restore
  # that skipped it would leave the guest unable to lock and the recovery case
  # would report a product failure about the injection's own wreckage.
  systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR \
    >/dev/null 2>&1 || true
  BUS_DOWN=0
}
trap '_restore_bus; session_done; rm -rf "$T"' EXIT INT TERM HUP

wire lock ''      swaylock
wire lock .verify locker-up

# --- given: the lock works, so the fault is the only difference -------------
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "go lock failed before the fault was injected, so nothing below is
attributable to the bus"
await 15 locker_up || fail "no locker came up before the fault"
"$VIGILANT" force open >/dev/null 2>&1 || true
systemctl --user stop screen-lock.service >/dev/null 2>&1 || true

# --- THE FAULT --------------------------------------------------------------
# The whole user instance, which is what "no per-user bus" means to anything
# that wants a transient --user unit. This is also the honest shape of the
# outside-integrator case: a stack with no user manager at all.
systemctl stop "user@$(id -u).service" >/dev/null 2>&1 || true
BUS_DOWN=1
# THE PRECONDITION, ASSERTED. If the bus is still reachable the whole scenario
# passes for the wrong reason, which is the rule every cell in this matrix
# follows. `systemd-run --user` is the exact call the provider makes.
if systemd-run --user --collect --unit=vig-bus-probe.service \
     -- /bin/true >/dev/null 2>&1; then
  systemctl --user stop vig-bus-probe.service >/dev/null 2>&1 || true
  fail "the user bus is still usable after stopping it, so this scenario would
prove nothing. systemd-run --user still succeeded"
fi

# --- 1. THE LOCK MUST FAIL, LOUDLY -----------------------------------------
_rc=0
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || _rc=$?
[ "$_rc" != 0 ] || fail "with no user bus, go lock reported SUCCESS. No locker
can be started at all, so this is the false green that lets lock-on-sleep
suspend the box with nothing guarding the session"
locker_up && fail "a locker is somehow running with no user bus"
said "HOOK FAILED" || fail "the provider could not start a locker and nothing
was logged. The audit tier reads that log and is the tier of last resort"

# --- 2. AND THE DIAGNOSIS MUST NAME THE BUS ---------------------------------
# The provider explains its failure path rather than only reporting it, which is
# right. But the explanation it had could only ever say one thing: it tested
# `systemctl --user show-environment | grep WAYLAND_DISPLAY`, and with no bus
# that command FAILS, produces nothing, and the grep therefore misses -- so a
# dead bus was reported as a missing WAYLAND_DISPLAY.
#
# That is worse than no diagnosis. It sends an integrator to import an
# environment variable into a manager they cannot reach, on the most
# security-critical edge there is, and the real cause is one line away.
grep -q 'user bus' "$T/stderr" 2>/dev/null \
  || grep -q 'user bus' "$T/out" 2>/dev/null \
  || fail "the provider did not name the BUS as the cause. What it said was:
$(grep -i 'swaylock provider' "$T/stderr" "$T/out" 2>/dev/null | tail -3)
A dead bus reported as a missing WAYLAND_DISPLAY sends the reader to import a
variable into a manager they cannot reach"

# --- 3. AND NOTHING MAY CLAIM THE SESSION IS SECURED -----------------------
# The record says `lock` (the depth is committed before the act tier, on
# purpose), so the tiers that ask about the MACHINE are the only defence.
_vrc=0
"$VIGILANT" verify lock >>"$T/out" 2>>"$T/stderr" || _vrc=$?
[ "$_vrc" != 0 ] || fail "verify lock succeeded with no locker and no bus. That
is the claim lock-on-sleep.service checks as ExecStartPost before a suspend"

# --- 4. AND IT RECOVERS WHEN THE BUS COMES BACK ----------------------------
# A transient fault that leaves the ladder unable to lock has become permanent.
_restore_bus
await 15 systemd-run --user --collect --unit=vig-bus-probe2.service \
  -- /bin/true || fail "the user bus did not come back; recovery is unjudgeable"
systemctl --user stop vig-bus-probe2.service >/dev/null 2>&1 || true
"$VIGILANT" force open >/dev/null 2>&1 || true
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "with the bus restored, the machine still could not lock"
await 15 locker_up || fail "the recovered lock crossed its edge and brought up
no locker"

pass
