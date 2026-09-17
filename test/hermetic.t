#!/bin/sh
# test/hermetic.t - THE TEST THAT WOULD HAVE CAUGHT MOST OF OUR BUGS.
#
# Seven distinct defects in this project came from ONE cause: a check or a test
# read the DEVELOPER'S LIVE BOX instead of a fixture, so its verdict was about
# the host rather than the code. Each was found late, by a human noticing
# something odd, and each cost a round trip:
#
#   report read the real backlight            -> failed a correct test
#   pgrep found the developer's real swaylock -> verdict tracked their screen
#   report read the real PATH                 -> sandboxed install "failed"
#   _check_path_unique read the real PATH     -> same, one layer out
#   _rep_idle_armed under a live pgrep        -> ran ONLY because the dev box
#                                                had swayidle up; VM missed it
#   _check_stale_trees assumed the live tree  -> named the working tree as stale
#   _check_root_inputs assumed the prefix     -> asserted a tree nothing runs
#
# Writing more scenarios would not have caught any of them. They were not wrong
# ANSWERS, they were right answers to a question about the wrong machine.
#
# So this asserts the BOUNDARY itself, as a ratchet:
#
#   1. every probe that reads host state is overridable, and scenario_init
#      sandboxes it; and
#   2. a host read may only appear in a function DECLARED to be deliberately
#      live. A new one anywhere else fails until it is given an override or
#      added below with a reason.
#
# The second half is the part that compounds. Every one of the seven was a new
# probe added without an override; each time, the author (me) did not notice,
# because nothing asked.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init hermetic

VIG=$HERE/bin/vigilant

# --- 1. every sandboxable probe is actually sandboxed -----------------------
# If a probe reads the host and has an override, scenario_init MUST set it, or
# every scenario silently inherits the developer's machine for that fact.
for _p in VIGILANCE_HOOK_ROOT VIGILANCE_MACHINE_HOOKS VIGILANCE_RUN_DIR \
          VIGILANCE_LOG VIGILANCE_SYS_BACKLIGHT VIGILANCE_SYS_DRM \
          VIGILANCE_SYS_LEDS VIGILANCE_LOCKER_UP VIGILANCE_SESSION \
          VIGILANCE_IDLE_CMDLINE VIGILANCE_SLEEP_BUDGET; do
  grep -q "export $_p=" "$HERE/test/scenario.sh" \
    || fail "$_p is an overridable host probe, but scenario_init does not set
it. Every scenario therefore reads the DEVELOPER'S box for that fact, and its
verdict changes with their screen, their hardware or their session"
  # ...and it must actually be exported into the environment at runtime.
  eval "_v=\${$_p:-}"
  [ -n "$_v" ] || fail "$_p is set by scenario.sh but empty at runtime"
done

# --- 2. THE RATCHET: no host read outside a declared-live function ----------
# These functions read the real system ON PURPOSE. The suite's own rule is that
# actuators may be stubbed but the TRUST ROOT may not -- a stubbed `systemctl`
# lies, and a lying stub is how a green test coexists with a broken box. So
# systemd, logind and the process table are read for real here, and scenarios
# scope around these sections rather than faking them.
#
# Adding a name here is a deliberate act with a cost: whatever it reads becomes
# untestable in the stub tier and host-dependent in both. Prefer an override
# with a live fallback (see _r_session, _rep_idle_armed) over a new entry.
LIVE_OK='_rep_machinery _rep_unit_runnable _rep_idle_armed _r_session
_r_locker_up cmd_rescue cmd_report _rep_budget_secs'

_offenders=$(awk -v ok="$LIVE_OK" '
  BEGIN { n = split(ok, a, /[[:space:]]+/)
          for (i = 1; i <= n; i++) allow[a[i]] = 1 }
  /^[_a-zA-Z][_a-zA-Z0-9]*\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn) }
  /^\}/ { fn = "" }
  # The host-state tokens. Deliberately narrow: these are reads of the RUNNING
  # machine, not of anything the test controls.
  /\/sys\/|\/proc\/|pgrep |systemctl |loginctl |journalctl |hostname -s/ {
    if ($0 ~ /^[[:space:]]*#/) next          # prose
    if ($0 ~ /VIGILANCE_[A-Z_]+/) next       # behind an override
    if (fn != "" && (fn in allow)) next      # declared live
    printf "%s:%d %s\n", (fn == "" ? "<toplevel>" : fn), FNR, substr($0, 1, 60)
  }' "$VIG")

if [ -n "$_offenders" ]; then
  printf '%s\n' "$_offenders" >&2
  fail "a host read appeared outside every declared-live function and without an
override. That is the shape of seven past bugs: the check answers a question
about the DEVELOPER'S machine. Give it a VIGILANCE_* override and sandbox it in
scenario_init, or add the function to LIVE_OK with a reason"
fi

# --- 3. the overrides must actually WORK, not merely exist ------------------
# An override nothing honours is worse than none: it reads as sandboxed while
# the probe still reaches the real box. Assert each changes the answer.
mkdir -p "$T/fake/backlight/panel0"
echo 7   > "$T/fake/backlight/panel0/actual_brightness"
echo 100 > "$T/fake/backlight/panel0/max_brightness"
_out=$(VIGILANCE_SYS_BACKLIGHT="$T/fake/backlight" "$VIG" report 2>&1) || true
case "$_out" in
  *panel0*) ;;
  *) fail "VIGILANCE_SYS_BACKLIGHT did not redirect the backlight probe; the
