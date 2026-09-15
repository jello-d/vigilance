#!/bin/sh
# test/alert.t - vigilant's own LOG, and the alert hook kind.
#
# The charter's second pillar is noticing when something silently did not
# happen. That is worthless if the noticing is itself silent, so two separate
# obligations are pinned here:
#
#   LOG    vigilant's own record. BUILT IN, mechanism-free, always on. A
#          supervisor that only records when an integrator wires something up
#          is not a supervisor. stderr goes to the journal under a unit but
#          NOWHERE under a keybind, which is exactly when the trail matters.
#   ALERT  telling a HUMAN. That is policy (a toast, a bar, an intervention
#          flag), so it is a hook and vigilant assumes no mechanism.
#
# The discrimination that keeps alerts worth reading: an ACTUATOR failure
# alerts (the monitor may not have slept), a REPORT failure does not (nobody
# was told, but the machine is fine). Alerting on the second would train the
# human to ignore the first.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init alert

VIGILANCE_LOG=$T/vigilant.log
export VIGILANCE_LOG

# alert.d is NOT per-edge: it is cross-cutting, raised by vigilant itself.
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-sink" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$VIGILANCE_ALERT_KIND" "\$VIGILANCE_ALERT_MSG" \
  >> "$T/alerts"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-sink"
: > "$T/alerts"

# --- a clean crossing is LOGGED and raises nothing --------------------------
hook lock 10-ok
go lock
expect_rc 0
grep -q "cross lock: open -> lock" "$VIGILANCE_LOG" \
  || fail "a crossing was not logged"
[ -s "$T/alerts" ] && fail "a clean crossing raised an alert"

# --- an ACTUATOR failure alerts, and names itself ---------------------------
go open
hook sleep 10-bad 4
go lock
go sleep
expect_rc 1
grep -q "^hook-failed|sleep hook 10-bad failed (rc=4)$" "$T/alerts" \
  || { echo "--- alerts ---"; cat "$T/alerts"; fail "no actuator alert"; }
grep -q "ALERT \[hook-failed\]" "$VIGILANCE_LOG" \
  || fail "the alert was not also written to the log"

# --- a REPORT failure is logged but does NOT alert --------------------------
: > "$T/alerts"
go open
hook unlock.report 10-bad 6
go lock
go open
grep -q "HOOK FAILED (rc=6): unlock.report 10-bad" "$VIGILANCE_LOG" \
  || fail "a failing reporter was not logged"
[ -s "$T/alerts" ] && fail "a report failure raised an alert (it must not)"

# --- a broken ALERT hook can never affect the outcome it reports on ---------
# The machine's state must not depend on whether we managed to complain.
printf '#!/bin/sh\nexit 9\n' > "$VIGILANCE_HOOK_ROOT/alert.d/20-broken"
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/20-broken"
go lock
go sleep
expect_rc 1                                  # unchanged: the actuator failed
grep -q "alert hook failed: 20-broken" "$VIGILANCE_LOG" \
  || fail "a broken alert hook was not itself logged"

# --- AND AN ALERT HOOK THAT HANGS, which is worse than one that fails -------
# _alert is reached FROM _run_hooks, when a hook on the edge has just failed.
# So a notifier that never returns blocks the very edge whose failure raised it:
# a broken toast stops the lock.
#
# It is a distinct hole from the hook bound because _alert keeps its OWN loop
# rather than going through _run_hooks, so it did not inherit the timeout when
# that was added. The hook here IGNORES SIGTERM, which is both the harder case
# and the realistic one for something wedged on a bus or a socket.
rm -f "$VIGILANCE_HOOK_ROOT/alert.d/20-broken"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-hangs" <<'H'
#!/bin/sh
trap "" TERM INT
sleep 30
H
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-hangs"

# CROSSES `sleep`, NOT `lock`, and the difference is the whole test. The failing
# hook wired above is on the SLEEP edge; nothing fails on `lock`, so a lock
# crossing raises no alert and the hanging hook never runs. Written that way
# first, this passed with the bound removed -- a timing assertion on a path the
# alert tier is never reached from.
go open
: > "$T/alerts"
_t0=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" go sleep >/dev/null 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _t0 ))

# The precondition, asserted rather than assumed: if no alert was raised, the
# timing below measures nothing.
[ -s "$T/alerts" ] || fail "no alert was raised on this edge, so the hanging
alert hook never ran and the timing assertion below proves nothing"

[ "$_el" -lt 15 ] || fail "the sleep edge took ${_el}s because an ALERT hook
hung. The alert tier is reached from a hook failure, so an unbounded notifier
lets a broken toast stop the edge -- the tier that exists to report trouble
becoming the trouble"

pass
