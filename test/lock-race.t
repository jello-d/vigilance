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
# "is it already up?" check before either starts the unit: a test-then-act
# whose comment claimed it was "racy-safe" because systemd arbitrates. systemd
# DOES arbitrate, correctly, refusing the second with "unit already exists".
# Treating that refusal as an error was the bug: the postcondition the hook
# exists for is satisfied either way.
#
# WHAT IS STUBBED AND WHY. `systemd-run` is the ACTUATOR that starts the
# locker, and the suite already substitutes the locker itself
# (VIGILANCE_LOCKER); making it fail is the realistic case. The TRUST-ROOT
# question (what state is the unit in) comes from
# VIGILANCE_LOCK_ACTIVE_FILE, a sanctioned probe override, because neither
# substrate can answer it for real: the stub tier must not create transient
# units on the developer's systemd, and the VM has no user bus at all.
#
# THE FIXTURE HOLDS A STATE, NOT A BOOLEAN, and that is not a detail. The first
# version of this file modelled "up or not", so it could not express
# ACTIVATING, and the code it was testing could not either. Both agreed, the
# file passed, and a live box failed the same way four hours later. A fixture
# that cannot represent the failing state cannot test for it.
set -eu
. "$(dirname "$0")/harness_lib"
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
    # exists because the OTHER request created it a moment ago, so it is
    # ACTIVATING, not yet active. This is the case the shipped code got wrong.
    # ...and the winner's locker finishes coming up a moment later.
    settling) printf '#!/bin/sh\necho activating > %s\n%s\nexit 1\n' \
                "$ACTIVE" "( sleep 1; echo active > $ACTIVE ) &" ;;
    # The easy half: the winner is already fully active when we look.
    lost)     printf '#!/bin/sh\necho active > %s\nexit 1\n' "$ACTIVE" ;;
    # A GENUINE failure: nothing started, nothing is up.
    dead)     printf '#!/bin/sh\nexit 1\n' ;;
    # The ordinary path. It RECORDS ITS ARGV, because the provider's promise
    # that the locker is substitutable is a claim about what it hands systemd.
    won)      printf '#!/bin/sh\nprintf "%%s\\n" "$*" > %s\n' "$T/argv"
              printf 'echo active > %s\nexit 0\n' "$ACTIVE" ;;
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
[ "$(cat "$ACTIVE" 2>/dev/null)" = active ] \
  || fail "the ordinary path never started the unit"

# --- 2. ALREADY UP IS A NO-OP, WITHOUT ATTEMPTING A START -------------------
# The unit is active and systemd-run would FAIL if reached. Exit status alone
# cannot tell "never tried" from "tried, failed, then noticed the unit was up",
# because the race branch returns 0 too, so the MESSAGE is the assertion. It
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
_runner settling
_hook
[ "$RC" = 0 ] || fail "the hook returned $RC after losing a start race to a
unit that was still ACTIVATING. systemctl reports a unit as inactive until it
finishes coming up, so sampling once answers before the answer exists, the
same test-then-act shape as the pre-check, inside the code written to fix it.
Seen on a live box four hours after the first fix deployed"
[ "$(cat "$ACTIVE")" = active ] || fail "fixture: the settling runner never
reached the active state, so this case proved nothing"

# ...and an ALREADY-active winner is the easy half of the same case. The
# PRE-CHECK must not be what satisfies it: the file starts absent, so the hook
# genuinely reaches the start and is genuinely refused.
rm -f "$ACTIVE"
_runner lost
_hook
[ "$RC" = 0 ] || fail "the hook returned $RC after losing a race to a unit that
was already fully active"

# --- 4. ...BUT A REAL FAILURE STILL FAILS -----------------------------------
# THE HALF THAT KEEPS THE FIX HONEST. If the retry-check were unconditional,
# every failed lock would report success and the box could sleep unlocked while
# lock-on-sleep reported a clean crossing.
rm -f "$ACTIVE"
_runner dead
_t0=$(date +%s)
_hook
_el=$(( $(date +%s) - _t0 ))
# AND IT MUST FAIL PROMPTLY. A unit that is inactive is not coming up, so
# waiting out the settle window buys nothing and spends it: this hook runs
# under a 10s per-hook bound on the security path, and burning 5 of them on a
# failure that was already decided is how a real failure turns into a killed
# hook instead of a reported one.
[ "$_el" -le 2 ] || fail "a genuine failure took ${_el}s to report. An inactive
unit is not settling, and the wait loop must break rather than sit out its
whole window"
[ "$RC" = 1 ] || fail "a start that failed with NO locker running returned $RC.
This is the case the provider's exit status exists for: nothing came up, and
lock-on-sleep must not report success"
grep -q "could not start" "$T/err" || fail "a real failure said nothing about
which unit could not be started"

