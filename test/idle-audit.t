#!/bin/sh
# test/idle-audit.t - the idle -> lock edge, which nothing used to watch.
#
# THE MOST COMMON SECURITY EDGE WAS THE LEAST SUPERVISED. `verify` cannot see a
# lock that never happened (a machine that never locked sits correctly at
# `open`), and `due` cannot enforce it (the deadline is anchored to the last
# INPUT, which vigilant has no way to observe). That left forensics, and there
# was no audit source for it -- so due/enforce said "audit covers it" while
# nothing did.
#
# It then failed for real, which is why both halves below exist:
#
#   2026-09-12  a sweep removed a stale /usr/local/bin/swayidle-mgr that a
#               RUNNING swayidle held in its argv. The 480s idle-lock fired into
#               a missing binary from that moment on. No trace in vigilant's log
#               (no edge was attempted), none in the journal, and `verify` was
#               content. The 600s `go sleep` timer still worked, so the screen
#               still darkened on idle and it all LOOKED fine.
#
# Two different questions, two different guards, and neither substitutes:
#
#   audit source  did a timer that FIRED produce its edge?
#   armed check   can the timer fire AT ALL?
#
# The audit source is blind to the second: when the exec fails there is no event
# to reconcile, because the log entry is written by the command that never ran.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init idle-audit

SRC=$HERE/libexec/vigilance/hooks/swayidle-idle-audit
export SWAYIDLE_LOG_DIR=$T/swayidle-mgr
mkdir -p "$SWAYIDLE_LOG_DIR"
EVENTS=$SWAYIDLE_LOG_DIR/events.log

# swayidle-mgr's own event log format: "<iso>.<ns> idle-lock delta=<n>s".
_fired() {   # <epoch>
  printf '%s.000000000 idle-lock delta=99s\n' \
    "$(date -d "@$1" '+%Y-%m-%dT%H:%M:%S')" >> "$EVENTS"
}
_logline() {   # <epoch> <text>
  printf '%s %s\n' "$(date -d "@$1" '+%Y-%m-%dT%H:%M:%S')" "$2" \
    >> "$VIGILANCE_LOG"
}

NOW=$(date +%s)

# --- the source emits one event per firing, as <epoch> lock -----------------
: > "$EVENTS"
_fired "$((NOW - 300))"
_out=$("$SRC") || fail "the audit source exited non-zero on a valid log"
case "$_out" in
  *" lock "*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the idle timer's edge is 'lock' (swayidle-mgr execs 'vigilant go
lock'); anything else would report a MISS on a healthy machine" ;;
esac
[ "$(printf '%s\n' "$_out" | grep -c .)" = 1 ] \
  || fail "one firing produced $(printf '%s\n' "$_out" | grep -c .) events"

# --- the WINDOW is respected, so an old log does not replay forever ---------
: > "$EVENTS"
_fired "$((NOW - 8 * 24 * 3600))"
[ -z "$(VIGILANCE_AUDIT_SINCE='-1 day' "$SRC")" ] \
  || fail "an 8-day-old firing was reported inside a 1-day window"
[ -n "$(VIGILANCE_AUDIT_SINCE='-30 days' "$SRC")" ] \
  || fail "an 8-day-old firing was dropped from a 30-day window"

# --- only a real FIRING counts, not any line mentioning idle-lock ----------
# Matched as a field rather than anywhere in the line, so `start`/`stop`/
# `detached` entries -- and any future message that merely says the words --
# cannot be mistaken for the timer going off.
: > "$EVENTS"
printf '%s.0 start foreground=0\n' "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$EVENTS"
printf '%s.0 detached idle-lock launcher\n' \
  "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$EVENTS"
[ -z "$("$SRC")" ] || fail "a non-firing log line was reported as an idle-lock
event; that would manufacture a MISS out of a lifecycle message"

