#!/bin/sh
# test/session-inhibit.t - WHEN, IF EVER, DOES THE IDLE TIMER HONOUR A LOGIND
# IDLE INHIBITOR?
#
# A MEASUREMENT WITH ONE ASSERTION, and it says so rather than pretending to
# more. The assertion is the CONTROL: a 3s timeout must fire on a permanently
# idle headless compositor, or nothing below means anything. The four cells
# after it are reported, not demanded, because the subject is a DEPENDENCY's
# behaviour and this file exists to establish it rather than to wish for it.
# When the answer is settled the cells become assertions and this comment goes.
#
# THE SUBJECT IS swayidle, NOT THE LADDER. vigilance never gets asked: the idle
# timer decides whether the security edge fires at all, so whether an inhibitor
# can defer it is a property of the timer. Asserted here for the same reason
# test/environment.t asserts `set -C` and `timeout -k`: the product rests on
# it, so a silent change must break a test rather than a box.
#
# WHAT RESTS ON IT. A live incident on manifold (2026-10-05): a Zoom call ran
# past the 480s idle deadline, the ladder crossed `lock` correctly, and
# `mute-on-lock` then muted the microphone mid meeting. Zoom had asked not to be
# interrupted, over `org.freedesktop.ScreenSaver`, and nothing on this fleet
# owns that name, so the request was lost. The candidate fix is a bridge
# translating that call into a logind idle inhibitor, which puts the whole
# design on the question this file asks. See shared-notes
# `_vigilance-notes-tackup.md` section 5.
#
# TWO AXES, because a single cell cannot tell three different stories apart:
#
#   ORDER  pre   the inhibitor is held BEFORE swayidle starts. If this defers
#                but `post` does not, swayidle reads the state once at startup,
#                which is still fatal to the bridge (an app joins a call long
#                after login) but is a different fact from not reading it.
#          post  taken AFTER swayidle has armed. This is what the bridge needs,
#                and it requires swayidle to re-evaluate on change.
#
#   SHAPE  bare  `swayidle timeout N CMD`, nothing else.
#          prod  what swayidle-mgr actually arms: `-w`, plus a `resume` arm.
#                Carried because a bare invocation may never put swayidle on
#                the bus at all, and then a null result would be an artifact of
#                MY argv rather than a fact about the timer. That is the
#                stub-fidelity trap this suite keeps paying for.
#
# A HEADLESS COMPOSITOR IS PERMANENTLY IDLE, which is why a short timeout is
# deterministic here and why this could not be measured on a desk at all.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/test/harness_lib"
. "$HERE/test/session_lib"

session_init session-inhibit

command -v systemd-inhibit >/dev/null 2>&1 \
  || fail "no systemd-inhibit, yet the session tier required systemd"

WHO=vig-inhibit-test
FIRED=$T/fired
# SHORT ON PURPOSE. Four cells that all defer cost 4x the wait below, and the
# guest suite measured 492s of a 600s bound before this file existed, so the
# margin is real rather than theoretical.
TIMEOUT=4

# OUR OWN PID, NEVER `pkill -x swayidle`. The guest may run a supervised
# swayidle of its own, and killing strangers by name is a defect this package
# has already fixed once in its own `stop` path. comm is confirmed because a
# recorded pid outlives its process and numbers get recycled.
_idle_pid=
_inh_pid=

_idle_stop() {
  if [ -n "$_idle_pid" ]; then
    if [ "$(cat "/proc/$_idle_pid/comm" 2>/dev/null)" = swayidle ]; then
      kill "$_idle_pid" 2>/dev/null || true
      wait "$_idle_pid" 2>/dev/null || true
    fi
  fi
  _idle_pid=
}

_inhibit_take() {
  systemd-inhibit --what=idle --who="$WHO" --why="session-inhibit.t" \
    sleep 600 >/dev/null 2>&1 &
  _inh_pid=$!
}

_inhibit_drop() {
  if [ -n "$_inh_pid" ]; then
    kill "$_inh_pid" 2>/dev/null || true
    wait "$_inh_pid" 2>/dev/null || true
  fi
  _inh_pid=
}

# ASKED OF LOGIND, never of our own intent. A fault that did not take makes
# every reading after it mean the opposite of what it says.
_inhibited() {
  systemd-inhibit --list --no-pager 2>/dev/null \
    | awk -v w="$WHO" '$1 == w && $6 == "idle" { f = 1 } END { exit !f }'
}

# A FUNCTION, not `await 10 '!' _inhibited`: await runs its arguments as a
# command, so a bare `!` would be looked up on PATH rather than negating.
_not_inhibited() { ! _inhibited; }

_fired() { [ -e "$FIRED" ]; }

# Everything of ours goes away even on a failure path, or the next scenario
# inherits a held inhibitor and reads as a box that cannot lock.
trap '_idle_stop; _inhibit_drop' EXIT

