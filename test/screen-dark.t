#!/bin/sh
# test/screen-dark.t - the one check that asks the RUNG'S question.
#
# WHY IT EXISTS. Every other verifier asks about its own mechanism, and each was
# individually correct while a lit screen survived four separate green verdicts:
#
#   a D6 code the panel does not implement      ddc-monitor was satisfied
#   a monitor that vanished from its own map    not in the map to be checked
#   a user session with no darkening mechanism  every hook declined
#   a greeter with none either                  every hook declined
#
# The failure lived in the gap BETWEEN per-device checks, which is exactly where
# a per-device check cannot look. This one is mechanism-blind on purpose: it
# measures what the display emits and compares it to what the rung claims, so it
# holds when a mechanism is broken, when one was never wired, and when the hook
# that owned it declined.
#
# DEFENSE IN DEPTH, not a replacement: the per-device verifiers say WHICH
# mechanism failed, which is what you need to fix it. This says THAT the machine
# is lying, which is what you need to know at all.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init screen-dark

HOOK=$HERE/libexec/vigilance/hooks/screen-dark
mkdir -p "$T/bin"

# THE BACKLIGHT ROOT IS PINNED AND EMPTY BY DEFAULT. Every case here is about
# a box with no backlight; left unpinned they would read the HOST's, and on a
# laptop at full brightness that happens to give the same answers: a verdict
# about the substrate rather than the code.
mkdir -p "$T/nobacklight"
# PEAK is set by the later cases only, so every case above them keeps supplying
# a mean alone and keeps asserting exactly what it used to.
_run() {   # <edge> <luma|-> [kind]   (PEAK= in the environment is optional)
  _r=0
  : > "$T/last"
  if [ "$2" = - ]; then
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
      VIGILANCE_SYS_BACKLIGHT="${BL_ROOT:-$T/nobacklight}" \
      VIGILANCE_SCREEN_PEAK="${PEAK:-}" \
      sh "$HOOK" "$1" 2>>"$T/last" || _r=$?
  else
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
      VIGILANCE_SYS_BACKLIGHT="${BL_ROOT:-$T/nobacklight}" \
      VIGILANCE_SCREEN_LUMA="$2" VIGILANCE_SCREEN_PEAK="${PEAK:-}" \
      sh "$HOOK" "$1" 2>>"$T/last" || _r=$?
  fi
  cat "$T/last" >> "$T/stderr"
  printf '%s' "$_r"
}
_said() { cat "$T/last" 2>/dev/null; }

# --- 1. THE FOUR MISSES, all caught by one mechanism-blind check ------------
# Each of these was a real green verdict with a lit screen behind it. The
# luminance is the one measured on the live desktop.
[ "$(_run sleep 0.2546)" = 1 ] || fail "a screen emitting 0.2546 at the SLEEP
rung was accepted. That is the exact state that survived four green verdicts:
unimplemented D6, a vanished monitor, and two sessions with no darkening
mechanism at all, because every per-device check was satisfied on its own
terms while nobody asked what the rung actually claims"

# ...and it is the same answer however the machine got there. The point of a
# mechanism-blind check is that it does not need to know.
for _e in sleep suspend resume; do
  [ "$(_run "$_e" 0.44)" = 1 ] || fail "a lit screen at the dark rung '$_e' was
accepted; the check must hold on every rung that claims darkness"
done

# --- 2. a genuinely dark screen passes -------------------------------------
[ "$(_run sleep 0)" = 0 ] || fail "a black screen was reported as drift"
[ "$(_run sleep 0.0009)" = 0 ] || fail "a near-black screen was reported as
drift; a threshold that fails on sub-thousandth luminance would cry wolf on a
panel that is off"

