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
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
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

# --- a CROSS-CUTTING tier is MACHINE FIRST, not ordered as a descent --------
# `idle.d`, `audit.d`, `alert.d` and friends are not ladder edges. They take
# the machine-first order for the reason the header gives: the always-available
# machine sink records BEFORE any user sink that might be slow or absent, so
# the RECORD is never the part that gets lost.
#
# ASSERTED FOR ONE TIER AND STRUCTURAL FOR THE REST. `_hooks_for` derives this
# from CROSS_KINDS, so a new cross-cutting kind inherits the order rather than
# needing a line here. It did not always: the branch carried a hand-written
# list of four, and `cursor` was added to CROSS_KINDS without being added to
# it, so it was filed as a DESCENT and ordered user-scope first. Immaterial for
# a one-answer tier, which is exactly why it sat unnoticed, and the same slip
# the branch's own comment already recorded about `audit`.
# ASKED OF EVERY KIND, AND THE LIST COMES FROM THE DECLARATION. A hand-written
# list here would be the same hazard one layer out, and `cursor` proves the
# point: a per-tier assertion would have been written for the four that were
# already right. `vigilant hooks` is the universal observer, because it labels
# the scope and lists in _hooks_for order without executing anything, so this
# covers tiers no verb in this file could drive.
_ck=$(sed -n "s/^CROSS_KINDS='\(.*\)'\$/\1/p" "$HERE/bin/vigilant")
[ -n "$_ck" ] || fail "could not read CROSS_KINDS out of bin/vigilant, so this
check is about nothing. The declaration moved or changed shape"
for _k in $_ck; do
  for _scr in "$VIGILANCE_HOOK_ROOT" "$VIGILANCE_MACHINE_HOOKS"; do
    mkdir -p "$_scr/$_k.d"
    printf '#!/bin/sh\nexit 78\n' > "$_scr/$_k.d/50-both"
    chmod +x "$_scr/$_k.d/50-both"
  done
done
_hout=$("$VIGILANT" hooks 2>&1) || true
for _k in $_ck; do
  _gotord=$(printf '%s\n' "$_hout" | awk -v k="$_k.d:" '
    $0 == k { f = 1; next } f && /\.d:$/ { f = 0 } f { print }' \
    | sed -n 's/.*\[\([a-z]*\)\].*/\1/p' | tr '\n' ' ')
  [ "$_gotord" = "machine user " ] || fail "the '$_k' tier is ordered
'$_gotord' and must be 'machine user '. A cross-cutting tier is not a ladder
edge and must not be ordered as a descent: the machine sink has to record
before a user sink that may be slow or absent, or the record is the part that
gets lost. If '$_k' is new, it was added to CROSS_KINDS while something else
still decides the order from a list of its own"
done

# a nonsense value falls back to `open` and says so, rather than inventing a
# rung the ladder does not have
rm -rf "$VIGILANCE_RUN_DIR"; mkdir -p "$VIGILANCE_RUN_DIR"
VIGILANCE_INITIAL_DEPTH=banana
expect_depth open
expect_stderr "ignoring bad VIGILANCE_INITIAL_DEPTH 'banana'"
unset VIGILANCE_INITIAL_DEPTH

pass
