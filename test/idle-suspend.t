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

# Run just _run, with the lock/sleep block disabled (VIGILANT_CMD not
# executable) so only the suspend seam varies, and swayidle stubbed on PATH.
runfn=$(sed -n '/^_run() {/,/^}/p' "$HERE/bin/swayidle-mgr")
run_run() {   # SUSPEND_TIMEOUT and SUSPEND_CMD passed as env
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" LOCK_TIMEOUT=480 \
    BLANK_DELAY=120 VIGILANT_CMD=/nonexistent SELF=self \
    "$@" sh -c "set -eu
$runfn
_run"
}

# seam set -> exactly the suspend timeout + command appears, lock timer intact
out=$(run_run SUSPEND_TIMEOUT=1200 SUSPEND_CMD=/bin/true)
echo "$out" | grep -q 'timeout 480' || fail "lock timer missing: $out"
echo "$out" | grep -q 'timeout 1200 /bin/true' \
  || fail "seam set but no 'timeout 1200 /bin/true': $out"

# seam unset (defined-empty, as the script's :- defaults leave it) -> no suspend
out=$(run_run SUSPEND_TIMEOUT= SUSPEND_CMD=)
echo "$out" | grep -q 'timeout 480' || fail "lock timer missing (unset case)"
echo "$out" | grep -qE '1200|/bin/true' \
  && fail "a suspend timer appeared with the seam unset: $out" || :

# only one of the pair set -> still no suspend timer (both are required)
out=$(run_run SUSPEND_TIMEOUT=1200 SUSPEND_CMD=)
echo "$out" | grep -q '1200' \
  && fail "suspend timer added with SUSPEND_CMD empty: $out" || :

pass
