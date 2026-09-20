#!/bin/sh
# idle-suspend.t - the optional idle-suspend seam in swayidle-mgr. vigilance
# ships no suspend policy; an integrator sets SUSPEND_TIMEOUT + SUSPEND_CMD (via
# idle.conf or env) and swayidle-mgr must then add exactly one more swayidle
# `timeout` running that command, and add NONE when the seam is unset. A stub
# swayidle captures the timer list _run assembles. This is load-bearing: a
# mistyped seam means no suspend timer, which is a flat battery.
. "$(dirname "$0")/lib.sh"
harness_init idle-suspend

# swayidle stub: print the args _run exec's it with.
mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$T/bin/swayidle"
chmod +x "$T/bin/swayidle"

# Run just _run, with swayidle stubbed on PATH so the assembled timer list is
# captured rather than executed.
#
# VIGILANT_CMD IS A REAL EXECUTABLE (/bin/true), not /nonexistent as before.
# _run now REFUSES to arm anything when `vigilant` cannot be resolved, because a
# timer armed with a command that cannot run fails silently forever -- the exact
# 2026-09-12 idle-lock outage. That guard is the point, so the test must satisfy
# it rather than route around it. _need_vigilant is extracted alongside _run for
# the same reason: the function has to exist for the guard to be the thing under
# test instead of a "not found" error.
#
# SUSPEND_CMD is /bin/echo, deliberately NOT /bin/true: with a real VIGILANT_CMD
# the sleep/resume block now appears in the list too, and a seam-unset assertion
# grepping for /bin/true would match THOSE and fail on the wrong thing.
runfn=$(sed -n '/^_need_vigilant() {/,/^}/p;/^_run() {/,/^}/p' \
  "$HERE/bin/swayidle-mgr")
run_run() {   # SUSPEND_TIMEOUT and SUSPEND_CMD passed as env
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" LOCK_TIMEOUT=480 \
    BLANK_DELAY=120 TICK_TIMEOUT=60 VIGILANT_CMD=/bin/true SELF=self \
    "$@" sh -c "set -eu
$runfn
_run"
}

# THE HEARTBEAT IS ARMED, and it is armed SEPARATELY from the lock timer.
# A wedged swayidle is running with correct argv and emits nothing, so every
# liveness check in this suite passes while the box never locks again. The
# watchdog needs an expectation to compare silence against, and `idle-lock` is
# far too rare to be one -- a whole day can pass without a single lock. This
# short observational timeout is what turns silence into evidence.
out=$(run_run SUSPEND_TIMEOUT= SUSPEND_CMD=)
echo "$out" | grep -q 'timeout 60 self event idle-tick' \
  || fail "no proof-of-life tick armed: $out"
echo "$out" | grep -q 'resume self event active' \
  || fail "the tick has no resume, so only half of each transition is
recorded and a log cannot show the timer CYCLING, only that it fired once"
# ...and it must not have displaced the lock timer, which is the whole point of
# arming it as its own timeout: swayidle measures each from the last input.
echo "$out" | grep -q 'timeout 480' \
  || fail "arming the tick displaced the lock timer: $out"

# seam set -> exactly the suspend timeout + command appears, lock timer intact
out=$(run_run SUSPEND_TIMEOUT=1200 SUSPEND_CMD=/bin/echo)
echo "$out" | grep -q 'timeout 480' || fail "lock timer missing: $out"
echo "$out" | grep -q 'timeout 1200 /bin/echo' \
  || fail "seam set but no 'timeout 1200 /bin/echo': $out"

# seam unset (defined-empty, as the script's :- defaults leave it) -> no suspend
out=$(run_run SUSPEND_TIMEOUT= SUSPEND_CMD=)
echo "$out" | grep -q 'timeout 480' || fail "lock timer missing (unset case)"
echo "$out" | grep -qE '1200|/bin/echo' \
  && fail "a suspend timer appeared with the seam unset: $out" || :

# only one of the pair set -> still no suspend timer (both are required)
out=$(run_run SUSPEND_TIMEOUT=1200 SUSPEND_CMD=)
echo "$out" | grep -q '1200' \
  && fail "suspend timer added with SUSPEND_CMD empty: $out" || :

# --- AND IT REFUSES TO ARM AT ALL when vigilant cannot be resolved ----------
# The guard that makes the rest of this file safe to trust. swayidle-mgr's one
# job is the idle-LOCK timer, and without `vigilant` it cannot do it -- so it
# must abort LOUDLY rather than arm timers that fire into nothing.
#
# That is not a hypothetical failure mode, it is the 2026-09-12 outage: a sweep
# removed the binary a running swayidle held in its argv, the 480s idle-lock
# fired into a missing path from then on, and NOTHING noticed for hours. It is
# also the failure the shared-command migration would otherwise re-create:
# publishing `vigilant` deletes the ~/.local/bin copy this used to hardcode.
_rc=0
_out=$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" LOCK_TIMEOUT=480 \
  BLANK_DELAY=120 VIGILANT_CMD=/nonexistent/vigilant SELF=self \
  SUSPEND_TIMEOUT= SUSPEND_CMD= \
  sh -c "set -eu
$runfn
_run" 2>&1) || _rc=$?
[ "$_rc" != 0 ] || fail "_run armed the idle timer with an unresolvable
'vigilant'; that timer fires into nothing, silently, forever"
case "$_out" in
  *"cannot resolve"*"vigilant"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the refusal did not name what could not be resolved" ;;
esac
echo "$_out" | grep -q 'timeout 480' \
  && fail "it printed a timer list despite refusing; the guard is too late" || :

pass