# --- NO LOG AT ALL is silence, not failure ---------------------------------
# A box that has never run the idle manager has nothing to reconcile. Failing
# here would make audit red on every machine that does not use this timer.
rm -f "$EVENTS"
"$SRC" >/dev/null 2>&1 || fail "a missing event log was treated as an error"

# --- END TO END: a fired timer with no lock edge is a MISS -----------------
mkdir -p "$SWAYIDLE_LOG_DIR" "$VIGILANCE_HOOK_ROOT/audit.d"
cp "$SRC" "$VIGILANCE_HOOK_ROOT/audit.d/20-idle"
: > "$EVENTS"; : > "$VIGILANCE_LOG"
_fired "$((NOW - 300))"
_out=$("$VIGILANT" audit 2>>"$T/stderr") && fail "the idle timer fired and no
lock edge followed, and audit called that clean. That is the failure this whole
tier exists to catch"
case "$_out" in
  *"audit MISS: lock"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "the miss was not announced" ;;
esac

# ...and the healthy case reconciles.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "cross lock: open -> lock"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "a timer firing that DID produce its lock edge was audited as a miss"

# An already-locked session counts too: swayidle-mgr execs `vigilant go lock`
# regardless, and a no-op is the edge's purpose achieved.
: > "$VIGILANCE_LOG"
_logline "$((NOW - 300))" "already at 'lock'; nothing to do"
"$VIGILANT" audit >/dev/null 2>>"$T/stderr" \
  || fail "an idle firing into an already-locked session was audited as a miss"

# --- THE ARMED CHECK: a timer pointing at a missing binary is a FAILURE ----
# The guard for the exact 2026-09-12 breakage. report reads what the RUNNING
# process is armed with, because a daemon pins its argv at start and a file that
# moves under it is invisible to every config-level check.
#
# The cmdline file stands in for /proc/<pid>/cmdline. The real one is
# NUL-separated and the probe runs it through `tr`, so a newline-separated
# fixture reads identically without needing \0 portability from the test shell.
rm -rf "$VIGILANCE_HOOK_ROOT/audit.d"
export VIGILANCE_IDLE_CMDLINE=$T/cmdline
cat > "$T/cmdline" <<EOF
swayidle
-w
timeout
480
$T/definitely-not-here event idle-lock
timeout
600
$(command -v true) go sleep
resume
$(command -v true) go lock
EOF
_rep=$("$VIGILANT" report 2>&1) || true
case "$_rep" in
  *"armed with a command that cannot run"*"definitely-not-here"*) ;;
  *) _section "$_rep" machinery >&2
     fail "report did not flag an idle timer armed with a missing binary; that
is the silent failure that stopped this machine auto-locking for hours" ;;
esac
# It must be a FAIL, not a warning: the machine is not locking.
case "$(_section "$_rep" machinery)" in
  *"[FAIL]"*"cannot run"*) ;;
  *) fail "the unrunnable idle command was not reported as a FAILURE" ;;
esac

# --- and an ENTIRELY RUNNABLE set is clean ---------------------------------
cat > "$T/cmdline" <<EOF
swayidle
-w
timeout
480
$(command -v true) event idle-lock
resume
$(command -v true) go lock
EOF
_rep=$("$VIGILANT" report 2>&1) || true
_no_fail_in "$_rep" machinery "a fully runnable set of idle timers was flagged"
case "$_rep" in
  *"idle timer command(s) armed and runnable"*) ;;
  *) fail "report did not confirm the armed timers positively; silence would
read as 'checked and fine' when it means 'not looked at'" ;;
esac

# --- no swayidle argv to read is silence, not failure ----------------------
# A headless box, or one whose idle manager is not running, has nothing to
# assert here. The DEAD swayidle case is already a FAIL elsewhere in machinery.
export VIGILANCE_IDLE_CMDLINE=$T/nothing-here
_rep=$("$VIGILANT" report 2>&1) || true
case "$_rep" in
  *"armed with a command that cannot run"*)
    fail "report invented an armed-command failure with no argv to read" ;;
esac

pass
