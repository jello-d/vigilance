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
# TWO QUESTIONS, deliberately not merged. The runner exports VIGILANCE_INTENT,
# the darkness the rung implies -- a fact about the LADDER. This adds the ACT
# policy on top: whether a hook should drive the hardware toward it. They differ
# only at lock/unlock, and merging them would put back the bug where unlocking
# re-asserted a brightness the user had set by hand.
#
# The runner's value WINS when present, so the ladder's table is stated once.
# The local copy is the standalone fallback (a hook run by hand, or by a test),
# and test/intent.t asserts the two agree, because a fallback that can drift
# silently is worse than no fallback.
hook_intent() {   # edge -> dark | lit | none
  _hi=${VIGILANCE_INTENT:-}
  if [ -z "$_hi" ]; then
    case "$1" in
      sleep|suspend|resume) _hi=dark ;;
      wake|lock|unlock)     _hi=lit ;;
      *)                    _hi=none ;;
    esac
  fi
  case "$1" in
    lock|unlock)
      if [ "${VIGILANCE_KIND:-act}" = verify ]; then echo "$_hi"
      else echo none; fi ;;
    *) echo "$_hi" ;;
  esac
}

# --- brightnessctl-backed save/restore --------------------------------------
# Every LED and backlight here is written through brightnessctl, never raw
# sysfs. Access comes from udev/99-vigilance.rules, which grants the `vigilant`
# GROUP write on exactly the nodes these hooks drive.
#
# THIS USED TO SAY "just put the login user in `input`", brightnessctl's own
# requirement, and it was wrong to ask for. `input` is overloaded: the same
# group guards /dev/input/event* (root:input crw-rw----, i.e. READ EVERY
# KEYSTROKE) and the LED brightness attributes. Joining it to dim a keyboard
# backlight buys a keylogging capability, and every consumer of this framework
# would have paid that price.
#
# It was also never CHECKED, only documented -- so on a box where the user held
# none of those groups, brightnessctl was denied on every call while hook_dark
# and hook_lit swallowed the failure (`|| true`) and vigilant logged clean
# crossings over hardware that never moved. `vigilant report` now probes the
# nodes for writability, because a requirement nothing verifies is a comment.
#
# SAVE ONCE is load-bearing. A hook wired into BOTH sleep.d and suspend.d runs
# twice on a lock -> sleep -> suspend descent, and `resume` re-asserts dark a
# third time. Without the guard the second write would save 0 over the real
# level and the restore would bring the screen back black.
_bc() { brightnessctl "$@" >/dev/null 2>&1; }

hook_have_brightnessctl() {
  command -v brightnessctl >/dev/null 2>&1
}

# WHAT THE SCREEN IS ACTUALLY EMITTING, independent of every mechanism.
#
# This is the only OUTCOME measurement in the suite. Every other verifier asks
# about its own device -- "did my I2C bus take the command", "is my sysfs
# backlight at 0" -- and when no device is applicable they all decline and the
# rung's actual claim goes unexamined. That is how a lit screen survived four
# separate green verdicts: an unimplemented D6 code, a monitor that vanished
# from its own map, a user session with no darkening mechanism, and a greeter
# with none either. Each hook was individually satisfied or n/a every time.
#
# A grab answers the question the RUNG is about rather than the question a
# device is about, so it holds however the darkening was supposed to happen --
# or was not wired at all.
#
# ALPHA OFF, and it is not optional: %[fx:mean] averages ALL channels, and a
# screengrab always carries alpha, so an opaque black frame reads 0.25 rather
# than 0. That measurement once called a pitch-black screen "not black" and
# contradicted a human looking straight at it.
#
# THE WHOLE SURFACE, not a crop: a 160x160 corner reads near zero on a dark
# wallpaper, so a corner-sampling check passes on a lit screen.
#
# OVERRIDABLE, or a test of any caller measures the DEVELOPER'S own screen --
# the mistake behind seven past defects here.
hook_screen_luma() {   # -> mean luminance 0..1, or empty if unmeasurable
  if [ -n "${VIGILANCE_SCREEN_LUMA:-}" ]; then
    printf '%s' "$VIGILANCE_SCREEN_LUMA"
    return 0
  fi
  command -v grim >/dev/null 2>&1   || return 0
  command -v magick >/dev/null 2>&1 || return 0
  # ALWAYS RETURNS 0. A caller writes `_l=$(hook_screen_luma)` under `set -e`,
  # and an assignment from a command substitution that FAILS aborts the caller
  # outright -- so a grab that could not run would kill the hook before it ever
  # reached its own "nothing to measure" branch. Observed exactly that: the
  # unmeasurable case exited 1 instead of declining with 78, which would have
  # read as drift on every headless box.
  _sl=$(timeout 25 grim -s 0.05 - 2>/dev/null \
        | timeout 25 magick - -alpha off -colorspace Gray \
            -format '%[fx:mean]' info: 2>/dev/null) || _sl=
  printf '%s' "$_sl"
  return 0
}

