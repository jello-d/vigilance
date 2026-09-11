# hooklib.sh - shared helpers for vigilance's shipped peripheral hooks.
#
# Sourced by libexec/vigilance/hooks/*. Those hooks are SYMLINKED into
# ~/.config/vigilance/hooks/<edge>.d/ by the integrator, so each resolves its
# own real path before sourcing this:
#
#   _self=$(readlink -f "$0"); . "$(dirname "$_self")/../hooklib.sh"
#
# WHY THIS EXISTS: panel-power implemented the same save-once/restore/forget
# discipline three separate times (backlight, kbd_backlight, mute_leds) as
# near-identical copy-paste. That duplication was the framework trying to be
# born. The runner supplies the state DIR; this supplies the state DISCIPLINE.

# --- which rungs are DARK ---------------------------------------------------
# Direction alone is NOT the answer, and getting this wrong leaves hardware in
# the wrong state. What matters is the darkness of the rung being ENTERED:
#
#   open, lock       lit    (locked is not dark; the screen is still on)
#   sleep, suspend   dark
#
# So `resume` (suspend -> sleep) is an ASCENT that must still be DARK: the
# machine is awake again but we are back at `sleep`, and after an S3 cycle the
# hardware may well have come back lit on its own. That is the "re-assert
# rather than restore" case, and it is why hooks branch on the EDGE, not on
# whether the ladder is moving up or down.
#
# `lock` and `unlock` are the edges whose intent DIFFERS BY KIND, and the
# asymmetry is the point. Both ENTER a lit rung, so that is what verify must
# assert. But neither may ACT on brightness: descending to `lock` leaves the
# screen on by definition, `wake` already re-lit the hardware on the way up,
# and an edge that re-asserted a level here would overwrite one the user had
# set by hand.
#
# Wiring them for verify is what closes the everyday hole. `vigilant verify`
# checks the CURRENT rung, and the current rung is `open` almost all the time,
# so with no verifier there the normal state of the machine was the one state
# nothing checked. It is also the most valuable assertion in the suite:
# "vigilance says this machine is open; is the screen actually on?" is exactly
# the black-screen-no-recovery condition that twice needed a hard reboot.
hook_intent() {   # edge -> dark | lit | none
  case "$1" in
    sleep|suspend|resume) echo dark ;;
    wake)                 echo lit ;;
    lock|unlock)
      if [ "${VIGILANCE_KIND:-act}" = verify ]; then echo lit
      else echo none; fi ;;
    *)                    echo none ;;
  esac
}

# --- brightnessctl-backed save/restore --------------------------------------
# Every LED and backlight here is written through brightnessctl, never raw
# sysfs. brightnessctl ships its own udev rule granting the `input` group
# rw on /sys/class/leds/*/brightness and the backlight nodes, so a hook needs
# no sudo and no integrator-specific rule: only that the login user is in
# `input`, which is brightnessctl's standard requirement everywhere.
#
# SAVE ONCE is load-bearing. A hook wired into BOTH sleep.d and suspend.d runs
# twice on a lock -> sleep -> suspend descent, and `resume` re-asserts dark a
# third time. Without the guard the second write would save 0 over the real
# level and the restore would bring the screen back black.
_bc() { brightnessctl "$@" >/dev/null 2>&1; }

hook_have_brightnessctl() {
  command -v brightnessctl >/dev/null 2>&1
}

# hook_dark <save-file> [brightnessctl-selector...]
hook_dark() {
  _sf=$1; shift
  if [ -f "$_sf" ]; then return 0; fi          # already saved: already dark
  if ! brightnessctl "$@" get > "$_sf" 2>/dev/null; then
    rm -f "$_sf"
    return 0                                   # no such device here; fine
  fi
  _bc "$@" set 0 || true
}

# hook_verify_level <save-file> <intent> [brightnessctl-selector...]
# Assert the device MATCHES the intent, and say what it found when it does not.
# "dark" is not exactly 0 on every device (some clamp to a floor), so compare
# against a tenth of max rather than demanding zero -- a panel at 1/400 is off
# for every practical purpose, and demanding 0 would cry wolf.
hook_verify_level() {
  _sf=$1; _want=$2; shift 2
  _cur=$(brightnessctl "$@" get 2>/dev/null) || return 0   # no device: n/a
  _max=$(brightnessctl "$@" max 2>/dev/null) || return 0
  case "$_cur$_max" in *[!0-9]*|'') return 0 ;; esac
  [ "$_max" -gt 0 ] || return 0
  if [ "$_want" = dark ]; then
    if [ "$_cur" -gt $((_max / 10)) ]; then
      echo "expected dark, found $_cur/$_max" >&2
      return 1
    fi
  else
    # Lit is only assertable when we recorded what to restore to; without a
    # save file nobody dimmed it and there is nothing to compare against.
    [ -f "$_sf" ] || return 0
    if [ "$_cur" -le $((_max / 10)) ]; then
      echo "expected lit, found $_cur/$_max" >&2
      return 1
    fi
  fi
  return 0
}

# hook_lit <save-file> [brightnessctl-selector...]
hook_lit() {
  _sf=$1; shift
  if [ ! -f "$_sf" ]; then return 0; fi        # nobody dimmed it; leave it
  _bc "$@" set "$(cat "$_sf")" || true
  rm -f "$_sf"
}
