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

pass
