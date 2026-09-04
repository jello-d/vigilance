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
hook_intent() {   # edge -> dark | lit | none
  case "$1" in
    sleep|suspend|resume) echo dark ;;
    wake)                 echo lit ;;
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

# hook_lit <save-file> [brightnessctl-selector...]
hook_lit() {
  _sf=$1; shift
  if [ ! -f "$_sf" ]; then return 0; fi        # nobody dimmed it; leave it
  _bc "$@" set "$(cat "$_sf")" || true
  rm -f "$_sf"
}
