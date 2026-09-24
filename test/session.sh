# test/session.sh - the SESSION tier: real hooks, real daemons, real ladder.
#
# WHY A THIRD TIER. The other two never run the shipped hooks at all:
# scenario_init points VIGILANCE_HOOK_ROOT at a tree of RECORDER hooks, and the
# VM runs the same scenarios, so it inherits the recorders. The VM answers
# "does a from-scratch install produce a working system"; nothing answered
# "does the real hook set, driven by the real daemons, do the right thing".
#
# That hole is where the defects have actually been. Classifying the last ten:
#
#   activating window          real user systemd
#   idle ceiling               a real swayidle RESTART
#   lid close lit the screen   a real logind lock-session
#   argv drift                 a real daemon restart
#   saved-level false FAIL     the real hook set, together
#   deeper-than-lock message   the real log
#
# Six of them are real-component integration, and every one was found by the
# OPERATOR's machine rather than by a test. This tier is the substitute for
# that machine.
#
# IT USES THE GUEST'S REAL PATHS, deliberately: the real log, the real
# ~/.config/vigilance/hooks, the real units. Sandboxing them would put the
# recorders back one layer down and test the sandbox instead of the system.
# The throwaway VM is what makes that acceptable -- it is the whole reason
# there is a VM.
#
# SO IT REFUSES TO RUN WITHOUT AN EXPLICIT VM MARKER. `require` gates it on
# capabilities only test/vm/run grants, and this is the belt to that braces: a
# scenario in this tier stops the operator's idle timer and locks their screen,
# so a capability granted by mistake must not be enough to aim it at a desk.

# session_init <name>: assert the substrate, locate the INSTALLED package, and
# start from a known rung with a clean slate.
session_init() {
  harness_init "$1"
  require systemd userbus compositor

  # THE MARKER, and it fails rather than skipping. A skip here would be the
  # quiet kind of wrong: the tier would report "not applicable" on the one
  # substrate built to run it, and nobody would notice it had stopped.
  [ "${VIGILANCE_VM:-0}" = 1 ] || fail "the session tier drives REAL daemons
and locks a REAL screen. It runs only in the throwaway VM, and the capability
that let it get here was granted somewhere that is not one"

  # THROUGH THE INSTALLED COMMAND, not the checkout. This tier is the one that
  # should notice a package which passes its own tests and installs wrong, so
  # it asks the same question a user's session asks: what is on PATH?
  VIGILANT=$(command -v vigilant) \
    || fail "vigilant is not on PATH; setup.sh install did not publish it"
  # The libexec tree by the hooks' own self-location rule, so the tier cannot
  # disagree with the package about where its plugins live.
  PLUGINS=$(dirname "$(readlink -f "$VIGILANT")")/../libexec/vigilance
  [ -d "$PLUGINS/hooks" ] || fail "no shipped hooks under $PLUGINS"

  for _t in swaylock swayidle; do
    command -v "$_t" >/dev/null 2>&1 \
      || fail "$_t absent despite the compositor capability; the VM's package
list has regressed and this tier would pass against nothing"
  done

  HOOKS=${XDG_CONFIG_HOME:-$HOME/.config}/vigilance/hooks
  LOG=${XDG_STATE_HOME:-$HOME/.local/state}/vigilance.log
  rm -rf "$HOOKS"

  # WHERE THIS TEST'S EVIDENCE STARTS. The log is shared with everything else
  # in the guest, so an assertion counting "how many times did X happen" has to
  # mean "since this test began" or it reads another scenario's traffic.
  mkdir -p "$(dirname "$LOG")"
  LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)

  session_stop_idle
  "$VIGILANT" force open >/dev/null 2>&1 || true
}

