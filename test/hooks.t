#!/bin/sh
# test/hooks.t - the shipped peripheral hooks' state discipline.
#
# Stubs brightnessctl, which is an ACTUATOR and therefore fair game; systemd
# and logind are never stubbed anywhere in this suite.
#
# The property under test is the one that is easy to get wrong and expensive
# when wrong: darkness follows the rung being ENTERED, not the direction of
# travel. `resume` is an ASCENT (suspend -> sleep) that must still be DARK,
# because after an S3 cycle the hardware may have come back lit on its own.
# Treating ascent as "restore" would light the screen of a machine that is
# still locked and blanked.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init hooks

HOOKS=$HERE/libexec/hooks
LEVEL=$T/level            # the stub device's current brightness
export VIGILANCE_STATE_DIR=$T/state
mkdir -p "$VIGILANCE_STATE_DIR"

# --- stub brightnessctl (an actuator, not the trust root) -------------------
mkdir -p "$T/bin"
cat > "$T/bin/brightnessctl" <<EOF
#!/bin/sh
# Models one device; selector flags (--class/--device) are ignored, so the
# same stub serves panel-backlight, kbd-backlight and mute-leds alike.
_mode=
for a in "\$@"; do
  case "\$a" in
    --*) continue ;;
    get) cat "$LEVEL"; exit 0 ;;
    set) _mode=set ;;
    *)   if [ "\$_mode" = set ]; then
           printf '%s' "\$a" > "$LEVEL"; exit 0
         fi ;;
  esac
done
exit 0
EOF
chmod +x "$T/bin/brightnessctl"
PATH=$T/bin:$PATH
export PATH

SAVE=$VIGILANCE_STATE_DIR/level

