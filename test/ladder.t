#!/bin/sh
# test/ladder.t - the ladder: traversal, ordering, depth and FROM.
# Substrate-agnostic (no systemd, no hardware), so it runs in BOTH tiers.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init ladder

hook lock    10-a; hook lock    20-b
hook sleep   10-a; hook sleep   20-b
hook suspend 10-a
hook resume  10-a
hook wake    10-a; hook wake    20-b
hook unlock  10-a; hook unlock  20-b

# --- go is DECLARATIVE: it crosses every edge in between --------------------
# Saying "be at sleep" from `open` crosses lock THEN sleep. The caller never
# has to know the ladder's shape or sequence its own steps, and there is no
# minimum-rung special case to get wrong.
go sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-a
lock open 20-b
sleep lock 10-a
sleep lock 20-b"

# --- descent hooks run ASCENDING (10 -> 90) ---------------------------------
# asserted by the transcript above: 10-a before 20-b on both edges.

# --- idempotence: already there is a no-op, not an error --------------------
: > "$RECORD"
go sleep
expect_rc 0
expect_depth sleep
expect_record ""

# --- traversal is why suspending actually powers hardware down --------------
# Descending to `suspend` from `lock` MUST cross sleep, or the monitor
# stays lit through an S3 cycle. That was the real behaviour before traversal.
: > "$RECORD"
go lock
: > "$RECORD"
go suspend
expect_rc 0
expect_depth suspend
expect_record "sleep lock 10-a
sleep lock 20-b
suspend sleep 10-a"

# --- ascent runs DESCENDING (90 -> 10), unwinding the way it wound ----------
# and FROM carries the rung being LEFT at each step, which is the only thing
# that lets a hook tell restore-from-save (leaving sleep) from re-assert
# (leaving suspend).
: > "$RECORD"
go open
expect_rc 0
expect_depth open
expect_record "resume suspend 10-a
wake sleep 20-b
wake sleep 10-a
unlock lock 20-b
unlock lock 10-a"

# --- an unknown state is a USAGE error, not a refusal -----------------------
go nowhere
expect_rc 2
expect_depth open
expect_stderr "unknown state 'nowhere'"

# --- force ignores the recorded depth (drift recovery) ----------------------
# Depth says `open` but reality is dark. `force` starts from the far end so
# every edge toward the target is crossed regardless of what depth claims.
: > "$RECORD"
force open
expect_rc 0
expect_depth open
expect_record "resume suspend 10-a
wake sleep 20-b
wake sleep 10-a
unlock lock 20-b
unlock lock 10-a"

# --- `only` crosses ONE edge, skipping the rungs between ---------------------
# The single-edge form, for testing and for edge cases where traversal is the
# wrong thing. Direction follows the current depth, so it reaches the ascent
# edges too, which a "run the hooks named for that rung" rule could not.
: > "$RECORD"
go open
: > "$RECORD"
only sleep
expect_rc 0
expect_depth sleep
expect_record "sleep open 10-a
sleep open 20-b"          # sleep.d only; lock.d was SKIPPED

# ...and it still commits the depth. A hook that changed hardware without the
# record following is the desync that left a monitor dark for two days.
: > "$RECORD"
only lock
expect_rc 0
expect_depth lock
expect_record "wake sleep 20-b
wake sleep 10-a"          # the ASCENT edge, chosen from current depth

# already there is a no-op, as with go/force
: > "$RECORD"
only lock
expect_rc 0
expect_record ""

pass
