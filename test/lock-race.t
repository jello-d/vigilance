#!/bin/sh
# test/lock-race.t - losing a race to start the locker is not failing.
#
# MEASURED ON MANIFOLD, four times across three days, and every one raised an
# alert on the most security-critical edge there is about a lock that came up
# perfectly:
#
#   12:58:55  cross lock: open -> lock          (logged TWICE, same second)
#   12:58:56  Started screen-lock.service        <- the winner
#   12:58:56  HOOK FAILED (rc=1): lock 10-swaylock   <- the loser
#
# Two lock requests arriving together is ordinary: a double hotkey press (the
# user did exactly that when a lock seemed not to take), or a keybind and a
# logind Session.Lock landing in the same second. Both then pass the
# "is it already up?" check before either starts the unit -- a test-then-act
# whose comment claimed it was "racy-safe" because systemd arbitrates. systemd
# DOES arbitrate, correctly, refusing the second with "unit already exists".
# Treating that refusal as an error was the bug: the postcondition the hook
# exists for is satisfied either way.
#
# WHAT IS STUBBED AND WHY. `systemd-run` is the ACTUATOR that starts the
# locker, and the suite already substitutes the locker itself
# (VIGILANCE_LOCKER); making it fail is the realistic case. The TRUST-ROOT
# question -- is the unit actually up -- comes from VIGILANCE_LOCK_ACTIVE_FILE,
# a sanctioned probe override, because neither substrate can answer it for
# real: the stub tier must not create transient units on the developer's
# systemd, and the VM has no user bus at all.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init lock-race

HOOK=$HERE/libexec/vigilance/providers/swaylock
mkdir -p "$T/bin"
PATH=$T/bin:$PATH; export PATH
# A locker that exists but is never actually run: the hook only checks that the
# name resolves before handing it to systemd-run.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/swaylock"; chmod +x "$T/bin/swaylock"

ACTIVE=$T/unit-active
export VIGILANCE_LOCK_ACTIVE_FILE=$ACTIVE
export VIGILANCE_LOCK_UNIT=test-lock.service

# _runner <mode>: install a systemd-run that wins, loses, or plain fails.
_runner() {
  case "$1" in
    # THE RACE: our start is refused because the unit already exists, and it
    # exists because the OTHER request created it a moment ago.
    lost) printf '#!/bin/sh\ntouch %s\nexit 1\n' "$ACTIVE" ;;
    # A GENUINE failure: nothing started, nothing is up.
    dead) printf '#!/bin/sh\nexit 1\n' ;;
    # The ordinary path.
    won)  printf '#!/bin/sh\ntouch %s\nexit 0\n' "$ACTIVE" ;;
  esac > "$T/bin/systemd-run"
  chmod +x "$T/bin/systemd-run"
}
_hook() {   # -> RC
  RC=0
  VIGILANCE_EDGE=lock VIGILANCE_KIND=act sh "$HOOK" lock \
    >>"$T/out" 2>>"$T/err" || RC=$?
}

# --- 1. THE ORDINARY PATH STILL WORKS ---------------------------------------
# Asserted first, because every fix below could be spelled "always exit 0" and
# that would pass the race case while switching the provider off entirely.
rm -f "$ACTIVE"
_runner won
_hook
[ "$RC" = 0 ] || fail "the ordinary start returned $RC"
[ -e "$ACTIVE" ] || fail "the ordinary path never started the unit"

# --- 2. ALREADY UP IS A NO-OP, WITHOUT ATTEMPTING A START -------------------
# The unit is active and systemd-run would FAIL if reached. Exit status alone
# cannot tell "never tried" from "tried, failed, then noticed the unit was up",
# because the race branch returns 0 too -- so the MESSAGE is the assertion. It
# also has to be right: claiming a concurrent start on an idle box would send a
# reader looking for a second lock request that never happened.
true > "$T/err"
_runner dead
_hook
[ "$RC" = 0 ] || fail "with the locker already up the hook returned $RC"
grep -q "concurrently" "$T/err" && fail "the hook attempted a start although
the locker was already up, and then reported the failure as a lost race"

# --- 3. LOSING THE RACE IS NOT FAILING --------------------------------------
# THE FINDING. Pre-check says down, our start is refused, and by then the other
# request has the unit up.
rm -f "$ACTIVE"
_runner lost
_hook
[ "$RC" = 0 ] || fail "the hook returned $RC after losing a start race. The
locker IS up -- the other request brought it up -- so the postcondition this
hook exists for holds, and reporting failure raises an alert on the lock edge
about a lock that worked. Seen four times on a live box"
[ -e "$ACTIVE" ] || fail "fixture: the lost-race runner did not mark the unit
active, so this case proved nothing"

# --- 4. ...BUT A REAL FAILURE STILL FAILS -----------------------------------
# THE HALF THAT KEEPS THE FIX HONEST. If the retry-check were unconditional,
# every failed lock would report success and the box could sleep unlocked while
# lock-on-sleep reported a clean crossing.
rm -f "$ACTIVE"
_runner dead
_hook
[ "$RC" = 1 ] || fail "a start that failed with NO locker running returned $RC.
This is the case the provider's exit status exists for: nothing came up, and
lock-on-sleep must not report success"
grep -q "could not start" "$T/err" || fail "a real failure said nothing about
which unit could not be started"

pass