# --- 3. a LIT rung is deliberately NOT asserted ----------------------------
# A black wallpaper, a dark theme, a mostly-black terminal: none is drift.
# Asserting the lit direction would make this the crying-wolf check that gets
# switched off, and then the dark direction goes with it.
[ "$(_run lock 0)" = 0 ] || fail "a black screen at a LIT rung was called drift.
A dark wallpaper is not a fault, and a check that fires on one is a check that
gets disabled, taking the direction that matters with it"
[ "$(_run unlock 0)" = 0 ] || fail "same, on unlock"

# AND THE ORDINARY CASE: a normally-lit screen at a lit rung. Testing only the
# black-at-lit case above missed this entirely: removing the lit guard still
# passed, because a black screen reads as dark whichever rung you ask about.
# This is the one that bites: every waking moment is a lit screen at a lit rung,
# so a hook that judged that direction would fire constantly.
[ "$(_run lock 0.2546)" = 0 ] || fail "a NORMALLY LIT screen at a lit rung was
reported as drift. That is every waking moment of the machine, so this check
would fire constantly and be switched off within a day, taking the dark
direction, the one that matters, with it"
[ "$(_run open 0.44)" = 0 ] || fail "same at the open rung"

# --- 4. NOTHING TO MEASURE is n/a, not a pass and not drift ----------------
# A greeter reached over ssh, a tty, a headless box: there is no compositor to
# grab from. Claiming either verdict would be inventing one.
printf '#!/bin/sh\nexit 1\n' > "$T/bin/grim"
chmod +x "$T/bin/grim"
_orig_path=$PATH
PATH="$T/bin:$PATH"; export PATH
[ "$(_run sleep -)" = 78 ] || fail "with no capturable display the hook did not
decline with 78. 0 would launder 'I could not look' into 'the screen is dark',
which is the conflation that produced every failure this hook exists to catch"
PATH=$_orig_path; export PATH

# --- 5. it ACTUATES NOTHING ------------------------------------------------
# Refusing to pick a mechanism is the whole design: an act tier here would have
# to choose DDC or DPMS or a backlight, and choosing is what the per-device
# hooks are for.
[ "$(_run sleep 0.2546 act)" = 0 ] || fail "the act tier did something. This
hook must not actuate: deciding HOW to darken is exactly what it refuses to
know, which is what lets it judge every mechanism impartially"

# --- A BACKLIGHT AT 0 IS DARK, WHATEVER THE FRAMEBUFFER SAYS ---------------
# THE FLAW THIS FILE MISSED, found on a live box. `grim` copies the
# COMPOSITOR'S framebuffer; the backlight is a panel property outside the
# compositor entirely, so a capture reads the same whether the panel is
# blazing or completely off. This hook claimed to measure "what the display
# emits" and never could.
#
# It looked correct only because lock-blank was painting the surface black on
# that box. Gating lock-blank to the hardware that needs it removed the mask,
# and this began reporting "still emitting, mean luminance 0.277" once a
# minute at a rung where display-watch recorded bl=0: a panel that was
# genuinely, physically dark.
#
# Every case above passes with the bug present, because none of them models a
# backlight at all. That is why it shipped.
mkdir -p "$T/haslight/intel_backlight"
printf '400\n' > "$T/haslight/intel_backlight/max_brightness"
printf '0\n'   > "$T/haslight/intel_backlight/brightness"
BL_ROOT=$T/haslight
[ "$(_run sleep 0.276981)" = 0 ] || fail "a panel held dark by its backlight
was reported as still emitting. That is the live manifold state exactly: bl=0
at the sleep rung, framebuffer still showing the lock surface. The capture
cannot see a backlight, so judging emission by the capture alone is a claim
this hook was never able to make"

# ...and the threshold matches hook_lib's, so the two tiers cannot disagree
# about what "dark" means on a device that floors above zero.
printf '40\n' > "$T/haslight/intel_backlight/brightness"     # exactly max/10
[ "$(_run sleep 0.276981)" = 0 ] || fail "a backlight at max/10 was called lit;
hook_lib treats that as dark, and two tiers disagreeing about the word is how a
box reports drift and a fix that cannot clear it"

