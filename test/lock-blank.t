#!/bin/sh
# test/lock-blank.t - the hook that repaints the LOCK SURFACE black.
#
# WHY THE MECHANISM IS A SIGNAL AT ALL. Under ext-session-lock the lock surface
# renders above every layer-shell layer, so nothing outside the locker can cover
# a locked screen. On a panel with no DPMS standby the hardware can only DIM
# (measured on an AW2725Q: VCP 10 = 0 is dim, not black). So the locker must
# repaint, and swaylock carries a two-signal interface for exactly that:
#
#     SIGUSR2   blank    solid colour instead of the image
#     SIGRTMIN  restore  the image again
#
# THE PATCH CARRIES NO POLICY -- no timer, no options. WHEN to blank is this
# hook's business, driven by the ladder. That split is the whole point: the
# 2026-09-04 retirement was right that a timer inside the locker duplicated
# swayidle, and wrong that the PAINT was replaceable from outside.
#
# pgrep/pkill are STUBBED, which the suite permits for actuators: they are the
# only way to assert WHICH signal was sent, and what was NOT sent. Nothing here
# stands in for system state.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init lock-blank

HOOK=$HERE/libexec/vigilance/hooks/lock-blank
mkdir -p "$T/bin" "$T/state"

cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
[ -n "${LOCKER_UP:-}" ] && exit 0
exit 1
EOF
cat > "$T/bin/pkill" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SIGNALS"
[ -n "${PKILL_FAIL:-}" ] && exit 1
exit 0
EOF
chmod +x "$T/bin/pgrep" "$T/bin/pkill"
PATH="$T/bin:$PATH"; export PATH
SIGNALS=$T/signals; export SIGNALS
export LOCKER_UP=1 PKILL_FAIL=

# THE BACKLIGHT ROOT IS PINNED, and empty by default. This hook is a LAST
# RESORT for a panel with no other way to go dark, so "no sysfs backlight" is
# the condition every case below is about. Left unpinned it reads the HOST:
# every case here would decline on the developer's laptop (intel_backlight,
# max 400) and pass on a desktop, which is a verdict about the substrate.
mkdir -p "$T/backlight"
_run() {   # <edge> [kind]
  : > "$SIGNALS"
  VIGILANCE_EDGE="$1" VIGILANCE_KIND="${2:-act}" \
    VIGILANCE_SYS_BACKLIGHT="${BL_ROOT:-$T/backlight}" \
    VIGILANCE_LOCK_BLANK="${BLANK_POLICY:-auto}" \
    VIGILANCE_STATE_DIR="$T/state" sh "$HOOK" "$1" 2>>"$T/stderr"
}
_sent() { cat "$SIGNALS" 2>/dev/null; }

# --- 1. a DARK rung blanks the surface --------------------------------------
_run sleep || fail "the hook failed on a dark edge with a locker running"
case "$(_sent)" in
  *USR2*) ;;
  *) fail "a dark rung did not send the blank signal (sent: '$(_sent)')" ;;
esac

# --- 2. a LIT rung restores it ----------------------------------------------
# Driven by swayidle's own `resume` -> `vigilant go lock` -> wake.d, which is
# where the presence-awareness lives. The locker carries no timer of its own,
# so this hook is the ONLY thing that puts the wallpaper back.
_run wake || fail "the hook failed on a lit edge"
case "$(_sent)" in
  *RTMIN*) ;;
  *) fail "a lit rung did not send the restore signal (sent: '$(_sent)')" ;;
esac
case "$(_sent)" in
  *USR2*) fail "a lit rung sent the BLANK signal; the screen would stay dark
through the password prompt" ;;
esac

# --- 3. NO LOCKER is n/a, not failure ---------------------------------------
# The common case, not an edge case: a machine crosses `sleep` from an unlocked
# session routinely (the display keybind, a manual `go sleep`), and a greeter
# has no locker at all. There is simply no lock surface to repaint.
LOCKER_UP=; export LOCKER_UP
_run sleep || fail "the hook FAILED with no locker running. That is an
unlocked session crossing sleep, which is routine, and a greeter's permanent
state -- it would alert on every such edge"
[ -z "$(_sent)" ] || fail "a signal was sent with no locker running"
LOCKER_UP=1; export LOCKER_UP

# --- 4. VERIFY MEASURES THE PIXELS ------------------------------------------
# swaylock exposes no way to ask what it is painting -- but the compositor can
# see the surface, so a grab plus ImageMagick turns "is it black" into a number.
# SANDBOXED through VIGILANCE_SCREEN_LUMA: without it this tier would measure
# the DEVELOPER'S OWN SCREEN, which is the mistake behind seven past defects
# here, arriving in the one hook whose job is to look at a display.
VIGILANCE_SCREEN_LUMA=0; export VIGILANCE_SCREEN_LUMA
_run sleep verify || fail "verify called a genuinely black surface drift"
[ -z "$(_sent)" ] || fail "the verify tier SENT A SIGNAL. Verify must observe,
not actuate: a tier that changes the thing it is checking cannot be trusted to
report on it"

