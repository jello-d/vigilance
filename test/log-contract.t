#!/bin/sh
# test/log-contract.t - the runner WRITES the log; the audit tier PARSES it.
# Two halves of one contract, held by nothing.
#
# THE GAP THIS CLOSES. Every existing audit test builds its log lines BY HAND:
#
#   _logline() { printf '%s %s\n' "$(date -d "@$1" '+%Y-%m-%dT%H:%M:%S')" "$2" }
#
# which restates _log's format instead of using it. So a change to how the
# runner writes a crossing -- a different timestamp format, a reworded "cross"
# line, a prefix -- would leave audit.t and idle-audit.t GREEN while, in
# production, `audit` silently matched nothing and reported "no events found in
# range". A forensic tier that has gone blind reports exactly the same thing as
# one with nothing to find.
#
# That is this project's signature failure wearing yet another hat: a fixture
# restating a value rather than exercising the producer. So this crosses REAL
# edges with the REAL runner and reconciles against the REAL log it wrote.
#
# It deliberately asserts NOTHING about the format itself. Pinning the text here
# would just move the restatement. What is asserted is the ROUND TRIP: whatever
# the runner writes, the auditor must understand.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init log-contract

# An audit source claiming "an event happened just now that should have
# produced <edge>". The epoch comes from the clock, not a fixture, so it lands
# inside the reconciliation window around whatever the runner just logged.
_src() {   # <edge>
  mkdir -p "$VIGILANCE_HOOK_ROOT/audit.d"
  cat > "$VIGILANCE_HOOK_ROOT/audit.d/10-src" <<EOF
#!/bin/sh
printf '%s $1 round-trip\\n' "\$(date +%s)"
EOF
  chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/10-src"
}

# --- 1. a REAL crossing is understood by the REAL parser --------------------
_src lock
go lock
expect_depth lock
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "the runner wrote a 'lock' crossing and the audit tier could not see
it. The two halves of the log contract have drifted: whatever _log now emits,
_log_has_edge no longer matches. In production this reports 'no events found in
range', which is indistinguishable from a healthy machine"

# --- 2. a REAL no-op is understood ------------------------------------------
# `go lock` when already locked logs "already at ...". That counts as the edge's
# purpose achieved, and it is the ONLY thing a healthy resume produces, so the
# parser understanding it is load-bearing rather than a nicety.
#
# THE LOG IS TRUNCATED FIRST, and that is the whole assertion. Without it the
# earlier `cross lock:` line was still present and satisfied the reconciliation
# on its own -- so this passed with the already-at branch DELETED from the
# parser. Caught by mutating the parser; the test proved nothing until the log
# held the no-op line and nothing else.
: > "$VIGILANCE_LOG"
go lock
grep -q "already at" "$VIGILANCE_LOG" \
  || fail "the setup for this case is wrong: a second 'go lock' did not log an
already-at line, so the assertion below is not testing the no-op form"
grep -qv "cross lock:" "$VIGILANCE_LOG" \
  || fail "the log still holds a 'cross lock:' line, which would satisfy the
reconciliation on its own and hide a broken already-at parser"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "a real no-op crossing ('already at lock') was not accepted; every
healthy resume produces exactly this and nothing else"

# --- 3. ARRIVING at the rung by another edge, for real ----------------------
# The case the live journal caught and no fixture had: descending to `sleep` and
# climbing back crosses `wake`, not `lock`, yet the machine IS at the lock rung.
: > "$VIGILANCE_LOG"
go sleep
go lock
grep -q 'cross wake:' "$VIGILANCE_LOG" \
  || fail "the fixture for this case no longer matches reality: climbing from
sleep to lock did not cross 'wake', so the assertion below proves nothing"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "a real 'wake' crossing that ARRIVED at the lock rung was audited as a
miss; this is the false MISS that appeared on every ordinary resume"

# --- 4. a REAL crossing of a DIFFERENT edge is still a MISS -----------------
# Without this the round trip could pass by matching everything, which would be
# worse than a strict parser: audit would go permanently green.
: > "$VIGILANCE_LOG"
go open
_src suspend
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" && fail "audit reconciled a
'suspend' expectation against a log holding only unlock/open crossings; the
parser matches too loosely and the tier can no longer report a miss at all"

