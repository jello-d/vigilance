#!/bin/sh
# test/budget.t - can the lock finish inside the time systemd gives it?
#
# Two numbers in two different files that must relate, with nothing relating
# them. lock-on-sleep.service is a system oneshot with TimeoutStartSec=25; the
# lock edge runs every block and act hook wired on it, each bounded by
# VIGILANCE_HOOK_TIMEOUT (plus the SIGKILL grace). Nothing ever compared them.
#
# WHY IT MATTERS, and why the total is the wrong number to watch. Hooks run in
# LEXICAL order and the block tier runs before any of them, so every hook
# ordered ahead of the provider is a hook that can delay the LOCK ITSELF. Found
# on a live box: block `10-phantom` and act `20-mute-on-lock` both precede
# `50-swaylock`, so at the 10s default the provider can start at 24s of a 25s
# budget. systemd then kills the unit mid-lock and logind suspends anyway,
# because nothing can veto a suspend.
#
# So the critical span is (block + act), not the whole edge. report and verify
# run after the screen is already locked: exceeding there costs the
# VERIFICATION, not the lock, and the two must not be reported as the same
# thing.
#
# I ESTIMATED THIS WRONG BY HAND FIRST -- counted lock.d only, got "2 hooks,
# fine", and missed that block, report and verify all draw on the same budget.
# The real figure on that box was 8 hooks. That is the argument for computing it
# rather than leaving it to whoever remembers the tiers.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init budget

# The budget comes from scenario.sh (25s, the shipped unit's value), so the
# arithmetic is what is under test rather than the host's systemd.
_hook_n() {   # <dir> <count>
  mkdir -p "$VIGILANCE_HOOK_ROOT/$1"
  _i=0
  while [ "$_i" -lt "$2" ]; do
    _i=$((_i + 1))
    printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/$1/1$_i-h"
    chmod +x "$VIGILANCE_HOOK_ROOT/$1/1$_i-h"
  done
}
_rep() { "$VIGILANT" report 2>>"$T/stderr" || true; }

# --- 1. nothing wired: there is no budget to spend --------------------------
_out=$(_rep)
case "$_out" in
  *"nothing can spend its budget"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no hooks on the lock edge, report did not say the budget is
unspendable. Reporting a number there invites tuning a limit nothing uses" ;;
esac

# --- 2. hooks that FIT are reported as fitting ------------------------------
# 2 hooks x 12s = 24s against 25s. Deliberately just inside: an off-by-one in
# the comparison shows up here and nowhere else.
_hook_n lock.d 2
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"fits lock-on-sleep's 25s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "2 hooks at a 10s bound is 24s of a 25s budget and was not reported
as fitting. A check that cries wolf on a correct machine is one you stop
reading, which costs you the case that matters" ;;
esac
_no_fail_in "$_out" budget "a lock edge that fits its budget was flagged"

# --- 3. ONE MORE HOOK and the LOCK no longer fits ---------------------------
# 3 x 12 = 36s > 25s. This is the whole point: the failure arrives months later
# when somebody wires an unrelated plugin onto the lock edge, and nothing
# connects that act to the suspend unit's timeout.
_hook_n lock.d 3
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take 36s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "3 hooks at a 10s bound is 36s against a 25s budget and report did
not say the LOCK itself can overrun. If those hooks hang, systemd kills the
unit mid-lock and logind suspends anyway -- nothing can veto a suspend" ;;
esac
# Actionable, or the reader has a number and no next step.
case "$_out" in
  *"provider FIRST"*) ;;
  *) fail "the overrun was reported without naming a remedy" ;;
esac

# --- 4. the BLOCK tier draws on the same budget -----------------------------
# Easy to miss, and the sharpest of them: block.d runs BEFORE the depth is
# committed and before any actuator, so a block hook is always ahead of the
# provider no matter how the act tier is numbered.
rm -rf "$VIGILANCE_HOOK_ROOT/lock.d"
_hook_n lock.d 2
_hook_n lock.block.d 1
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take 36s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a block hook was not counted against the lock's budget. block.d runs
before every act hook, so it delays the provider more reliably than anything in
lock.d does" ;;
esac

