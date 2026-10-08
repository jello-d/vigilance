#!/bin/sh
# test/lock-span.t - can SYSTEMD own the lock's lifetime, so smart-lock and
# smart-trigger can be deleted?
#
# A lock is a SPAN, not an edge, and something must own it: stay alive for its
# duration so the transient unit's cgroup is not reaped (the frozen
# ext-session-lock of 2026-08-08), and notice when it ends. Today `smart-lock`
# owns that with a foreground process and a `pgrep` poll loop. If systemd can
# own it instead, ~200 lines of hand-rolled lifetime management delete.
#
# A synthetic forking program already showed the systemd MECHANICS work. It
# could not answer the two questions that actually decide this, both of which
# need the REAL binary:
#
#   1. is the SPAN tracked at all once swaylock daemonizes?
#   2. does ExecStopPost fire when swaylock CRASHES, not just on clean exit?
#
# (1) was first written as "does GuessMainPID latch swaylock's child", and the
# VM answered NO: swaylock forks a password-backend child, so the cgroup holds
# two processes and systemd cannot guess which is main (MainPID=0). That turned
# out to be the WRONG QUESTION. systemd falls back to CGROUP EMPTINESS for
# liveness, which tracks the span perfectly well and does not care how many
# processes swaylock forks. GuessMainPID is explicitly disabled below rather
# than left to guess wrong.
#
# (2) is the one that matters. If a crash does not fire it, depth stays at
# `lock` while the screen is live: vigilance believing the machine is secured
# when it is not. That is the worst failure this project can have, and it
# would be invisible without the verify tier.
#
# Needs a real compositor, so it is VM-only and SKIPS loudly elsewhere.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init lock-span

require systemd compositor

command -v swaylock >/dev/null 2>&1 || fail "swaylock absent despite the cap"

UNIT=vig-lockspan.service
EVENTS=$T/events
: > "$EVENTS"

_cleanup() { systemctl stop "$UNIT" >/dev/null 2>&1 || true; }
trap '_cleanup; rm -rf "$T"' EXIT INT TERM

# The shape the real thing would use: swaylock -f under Type=forking, with the
# edges announced by systemd rather than by a wrapper we maintain.
# Diagnose rather than just assert: a bare "it did not work" from a VM-only
# scenario is unactionable, and the interesting outcomes here are the failures.
_diag() {   # <label>
  echo "--- lock-span diagnostics ($1) ---" >&2
  systemctl show "$UNIT" -p ActiveState -p SubState -p Result \
    -p MainPID -p ExecMainStatus 2>&1 | sed 's/^/    /' >&2
  journalctl -u "$UNIT" --no-pager -n 25 2>&1 | sed 's/^/    /' >&2
  echo "    swaylock direct probe:" >&2
  swaylock --version 2>&1 | sed 's/^/      /' >&2
  timeout 5 swaylock -f 2>&1 | head -5 | sed 's/^/      /' >&2
}

# GuessMainPID=no: do not let systemd pick one of swaylock's two processes and
# then track the wrong one. Cgroup emptiness is the honest liveness signal for
# a process that forks helpers.
systemd-run --unit="$UNIT" --property=Type=forking \
  --property=GuessMainPID=no \
  --property="Environment=WAYLAND_DISPLAY=$WAYLAND_DISPLAY" \
  --property="Environment=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
  --property="ExecStartPost=/bin/sh -c 'echo commit >> $EVENTS'" \
  --property="ExecStopPost=/bin/sh -c 'echo stopped >> $EVENTS'" \
  swaylock -f >/dev/null 2>&1 \
  || { _diag "systemd-run failed"; fail "systemd-run of swaylock failed"; }

# --- 1. is the SPAN tracked once swaylock daemonizes? -----------------------
# The unit must stay ACTIVE for as long as the lock is up. That is the whole
# reason a transient unit exists: if it goes inactive, systemd reaps the cgroup
# and the lock is destroyed, which is the frozen ext-session-lock of
# 2026-08-08.
_n=0
while [ "$_n" -lt 20 ]; do
  _st=$(systemctl show "$UNIT" -p ActiveState --value 2>/dev/null || echo none)
  if [ "$_st" = active ]; then break; fi
  sleep 0.5; _n=$((_n + 1))
done
if [ "$_st" != active ]; then
  _diag "unit not active"
  fail "the unit did not stay active while swaylock held the lock"
fi

pgrep -x swaylock >/dev/null 2>&1 \
  || { _diag "no swaylock"; fail "swaylock is not running"; }

# ExecStartPost is the COMMIT signal: it runs once the -f parent has exited,
# which is after the compositor confirmed the lock. That is what replaces
# smart-lock's marker file and smart-trigger's polling suspend gate.
grep -q '^commit$' "$EVENTS" \
  || { _diag "no commit"; fail "ExecStartPost did not fire at commit"; }

