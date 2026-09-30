#!/bin/sh
# test/watchdog.t - catching a daemon that is RUNNING and doing nothing.
#
# THE FAILURE THAT CREATED THIS PACKAGE, and the one thing nothing here could
# see. swayidle wedges on this Wayfire build: it resumed a suspend UNLOCKED and
# silently dropped a Session.Lock that fired. A wedged instance is alive:
# correct argv, active unit, right cgroup, and emits nothing, so `report` is
# green, `audit` has no event to reconcile, and the standing recheck is
# satisfied because the machine genuinely IS at the rung it claims.
#
# Seeing it needs an EXPECTATION to compare silence against, and the obvious
# one (an idle clock) is exactly what vigilant cannot measure. The way out
# is two pieces, neither of which is a clock:
#
#   A HEARTBEAT the subject cannot avoid emitting when healthy, which turns a
#   rare event into a frequent one and silence into evidence;
#   AN OBSERVER that cannot share its fate, which is a systemd timer.
#
# The heartbeat SHARING fate with the subject is the design, not a flaw: it
# goes quiet precisely when the subject does. Only the observer must be apart.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init watchdog

_wd() {   # rc [message] -> install a watchdog hook with that verdict
  mkdir -p "$VIGILANCE_HOOK_ROOT/watchdog.d"
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "${2:-subject is wedged}" "$1" \
    > "$VIGILANCE_HOOK_ROOT/watchdog.d/10-probe"
  chmod +x "$VIGILANCE_HOOK_ROOT/watchdog.d/10-probe"
}
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-sink" <<EOF
#!/bin/sh
printf '%s %s\n' "\$1" "\$2" >> $T/alerts
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-sink"
_run() { _r=0; OUT=$("$VIGILANT" enforce 2>>"$T/stderr") || _r=$?
         printf '%s' "$_r"; }
_alerts() { cat "$T/alerts" 2>/dev/null || true; }

go lock

# --- 1. a HEALTHY subject is silent ----------------------------------------
: > "$T/alerts"
_wd 0
[ "$(_run)" = 0 ] || fail "a healthy watchdog failed the supervision pass.
This runs every minute, so a tier that cries on a correct machine is one that
gets switched off, and it takes the real finding with it"
[ -z "$(_alerts)" ] || fail "a healthy watchdog raised an alert"

# --- 2. A WEDGED SUBJECT IS CAUGHT ------------------------------------------
# The whole point: nothing crossed an edge, the machine matches its rung, and
# the daemon is running. Every other tier here is green on this input.
: > "$T/alerts"
_wd 1 "the idle timer has emitted nothing for 20000s"
[ "$(_run)" != 0 ] || fail "a watchdog reporting its subject WEDGED left the
supervision pass green. A running-but-silent daemon passes every other check
in this suite (process alive, argv correct, unit active, rung matching)
so if this tier does not report it, nothing does"
case "$(_alerts)" in
  *watchdog*) ;;
  *) printf '%s\n' "$(_alerts)" >&2
     fail "no watchdog alert was raised. The log alone reaches nobody until
someone goes looking, and nobody goes looking at a box that seems fine" ;;
esac
# The hook's OWN words must survive: "the idle timer is silent" and "a daemon
# is unhealthy" send a reader to different places.
case "$(_alerts)" in
  *"emitted nothing for 20000s"*) ;;
  *) fail "the watchdog's message was replaced by a generic one; the finding
has to name what was observed or it cannot be acted on" ;;
esac

# --- 3. 78 IS NOT A FAILURE -------------------------------------------------
# A hook that cannot tell must not fail the pass. Most boxes will have a
# watchdog whose subject is absent (no swayidle on a server), and a tier that
# goes red there is one integrators delete.
: > "$T/alerts"
_wd 78 "no swayidle on this host; nothing to watch"
[ "$(_run)" = 0 ] || fail "a watchdog declining with 78 failed the pass.
'I cannot tell' is neither success nor failure, and treating it as failure
turns every host without the subject red"
[ -z "$(_alerts)" ] || fail "a declining watchdog raised an alert"

