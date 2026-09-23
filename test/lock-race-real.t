#!/bin/sh
# test/lock-race-real.t - the locker race, against a REAL user systemd.
#
# THE GAP THIS CLOSES, and it is the reason the bug it covers reached a live
# box twice. Everything vigilance builds on `--user` units -- the locker's
# transient unit, the idle supervisor, the logind trigger -- was testable
# NOWHERE:
#
#   the stub tier   must not create transient units on the developer's systemd
#   the VM          had no user bus at all ("Failed to connect to bus")
#
# So the provider's race branch was exercised only through a FILE fixture built
# from what I believed systemd does. The fixture was a boolean, systemd has a
# third state, and `activating` shipped an alert on the lock edge. A fixture
# derived from my mental model can only ever test my mental model.
#
# The VM now runs a real `systemd --user` (test/vm/run starts user@0.service),
# so this asks systemd itself. No VIGILANCE_LOCK_ACTIVE_FILE here on purpose:
# the override exists for the substrate that cannot answer, and this one can.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init lock-race-real
require systemd userbus

HOOK=$HERE/libexec/vigilance/providers/swaylock
UNIT=vigilance-test-lock-$$.service
export VIGILANCE_LOCK_UNIT=$UNIT
_cleanup() { systemctl --user stop "$UNIT" >/dev/null 2>&1 || true
             systemctl --user reset-failed "$UNIT" >/dev/null 2>&1 || true; }
trap _cleanup EXIT INT TERM HUP

# A LOCKER THAT TAKES ITS TIME COMING UP. This is the whole point: the unit is
# `activating` for about two seconds, which is the window the losing request
# lands in. swaylock behaves this way for real -- it forks, and the parent exits
# only once the compositor has confirmed the session lock -- so a locker that
# comes up instantly would model a machine that does not exist.
mkdir -p "$T/bin"
PATH=$T/bin:$PATH; export PATH
cat > "$T/bin/slowlocker" <<'EOF'
#!/bin/sh
sleep 2
( exec sleep 60 ) &
exit 0
EOF
chmod +x "$T/bin/slowlocker"
export VIGILANCE_LOCKER=slowlocker

_provider() {   # <tag>
  _rc=0
  VIGILANCE_EDGE=lock VIGILANCE_KIND=act sh "$HOOK" lock \
    >>"$T/$1.out" 2>>"$T/$1.err" || _rc=$?
  printf '%s' "$_rc" > "$T/$1.rc"
}

# --- 1. TWO CONCURRENT STARTS, BOTH SUCCEED --------------------------------
# One wins, one is refused by systemd with "unit already exists" -- against the
# real thing, not a stub that returns 1 because a fixture said so. The loser
# must then WAIT for the winner's locker to finish coming up, because at the
# moment it looks the unit is ACTIVATING and `is-active` is false.
_cleanup
_provider a & _provider b & wait
_ra=$(cat "$T/a.rc"); _rb=$(cat "$T/b.rc")
if [ "$_ra" != 0 ] || [ "$_rb" != 0 ]; then
  cat "$T/a.err" "$T/b.err" 2>/dev/null >&2
  fail "two concurrent starts against a REAL user systemd returned $_ra and
$_rb. Losing the race is not failing: the locker came up, so the postcondition
this hook exists for holds. The loser sampling too early -- while the winner's
unit was still activating -- is precisely what alerted on a live box"
fi

# ...and exactly one unit is running, which is what makes it a race and not
# two independent starts that happened to work.
_st=$(systemctl --user show "$UNIT" -p ActiveState --value 2>/dev/null)
[ "$_st" = active ] || fail "after two concurrent starts the unit is '$_st',
not active"

# --- 2. AN ALREADY-RUNNING LOCKER IS A NO-OP -------------------------------
# The cheap path, against real systemd rather than a file that says so.
true > "$T/c.err"
_provider c
[ "$(cat "$T/c.rc")" = 0 ] || fail "starting into an already-active unit failed"
grep -q "concurrently" "$T/c.err" && fail "the hook attempted a start although
the locker was already up, and reported the refusal as a lost race"

# --- 3. A GENUINE FAILURE STILL FAILS --------------------------------------
# The half that keeps the fix honest: if the settle loop returned 0 whenever
# the unit was not active, every failed lock would report success and
# lock-on-sleep could let the box sleep unlocked.
_cleanup
VIGILANCE_LOCKER=definitely-not-a-real-locker
export VIGILANCE_LOCKER
_provider d
[ "$(cat "$T/d.rc")" = 1 ] || fail "a start with no locker binary returned
$(cat "$T/d.rc"); nothing came up and the hook must say so"

pass