# --- BUT A LIT BACKLIGHT STILL JUDGES THE FRAMEBUFFER -----------------------
# Without this, "always pass when a backlight exists" would satisfy the case
# above while switching the hook off entirely on every laptop in the fleet.
printf '400\n' > "$T/haslight/intel_backlight/brightness"
[ "$(_run sleep 0.276981)" = 1 ] || fail "with the backlight at FULL and a lit
framebuffer, the screen is emitting and the rung claims dark. Passing that
would disable this check on every box that has a backlight"
BL_ROOT=

# --- SCIENTIFIC NOTATION IS A NUMBER --------------------------------------
# THE BUG THAT FIRED 275 TIMES ON manifestor, on the box where the mechanism
# was working BEST. hook_luma_is_dark matched strings (`0|0.00*`), and
# ImageMagick emits an exponent for very small means, which is precisely the
# success case. A genuinely black lock surface measured 3.64999e-05, blacker
# than the other box ever gets, and was reported as still emitting.
#
# A check that fires hardest where the mechanism works is worse than no check:
# it teaches the reader that the tier is noise, on the one box whose OLED has
# no other way to go dark.
for _v in 3.64999e-05 3.44196e-05 1.0e-9 0E0; do
  [ "$(_run sleep "$_v")" = 0 ] || fail "a luminance of $_v (black to nine
decimal places) was reported as a lit screen. Comparing a number as a string
cannot read an exponent, and an exponent is what a working blank produces"
done

# ...and the threshold still bites on the other side of it.
[ "$(_run sleep 0.0100001)" = 1 ] || fail "a luminance just over the 0.01
threshold was accepted; the fix must not widen what counts as dark"
[ "$(_run sleep 1e3)" = 1 ] || fail "a LARGE value in exponent form was read as
dark. Parsing the exponent must not mean trusting the sign of it"

# A NON-NUMBER IS NOT DARK. awk turns garbage into 0 silently, and 0 is the one
# answer that switches this tier off rather than merely annoying it.
[ "$(_run sleep abc)" = 1 ] || fail "a non-numeric luminance was treated as
black. That is the reading that makes a broken measurement look like a working
blank, which is the failure mode this whole hook exists to catch"

# --- A MEAN CANNOT SEE A CURSOR, which is the wrong STATISTIC, not a bad cut --
# THE USER SAW IT ON THE GLASS FIRST. On manifestor a notification coming to the
# forefront brings the pointer up, and with the lock surface painted black that
# leaves a white cursor sitting on an OLED: the burn-in lock-blank exists to
# prevent, held perfectly still for as long as nobody touches the mouse.
#
# The mean is structurally unable to report it. Measured through the real
# pipeline on a 2880x1800 panel at the 5% capture scale, against a 0.01 cut:
#
#   shape                      lit px   mean        peak
#   48x48 solid white            2304   0.000450    1.00
#   a realistic arrow pointer     931   0.000184    0.62 to 0.77
#   a 24px arrow                  264   0.0000526   0.35
#   a thin I-beam, the sparsest    123   0.0000255   0.084
#   four dim scattered pixels        4   0.00000014  0.0004
#
# EVERY ONE OF THOSE MEANS IS DARK. A fully white cursor lifts the mean 22x less
# than the threshold, so the old check certified the exact state it existed to
# catch. These are the measured pairs, so the rows are the evidence rather than
# illustrations.
PEAK=1
[ "$(_run sleep 0.000450)" = 1 ] || fail "a 48x48 WHITE CURSOR
on a surface that averages black was accepted. The mean is 22x below the
threshold by construction, so the mean alone can never see it"
PEAK=0.765728
[ "$(_run sleep 0.000184)" = 1 ] || fail "a realistic arrow
pointer (peak 0.77) was accepted"
PEAK=0.35314
[ "$(_run sleep 0.0000526)" = 1 ] || fail "a 24px pointer (peak
0.35) was accepted; a smaller cursor must not fall through the cut"
PEAK=0.0843671
[ "$(_run sleep 0.0000255)" = 1 ] || fail "a thin I-BEAM (peak
0.084) was accepted. That is the sparsest realistic pointer shape and so the
tightest margin the 0.02 threshold has; losing it loses text cursors"

