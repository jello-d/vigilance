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
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init hooks

HOOKS=$HERE/libexec/vigilance/hooks
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
# readlink and dirname to locate hooklib.sh.
mkdir -p "$T/minbin"
for _u in sh readlink dirname basename cat rm; do
  _p=$(command -v "$_u" 2>/dev/null) || continue
  ln -sf "$_p" "$T/minbin/$_u"
done
PATH=$T/minbin
export PATH
[ -z "$(command -v brightnessctl 2>/dev/null)" ] \
  || fail "sandbox leak: brightnessctl still reachable in the absent case"
run_hook sleep || fail "hook errored when brightnessctl is absent"
[ -f "$SAVE" ] && fail "absent brightnessctl still wrote a save file"

pass