# wire <edge> <tier> <hook>: symlink a REAL shipped hook, the way an integrator
# does. BY SYMLINK, NEVER COPY -- a copied hook breaks the self-location that
# lets it find hooklib, which is a live-box rule this tier should share.
wire() {   # <edge> <tier ('' | .verify | .due | .block)> <hook-name>
  _wd=$HOOKS/$1$2.d
  mkdir -p "$_wd"
  [ -f "$PLUGINS/hooks/$3" ] || [ -f "$PLUGINS/providers/$3" ] \
    || fail "wire: no shipped hook or provider named '$3'"
  if [ -f "$PLUGINS/providers/$3" ]; then
    ln -sf "$PLUGINS/providers/$3" "$_wd/10-$3"
  else
    ln -sf "$PLUGINS/hooks/$3" "$_wd/50-$3"
  fi
}

# wire_cross <kind> <hook>: the cross-cutting tiers, which sit at the scope
# root rather than under an edge.
wire_cross() {   # <idle|watchdog|audit|alert> <hook-name>
  mkdir -p "$HOOKS/$1.d"
  ln -sf "$PLUGINS/hooks/$2" "$HOOKS/$1.d/10-$2"
}

# --- driving it -------------------------------------------------------------

session_idle_start() {   # <lock-secs> <sleep-secs>
  SWAYIDLE_LOG_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/swayidle-mgr
  export SWAYIDLE_LOG_DIR
  LOCK_TIMEOUT=$1 BLANK_DELAY=$(( $2 - $1 )) VIGILANT_CMD=$VIGILANT \
    swayidle-mgr start >>"$T/idle.out" 2>&1 &
  SESSION_IDLE_PID=$!
  # Wait for the daemon to actually be up. Asserting on a timer that has not
  # started yet is how a scenario measures nothing and calls it a pass.
  _n=0
  while [ "$_n" -lt 50 ]; do
    pgrep -x swayidle >/dev/null 2>&1 && return 0
    sleep 0.2; _n=$((_n + 1))
  done
  fail "swayidle did not come up within 10s; this tier cannot proceed"
}

session_stop_idle() {
  swayidle-mgr stop >/dev/null 2>&1 || true
  [ -n "${SESSION_IDLE_PID:-}" ] && kill "$SESSION_IDLE_PID" 2>/dev/null
  SESSION_IDLE_PID=
  return 0
}

# --- reading the evidence ---------------------------------------------------

logsince() { tail -n +$(( LOG_FROM + 1 )) "$LOG" 2>/dev/null || true; }

crossed() {   # <edge> -> how many times since this test began
  logsince | grep -c "cross $1:" || true
}

said() { logsince | grep -q "$1"; }

depth() { "$VIGILANT" status 2>/dev/null | awk '/^depth:/ {print $2}'; }

# await <seconds> <predicate...>: poll rather than sleep-and-hope. A fixed
# sleep either wastes the run or fails under load, and under load is exactly
# when a timing bug shows up.
await() {
  _aw=$1; shift
  _n=0
  while [ "$_n" -lt $(( _aw * 5 )) ]; do
    if "$@"; then return 0; fi
    sleep 0.2; _n=$((_n + 1))
  done
  return 1
}

locker_up() { pgrep -x swaylock >/dev/null 2>&1; }

session_done() {
  session_stop_idle
  systemctl --user stop screen-lock.service >/dev/null 2>&1 || true
  systemctl --user reset-failed screen-lock.service >/dev/null 2>&1 || true
  "$VIGILANT" force open >/dev/null 2>&1 || true
  rm -rf "$HOOKS"
}

# session_reset: back to a known rung with a clean hook tree, WITHOUT
# re-running session_init. Re-initing mid-file calls harness_init again, which
# mints a second temp dir, leaks the first and clobbers the EXIT trap -- and it
# renames the test, so the pass line reports whichever name ran last. The
# "never swap a fixture mid-file, add a switch" rule, arriving as a fixture
# that swaps itself.
session_reset() {
  session_stop_idle
  systemctl --user stop screen-lock.service >/dev/null 2>&1 || true
  systemctl --user reset-failed screen-lock.service >/dev/null 2>&1 || true
  rm -rf "$HOOKS"
  "$VIGILANT" force open >/dev/null 2>&1 || true
}
