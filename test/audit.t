#!/bin/sh
# test/audit.t - the forensic tier: did a past event produce the edge it should?
#
# THE THIRD QUESTION, and the only one that could have caught the bug it was
# built for. `verify` asks whether the hardware matches now; `due` asks whether
# an edge is overdue; neither can see an event that ALREADY happened and
# produced nothing.
#
# Concretely: logind slept the machine, lock-on-sleep.service was asked to lock
# it first, the unit died 203/EXEC on a bad ExecStart, and systemd reached
# sleep.target and slept anyway, because a failed Before= oneshot does not block
# the transition. Afterwards nothing was in a wrong state and nothing was
# pending. It had been doing that on every sleep for a whole refactor while
# reporting `enabled` and `canonical`.
#
# Run against the real journal it reported 13 misses in 14 events over 3 days.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init audit

# An audit hook prints "<epoch> <edge> [note]" lines: one per external event
# that should have produced an edge. vigilant owns the reconciliation.
audithook() {   # <name> <line>...
  _ah=$1; shift
  mkdir -p "$VIGILANCE_HOOK_ROOT/audit.d"
  { printf '#!/bin/sh\n'
    for _l in "$@"; do printf 'printf "%%s\\n" "%s"\n' "$_l"; done
  } > "$VIGILANCE_HOOK_ROOT/audit.d/$_ah"
  chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/$_ah"
}

# A log line as vigilant writes them, at a chosen time.
_logline() {   # <epoch> <text>
  printf '%s %s\n' "$(date -d "@$1" '+%Y-%m-%dT%H:%M:%S')" "$2" \
    >> "$VIGILANCE_LOG"
}

NOW=$(date +%s)

# --- no audit hooks: n/a, never a pass --------------------------------------
# Reporting clean when no event source is reconciled is the false green this
# whole project keeps having to unlearn.
_out=$("$VIGILANT" audit 2>>"$T/stderr") || fail "audit errored with no hooks"
case "$_out" in
  *"n/a"*"no audit hooks"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an empty audit tier did not announce itself as n/a" ;;
esac

# --- an event WITH its edge is ok -------------------------------------------
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross lock: open -> lock"
audithook 10-src "$((NOW - 300)) lock went to sleep"
_out=$("$VIGILANT" audit 2>>"$T/stderr") \
  || fail "audit failed on an event whose edge WAS crossed"
case "$_out" in
  *"audit ok: lock"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "a matched event was not reported ok" ;;
esac

# --- an event with NO edge is a MISS, and must be non-zero ------------------
# This is the bug, reduced: the event happened, the handler did not run, and
# nothing anywhere else would ever show it.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross unlock: lock -> open"   # a DIFFERENT edge
_out=$("$VIGILANT" audit 2>>"$T/stderr") && fail "audit passed on an event that
produced no edge; that is precisely the silent failure it exists to catch"
case "$_out" in
  *"audit MISS: lock"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "a missed event was not announced" ;;
esac

# ...and it ALERTS. The event is historical, so an alert is the only thing that
# will ever reach the human about it.
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-catch" <<EOF
#!/bin/sh
printf '%s %s\n' "\$VIGILANCE_ALERT_KIND" "\$VIGILANCE_ALERT_MSG" >> "$T/alerts"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-catch"
: > "$T/alerts"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" || true
grep -q "^audit-miss " "$T/alerts" || fail "a missed event raised no alert"

# --- "already at <rung>" SATISFIES a descent edge --------------------------
# A descent edge shares its name with the rung it enters, so being there already
# is the edge's purpose achieved, not a miss. Counting it as a failure would cry
# wolf on every sleep that happened from an already-locked session.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "already at 'lock'; nothing to do"
_out=$("$VIGILANT" audit 2>>"$T/stderr") \
  || fail "'already at lock' was not accepted as the lock edge satisfied"
case "$_out" in
  *"audit ok: lock"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "already-at was not treated as satisfied" ;;
esac

