#!/bin/sh
# test/fault-recheck.t - a crossing lands while the standing recheck measures.
#
# FAULT: crossing-during-a-recheck.
#
# THIS CLASS HAS ESCAPED THE STUB TIER THREE TIMES, which is the whole argument
# for testing it here. Each fix was correct about the variant in front of it and
# blind to the next:
#
#   29d5661  the depth MOVED during the verify        -> compare before/after
#   fa29173  a crossing was ALREADY running           -> an in-flight marker
#   this     a crossing STARTS during the verify      -> defer the alert
#
# The third is the one no ordering of a state check can catch. The recheck
# discarded its verdict exactly as designed, every time -- but the verify tier
# raises `hook-failed` from INSIDE cmd_verify, so the toast had already reached
# the user's screen before the verdict it belonged to was thrown away. Observed
# on manifold at 2026-09-24T17:51:20 with both earlier guards deployed:
#
#   17:51:13  cross lock: open -> lock
#   17:51:20  HOOK FAILED (rc=1): lock.verify 50-locker-up      <- notified
#   17:51:21  an edge was crossed while verifying 'lock'; no verdict
#
# THE GENERAL RULE, which is what makes this the last variant rather than the
# next one: the recheck uses optimistic concurrency because it must NOT hold the
# crossing lock (a verify is seconds of real work, and making a lock request
# wait on one trades a reporting fault for a security fault). Optimistic
# concurrency is only valid if the discarded work had no externally visible
# effect. A transaction that can be rolled back must not emit before it commits.
#
# THE CROSSING IS REAL. A real `go` through the real runner, taking the real
# crossing lock and writing the real depth record, against the real locker-up
# hook reading a real absent process. Nothing here is a probe override.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init fault-recheck
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

# AN ALERT SINK OF OUR OWN, recording the KIND and the MESSAGE. The kind alone
# cannot answer the question this file exists to ask -- whether deferring a
# notification LOSES the finding -- and the shipped sinks notify a desktop
# rather than anything a test can read.
mkdir -p "$HOOKS/alert.d"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> %s\n' "$T/alerts" \
  > "$HOOKS/alert.d/10-sink"
chmod +x "$HOOKS/alert.d/10-sink"

# DEDUP OFF. Both cases below raise findings about the same rung, so left on,
# the second case's verdict would depend on what the first happened to emit --
# and a suppressed-as-repeat alert is indistinguishable from a deferred one,
# which is precisely the distinction under test.
VIGILANCE_ALERT_COOLDOWN=0; export VIGILANCE_ALERT_COOLDOWN

# NO PROVIDER IS WIRED, deliberately: the fault needs the rung to claim `lock`
# while no locker is up, so that the real locker-up hook really does fail. With
# the provider wired the edge would bring up swaylock and there would be no
# failing hook to defer.
mkdir -p "$HOOKS/lock.verify.d"
wire lock .verify locker-up

# A SLOW VERIFIER AHEAD OF IT, so the crossing has a window to land in. It
# announces itself first, which is what makes the overlap a FACT the test
# checks rather than a race it hopes for -- the live window was one second and
# a sleep-and-hope version of this would pass on a machine where it never
# overlapped at all.
cat > "$HOOKS/lock.verify.d/01-slow" <<EOF
#!/bin/sh
: > $T/verifying
sleep 4
EOF
chmod +x "$HOOKS/lock.verify.d/01-slow"

_alerted() { grep -c . "$T/alerts" 2>/dev/null || true; }

# --- 1. the fault: a real crossing inside the recheck's verify ---------------
: > "$T/alerts"
rm -f "$T/verifying"
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
[ "$(depth)" = lock ] || fail "fixture: depth is '$(depth)', not lock"
locker_up && fail "fixture: a locker is up, so locker-up would PASS and there
would be no failing verify hook for this case to be about"

"$VIGILANT" enforce >>"$T/enforce.out" 2>&1 &
_erp=$!
await 10 test -e "$T/verifying" \
  || fail "the recheck never reached its verify tier, so nothing below is about
a crossing landing inside one"
# NOW, with the verify demonstrably in flight.
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" || true
wait "$_erp" || true

[ "$(depth)" = sleep ] || fail "the crossing did not take; depth is '$(depth)'.
The fault was not injected and every assertion below passes for nothing"
# IN THE LOG, not merely on stdout. The log is what the audit tier reads, and
# it now records a DEFERRED alert -- so it owes the reader the verdict that
# alert was deferred to, or the record stops mid-sentence.
said "NO-VERDICT: an edge was crossed while verifying 'lock'" \
  || fail "the recheck did not record that an edge moved underneath it. Its
verdict was about the rung the machine had already left, and the log holds a
deferred hook failure with nothing ever saying what became of it"

# THE ASSERTION THIS FILE EXISTS FOR.
if grep -q '^hook-failed|' "$T/alerts" 2>/dev/null; then
  fail "a crossing landed inside the recheck's verify and hook-failed was
NOTIFIED anyway. The verdict was discarded correctly and the toast had already
gone out -- the user sees a lock failure for a lock that was coming up"
fi
[ "$(_alerted)" = 0 ] || fail "the discarded pass notified anyway:
$(cat "$T/alerts")"

# AND THE LOG STILL HOLDS IT. Deferring a notification must never thin the
# record: the audit tier reads this file, and here the hook genuinely did
# return non-zero.
said "HOOK FAILED (rc=1): lock.verify 50-locker-up" \
  || fail "the deferred failure was not logged. Throttling is a courtesy to the
human, never a gap in the record"
said "logged, not notified" || fail "the deferral was not marked in the log, so
a reader cannot tell a deferred alert from one that never happened"

# --- 2. ...and a settled machine STILL alerts, carrying the hook's words -----
# Without this half the fix could be "never notify from a recheck", which passes
# case 1 and switches the only tier that watches a settled machine off.
#
# THE DRIFT MESSAGE MUST CARRY THE VERIFY OUTPUT. That is what makes deferring
# hook-failed a de-duplication rather than a loss: the hook's own sentence
# reaches the human either way, attributed to the finding that owns it.
session_reset
mkdir -p "$HOOKS/alert.d" "$HOOKS/lock.verify.d"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> %s\n' "$T/alerts" \
  > "$HOOKS/alert.d/10-sink"
chmod +x "$HOOKS/alert.d/10-sink"
wire lock .verify locker-up
: > "$T/alerts"

"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
[ "$(depth)" = lock ] || fail "fixture: depth is '$(depth)', not lock"
_rc=0
"$VIGILANT" enforce >>"$T/enforce.out" 2>&1 || _rc=$?
[ "$_rc" != 0 ] || fail "a settled machine at 'lock' with no locker up reported
success. Nothing moved underneath this pass, so there was nothing to discard"
grep -q '^drift|' "$T/alerts" \
  || fail "a real drift on a settled machine raised no alert. Discarding a
verdict is only correct when an edge moved; doing it always passes case 1 and
retires the tier"
grep '^drift|' "$T/alerts" | grep -q "no locker is" \
  || fail "the drift alert does not carry the verify's own words, so deferring
hook-failed LOSES the hook's sentence instead of de-duplicating it:
$(grep '^drift|' "$T/alerts")"

pass
