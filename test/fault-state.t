#!/bin/sh
# test/fault-state.t - the bookkeeping fails. THE LOCK MUST STILL HAPPEN.
#
# FAULT: runtime-dir-read-only.
#
# The rule this defends is stated twice in the source and has been broken twice
# in practice: "a failure to WRITE A FILE must never suppress the thing the edge
# exists to do". Suppressing a lock is a security failure; a wrong record is a
# reporting one. `_set_depth` carries that comment, and `ddc-monitor` later
# reintroduced the bug one layer out, where a state dir it could not create
# aborted the hook before EITHER monitor was driven.
#
# A READ-ONLY MOUNT, NOT chmod. The guest runs as root and root ignores
# permission bits entirely, so `chmod a-w` injects nothing at all -- the same
# reason test/actuators declares `require unprivileged`. A read-only mount is
# refused even for root, and it is also the realistic shape: a full or
# remounted-read-only filesystem is how this happens to a real box.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-state
_unmount() { umount "$RUN" 2>/dev/null || true; }
trap '_unmount; session_done; rm -rf "$T"' EXIT INT TERM HUP

RUN=${XDG_RUNTIME_DIR:-/run/user/0}/vigilance
mkdir -p "$RUN"

wire lock ''      swaylock
wire lock .verify locker-up

# --- the runtime dir becomes unwritable, to root included -------------------
mount -t tmpfs -o ro,size=1k tmpfs "$RUN" \
  || fail "could not mount a read-only tmpfs over $RUN; this fault cannot be
injected on this substrate and the case would prove nothing"
# STDERR REDIRECTED FIRST. Redirections apply left to right, so with `>` ahead
# of it the failing output redirect is reported by the shell while stderr is
# still the terminal -- and this probe is MEANT to fail, so it printed an
# alarming "Read-only file system" line on every successful run.
if printf 'x' 2>/dev/null > "$RUN/canary"; then
  fail "the fault did not take: $RUN is still writable, so everything below
would pass for the wrong reason"
fi

# --- the lock must happen anyway -------------------------------------------
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
await 15 locker_up || fail "with its runtime dir unwritable, vigilance did not
lock the screen. Bookkeeping is not the job: a record it cannot keep must never
suppress the lock, which is what _set_depth's own comment says and what
ddc-monitor once broke one layer out"

# AND IT MUST SAY SO. Failing loudly is the other half of the rule -- a lock
# that worked while the record silently did not is drift nobody was told about,
# and drift nobody was told about is this package's whole subject.
said "could not record depth" || fail "the depth record failed and nothing was
logged. The edge is then invisible to audit, which parses that log and is the
tier of last resort"

# --- and it must recover once the fault clears ------------------------------
# A transient fault that leaves a permanent fault behind is not handled. This
# is the stale-save shape: an interrupted write whose wreckage outlives it.
_unmount
[ -w "$RUN" ] || fail "fixture: $RUN is still not writable after unmounting"
"$VIGILANT" force open >/dev/null 2>&1 || true
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" \
  || fail "vigilance could not lock again once the filesystem came back"
await 10 locker_up || fail "the recovered lock crossed its edge but brought up
no locker"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after recovery; the record
did not resume working when it could be written again"

pass
