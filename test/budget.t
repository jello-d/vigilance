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
# Actionable, or the reader has a number and no next step. These are plain
# hooks, none of which resolves into a providers/ directory, so this is the
# PESSIMISTIC branch: it must say so rather than present the assumption as a
# measurement.
case "$_out" in
  *"no hook in lock.d resolves into a providers/ directory"*|\
  *"No hook in lock.d resolves into a providers/ directory"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no identifiable provider the check assumed every act hook runs
before the lock -- correct, and the safe direction -- but did not say it was an
assumption. A guess presented as a measurement is what sends someone tuning a
number that was never measured" ;;
esac
case "$_out" in
  *VIGILANCE_HOOK_TIMEOUT*) ;;
  *) fail "the overrun was reported without naming a remedy" ;;
esac

# --- 3b. AN IDENTIFIED PROVIDER changes the number, not just the wording ----
# This is the whole point of identifying it: only the hooks that run BEFORE the
# lock can cost the lock. A provider ordered first means one act hook precedes
# it, however many follow.
#
# It is found by CONVENTION -- a hook resolving into a providers/ directory --
# so the fixture builds exactly that: a real directory of that name, symlinked
# into lock.d the way an integrator wires it.
mkdir -p "$T/plug/providers"
printf '#!/bin/sh\nexit 0\n' > "$T/plug/providers/swaylock"
chmod +x "$T/plug/providers/swaylock"

rm -rf "$VIGILANCE_HOOK_ROOT/lock.d"
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
ln -sf "$T/plug/providers/swaylock" "$VIGILANCE_HOOK_ROOT/lock.d/05-provider"
_hook_n lock.d 3                      # 3 plain hooks, all sorting AFTER 05-
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take"*)
     printf '%s\n' "$_out" >&2
     fail "with the provider ordered FIRST, three hooks behind it were still
counted against the lock. They run after the screen is already locked: counting
them means the warning can never be cleared by the remedy it recommends, which
is how a check gets ignored" ;;
esac
# The milder TOTAL warning is still correct here and must remain: 4 hooks x 12s
# is 48s, so the unit can still be killed -- after the screen is locked. The two
# claims are different and the distinction is the reason for identifying the
# provider at all.
case "$_out" in
  *"total"*"against lock-on-sleep's 25s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the lock now fits, but 48s of total work against a 25s budget went
unreported. The unit is still killed; what survives is the lock" ;;
esac

# ...and ordering it LAST puts them back, which is the same fixture proving the
# position is what is being read rather than the mere presence of a provider.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/05-provider"
ln -sf "$T/plug/providers/swaylock" "$VIGILANCE_HOOK_ROOT/lock.d/99-provider"
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take 48s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with the provider ordered LAST, the three hooks ahead of it were not
counted against the lock. Those are exactly the hooks that can stop the screen
locking at all" ;;
esac
case "$_out" in
  *"run before the provider finishes"*) ;;
  *) fail "an identified provider was not described in terms of its position" ;;
esac

# --- 3c. BLOCK hooks still count, even with the provider identified --------
# The two halves of the critical span come from different places and only this
# case needs both: every other provider case has no block hooks, so dropping
# the block term entirely goes unnoticed there.
#
# 1 block + a provider ordered SECOND = 3 hooks x 12s = 36s, over the 25s
# budget. Drop the block term and it reads 24s, which fits -- so the verdict
# flips, which is what makes the case worth having.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/99-provider"
rm -rf "$VIGILANCE_HOOK_ROOT/lock.d"
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/lock.d/10-first"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/10-first"
ln -sf "$T/plug/providers/swaylock" "$VIGILANCE_HOOK_ROOT/lock.d/20-provider"
_hook_n lock.block.d 1
_out=$(VIGILANCE_HOOK_TIMEOUT=10 _rep)
case "$_out" in
  *"LOCK itself can take 36s"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a block hook was not counted alongside an identified provider. The
block tier runs before every act hook, so it is always part of the delay before
the lock -- dropping it understates the span by exactly the tier that is
guaranteed to precede the provider" ;;
esac
rm -rf "$VIGILANCE_HOOK_ROOT/lock.block.d" "$VIGILANCE_HOOK_ROOT/lock.d"
_hook_n lock.d 3

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
# ...as INFO, not WARN. The lock -- the guarantee -- fits. On a normally-wired
# box the total exceeds the budget permanently and no realistic wiring clears
# it, so warning here would be a line that is always on, which is how a report
# teaches you to skip the line that matters.
# Matched on the LINE, not on the whole report: a shell glob spans newlines, so
# `*"[WARN]"*"total"*` against the full output matches any unrelated warning
# earlier in the report followed by the word "total" later. That is the same
# too-loose-assertion class this suite keeps finding, in a test written to
# police severity.
_totline=$(printf '%s\n' "$_out" | grep 'total')
case "$_totline" in
  *"[WARN]"*)
     printf '%s\n' "$_totline" >&2
     fail "an overrun that costs only the verification was raised as a WARN.
The lock itself fits, and a warning no wiring can clear is one the reader
learns to scroll past" ;;
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