# --- 4. it runs even when there is NO deadline to enforce -------------------
# Every early return in the supervision path (no target, no deadline, not due
# yet) would otherwise skip it, which is most passes on a healthy machine.
# Same lesson the standing recheck already paid for.
: > "$T/alerts"
_wd 1 "wedged"
go sleep          # nothing below 'sleep' is an enforcement target
[ "$(_run)" != 0 ] || fail "with no enforcement target, the watchdog tier was
skipped. 'Is anything overdue' and 'is the machinery that would do it alive'
are different questions, and the second must not depend on the first"
go lock

# --- 4b. AND WHEN THERE IS NO RECORD AT ALL, which is every fresh login -----
# The early return this one skipped sat ABOVE the unconditional calls, so the
# comment on case 4 was true of four returns and false of the fifth. Found by
# reproducing it: against an empty runtime dir the hook ran zero times.
#
# THE STATE IS SELF-SUSTAINING, which is why this is the sharpest of the five.
# RUN_DIR is cleared at logout, so a session begins with no record; an idle
# timer wedged from login crosses no edge, so no record is ever written, so the
# one tier that can see a wedged timer stayed inert for the whole session. The
# founding failure, in the state that hides it.
: > "$T/alerts"
_wd 1 "wedged"
rm -f "$VIGILANCE_RUN_DIR/depth"
[ "$(_run)" != 0 ] || fail "with no depth record the watchdog tier was skipped.
That is every fresh login, and an idle timer wedged from login never writes a
record, so the tier built for exactly that failure would never run at all"
case "$(_alerts)" in
  *watchdog*) ;;
  *) fail "no watchdog alert with no depth record: the tier ran and its
finding went nowhere" ;;
esac

# ...AND THE RECHECK MUST STILL ABSTAIN THERE, which is the other half. With no
# record `_depth` answers `open`, and judging that default asserts the screen
# must be LIT: exactly how report once declared FAIL over a machine doing the
# right thing, where the greeter had correctly put the monitor into standby.
# Here it would ALERT. So moving the return must not have made the machine's
# state judgeable, only its machinery observable.
: > "$T/alerts"
_wd 0
mkdir -p "$VIGILANCE_HOOK_ROOT/unlock.verify.d"
cat > "$VIGILANCE_HOOK_ROOT/unlock.verify.d/10-drift" <<'DRIFT'
#!/bin/sh
echo "the screen is dark"
exit 1
DRIFT
chmod +x "$VIGILANCE_HOOK_ROOT/unlock.verify.d/10-drift"
rm -f "$VIGILANCE_RUN_DIR/depth"
[ "$(_run)" = 0 ] || fail "the standing recheck judged a machine with no depth
record. The rung it judged was a DEFAULT, not a claim, and the verdict alerts"
[ -z "$(_alerts)" ] || fail "an alert was raised about a default rung:
$(_alerts)"

# ...and it is not simply switched off: with a record, the same verifier IS
# judged. Without this the fix reads identically to deleting the tier.
go lock
go open
[ "$(_run)" != 0 ] || fail "with a depth record the standing recheck did not
report a verifier that failed, so the no-record guard above is indistinguishable
from having switched the recheck off"
case "$(_alerts)" in
  *drift*) ;;
  *) fail "no drift alert once the rung was a real claim: $(_alerts)" ;;
esac
rm -f "$VIGILANCE_HOOK_ROOT/unlock.verify.d/10-drift"
go lock

# --- 5. IT IS BOUNDED -------------------------------------------------------
# It runs on a one-minute timer forever. A watchdog that hangs wedges the
# supervision loop that exists to notice things not happening, which would be
# the tier acquiring the exact fault it was built to catch.
#
# The hook BOTH ignores SIGTERM and leaves a child holding stdout: either alone
# cannot tell a real bound from a decorative one. A hook that dies politely
# behaves identically with and without the bound, and a capture through $(...)
# waits for the PIPE rather than the process.
mkdir -p "$VIGILANCE_HOOK_ROOT/watchdog.d"
cat > "$VIGILANCE_HOOK_ROOT/watchdog.d/10-probe" <<'HANG'
#!/bin/sh
trap "" TERM
sleep 30 &
exec 1>&1
sleep 30
HANG
chmod +x "$VIGILANCE_HOOK_ROOT/watchdog.d/10-probe"
_t0=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" enforce >/dev/null 2>&1 || true
_el=$(( $(date +%s) - _t0 ))
[ "$_el" -lt 15 ] || fail "a hanging watchdog held the supervision pass for
${_el}s against a 2s bound. The tier that watches for things not happening
must not be the thing that stops happening"

pass