# --- 5. report/verify overrun is a DIFFERENT, milder claim ------------------
# They run after the screen is locked. Saying "the lock can overrun" there would
# be false, and false alarms are how this check gets ignored.
rm -rf "$VIGILANCE_HOOK_ROOT/lock.block.d" "$VIGILANCE_HOOK_ROOT/lock.d"
_hook_n lock.d 1
_hook_n lock.verify.d 3
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take"*)
     printf '%s\n' "$_out" >&2
     fail "verify hooks were counted as delaying the LOCK. They run in
ExecStartPost, after the screen is already locked: an overrun there costs the
verification, not the lock, and conflating them makes the sharp warning
routine" ;;
esac
case "$_out" in
  *"total"*"against lock-on-sleep's 25s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "48s of verify work against a 25s budget was not reported at all. The
unit is still killed; what survives is the lock, not the verification" ;;
esac

# --- 6. the BOUND is what scales it, so it must be read live ----------------
# Lowering VIGILANCE_HOOK_TIMEOUT is one of the three remedies the warning
# names. If the check used a hardcoded 10 it would keep warning after the
# operator took its own advice.
_out=$(VIGILANCE_HOOK_TIMEOUT=3 _rep)
_no_fail_in "$_out" budget "a lowered hook bound still reported an overrun"
case "$_out" in
  *"fits lock-on-sleep's 25s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with the bound lowered to 3s, 4 hooks is 20s and fits, but report
still says otherwise -- it is not reading the bound actually in force, so it
would go on warning after the remedy it suggested was applied" ;;
esac

# --- 6b. EXACTLY on the budget still fits ----------------------------------
# The boundary, which nothing above touches: every other case is several
# seconds clear of it, so `>` and `>=` are indistinguishable there. A worst case
# of exactly the budget is spent, not exceeded, and reporting it as an overrun
# would send an operator chasing headroom they already have.
rm -rf "$VIGILANCE_HOOK_ROOT/lock.verify.d" "$VIGILANCE_HOOK_ROOT/lock.d"
_hook_n lock.d 1
_out=$(VIGILANCE_HOOK_TIMEOUT=23 _rep)      # 1 x (23+2) = 25s, the budget
case "$_out" in
  *"can take"*)
     printf '%s\n' "$_out" >&2
     fail "a worst case of exactly 25s against a 25s budget was reported as an
overrun. It is spent, not exceeded; an off-by-one here sends the operator
looking for headroom that is already there" ;;
esac
case "$_out" in
  *"fits lock-on-sleep's 25s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a worst case of exactly the budget was not reported as fitting" ;;
esac

# --- 7. an UNREADABLE budget says nothing rather than guessing -------------
# A box where the sleep unit was never installed has no TimeoutStartSec. Any
# number invented here would be a verdict about a unit that does not exist.
_out=$(VIGILANCE_SLEEP_BUDGET=infinity _rep)
case "$_out" in
  *"can take"*|*"fits lock-on-sleep"*)
     printf '%s\n' "$_out" >&2
     fail "with the unit's timeout reported as 'infinity', report still pinned
a budget verdict on it" ;;
esac
# Two shapes, because they take DIFFERENT branches and only one was covered.
# "1min 30s" ends in `s`, so it survives the seconds-suffix strip and is caught
# by the digit check; "2min" does not end in `s` at all. A mutation deleting the
# second branch passed until this case existed.
for _bad in "1min 30s" "2min" "25000000"; do
  _out=$(VIGILANCE_SLEEP_BUDGET="$_bad" _rep)
  case "$_out" in
    *"not a plain number of seconds"*) ;;
    *) printf '%s\n' "$_out" >&2
       fail "a timeout of '$_bad' was neither understood nor reported as
unparsed: the check silently did nothing, which is the exact failure this
project exists to catch, inside the check meant to catch it" ;;
  esac
done

pass