# SAFETY NET, and the reason this file now has one: an earlier version of the
# "absent hardware" case below set PATH to /nonexistent:/usr/bin:/bin, which
# still resolved the REAL brightnessctl. The hook then ran a real `set 0` and
# blacked out the developer's laptop, with the save file inside $T so nothing
# could restore it. A test that can reach real hardware is a hazard, not a
# test. Refuse to invoke a hook unless brightnessctl resolves inside $T, so
# this can never happen again however PATH is manipulated later.
run_hook() {   # <edge> [from]
  _bc=$(command -v brightnessctl 2>/dev/null || echo none)
  case "$_bc" in
    "$T"/*|none) ;;
    *) fail "REFUSING: brightnessctl resolves to '$_bc', outside the sandbox" ;;
  esac
  VIGILANCE_EDGE=$1 "$HOOKS/panel-backlight" "$1" "${2:-none}"
}

# --- an edge this hook does not care about must not touch anything ----------
printf '128' > "$LEVEL"
run_hook lock
[ "$(cat "$LEVEL")" = 128 ] || fail "lock changed the backlight"
[ -f "$SAVE" ] && fail "lock created a save file"

# --- descend: save the real level once, then go dark ------------------------
run_hook sleep
[ "$(cat "$LEVEL")" = 0 ]   || fail "sleep did not zero the backlight"
[ "$(cat "$SAVE")"  = 128 ] || fail "sleep did not save the real level"

# --- SAVE ONCE: a second dark edge must not save 0 over the real level ------
# A hook wired into both sleep.d and suspend.d runs twice on one descent.
# Without the guard the restore would bring the screen back black.
run_hook suspend
[ "$(cat "$SAVE")" = 128 ] || fail "suspend clobbered the saved level with 0"

# --- resume is an ASCENT that stays DARK, and must not re-save either -------
run_hook resume suspend
[ "$(cat "$LEVEL")" = 0 ]   || fail "resume lit a screen that is still asleep"
[ "$(cat "$SAVE")"  = 128 ] || fail "resume clobbered the saved level"

# --- wake is the ascent that restores, and forgets the save -----------------
run_hook wake sleep
[ "$(cat "$LEVEL")" = 128 ] || fail "wake did not restore the real level"
[ -f "$SAVE" ] && fail "wake left a stale save file behind"

# --- nobody dimmed it: a stray restore must leave the device alone ----------
printf '77' > "$LEVEL"
run_hook wake sleep
[ "$(cat "$LEVEL")" = 77 ] || fail "wake restored a device nobody dimmed"

# --- absent hardware degrades to a clean no-op, never an error --------------
# A minimal bin holding only the coreutils the hook needs, and deliberately NO
# brightnessctl. Emptying PATH outright would not work: the hook shells out to
# readlink and dirname to locate hook_lib.
mkdir -p "$T/minbin"
for _u in sh readlink dirname basename cat rm; do
  _p=$(command -v "$_u" 2>/dev/null) || continue
  ln -sf "$_p" "$T/minbin/$_u"
done
PATH=$T/minbin
export PATH
[ -z "$(command -v brightnessctl 2>/dev/null)" ] \
  || fail "sandbox leak: brightnessctl still reachable in the absent case"
# 78 IS THE GRACEFUL ANSWER NOW, not 0. Without brightnessctl the hook drives
# nothing, and counting it as a tier that acted is how an edge where every
# mechanism was missing read exactly like one where all of them worked.
_rc=0
run_hook sleep || _rc=$?
[ "$_rc" = 78 ] || fail "with brightnessctl absent the hook exited $_rc, not
78; it must decline rather than claim work it could not do"
[ -f "$SAVE" ] && fail "absent brightnessctl still wrote a save file"

# --- AN ACT TIER THAT RAN NOTHING CANNOT CLAIM THE EDGE ---------------------
# MEASURED LIVE 2026-10-04: `cross lock: open -> lock` with both wired hooks
# dangling after a layout change, rc=0, and a clean log. The rung meaning "the
# session is secured" was recorded with nothing having secured it, which is the
# conflation HOOK_NA was introduced to break for the VERIFY tier and which the
# ACT tier never got.
#
# THE DISCRIMINATOR IS present-but-BLOCKED, and that is what makes it safe to
# assert at all: `_hooks_for` returns empty both when nothing is wired (a
# greeter, legitimately) and when everything wired is unrunnable. Those read
# identically to the runner, so failing on "ran nothing" alone would cry wolf on
# every greeter crossing. All three directions are asserted below.
# A PREVIOUS CASE NARROWED PATH to $T/minbin and did not restore it, so this
# block inherits a PATH with no mkdir and failed with "mkdir: not found".
# Restored HERE rather than changed there, because the narrowing is
# load-bearing for that case: it is how a hook is made to look absent.
PATH=$T/bin:/usr/bin:/bin

_dangle() {   # wire a hook whose target has MOVED, as a deploy does
  mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
  printf '#!/bin/sh\nexit 0\n' > "$T/tgt"; chmod +x "$T/tgt"
  ln -sf "$T/tgt" "$VIGILANCE_HOOK_ROOT/lock.d/10-prov"
  mv "$T/tgt" "$T/tgt-gone"
}
rm -f "$VIGILANCE_HOOK_ROOT"/lock.d/* 2>/dev/null || true
go open
_dangle
go lock
[ "$CROSS_RC" != 0 ] \
  || fail "the lock edge crossed with every wired hook UNRUNNABLE and reported
SUCCESS. Nothing actuated, and the rung that means the session is secured was
recorded anyway: that is the live fault, and the status is what lock-on-sleep
and the keybind read"
grep -q "ran NOTHING" "$VIGILANCE_LOG" \
  || fail "the edge actuated nothing and the log does not say so. The status
alone reaches a unit; the log is what reaches a human reading back"
# THE RECORD STILL MOVES, deliberately and like _set_depth's own tolerance: a
# hook that could not run is not a reason to lie about where the machine was
# asked to be, and the drift is then visible to coherence and the recheck.
expect_depth lock

# A HEALTHY TIER MUST BE SILENT, or every crossing on every box fails.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/10-prov"
hook lock 10-prov
go open
go lock
[ "$CROSS_RC" = 0 ] \
  || fail "a healthy lock edge now reports failure (rc=$CROSS_RC)"

# AND NOTHING WIRED IS NOT A FAILURE, which is the greeter: it sits at `lock`
# with no provider, forever and correctly. Failing here would make every
# greeter crossing red, which is how a check gets switched off.
rm -f "$VIGILANCE_HOOK_ROOT"/lock.d/*
go open
go lock
[ "$CROSS_RC" = 0 ] \
  || fail "an edge with NOTHING wired reported failure (rc=$CROSS_RC). That is
the greeter shape and it is correct: demanding a hook there asserts something
no mechanism in that session can satisfy"

pass