# ...and a surface still EMITTING at a dark rung is the finding.
VIGILANCE_SCREEN_LUMA=0.2665
_run sleep verify && fail "verify passed a lock surface emitting light at a
dark rung. That is a lit wallpaper burning into an OLED all night, which is the
whole reason this hook exists" || :

# THE ALPHA TRAP, pinned as a regression. ImageMagick's %[fx:mean] averages ALL
# channels including alpha, so an opaque all-black frame reads 0.25 rather than
# 0. The first version of this check called a pitch-black screen "not black"
# for exactly that reason and contradicted a human looking at it. If the
# measurement ever stops excluding alpha, 0.25 is what it will report -- so
# 0.25 must read as EMITTING, and the fix is to measure with -alpha off.
VIGILANCE_SCREEN_LUMA=0.25
_run sleep verify && fail "verify accepted 0.25 as black. That is precisely
what an opaque black frame reads when alpha is averaged in, so accepting it
would restore the bug where a working blank measured as broken" || :
VIGILANCE_SCREEN_LUMA=0; export VIGILANCE_SCREEN_LUMA

# --- 4z. THE MEASUREMENT ITSELF, against a real image -----------------------
# Everything above tests the THRESHOLD through VIGILANCE_SCREEN_LUMA, which
# short-circuits the pipeline -- so the alpha handling, the thing that actually
# produced a wrong verdict, would go untested. Here grim is stubbed to emit a
# known opaque-black RGBA frame and the REAL magick measures it.
#
# The trap, reproduced exactly:
#     -colorspace Gray            0.5   <- alpha averaged in
#     -alpha off -colorspace Gray 0     <- the truth
#
# A screengrab always carries an alpha channel, so this is not a corner case;
# it is what every capture looks like.
if command -v magick >/dev/null 2>&1; then
  unset VIGILANCE_SCREEN_LUMA
  magick -size 8x8 xc:black -alpha set PNG32:"$T/black.png" 2>/dev/null
  printf '#!/bin/sh\ncat %s\n' "$T/black.png" > "$T/bin/grim"
  chmod +x "$T/bin/grim"
  _run sleep verify || fail "the REAL measurement called an opaque all-black
frame 'emitting'. That is the alpha channel being averaged into the mean, which
reads 0.5 on a black RGBA frame -- the bug that made a pitch-black screen
measure as lit and contradicted a human looking straight at it"
  rm -f "$T/bin/grim"
  VIGILANCE_SCREEN_LUMA=0; export VIGILANCE_SCREEN_LUMA
fi

# --- 4a. A CAPTURE THAT FAILS is n/a, not drift -----------------------------
# A greeter, a tty, a session with no compositor: there is no display to grab.
# Asserting about a surface we cannot see is precisely what this hook was
# rewritten to stop doing, so an unmeasurable screen must say nothing.
unset VIGILANCE_SCREEN_LUMA
printf '#!/bin/sh\nexit 0\n' > "$T/bin/grim"      # succeeds, emits nothing
printf '#!/bin/sh\nexit 0\n' > "$T/bin/magick"
chmod +x "$T/bin/grim" "$T/bin/magick"
_run sleep verify || fail "an unmeasurable screen was reported as drift. A
greeter or a tty has no display to grab, and a hook that cannot see must not
claim -- that is the whole reason this tier was rewritten"
rm -f "$T/bin/grim" "$T/bin/magick"
VIGILANCE_SCREEN_LUMA=0; export VIGILANCE_SCREEN_LUMA

# --- 4b. a LIT rung is checked against the RECORD, not the pixels -----------
# A legitimately dark wallpaper cannot be told from a stuck blank by looking,
# and failing on that would cry wolf at anyone whose lock screen is black. What
# IS unambiguous is our own marker surviving: we blanked and never restored.
_run sleep                     # act: blank, marker dropped
_run wake                      # act: restore, marker cleared
_run wake verify || fail "verify flagged a lit rung after the restore had
actually run. The marker was cleared, so there is nothing to report"

# ...and a restore that never happened IS the finding.
_run sleep                     # blank, marker dropped
_run wake verify && fail "verify passed a lit rung with the blank marker still
outstanding. We blanked and never restored, so the screen is black while the
machine believes it is showing a prompt" || :
_run wake                      # tidy up: clear the marker

# --- 5. an edge with no darkness intent is a no-op --------------------------
# `lock` is a LIT rung -- the screen is on, showing the locker. Blanking there
# would black the screen at the moment the user is being asked for a password.
_run lock || fail "the hook failed on the lock edge"
case "$(_sent)" in
  *USR2*) fail "the hook blanked the surface at the LOCK rung, which is lit --
that blacks the screen exactly when the password prompt appears" ;;
esac