override exists but the code still read the real /sys" ;;
esac

# The locker probe flips the coherence verdict, so it is observable -- but only
# where a lock PROVIDER is wired. report deliberately says "no locker expected"
# when nothing could raise one, because a greeter sits at this rung forever with
# no provider and demanding a locker made its report permanently red. So wire a
# provider first: this is asserting that the override is honoured, not
# re-testing the greeter carve-out.
hook lock 50-provider
go lock
_up=$(VIGILANCE_LOCKER_UP=1 "$VIG" report 2>&1) || true
_dn=$(VIGILANCE_LOCKER_UP=0 "$VIG" report 2>&1) || true
case "$_up" in *"matches a live locker"*) ;; *)
  fail "VIGILANCE_LOCKER_UP=1 was not honoured" ;; esac
case "$_dn" in *"no locker is running"*) ;; *)
  fail "VIGILANCE_LOCKER_UP=0 was not honoured" ;; esac

# --- 4. a scenario must not write outside its own sandbox ------------------
# The other half of hermeticity. Tests have polluted the operator's real
# vigilance.log by accident before, which is why the log is sandboxed at all.
# This asserts the sandbox actually holds across a full crossing.
_realdir=${XDG_STATE_HOME:-$HOME/.local/state}
_before=$(cksum "$_realdir/vigilance.log" 2>/dev/null || echo none)
go open
go lock
go open
_after=$(cksum "$_realdir/vigilance.log" 2>/dev/null || echo none)
[ "$_before" = "$_after" ] || fail "crossing edges in a scenario wrote to the
REAL vigilance.log ($_realdir); the sandbox leaks and every test run pollutes
the operator's own record"

# --- 5. AND THE TESTS THEMSELVES, which nothing was ratcheting -------------
# Sections 1-3 guard the PRODUCT against reading the host. This guards the
# SUITE, and it is a distinct failure with the same cause.
#
# `report` has ONE exit code for nine sections, and some of them ask the real
# machine -- machinery queries the live systemd about whether vigilance's units
# are enabled. So:
#
#   _out=$("$VIGILANT" report) && fail "it should have failed"
#
# is not an assertion about the code under test. On any host red for an
# unrelated reason it passes for free, and keeps passing with the check it
# claims to cover DELETED. greeter.t hit this in the VM, where report was red on
# units that file never meant to test; actuators.t and rescue.t each carried one
# of these until this ratchet was written.
#
# The fix is never to weaken the claim, it is to aim it: assert on the SECTION
# that owns the behaviour, via _fail_in / _no_fail_in. Those give the same
# verdict on every substrate, which is the whole property.
#
# Scoped to `report` deliberately. Other verbs (verify, audit, due, enforce) run
# entirely on sandboxed state, so their exit codes ARE attributable and tests
# branch on them correctly throughout.
# The `|| true` exemption is matched ANYWHERE on the line, not only after a
# closing paren. Written paren-anchored it flagged
#
#   _rep() { "$VIGILANT" report 2>>"$T/stderr" || true; }
#
# which discards the code exactly as intended -- a false positive on the helper
# form, in a checker whose whole value is that its verdicts are trusted.
#
# PROSE IS SKIPPED, and it caught this scanner on its first run: the comment
# above quotes the banned pattern to explain it, and the scan matched its own
# explanation. A checker that flags the documentation OF the rule is the same
# reading-the-wrong-thing class it exists to police, one level up.
_branchers=$(grep -n '\("\$VIGILANT"\|"\$VIG"\) report' "$HERE"/test/*.t \
               2>/dev/null \
             | grep -v ':[0-9]*: *#' \
             | grep -v '|| *true' | grep -v '|| *:' \
             | grep -e '&&' -e '||' -e '^[^:]*:[0-9]*: *if ' || true)
if [ -n "$_branchers" ]; then
  printf '%s\n' "$_branchers" >&2
  fail "a test BRANCHES on the whole exit code of 'report'. That code folds in
sections which read the real host, so the assertion is partly about the machine
running the suite: it passes for free wherever the host is already red, and goes
on passing with the check it claims to cover removed. Assert on the owning
section instead -- _fail_in / _no_fail_in -- which reads the same on every
substrate. Discarding the code with '|| true' and grepping the output is fine"
fi

pass
