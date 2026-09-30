#!/bin/sh
# test/perf.t - the runner's own cost per crossing, which nothing guarded.
#
# THE REGRESSION THIS EXISTS FOR ALREADY HAPPENED. Single-sourcing the ladder
# made `_intent_of` spawn an `awk` per call, and it is called once per HOOK per
# edge: 1210ms against 1128ms for a lock+unlock pair, ~7% on the security path.
# It was found by going looking during a debt review, months later. Nothing in
# the suite could have seen it, and the reasoning that let it through ("80ms
# is noise against a 25s budget") is TRUE and is also exactly how a real
# regression ships.
#
# COUNTS, NOT MILLISECONDS, and that choice is what makes this worth having. A
# wall-clock assertion on a shared developer box is flaky, and a flaky test is
# one people re-run until it goes green; a fork count is deterministic
# (measured: identical across repeated runs and both substrates) and it is
# ALSO the actual defect: the regression was a process spawned per hook, not
# a slow algorithm.
#
# HOW: every external the runner can reach is replaced by a counting shim, and
# PATH is set to that dir ALONE. A command this file forgot to shim therefore
# fails to resolve and the crossing breaks, which case 1 asserts against, so
# an incomplete shim list is a loud failure rather than a silent undercount.
#
# WHAT IT CANNOT SEE: the hooks' own internals. A hook is exec'd directly, and
# what it spawns is the integrator's business, not the runner's. That boundary
# is the point: `report`'s budget section already covers hook count x bound.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init perf

VIGILANT=$HERE/bin/vigilant

# THE SHIMS. Every tool the runner might invoke, resolved to an absolute path
# ONCE so the shim cannot recurse into itself through PATH.
SHIM=$T/shim
mkdir -p "$SHIM"
_tools="awk sed date cat head tail tr cut grep wc cksum basename dirname
        mkdir rm ln mv cp timeout sort uniq stat id hostname sleep pgrep pkill
        systemctl loginctl readlink find xargs touch chmod comm expr od logger
        notify-send systemd-cat busctl"