# ...AND THE NOISE FLOOR MUST NOT FIRE, which is the half that decides whether
# this check survives contact with a real box. A capture of a genuinely black
# surface still carries a few dim pixels, and the downscale averages them to
# 0.0004: 50x under the threshold. A check that fires on a working blank is the
# cry-wolf this suite bans, and it would take the cursor case down with it.
PEAK=0.000396735
[ "$(_run sleep 0.00000014)" = 0 ] || fail "four dim scattered
pixels (peak 0.0004, the measured noise floor of a real black capture) were
reported as a bright spot. This tier would then fire on every correct blank"
PEAK=0
[ "$(_run sleep 0)" = 0 ] || fail "a pure black surface
with no bright spot anywhere was rejected"

# A NON-NUMERIC PEAK IS NOT DARK EITHER, the same reason as the mean's: awk
# would turn it into 0 and 0 is the answer that silences the check.
PEAK=banana
[ "$(_run sleep 0)" = 1 ] || fail "a non-numeric PEAK was treated as
no bright spot. Garbage must never read as the reassuring answer"

# --- AN UNKNOWN PEAK IS A WEAKER PASS, AND HAS TO SAY SO -------------------
# The exit code is 0 either way, so without a word of explanation "the surface
# averages black" and "nothing is emitting anywhere" are indistinguishable: the
# conflation this change is about, surviving in the one place left for it.
PEAK= ; [ "$(_run sleep 0)" = 0 ] || fail "an answer carrying no peak was
treated as a failure. An older deployed hook and a mean-only fixture both look
like this, and neither is evidence that something is emitting"
case "$(_said)" in
  *'NOT checked'*)
    case "$(_said)" in
      *'not a power state'*) ;;
      *) fail "the unknown-peak pass admits the bright-spot question was not
checked, but does not say that black CONTENT is not a power state. That second
half is the point: the panel is on and scanning out:
$(_said)" ;;
    esac ;;
  *) fail "an unknown peak passed SILENTLY, so it reads exactly like a surface
proven to have nothing emitting on it. That is the conflation the whole change
exists to remove:
$(_said)" ;;
esac

# --- AND THE FAILURE NAMES THE PANEL'S STATE --------------------------------
# "dark" was being used for two things: a panel that EMITS NOTHING whatever is
# drawn on it (a backlight at zero, a monitor in standby) and a panel that is on
# and scanning out black CONTENT. Only the first survives something else
# drawing. A reader who cannot tell them apart cannot judge the risk.
PEAK=1 ; _r=$(_run sleep 0.000450)
case "$(_said)" in
  *'panel itself is ON'*) ;;
  *) fail "the bright-spot failure does not say the panel is still on and
scanning out. Without it the message reads as a monitor that failed to power
down, which is a different fault with a different remedy:
$(_said)" ;;
esac
case "$(_said)" in
  *'AVERAGES black'*) ;;
  *) fail "the failure does not distinguish itself from the whole-surface case.
Both exit 1, so the words are the only thing telling a reader whether the screen
is lit or merely carrying a bright spot:
$(_said)" ;;
esac