# --- 2. does a CRASH still end the span? ------------------------------------
# SIGKILL, not SIGTERM: an unhandled crash is the case that would strand depth
# at `lock` with a live screen if systemd did not notice.
pkill -9 -x swaylock 2>/dev/null || fail "could not kill swaylock"

_n=0
while [ "$_n" -lt 20 ]; do
  if grep -q '^stopped$' "$EVENTS"; then break; fi
  sleep 0.5; _n=$((_n + 1))
done
grep -q '^stopped$' "$EVENTS" \
  || fail "ExecStopPost did NOT fire on a crashed swaylock (depth would stick)"

# and the unit is genuinely done, not lingering half-alive
_st=$(systemctl show "$UNIT" -p ActiveState --value 2>/dev/null || echo unknown)
case "$_st" in
  active) fail "unit still active after its main process was killed" ;;
esac

# --- 3. THE TWO WAYS OUT ARE NOT THE SAME ----------------------------------
# A CRASH sends no ext_session_lock_v1_unlock_and_destroy, so the compositor
# keeps the session locked: that is the protocol's security guarantee and it is
# what case 2 above exercises. SIGUSR1 is upstream's documented "unlock the
# screen and exit", and it is a DIFFERENT exit: the event loop ends normally
# and swaylock sends the protocol's release on its way out.
#
# THAT DISTINCTION IS A SECURITY PROPERTY OF THE SHIPPED LOCKER and was
# asserted nowhere, which is how it came to be argued from source reading
# instead. It also keeps being misremembered as ours: the blank patch adds
# SIGUSR2 (blank) and SIGRTMIN (restore) and deliberately leaves SIGUSR1 alone
# precisely because upstream already owns it.
#
# THE EXIT STATUS IS THE PROOF, and it needs no compositor introspection.
# `unlock_and_destroy` sits at ONE unconditional call site, immediately after
# the display loop, so EVERY exit from that loop sends the release; and the
# only route to status 0 is falling out of that loop. So exit 0 means the
# release was sent. Verified against v1.8.5's main.c, and the control below is
# what makes the instrument trustworthy rather than merely agreeable.
#
# THE OBVIOUS PROBE DOES NOT WORK, which is worth recording so it is not tried
# again: starting a second swaylock cannot tell the two states apart, because a
# fresh client taking over an abandoned lock IS the protocol's designed
# crash-recovery, so it is granted either way.
#
# Foreground, not `-f`: `wait` must reap the process that holds the lock, and
# under -f the parent exits at once and its status says nothing.
swaylock >/dev/null 2>&1 &
_sl=$!
_n=0
while [ "$_n" -lt 20 ]; do
  kill -0 "$_sl" 2>/dev/null || break
  pgrep -x swaylock >/dev/null 2>&1 && break
  sleep 0.5; _n=$((_n + 1))
done
pgrep -x swaylock >/dev/null 2>&1 \
  || { _diag "case 3 locker never came up"; fail "could not raise a locker to
signal; the assertions below would pass for want of a subject"; }
sleep 1                     # let the compositor confirm the lock

kill -USR1 "$_sl" 2>/dev/null || fail "could not signal the locker"
_urc=0; wait "$_sl" 2>/dev/null || _urc=$?
[ "$_urc" = 0 ] || { _diag "USR1 gave $_urc"; fail "SIGUSR1 did not take the
clean exit: status $_urc, where 0 is the only route out of the display loop and
therefore the only status that proves unlock_and_destroy was sent. 128+n means
it was killed by a signal instead and sent NO release"; }

# THE CONTROL, or exit 0 proves nothing: a crashed locker must NOT look like a
# released one, and the whole claim is that the two differ.
swaylock >/dev/null 2>&1 &
_sl2=$!
_n=0
while [ "$_n" -lt 20 ]; do
  pgrep -x swaylock >/dev/null 2>&1 && break
  sleep 0.5; _n=$((_n + 1))
done
pgrep -x swaylock >/dev/null 2>&1 \
  || fail "the control locker never came up, so the contrast is unmeasured"
sleep 1
kill -9 "$_sl2" 2>/dev/null || true
_krc=0; wait "$_sl2" 2>/dev/null || _krc=$?
[ "$_krc" != 0 ] \
  || fail "a SIGKILLed locker also reported status 0, so the exit status cannot
tell a released lock from an abandoned one and case 3 asserts nothing"

pass "the span is tracked, a crash still ends it, and SIGUSR1 exits 0 (release\
 sent) where SIGKILL exits $_krc (no release)"
