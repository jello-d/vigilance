#!/bin/sh
# test/fault-act.t - the act tier under duress. THE LOCK MUST STILL HAPPEN.
#
# FAULTS: hook-hangs-before-the-provider, hook-fails.
#
# This is the most consequential invariant in the package, and it had never
# been tested against a real hang. Hooks run in LEXICAL order and the provider
# is not first by accident: it is ordered first precisely so that a hook ahead
# of it cannot stop the screen locking. Before that ordering existed, a hook
# that hung blocked the traversal forever, `50-provider` never ran, the screen
# never locked, nothing was logged and no alert fired -- and under
# lock-on-sleep.service systemd then killed the unit and the box slept UNLOCKED,
# because nothing can veto a suspend.
#
# The stub tier proves the BOUND exists (hook-bounds.t) and `report` computes
# the budget arithmetic (budget.t). Neither answers the question an operator
# cares about: with a hook genuinely wedged, does the machine still lock?
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-act
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

# A SYNTHETIC hook, not a shipped one: no shipped hook hangs, and the fault
# being injected is "a hook misbehaves", which is a property of the tier rather
# than of any particular plugin. Ordered 05- so it runs BEFORE the provider's
# 10-, which is the whole point.
_badhook() {   # <name> <body>
  mkdir -p "$HOOKS/lock.d"
  printf '#!/bin/sh\n%s\n' "$2" > "$HOOKS/lock.d/$1"
  chmod +x "$HOOKS/lock.d/$1"
}

wire lock ''      swaylock
wire lock .verify locker-up

# --- 1. A HOOK THAT HANGS MUST NOT STOP THE LOCK ---------------------------
# It IGNORES SIGTERM as well as hanging, because a hook that dies politely is
# indistinguishable from a bounded one -- the distinction a mutation dropping
# the `-k` backstop once hid behind.
_badhook 05-hang 'trap "" TERM; sleep 900'
_t0=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=3 "$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _t0 ))

await 15 locker_up || fail "a hook ordered AHEAD of the provider hung, and no
locker came up. That is the founding failure of this package: the screen never
locks, and under the suspend unit systemd kills the unit and the box sleeps
UNLOCKED, because nothing can veto a suspend"
[ "$(depth)" = lock ] || fail "the lock edge did not record; depth='$(depth)'"
[ "$_el" -le 40 ] || fail "the crossing took ${_el}s against a 3s per-hook
bound. The bound is advisory, and the suspend unit's budget is 25s"
# A TIMEOUT IS NOT A FAILURE, and the runner is right to say so in different
# words: "HOOK TIMED OUT after Ns" names the bound that fired, where "HOOK
# FAILED" names an exit status. A reader chasing a wedged plugin needs to know
# which. My first draft asserted the generic message and the tier correctly
# disagreed with it.
said "HOOK TIMED OUT" || fail "a wedged hook was killed and the log does not
say so. Bounding a hook silently is how a broken plugin runs for weeks"
said "HOOK FAILED" && fail "a hook killed by its BOUND was reported as a plain
failure. The distinction is the whole diagnosis: one names an exit status, the
other names the bound that fired"

# --- 2. A HOOK THAT FAILS MUST NOT STOP THE LOCK EITHER --------------------
# The quieter half: a hook that returns 1 immediately. The edge must still
# cross and the failure must be LOUD -- exit 1 from the runner means "crossed
# but a hook failed", which is a different claim from "did not cross".
session_reset
wire lock ''      swaylock
wire lock .verify locker-up
_badhook 05-fail 'exit 1'
_rc=0
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || _rc=$?
await 10 locker_up || fail "a hook returning 1 prevented the locker coming up"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after a failing hook"
[ "$_rc" = 1 ] || fail "the runner exited $_rc with a failed hook. 1 means
'crossed, but a hook failed'; 0 would tell a unit everything went well and 3
would tell it nothing happened, and both are false here"
said "HOOK FAILED" || fail "a failing hook raised nothing in the log"

pass