# --- 6. a failed signal is REPORTED, not swallowed --------------------------
# It costs only a wallpaper, never access -- but a blank that silently did not
# happen is a screen quietly emitting all night, which is the whole point of
# the hook.
PKILL_FAIL=1; export PKILL_FAIL
if _run sleep 2>>"$T/stderr"; then
  fail "the hook returned SUCCESS while the signal failed. The surface never
blanked and nothing anywhere says so"
fi
PKILL_FAIL=; export PKILL_FAIL

# --- 7. the locker NAME is overridable --------------------------------------
# An integrator running something other than swaylock must be able to say so,
# and the signal must follow the name rather than a hardcoded one.
VIGILANCE_LOCKER=mylocker; export VIGILANCE_LOCKER
_run sleep || fail "the hook failed with a custom locker name"
case "$(_sent)" in
  *myotherlocker*) fail "unreachable" ;;
  *mylocker*) ;;
  *) fail "the signal did not target the configured locker:
$(_sent)" ;;
esac
unset VIGILANCE_LOCKER

# --- THE HARDWARE GATE ------------------------------------------------------
# This is a last resort, not a preference. It exists for a panel that cannot go
# dark any other way; on a box WITH a backlight, panel-backlight already takes
# the panel genuinely dark and this only costs the lock wallpaper.
#
# And not merely nothing: on an ASCENT the machine scope unwinds FIRST, so
# 20-panel-backlight restores brightness before this user-scope hook repaints.
# The panel lights up showing a BLACK lock surface and the wallpaper arrives
# afterwards -- a visible black flash on every wake, on a box that needed none
# of it. Observed on manifold, which has intel_backlight at max 400.
mkdir -p "$T/haslight/intel_backlight"
printf '400\n' > "$T/haslight/intel_backlight/max_brightness"
rm -f "$T/state/blanked"

BL_ROOT=$T/haslight
_rc=0; _run sleep >/dev/null || _rc=$?
[ "$_rc" = 78 ] || fail "with a usable sysfs backlight the hook returned $_rc,
not 78. It must DECLINE: panel-backlight already darkens that panel, so
blanking the surface costs the lock wallpaper and buys nothing"
case "$(_sent)" in
  *USR2*) fail "a gated hook still signalled the locker" ;;
esac

# A DEVICE WITH max_brightness 0 IS NOT A BACKLIGHT. Treating it as one would
# decline on hardware that genuinely cannot dim -- exactly the box this hook
# exists for, left with a lit wallpaper on an OLED.
mkdir -p "$T/zerolight/fake"
printf '0\n' > "$T/zerolight/fake/max_brightness"
BL_ROOT=$T/zerolight
_run sleep >/dev/null || fail "a max_brightness=0 device was treated as a
working backlight, so the one panel that needs blanking would not get it"
case "$(_sent)" in
  *USR2*) ;;
  *) fail "no blank signal on a box whose only 'backlight' cannot dim" ;;
esac
rm -f "$T/state/blanked"

# --- A RESTORE IS NEVER GATED -----------------------------------------------
# If a marker is outstanding we blanked before the policy said not to -- a
# deploy, a config change, a mixed setup. Declining then would leave the
# wallpaper black with nothing able to bring it back. A short-circuit on state
# that cannot clear the state is what left a stale save failing every ascent
# for four days.
BL_ROOT=$T/zerolight
_run sleep >/dev/null || fail "setup: could not blank to create the marker"
[ -f "$T/state/blanked" ] || fail "setup: no marker was written"
BL_ROOT=$T/haslight            # policy now says do not blank this box
_run wake >/dev/null || fail "a gated hook refused to RESTORE an outstanding
blank. That leaves a black wallpaper with nothing able to repaint it"
case "$(_sent)" in
  *RTMIN*) ;;
  *) fail "the restore signal was not sent (sent: '$(_sent)')" ;;
esac
[ ! -f "$T/state/blanked" ] || fail "the marker survived the restore"

# ...but once nothing is outstanding, a gated box stays out of the way.
_rc=0; _run wake >/dev/null || _rc=$?
[ "$_rc" = 78 ] || fail "with no marker outstanding a gated box returned $_rc,
not 78; it should decline rather than signal on every ascent forever"

# --- THE OVERRIDE, both directions ------------------------------------------
BL_ROOT=$T/haslight BLANK_POLICY=always
_run sleep >/dev/null || fail "VIGILANCE_LOCK_BLANK=always did not override the
gate. A laptop with an internal backlight AND an external monitor without one
is exactly the mixed case the cheap predicate answers wrong"
case "$(_sent)" in *USR2*) ;; *) fail "always: no blank signal" ;; esac
rm -f "$T/state/blanked"

BL_ROOT=$T/zerolight BLANK_POLICY=never
_rc=0; _run sleep >/dev/null || _rc=$?
[ "$_rc" = 78 ] || fail "VIGILANCE_LOCK_BLANK=never did not suppress the blank"

pass
