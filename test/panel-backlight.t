#!/bin/sh
# test/panel-backlight.t - the hook must drive the PANEL, or nothing at all.
#
# WHAT THIS FOUND, on manifestor, a desktop with two external monitors and no
# internal panel:
#
#   HOOK FAILED (rc=1): wake 20-panel-backlight
#   ALERT [hook-failed] wake hook 20-panel-backlight failed (rc=1)
#
# on EVERY wake, three times that day, alerting each time.
#
# /sys/class/backlight was empty -- correct for a desktop -- but the hook passed
# NO selector to brightnessctl, and with no backlight device brightnessctl falls
# back to the `leds` class and takes whatever comes first. On that box it was a
# keyboard kana LED. So a hook named panel-backlight silently drove an unrelated
# LED, could not write it, and failed forever.
#
# The guard it had, hook_have_brightnessctl, checks that the TOOL exists.
# Nothing checked that the thing the tool is meant to drive does. kbd-backlight
# has always passed --class=leds --device=...; this was the one hook trusting
# the default.
#
# Asserted BEHAVIOURALLY rather than by grepping for the flag: a grep for a
# spelling cannot tell "does not scope" from "scopes another way", which is an
# error this project has made twice. The stub here answers ONLY for the class it
# is told to answer for, so a hook that does not scope reaches the leds device
# and is caught doing it.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init panel-backlight

HOOK=$HERE/libexec/vigilance/hooks/panel-backlight
mkdir -p "$T/bin" "$T/state"

# A brightnessctl that models a machine with NO backlight device and one leds
# device -- exactly manifestor. It records every call, so "which device did the
# hook touch" is answerable rather than inferred.
cat > "$T/bin/brightnessctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BC_LOG"
_class=backlight                       # brightnessctl's own default target
_explicit=                             # ...but was it ASKED for?
for _a in "$@"; do
  case "$_a" in
    --class=*) _class=${_a#--class=}; _explicit=1 ;;
    -c)        _class=NEXT ;;
    *)         if [ "$_class" = NEXT ]; then _class=$_a; _explicit=1; fi ;;
  esac
done
# THE FALLBACK THAT CAUSED THE BUG, and it only happens when NO class was
# asked for. Verified against the real tool on the affected box:
#
#   brightnessctl -c backlight get -> "Failed to read any devices of class
#                                      'backlight'." (exit 1, no fallback)
#   brightnessctl get              -> 0, from a leds device
#
# Modelling the fallback as unconditional made the FIXED hook look broken: an
# explicit --class=backlight was silently rerouted to leds, so the baseline
# failed while the bug it was meant to catch was already gone.
if [ "$_class" = backlight ] && [ -n "${BC_NO_BACKLIGHT:-}" ]; then
  if [ -n "${BC_FALLBACK:-}" ] && [ -z "$_explicit" ]; then _class=leds
  else echo "Failed to read any devices of class 'backlight'." >&2; exit 1; fi
fi
case "$_class" in
  leds) printf '%s\n' "leds" >> "$BC_TOUCHED" ;;
esac
case "$*" in
  *max*) echo 1; exit 0 ;;
  *get*) echo 0; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/brightnessctl"
PATH="$T/bin:$PATH"; export PATH
BC_LOG=$T/calls; BC_TOUCHED=$T/touched; export BC_LOG BC_TOUCHED
export BC_NO_BACKLIGHT=1
VIGILANCE_STATE_DIR=$T/state; export VIGILANCE_STATE_DIR

_run() {   # <edge> [kind]
  : > "$BC_LOG"; : > "$BC_TOUCHED"
  VIGILANCE_EDGE="$1" VIGILANCE_KIND="${2:-act}" sh "$HOOK" "$1" \
    2>>"$T/stderr"
}

# --- 1. a box with NO panel backlight: the hook is a clean no-op ------------
# Not a failure. A desktop without a panel backlight is not a broken desktop,
# and crying wolf there is what teaches you to ignore the alert that matters.
_run sleep || fail "the hook FAILED on a machine with no panel backlight. That
is every desktop; it is n/a, not drift, and it alerts on every edge"
[ ! -s "$T/touched" ] || fail "the hook reached a LEDS device on a machine with
no panel backlight. brightnessctl falls back to the leds class when given no
selector, so a hook named panel-backlight drove a keyboard LED -- which it
cannot write, so it then failed every ascent and alerted each time"