# --- THE LOCKER IS SUBSTITUTABLE, argv AND UNIT TYPE INCLUDED ---------------
# THE ARGV HELPER IS PINNED, because the first version of this case asserted
# against the DEVELOPER's live `vigilance-lock-argv` and their shapes config,
# a host read, in the suite that ratchets against exactly that. It also records
# the argument it was given, which is the contract being added here: the helper
# is asked ABOUT THE LOCKER, because its output is inherently locker-specific.
cat > "$T/bin/vigilance-lock-argv" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > $T/helper-arg
case "\$1" in
  i3lock) echo "--color=000000" ;;
  *)      echo "-C /shapes/swaylock.conf" ;;
esac
EOF
chmod +x "$T/bin/vigilance-lock-argv"

# `VIGILANCE_LOCKER` was a HALF PROMISE: the man page called it the locker
# process name while `-f` (swaylock's --daemonize) and `Type=forking` were
# hardcoded beside it. `VIGILANCE_LOCKER=i3lock` therefore resolved, passed the
# `command -v` check, and was handed a flag i3lock does not have, so the unit
# fails and the screen does not lock, on the one edge where that matters.
#
# Type is the same assumption one layer down: it asserts the locker DETACHES. A
# foreground locker under Type=forking leaves systemd-run waiting for a fork
# that never comes, and the provider then reports failure about a locked screen.
#
# Found while costing X11 support, before any X11 code existed, which is the
# argument for that work: a second platform does not add a mechanism so much as
# it reads back the promises the first one let us leave untested.
_runner won
echo inactive > "$ACTIVE"
rm -f "$T/argv"
_hook
[ "$RC" = 0 ] || fail "the default path failed (rc=$RC)"
_a=$(cat "$T/argv" 2>/dev/null || true)
case "$_a" in
  *"Type=forking"*" swaylock -f "*"-C /shapes/swaylock.conf"*) ;;
  *) fail "the DEFAULT invocation changed: a shipped box must still get
swaylock with -f under Type=forking, followed by the helper's argv. Got:
$_a" ;;
esac
[ "$(cat "$T/helper-arg" 2>/dev/null)" = swaylock ] || fail "the argv helper was
not told which locker it is being asked about (got
'$(cat "$T/helper-arg" 2>/dev/null)'). Its output is locker-specific, so a
helper that cannot tell has to guess, which is how i3lock was handed a
swaylock config file"

# ...and an X11-shaped locker gets ITS argv and ITS unit type.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/i3lock"; chmod +x "$T/bin/i3lock"
echo inactive > "$ACTIVE"
rm -f "$T/argv"
RC=0
VIGILANCE_LOCKER=i3lock VIGILANCE_LOCKER_ARGV=-n \
  VIGILANCE_LOCKER_TYPE=simple VIGILANCE_EDGE=lock VIGILANCE_KIND=act \
  sh "$HOOK" lock >>"$T/out" 2>>"$T/err" || RC=$?
[ "$RC" = 0 ] || fail "a substituted locker failed to start (rc=$RC):
$(tail -2 "$T/err")"
_a=$(cat "$T/argv" 2>/dev/null || true)
[ "$(cat "$T/helper-arg" 2>/dev/null)" = i3lock ] || fail "the helper was asked
about '$(cat "$T/helper-arg" 2>/dev/null)' while the locker was i3lock"
case "$_a" in
  *"Type=simple"*" i3lock -n "*"--color=000000"*) ;;
  *) fail "the locker knobs did not reach systemd-run. That is the difference
between a documented extension point and a name the code ignores. Got:
$_a" ;;
esac
case "$_a" in
  *swaylock*|*" -f"*) fail "swaylock's name or flag survived a substitution:
$_a" ;;
esac

pass