# --- THE MEASUREMENT, NOT THE THRESHOLD ------------------------------------
# EVERY CASE ABOVE GOES THROUGH THE OVERRIDE, which short-circuits the capture
# pipeline entirely. That is exactly how the alpha-channel bug survived its own
# test file: all the threshold cases passed with it still in. So one case drives
# the REAL grim-to-magick pipeline and lets it produce its own numbers.
#
# AND THE STUB MODELS A REAL COMPOSITOR'S CURSOR RULE. `grim` omits the pointer
# unless given `-c`, so the stub emits a frame with a bright block ONLY when it
# sees that flag, exactly as a compositor would. The hook must therefore pass
# `-c` or it measures a frame with no cursor in it and reports black: the second
# of the two independent blindnesses, and either one alone still certifies the
# state.
_vskip=${_vskip:-}
if command -v magick >/dev/null 2>&1; then
  magick -size 400x250 xc:black -fill white -draw 'rectangle 10,10 26,26' \
    PNG32:"$T/with-cursor.png" 2>/dev/null
  magick -size 400x250 xc:black PNG32:"$T/no-cursor.png" 2>/dev/null
  cat > "$T/bin/grim" <<EOF
#!/bin/sh
for _a in "\$@"; do [ "\$_a" = -c ] && exec cat "$T/with-cursor.png"; done
exec cat "$T/no-cursor.png"
EOF
  chmod +x "$T/bin/grim"
  _rc=0
  PATH="$T/bin:$PATH" WAYLAND_DISPLAY=wayland-0 \
    VIGILANCE_EDGE=sleep VIGILANCE_KIND=verify \
    VIGILANCE_SYS_BACKLIGHT="$T/nobacklight" \
    sh "$HOOK" sleep 2>>"$T/realmeas" || _rc=$?
  [ "$_rc" = 1 ] || fail "with a REAL capture of a black frame carrying a white
block, and the real ImageMagick measuring it, the hook returned $_rc instead of
1. Either it did not pass grim -c (so it measured the cursorless frame, which is
what a compositor really gives you) or the peak never reached the threshold
through the actual pipeline. Every case above this one uses the override and
would pass with both of those broken:
$(cat "$T/realmeas" 2>/dev/null)"
  rm -f "$T/bin/grim"

  # AND A SUPPLIED GRABBER REACHES THE SAME MEASUREMENT. A KDE Plasma session
  # has neither grim nor import and reaches for spectacle; without
  # VIGILANCE_SCREEN_GRAB such a box could only override the WHOLE ANSWER,
  # which replaces the statistic along with the capture and makes the tier a
  # fixture, or patch hook_lib to supply a tool.
  #
  # DRIVEN THROUGH THE REAL PIPELINE for the same reason as the case above: the
  # point is that only the FRAME'S SOURCE changes while the threshold, the
  # alpha handling and the whole-surface rule stay shared. So the grabber emits
  # the cursor frame and the hook must reach the same verdict it reached from
  # grim, with no grim or import on PATH at all.
  cat > "$T/bin/plasma-grab" <<EOF
#!/bin/sh
exec cat "$T/with-cursor.png"
EOF
  chmod +x "$T/bin/plasma-grab"
  _rc=0
  PATH="$T/nothing:/usr/bin:/bin" \
    VIGILANCE_SCREEN_GRAB="$T/bin/plasma-grab" \
    VIGILANCE_EDGE=sleep VIGILANCE_KIND=verify \
    VIGILANCE_SYS_BACKLIGHT="$T/nobacklight" \
    sh "$HOOK" sleep 2>>"$T/grabmeas" || _rc=$?
  [ "$_rc" = 1 ] || fail "with a SUPPLIED grabber handing over the same frame,
the hook returned $_rc instead of 1. The knob has to feed the real measurement
rather than bypass it, or an integrator on a third stack gets a tier that
either declines for ever or measures a value it was handed:
$(cat "$T/grabmeas" 2>/dev/null)"
  rm -f "$T/bin/plasma-grab"
else
  # NAMED, NOT SILENT. Everything above needs magick, so
  # without it those assertions simply do not run while the
  # verdict below still claims them. environment.t already
  # carries this pattern: say what was NOT checked.
  _vskip="$_vskip magick"
fi

pass "mean and peak, the measured noise floor, the real pipeline, and a\
 supplied grabber${_vskip:+ (not checked:$_vskip)}"
