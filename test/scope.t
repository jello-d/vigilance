#!/bin/sh
# test/scope.t - the two hook scopes and the layering that orders them.
#
# Peripherals belong to the MACHINE (/etc/vigilance/hooks, every session);
# locking, audio and notifications belong to a USER (~/.config/vigilance/
# hooks). This is what lets a greeter session work with NO configuration of its
# own: it has no user root, so it gets the machine hooks and nothing else.
#
# MACHINE IS THE LOWER LAYER, so it comes up first and goes down last, exactly
# as systemd orders units. Dependencies point user -> machine and never the
# reverse: a USB DAC powered down by a machine hook must be back before a user
# hook tries to unmute it by name, or pactl will not find the device.
#
#   descent  user 10->90, then machine 10->90   (tear down high, then low)
#   ascent   machine 90->10, then user 90->10   (bring up low, then high)
#
# Getting this backwards is silent and only bites when a user hook genuinely
# depends on hardware being awake, which is exactly the case that is hardest
# to debug after the fact.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init scope

hook  sleep 10-u; hook  sleep 90-u
mhook sleep 10-m; mhook sleep 90-m
hook  wake  10-u; hook  wake  90-u
mhook wake  10-m; mhook wake  90-m
hook  lock  10-u
mhook lock  10-m

# --- descent: USER first, then MACHINE, each ascending ----------------------
go sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-u
lock open M:10-m
sleep lock 10-u
sleep lock 90-u
sleep lock M:10-m
sleep lock M:90-m"

# --- ascent: MACHINE first, then USER, each descending ----------------------
# The exact mirror of the descent: reverse the scope order AND the order
# within each scope. The hardware is back before user hooks touch it.
: > "$RECORD"
go lock
expect_rc 0
expect_record "wake sleep M:90-m
wake sleep M:10-m
wake sleep 90-u
wake sleep 10-u"

# --- a session with NO user root gets the machine hooks, and only those -----
# This is the greeter, exactly: no configuration of its own, no filtering, no
# special case in the mechanism. It simply has no user scope.
rm -rf "$VIGILANCE_HOOK_ROOT"
: > "$RECORD"
go open                                   # back to the top
: > "$RECORD"
go sleep
expect_rc 0
expect_record "lock open M:10-m
sleep lock M:10-m
sleep lock M:90-m"

# --- a session that BEGINS at a rung: the greeter -----------------------------
# The greeter IS the locked state. Without an initial depth its `go sleep`
# would traverse open -> lock -> sleep and fire lock.d, whose provider would
# try to start a lock screen on top of a session that already is one.
#
# This is an INITIALISATION, not a crossing: no hooks fire, because nothing was
# traversed.
rm -rf "$VIGILANCE_RUN_DIR"
mkdir -p "$VIGILANCE_RUN_DIR"
VIGILANCE_INITIAL_DEPTH=lock; export VIGILANCE_INITIAL_DEPTH
expect_depth lock
: > "$RECORD"
go sleep
expect_rc 0
expect_depth sleep
# ONLY the sleep edge: the lock edge was never crossed, so the provider that
# would have fought the greeter never ran.
expect_record "sleep lock M:10-m
sleep lock M:90-m"

# a nonsense value falls back to `open` and says so, rather than inventing a
# rung the ladder does not have
rm -rf "$VIGILANCE_RUN_DIR"; mkdir -p "$VIGILANCE_RUN_DIR"
VIGILANCE_INITIAL_DEPTH=banana
expect_depth open
expect_stderr "ignoring bad VIGILANCE_INITIAL_DEPTH 'banana'"
unset VIGILANCE_INITIAL_DEPTH

pass