# --- ARRIVING at the rung by another edge satisfies it too ------------------
# THE LIVE JOURNAL FOUND THIS. On resume, `go lock` is a no-op only when the
# depth file survived at `lock`; when the box had descended to `sleep` first --
# which is the ORDINARY idle path -- it crosses `wake` to climb back. Both
# outcomes mean the session is locked, and only one was being counted, so every
# resume from the normal idle path was reported as a MISS. Two of them were
# sitting in the real audit output, indistinguishable from the three genuine
# failures beside them, which is exactly how a forensic tier becomes ignorable.
: > "$VIGILANCE_LOG"
rm -f "$VIGILANCE_HOOK_ROOT"/audit.d/*
_logline "$((NOW - 300))" "cross wake: sleep -> lock"
audithook 10-src "$((NOW - 300)) lock resumed from sleep"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "a resume that reached the 'lock' rung by crossing 'wake' was audited
as a miss. The assertion is about the RUNG, and there is more than one correct
route to being there"

# ...but arriving somewhere ELSE does not satisfy it. Without this the guard
# above would degrade into "any crossing at all counts", which would excuse the
# genuine misses it exists to find.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross unlock: lock -> open"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" && fail "a crossing that ended at
'open' satisfied a 'lock' assertion; arriving at a DIFFERENT rung is not the
edge's purpose achieved"

# And a rung whose name merely starts the same must not match.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross locked-thing: open -> lockdown"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" && fail "'-> lockdown' satisfied a
'lock' assertion; the match is not anchored"

# --- the WINDOW is respected, in both directions ----------------------------
# Too narrow and a correctly handled sleep reads as a miss; unbounded and any
# lock ever recorded would excuse any sleep.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300 - 20))" "cross lock: open -> lock"     # inside 120s
_out=$("$VIGILANT" audit 2>>"$T/stderr") \
  || fail "an edge 20s from the event fell outside the window"

: > "$VIGILANCE_LOG"
_logline "$((NOW - 300 - 5000))" "cross lock: open -> lock"   # far outside
_out=$("$VIGILANT" audit 2>>"$T/stderr") && fail "an edge 5000s away satisfied
the event; the window is not bounded"
case "$_out" in
  *"audit MISS"*) ;;
  *) fail "a far-away edge was not reported as a miss" ;;
esac

# --- a junk line from a hook is IGNORED, not fatal -------------------------
# An event source that emits something unparseable must not take the whole
# audit down, or one bad plugin blinds every other.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross lock: open -> lock"
audithook 20-junk "not-an-epoch lock junk" "" "   "
_out=$("$VIGILANT" audit 2>>"$T/stderr") \
  || fail "a junk audit line broke the whole run"
case "$_out" in
  *"audit ok: lock"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the good event was lost alongside the junk one" ;;
esac

# --- a BROKEN source is not "no events" ------------------------------------
# The sharpest false green in this tier, and it was live: a source hook that
# exits non-zero was skipped with a bare `|| continue`, so audit printed
# "nothing to reconcile" and exited 0. A forensic tier reporting clean because
# it could not look is worse than one reporting a miss: audit is the tier of
# last resort, and if it is blind, nothing else is watching.
: > "$VIGILANCE_LOG"
rm -f "$VIGILANCE_HOOK_ROOT"/audit.d/*
mkdir -p "$VIGILANCE_HOOK_ROOT/audit.d"
printf '#!/bin/sh\nexit 7\n' > "$VIGILANCE_HOOK_ROOT/audit.d/10-broken"
chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/10-broken"
: > "$T/alerts"
_out=$("$VIGILANT" audit 2>>"$T/stderr") && fail "audit reported success while
its only event source could not be read; that is a green light meaning nobody
looked, which is the exact failure this tier exists to expose"
case "$_out" in
  *"audit BROKEN"*"10-broken"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an unreadable source was not named as BROKEN" ;;
esac
# It must reach the human, and as its OWN kind: a blind source is an unknown
# number of missed events, a different alarm from one known miss.
grep -q "^audit-broken " "$T/alerts" \
  || fail "an unreadable audit source raised no alert"

# --- a broken source must not mask a WORKING one ----------------------------
# One bad plugin blinding every other is how a tier dies quietly.
_logline "$((NOW - 300))" "cross lock: open -> lock"
audithook 20-good "$((NOW - 300)) lock went to sleep"
_out=$("$VIGILANT" audit 2>>"$T/stderr") || true
case "$_out" in
  *"audit ok: lock"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a working source was lost because another one was broken" ;;
esac

# --- THE SHIPPED HOOK asserts an edge the units actually cross --------------
# A regression guard for a live bug: logind-sleep-audit claimed the RESUME
# direction should produce the `sleep` edge, left over from when that unit ran
# `go sleep`. It runs `go lock` now, so every correctly handled resume would
# have been reported as a MISS: the forensic tier crying wolf, which is exactly
# how a human learns to ignore it.
#
# Asserted through the REAL hook rather than a fixture, because the bug was in
# the hook's own claim. A fixture would have agreed with whatever it said.
rm -f "$VIGILANCE_HOOK_ROOT"/audit.d/*
_SRC=$HERE/libexec/vigilance/hooks/logind-sleep-audit
# 30 days, not 1: the window only has to be wide enough to contain a sleep.
_edges=$(VIGILANCE_AUDIT_SINCE='-30 days' "$_SRC" 2>/dev/null \
           | awk '{print $2}' | sort -u)
if [ -z "$_edges" ]; then
  # NEVER SILENT. A host whose journal holds no sleeps has nothing to assert
  # here, and a vacuous pass would read exactly like a verified one -- the same
  # false green as the empty verify tier. Say what went unchecked.
  echo "  note: no sleep events in this journal; the shipped-hook edge" \
       "assertion had nothing to check" >&2
else
  for _edge in $_edges; do
    case "$_edge" in
      lock) ;;
      *) fail "logind-sleep-audit asserts the '$_edge' edge, but the units it
audits (lock-on-sleep, vigilance-resume) both run 'go lock' and can only ever
produce 'lock'; asserting anything else reports a MISS on a healthy machine" ;;
    esac
  done
fi

# And the no-op a healthy resume actually produces. The depth file lives in
# XDG_RUNTIME_DIR and survives suspend, so the machine comes back still recorded
# at `lock` and `go lock` is correctly a no-op that crosses nothing at all.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "already at 'lock'; nothing to do"
audithook 10-resume "$((NOW - 300)) lock resumed from sleep"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "a healthy resume (depth already 'lock', so no edge crossed) was
audited as a miss"

# --- AN n/a SOURCE IS NOT A BROKEN ONE -------------------------------------
# `journalctl` absent on a non-systemd box, or an event log that was never
# created, means there is nothing to reconcile and nothing wrong. Reporting
# that as BROKEN is the crying-wolf half of the same conflation 78 exists to
# break -- and this is the tier of last resort, so teaching a reader to
# discount it is expensive.
rm -f "$VIGILANCE_HOOK_ROOT"/audit.d/*
printf '#!/bin/sh\nexit 78\n' > "$VIGILANCE_HOOK_ROOT/audit.d/10-absent"
chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/10-absent"
_arc=0
_aout=$("$VIGILANT" audit 2>>"$T/stderr") || _arc=$?
[ "$_arc" = 0 ] || fail "an audit source that DECLINED (78) failed the tier
(rc=$_arc). It has no event source here; that is not a fault"
case "$_aout" in
  *"audit n/a"*) ;;
  *) printf '%s\n' "$_aout" >&2
     fail "a declining audit source was not reported as n/a" ;;
esac
case "$_aout" in
  *BROKEN*) fail "a source with nothing to read was called BROKEN. That is the
verdict for a source that could not do its job, and using it for one that had
no job here is how a forensic tier gets ignored" ;;
esac

pass