# Is a luminance reading dark enough to call black? Named so every caller uses
# the SAME threshold: two checks disagreeing about what "dark" means is its own
# source of false verdicts.
hook_luma_is_dark() {   # <luma>
  case "$1" in
    0|0.00*) return 0 ;;
    *)       return 1 ;;
  esac
}

# hook_dark <save-file> [brightnessctl-selector...]
hook_dark() {
  _sf=$1; shift
  # SAVE ONCE, BUT ASSERT EVERY TIME.
  #
  # This used to `return 0` outright when the save file existed, reading it as
  # "already saved, therefore already dark". That is an inference, not an
  # observation, and when it was wrong the descent became a SILENT NO-OP THAT
  # REPORTED SUCCESS -- and crossings do not run the verify tier, so nothing
  # caught it at the edge.
  #
  # Observed live on manifold: a leftover save file made every `sleep` leave
  # the keyboard backlight lit, the crossing logged clean, and only the
  # once-a-minute standing recheck ever said so. Reproduced exactly: with a
  # save file present the act tier returned 0 and the device never moved.
  #
  # The same short-circuit-on-state shape once left a stale save failing every
  # ascent for four days; it was fixed in hook_lit and left here. Re-asserting
  # is idempotent, which is what this package claims to be by default, and it
  # costs one write.
  _hd_new=0
  if [ ! -f "$_sf" ]; then
    _hd_new=1
    if ! brightnessctl "$@" get > "$_sf" 2>/dev/null; then
      rm -f "$_sf"
      return 0                                 # no such device here; fine
    fi
  # A SAVE FILE THAT CANNOT BE RESTORED FROM is worse than none: hook_lit would
  # hand it to brightnessctl as a level, fail, and (before this) delete it.
    _hd_lvl=$(cat "$_sf" 2>/dev/null || true)
    case "${_hd_lvl:-}" in
      ''|*[!0-9]*)
        rm -f "$_sf"
        echo "hooklib: saved level '$_hd_lvl' is not a number; not dimming" >&2
        return 1 ;;
    esac
  fi
  # A FAILED DIM IS NOT SUCCESS. It used to be `|| true`, which is how a denied
  # brightnessctl produced clean crossings over hardware that never moved.
  #
  # The save file goes too, and that is not tidying: nothing was dimmed, so
  # leaving it would make `report` cry "saved levels outstanding at a lit rung"
  # about a device sitting in exactly the state it should be in.
  if ! _bc "$@" set 0; then
    # ONLY DROP A SAVE WE JUST CREATED. Deleting a PRE-EXISTING one because a
    # re-assert failed would throw away the level the device must be restored
    # to, stranding a panel that may well still be dark from the first descent.
    if [ "$_hd_new" = 1 ]; then rm -f "$_sf"; fi
    echo "hooklib: could not dim $* (brightnessctl denied or absent)" >&2
    return 1
  fi
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
#
# THE SAVE FILE IS THE EVIDENCE, so it only goes when the restore WORKED.
#
# This used to be `_bc set "$(cat "$_sf")" || true; rm -f "$_sf"`, and that one
# line defeated both things that could have noticed a screen staying dark:
#
#   the exit status      swallowed, so the runner logged a clean crossing and
#                        raised no alert
#   report's "saved       could never fire, because the evidence it looks for
#   levels outstanding    had just been deleted by the thing that failed
#   at a lit rung"
#
# Keeping the file on failure also means a LATER ascent can still restore the
# real level -- `force open`, the rescue key, or simply the next unlock -- so
# the brightness is recoverable instead of lost.
hook_lit() {
  _sf=$1; shift
  if [ ! -f "$_sf" ]; then return 0; fi        # nobody dimmed it; leave it
  _hl_lvl=$(cat "$_sf" 2>/dev/null || true)
  case "${_hl_lvl:-}" in
    ''|*[!0-9]*)
      echo "hooklib: saved level '$_hl_lvl' is not a number; not restoring" >&2
      return 1 ;;
  esac
  # AN ABSENT DEVICE IS NOT A FAILED RESTORE, the same distinction hook_dark
  # already draws on `get`. If the device cannot even be READ there is nothing
  # here to restore TO: the save is a leftover from a machine that has since
  # changed -- a dock unplugged, a hook rescoped, a monitor retired.
  #
  # Keeping it would fail this edge on EVERY ascent, forever, and raise an alert
  # each time, while report cried drift about hardware that is not there. That
  # is not hypothetical: a stale save from an older hooklib outlived the fix and
  # failed every wake on a live box, because hook_dark short-circuits on the
  # file's existence and so never re-created the condition that made it.
  if ! brightnessctl "$@" get >/dev/null 2>&1; then
    rm -f "$_sf"
    return 0
  fi
  if ! _bc "$@" set "$_hl_lvl"; then
    echo "hooklib: could not restore $* to $_hl_lvl; keeping $_sf so the level"\
" is not lost and report can see it" >&2
    return 1
  fi
  rm -f "$_sf"
}
