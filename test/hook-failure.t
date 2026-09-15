#!/bin/sh
# test/hook-failure.t - a failing hook must be LOUD, must NAME itself, and must
# NOT abort its siblings.
#
# This is the regression for the bug that hid on two machines for days: the
# patched swaylock forked $HOME/bin/panel-power, the path went stale when
# vigilance extracted panel-power to ~/.local/bin, the execl failed, and
# _exit(127) swallowed it BY DESIGN ("best-effort: any failure is silently
# ignored"). Nothing anywhere reported it. A monitor burned its backlight for
# days and the only symptom was a screen that did not turn off.
#
# Three properties, all absent before:
#   1. the runner's exit status is non-zero, so a caller can react
#   2. the failing hook is NAMED on stderr, so the log says which one
#   3. siblings still run: one dark monitor must not leave the keyboard lit
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init hook-failure

hook lock 10-ok
hook lock 20-broken 3       # exits 3, as a stale path or dead tool would
hook lock 30-ok

go lock
expect_rc 1                                  # 1. loud, not silent
expect_stderr "HOOK FAILED (rc=3): lock 20-broken"   # 2. names the hook
expect_record "lock open 10-ok
lock open 20-broken
lock open 30-ok"                             # 3. siblings still ran

# The edge still CROSSED. A hook that could not act does not mean the session
# is unlocked; depth must reflect reality so the ascent unwinds correctly.
expect_depth lock

# --- verify is the shared oracle, and it reports the same failure -----------
# A verify hook that cannot confirm its edge took effect fails the same way,
# which is what lets the test suite and the production watchdog agree.
: > "$RECORD"
hook lock.verify 10-confirm
expect_verify lock ok

hook lock.verify 20-cannot-confirm 4
expect_verify lock fail

# --- A HOOK THAT HANGS: the fourth property, and the one with teeth ----------
# Same class as the three above, one step further along. A hook that FAILS is
# now loud; a hook that never returns was not even that, and it took the whole
# edge with it.
#
# MEASURED before the timeout existed: a hook in lock.d running `sleep` blocked
# the traversal indefinitely, and `50-provider` NEVER RAN. Hooks run in lexical
# order and the lock provider is not first, so one hung plugin ordered ahead of
# it means the screen is simply never locked -- with nothing in the log, no
# alert, and no bound on the wait.
#
# Under lock-on-sleep.service that is the entire guarantee gone: the unit is a
# system oneshot with TimeoutStartSec=25, systemd kills it at 25s, and nothing
# can veto a suspend -- so logind proceeds and the box sleeps UNLOCKED.
#
# The timeout is set SHORT here rather than waiting out the default, and the
# hook sleeps far longer than the bound so the assertion cannot pass by the
# hook simply finishing.
# ISOLATE THE VARIABLE FIRST. The sections above leave `20-broken` (exit 3)
# wired in lock.d, so this edge already returns non-zero for a reason that has
# nothing to do with a timeout. Asserting "the edge failed" on top of that
# proves nothing: it would pass with the timeout removed entirely. Clear it, and
# assert the baseline is CLEAN, so every later verdict is attributable.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/20-broken"
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
go open
"$VIGILANT" go lock >/dev/null 2>>"$T/stderr" \
  || fail "the baseline edge is not clean after clearing the broken hook, so
nothing below can attribute a failure to the timeout under test"

printf '#!/bin/sh\nexec sleep 30\n' > "$VIGILANCE_HOOK_ROOT/lock.d/20-hangs"
printf '#!/bin/sh\ntouch %s/provider-ran\n' "$T" \
  > "$VIGILANCE_HOOK_ROOT/lock.d/50-provider"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/20-hangs" \
         "$VIGILANCE_HOOK_ROOT/lock.d/50-provider"

go open
_t0=$(date +%s)
_rc=0
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || _rc=$?
_el=$(( $(date +%s) - _t0 ))

[ "$_el" -lt 15 ] || fail "the edge took ${_el}s with a 2s hook timeout; the
bound is not being applied and a hung hook still blocks the traversal"

# THE ASSERTION THAT MATTERS. Not that the hook was killed -- that the LOCK
# still happened. Everything else here is mechanism.
[ -e "$T/provider-ran" ] || fail "the lock provider never ran because an earlier
hook hung. Hooks run in lexical order, so any plugin sorting before the provider
can stop the screen locking at all -- and under lock-on-sleep the box then
suspends UNLOCKED"

# ...and it is LOUD, in terms that name the consequence. A bound that fires
# silently would leave a hook mysteriously half-working forever.
grep -q "HOOK TIMED OUT" "$VIGILANCE_LOG" \
  || fail "a hook was killed for exceeding its timeout and the log does not say
so; the hook appears to have run and the reader has no way to know otherwise"
grep -q "20-hangs" "$VIGILANCE_LOG" \
  || fail "the timeout was logged without naming which hook hung"

# A timeout is a FAILURE, not a pass: the runner must report the edge degraded.
[ "$_rc" != 0 ] || fail "the edge returned SUCCESS after a hook was killed for
hanging. A caller cannot distinguish that from every hook completing"

# --- A HOOK THAT IGNORES SIGTERM still dies, or the bound is advisory -------
# timeout(1) sends TERM, which a shell script can trap and ignore -- and a hook
# wedged in an uninterruptible retry loop is exactly the kind that hangs in the
# first place. Without `-k` the bound would be a polite request, and the edge
# would block forever anyway while the log claimed a timeout had been applied.
#
# The plain `timeout` and the `-k` form are indistinguishable against a hook
# that dies politely, which is why this case is separate: the mutation that
# dropped `-k` passed every assertion above.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/20-hangs" "$T/provider-ran"
cat > "$VIGILANCE_HOOK_ROOT/lock.d/20-stubborn" <<'H'
#!/bin/sh
trap "" TERM INT
sleep 30
H
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/20-stubborn"
go open
_t0=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _t0 ))
[ "$_el" -lt 15 ] || fail "a hook that IGNORES SIGTERM survived its timeout and
blocked the edge for ${_el}s. The bound needs a SIGKILL backstop or it is only
advisory, and the hooks most likely to hang are the ones least likely to die
politely"
[ -e "$T/provider-ran" ] || fail "the provider never ran: a hook that ignored
SIGTERM held the edge past its bound"
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/20-stubborn"

# --- and a hook WELL INSIDE the bound is untouched ---------------------------
# The mirror. A bound that kills slow-but-working hooks would trade a rare hang
# for a routine failure, which is a worse bargain: ddcutil over three displays
# legitimately takes seconds.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/20-hangs" "$T/provider-ran"
printf '#!/bin/sh\nsleep 1\n' > "$VIGILANCE_HOOK_ROOT/lock.d/20-slow"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/20-slow"
go open
VIGILANCE_HOOK_TIMEOUT=10 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" \
  || fail "a hook taking 1s was killed under a 10s bound; a slow but healthy
hook must not be turned into a routine failure"
[ -e "$T/provider-ran" ] || fail "the provider did not run on the healthy path"

pass