# --- 5. the WINDOW is real time, not fixture time ---------------------------
# _log_has_edge converts an epoch to the runner's timestamp format to compare
# lexicographically. If those two formats ever disagree, every event falls
# outside every window and audit goes quietly green. A hand-written fixture
# cannot catch that, because it uses the same format on both sides by
# construction.
: > "$VIGILANCE_LOG"
_src lock
go lock
_out=$("$VIGILANT" audit 2>>"$T/stderr") || true
case "$_out" in
  *"audit ok: lock"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a crossing made SECONDS ago fell outside the reconciliation window.
The epoch-to-timestamp conversion in _log_has_edge and the format in _log have
diverged, so no real event can ever match" ;;
esac

# --- 6. an ASCENT-edge assertion, which ONLY the `cross` form can satisfy ---
# The contract lets a source name any edge, and the three parser branches are
# not equally reachable. For a DESCENT edge the arrived-at-rung form subsumes
# the cross form -- "cross lock: open -> lock" ends in "-> lock" either way --
# so deleting the cross branch entirely left every test above green.
#
# An ASCENT edge is the case that separates them: "cross wake: sleep -> lock"
# ends at the LOCK rung, so only the literal `cross wake:` match can see it.
# Without this, one third of the parser is untested and could be removed
# silently.
: > "$VIGILANCE_LOG"
go sleep
_src wake
go lock
grep -q 'cross wake:' "$VIGILANCE_LOG" \
  || fail "setup wrong: climbing from sleep did not cross 'wake'"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "an audit source naming the ASCENT edge 'wake' was not reconciled
against a real 'cross wake:' line. Only the literal cross-form match can satisfy
an ascent edge, so that branch of the parser is now dead"

# --- 7. EVERY LINE IS A RECORD ----------------------------------------------
# The contract this file is named for, and it was never actually asserted --
# every case above tests that the PARSER understands well-formed records, and
# none tested that the WRITER only ever produces them.
#
# It shipped broken because of it. `log()` writes to stderr AND the log, so the
# standing recheck's `$(cmd_verify 2>&1)` captured vigilant's own already-
# logged output, and feeding that into _log wrote a record whose first line had
# a timestamp and whose remaining lines had none. Observed on a live box:
#
#   2026-09-20T21:21:50 STILL-DRIFTED at 'sleep': expected dark, found 1/2
#   vigilant: HOOK FAILED (rc=1): sleep.verify 30-kbd-backlight
#   verify sleep: FAIL
#
# The audit tier reads this file BY LINE, so untimestamped debris is precisely
# what makes a forensic pass mis-read a window -- and this is the tier of last
# resort, so when it is confused nothing else is looking.
#
# Driven through the path that produced it rather than a synthetic message: a
# failing verify at the rung the machine is actually at, which is what the
# once-a-minute standing recheck does on every pass.
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.verify.d"
cat > "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-multiline" <<'MULTI'
#!/bin/sh
echo "first line of trouble" >&2
echo "second line of trouble" >&2
exit 1
MULTI
chmod +x "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-multiline"
go open
go lock
"$VIGILANT" enforce >/dev/null 2>&1 || true

_bad=$(grep -vcE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ' \
  "$VIGILANCE_LOG" || true)
[ "${_bad:-0}" = 0 ] || fail "$_bad line(s) in the log are not timestamped
records:

$(grep -vE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ' \
  "$VIGILANCE_LOG" | head -5)

One record is one line. The audit tier parses this file by line, and a record
that spills extra lines puts debris between the entries it reads."

# ...and the information must SURVIVE the flattening, or the fix would be to
# throw the finding away rather than to format it.
grep -q "first line of trouble" "$VIGILANCE_LOG" \
  || fail "flattening the transcript lost the hook's message. A one-line
record is the requirement; silence is not the way to meet it"
grep -q "second line of trouble" "$VIGILANCE_LOG" \
  || fail "only the first line of a multi-line hook message survived"

pass