for _t in $_tools; do
  _real=$(command -v "$_t" 2>/dev/null) || continue
  case $_real in */*) ;; *) continue ;; esac     # a builtin costs no fork
  printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' \
    "$_t" "$T/calls" "$_real" > "$SHIM/$_t"
  chmod +x "$SHIM/$_t"
done

# ONE MEASUREMENT: a lock+unlock pair with N no-op hooks on each edge, from a
# fresh runtime dir so nothing depends on what a previous case left behind.
#
# The hooks record through a SHELL BUILTIN, deliberately: an `echo` into a file
# forks nothing, so proving the hooks ran costs nothing that this counts.
_measure() {   # <hooks per edge> -> prints the total external count
  _m_d=$T/m$1
  rm -rf "$_m_d"
  mkdir -p "$_m_d/hooks/lock.d" "$_m_d/hooks/unlock.d" "$_m_d/run" "$_m_d/mach"
  _m_i=1
  while [ "$_m_i" -le "$1" ]; do
    for _m_e in lock unlock; do
      printf '#!/bin/sh\necho ran >> "%s"\nexit 0\n' "$_m_d/ran" \
        > "$_m_d/hooks/$_m_e.d/$_m_i-noop"
      chmod +x "$_m_d/hooks/$_m_e.d/$_m_i-noop"
    done
    _m_i=$((_m_i + 1))
  done
  : > "$T/calls"
  : > "$_m_d/ran"
  for _m_v in lock open; do
    # VIGILANCE_HOOK_PATH so the shims count the `timeout` that wraps each
    # hook as well: the runner sets PATH for a hook invocation, so without it
    # the bound's own fork resolves from the real PATH and goes unseen. That
    # would understate the per-hook cost by one and, worse, measure a runner
    # whose hooks are UNBOUNDED, which is not the shipped configuration.
    env -i PATH="$SHIM" HOME="$HOME" \
      VIGILANCE_HOOK_ROOT="$_m_d/hooks" VIGILANCE_MACHINE_HOOKS="$_m_d/mach" \
      VIGILANCE_RUN_DIR="$_m_d/run" VIGILANCE_LOG="$_m_d/log" \
      VIGILANCE_HOOK_PATH="$SHIM" \
      "$VIGILANT" go "$_m_v" >/dev/null 2>>"$T/stderr" \
      || { printf 'CROSSING FAILED (go %s)\n' "$_m_v" >&2; return 1; }
  done
  wc -l < "$T/calls" | tr -d ' '
}

# --- 1. THE PRECONDITIONS, or every number below is about nothing -----------
_n2=$(_measure 2) || fail "a crossing failed under the shimmed PATH. The usual
cause is a tool this file does not shim: PATH is the shim dir ALONE, so an
unshimmed command cannot resolve. Add it to _tools, and note that the miss
was LOUD, which is why the list is exhaustive rather than trusted.
$(tail -3 "$T/stderr" 2>/dev/null)"
_ran=$(wc -l < "$T/m2/ran" | tr -d ' ')
[ "$_ran" = 4 ] || fail "expected 4 hook runs (2 hooks x 2 edges), saw $_ran.
The count below would be measuring a traversal that did not happen"
# AND THE BOUND WAS IN FORCE. Without this the file would happily certify a
# cheaper runner that had stopped wrapping its hooks in `timeout`: a cost
# reduction that is a safety regression, and the one this test could be read as
# encouraging.
_tmo=$(grep -c '^timeout$' "$T/calls" 2>/dev/null || echo 0)
[ "$_tmo" -ge 4 ] || fail "the per-hook `timeout` bound did not run ($_tmo of 4
hook invocations). Either the shim list lost `timeout` or the runner stopped
bounding its hooks; the second is a security regression this must not pass"

# --- 2. THE MARGINAL COST PER HOOK, which is the invariant ------------------
# The historical defect added ONE spawn per hook per edge. A total alone cannot
# see that (it moves with the fixed cost too), so the claim is the SLOPE:
# measure at two hook counts and divide.
#
# Measured on 2026-09-29: 1.5 per hook run. It was 4 when this file was written:
# the state dir (`mkdir`), the kind string (`tr`), the hook name (`basename`)
# and the bound (`timeout`), and writing the guard is what made the first
# three visible as forks that the shell does for nothing. Only the bound is
# unavoidable, and it is the one that must never be optimised away.
_n8=$(_measure 8) || fail "the 8-hook crossing failed"
# IN TENTHS, because the honest figure is not a whole number and rounding hides
# a regression. The per-hook state dir is created only when missing, and a hook
# wired on two edges shares one state dir, so the `mkdir` is paid on the first
# crossing and not the second: 1.5 per hook run, not 2.
_slope=$(( (_n8 - _n2) * 10 / (16 - 4) ))
[ "$_slope" -le 15 ] || fail "the runner now spawns $(( _slope / 10 )).$((
_slope % 10 )) external commands per hook run, against a ceiling of 1.5. With 8
hooks across two edges that is $(( _slope * 16 / 10 )) forks on the security
path where 24 is the measured budget. This is the exact shape of the regression
this file exists for: a helper called once per hook per edge that runs a program
instead of using the shell.

If the cost is deliberate, re-derive the ceiling and say why in the commit,
do not nudge the number. n2=$_n2 n8=$_n8"

# --- 3. AND THE FIXED COST, so startup cannot grow unwatched ---------------
# Everything that is not per-hook: reading the depth, the ladder flattening,
# the lock, the log. Asserted as a ceiling on the small case, because the slope
# above already covers the part that scales.
[ "$_n2" -le 36 ] || fail "a lock+unlock pair with 2 hooks per edge now costs
$_n2 external commands, against 36 measured. The slope is unchanged, so this is
STARTUP work: something the runner does once per invocation got more expensive,
and every crossing pays it. Re-derive deliberately rather than raising it."

pass "runner cost: $_n2 for 2 hooks/edge, $_n8 for 8, $(( _slope / 10 )).$((
_slope % 10 )) per hook run"