_start_shape() {   # <bare|prod>
  case $1 in
    bare)
      swayidle timeout "$TIMEOUT" "touch $FIRED" >>"$T/idle.out" 2>&1 &
      ;;
    prod)
      swayidle -w timeout "$TIMEOUT" "touch $FIRED" resume true \
        >>"$T/idle.out" 2>&1 &
      ;;
    sleeparm)
      # WITH A LOGIND EVENT ARMED. The hypothesis this shape exists to test:
      # swayidle's four D-Bus match rules (lock, unlock, sleep, property
      # changed) and its BlockInhibited read may all live behind a logind
      # connection it only opens when a logind-dependent event is configured.
      # Neither `bare`, `prod`, nor PRODUCTION arms one, so if this shape
      # defers and prod does not, the remedy is one argument in swayidle-mgr
      # rather than a whole bridge.
      swayidle -w timeout "$TIMEOUT" "touch $FIRED" resume true \
        before-sleep true >>"$T/idle.out" 2>&1 &
      ;;
    *) fail "unknown shape '$1'" ;;
  esac
  _idle_pid=$!
}

TABLE=
_cell() {   # <shape> <pre|post>
  rm -f "$FIRED"
  if [ "$2" = pre ]; then
    _inhibit_take
    if ! await 5 _inhibited; then
      fail "the inhibitor never reached logind, so cell $1/$2 would have
measured nothing. systemd-inhibit --list said:
$(systemd-inhibit --list --no-pager 2>&1)"
    fi
  fi
  _start_shape "$1"
  if [ "$2" = post ]; then
    sleep 1
    _inhibit_take
    if ! await 5 _inhibited; then
      fail "the inhibitor never reached logind, so cell $1/$2 would have
measured nothing. systemd-inhibit --list said:
$(systemd-inhibit --list --no-pager 2>&1)"
    fi
  fi
  # Generously past the timeout: an unsubscribed timer fires at TIMEOUT, so
  # waiting 3x that distinguishes "deferred" from "merely slow".
  if await $(( TIMEOUT * 3 )) _fired; then _r=FIRED; else _r=deferred; fi
  _idle_stop
  _inhibit_drop
  if ! await 10 _not_inhibited; then
    fail "the inhibitor row outlived its holder, so every later cell would
read against a still-held inhibitor"
  fi
  TABLE="$TABLE $1/$2=$_r"
  printf '  %-5s %-5s %s\n' "$1" "$2" "$_r" >&2
}

# --- THE ASSERTION: the instrument works ------------------------------------
# Without this, every "deferred" below is indistinguishable from a timer that
# was never going to fire, which is the vacuous-assertion shape this suite has
# paid for three times.
rm -f "$FIRED"
_start_shape bare
if ! await $(( TIMEOUT * 3 )) _fired; then
  fail "CONTROL FAILED: a ${TIMEOUT}s swayidle timeout did not fire on a
permanently idle headless compositor, so this file cannot measure anything
about inhibitors. swayidle output:
$(cat "$T/idle.out" 2>/dev/null)"
fi
_idle_stop

# --- THE MEASUREMENT: four cells, reported ----------------------------------
printf '  shape order result\n' >&2
_cell bare pre
_cell bare post
_cell prod pre
_cell prod post
_cell sleeparm pre
_cell sleeparm post

# --- WHAT IS ASSERTED, AND WHAT IS ONLY REPORTED ----------------------------
# ASSERTED: that arming a logind event makes the inhibitor effective in BOTH
# orderings. That is the mechanism the fix rests on, so a swayidle change which
# removed it must break a test rather than a box.
case $TABLE in
  *sleeparm/pre=deferred*) ;;
  *) fail "with a logind event armed, an inhibitor held BEFORE swayidle
started did not defer the timeout. The whole remedy rests on swayidle reading
BlockInhibited once it is on the bus, and it did not. Table:$TABLE" ;;
esac
case $TABLE in
  *sleeparm/post=deferred*) ;;
  *) fail "with a logind event armed, an inhibitor taken AFTER swayidle armed
did not defer the timeout, so swayidle reads BlockInhibited only at startup.
An app joins a call long after login, so a bridge targeting logind cannot
work and must target zwp_idle_inhibit_manager_v1 instead. Table:$TABLE" ;;
esac

# ONLY REPORTED: the `bare` and `prod` cells. They read FIRED today, which is
# precisely the defect being fixed, and ASSERTING them would be a test that
# DEMANDS A DEFECT: the moment swayidle-mgr arms a logind event, prod becomes
# `deferred` and a green assertion here would turn red on the fix. This suite
# has shipped that mistake twice (requiring `$(...)` to defeat a timeout bound,
# and requiring `go open` to tear a locker down), so the cells stay in the
# verdict line as a measurement and nothing branches on them.
pass "session-inhibit (control fires;$TABLE)"