# ...and it must not leave a save file, or the next ascent has something to
# restore to a device that does not exist.
[ ! -f "$T/state/level" ] || fail "a save file was written for a panel backlight
that does not exist"

# --- 2. the ASCENT is a no-op too, which is where it actually failed --------
# The descent looked fine on the live box precisely because hook_dark
# short-circuits on an existing save file; every WAKE was what failed.
_run wake || fail "the ascent FAILED with no panel backlight present"
[ ! -s "$T/touched" ] || fail "the ascent reached a LEDS device"

# --- 3. verify says n/a as well, rather than reporting drift ---------------
_run lock verify || fail "verify reported drift about a panel backlight that
does not exist on this machine"

# --- 4. WITH a panel backlight, it still does its job ----------------------
# The fix must scope the hook, not disable it. Without this, "never touch
# anything" would pass every assertion above.
unset BC_NO_BACKLIGHT
_run sleep || fail "the hook failed on a machine that HAS a panel backlight"
grep -q 'set' "$T/calls" \
  || fail "with a real panel backlight present the hook set nothing; scoping it
must not turn it into a no-op everywhere"
grep -q 'class=backlight' "$T/calls" \
  || fail "the hook did not name the backlight class, so on a box without one
brightnessctl will again fall back to the leds class and pick a keyboard LED"

# --- 5. AND THE ORIGINAL BUG, reproduced exactly ---------------------------
# BC_FALLBACK makes the stub behave like the real tool did on manifestor: no
# backlight device, so an unscoped call silently lands on leds. With the hook
# scoped this is unreachable; unscoped, it is the live failure.
export BC_NO_BACKLIGHT=1 BC_FALLBACK=1
rm -f "$T/state/level"

# EVERY TIER, not just the act one. The hook asks brightnessctl in three places
# -- dark, lit and verify -- and each carries its own selector. Scoping two of
# them and missing the third leaves the same bug on the tier that runs on the
# lock and unlock edges too; a mutation dropping the selector from verify alone
# passed until this loop existed.
for _case in "sleep act" "wake act" "lock verify" "unlock verify"; do
  set -- $_case
  _run "$1" "$2" \
    || fail "the hook failed on the $1 edge ($2 tier) against a
fallback-capable brightnessctl"
  [ ! -s "$T/touched" ] || fail "reproduced the manifestor bug on the $1 edge
($2 tier): the hook fell through to the leds class and drove a keyboard LED.
That is the failure that alerted on every wake for days, and it is per-tier --
each of dark, lit and verify carries its own selector"
done

# --- 6. THE STUCK STATE, which is what was actually on the live box --------
# hook_lit returns early when there is no save file, so every case above skips
# it entirely -- a mutation unscoping the `lit` tier passed until this existed.
# Reaching it needs a save file present, which is precisely manifestor's
# condition: one written 2026-09-14 by an older hooklib that swallowed the
# failed dim, still there days later.
#
# It could not clear itself, and that is the trap. hook_dark short-circuits on
# the save file's existence, so every descent was a silent no-op returning 0 --
# which is why the log showed clean `sleep` crossings and a FAILED `wake`, every
# single time, for days.
printf '42\n' > "$T/state/level"
_run wake
[ ! -s "$T/touched" ] || fail "with a stale save file present, the restore fell
through to the leds class and wrote a keyboard LED. This is the exact live
failure: hook_lit is the tier that actually ran on the box, and it is the one
the cases above cannot reach because they leave no save file behind"

# ...and the stale save is GONE, so the machine self-heals rather than failing
# every ascent until someone deletes a file in /run by hand.
[ ! -f "$T/state/level" ] || fail "the stale save file survived. The device it
names does not exist, so it can never be restored: kept, it fails every ascent
forever and alerts each time, and the descent cannot clear it because hook_dark
short-circuits on its existence"

pass
