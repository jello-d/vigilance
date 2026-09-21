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
. "$(dirname "$0")/lib.sh"
harness_init screen-dark

HOOK=$HERE/libexec/vigilance/hooks/screen-dark
mkdir -p "$T/bin"

# THE BACKLIGHT ROOT IS PINNED AND EMPTY BY DEFAULT. Every case here is about
# a box with no backlight; left unpinned they would read the HOST's, and on a
# laptop at full brightness that happens to give the same answers -- a verdict
# about the substrate rather than the code.
mkdir -p "$T/nobacklight"
_run() {   # <edge> <luma|-> [kind]
  _r=0
  if [ "$2" = - ]; then
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
      VIGILANCE_SYS_BACKLIGHT="${BL_ROOT:-$T/nobacklight}" \
      sh "$HOOK" "$1" 2>>"$T/stderr" || _r=$?
  else
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
      VIGILANCE_SYS_BACKLIGHT="${BL_ROOT:-$T/nobacklight}" \
      VIGILANCE_SCREEN_LUMA="$2" sh "$HOOK" "$1" 2>>"$T/stderr" || _r=$?
  fi
  printf '%s' "$_r"
}

# --- 1. THE FOUR MISSES, all caught by one mechanism-blind check ------------
# Each of these was a real green verdict with a lit screen behind it. The
# luminance is the one measured on the live desktop.
[ "$(_run sleep 0.2546)" = 1 ] || fail "a screen emitting 0.2546 at the SLEEP
rung was accepted. That is the exact state that survived four green verdicts --
unimplemented D6, a vanished monitor, and two sessions with no darkening
mechanism at all -- because every per-device check was satisfied on its own
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
gets disabled -- taking the direction that matters with it"
[ "$(_run unlock 0)" = 0 ] || fail "same, on unlock"

# AND THE ORDINARY CASE: a normally-lit screen at a lit rung. Testing only the
# black-at-lit case above missed this entirely -- removing the lit guard still
# passed, because a black screen reads as dark whichever rung you ask about.
# This is the one that bites: every waking moment is a lit screen at a lit rung,
# so a hook that judged that direction would fire constantly.
[ "$(_run lock 0.2546)" = 0 ] || fail "a NORMALLY LIT screen at a lit rung was
reported as drift. That is every waking moment of the machine, so this check
would fire constantly and be switched off within a day -- taking the dark
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
# minute at a rung where display-watch recorded bl=0 -- a panel that was
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

# ...and the threshold matches hooklib's, so the two tiers cannot disagree
# about what "dark" means on a device that floors above zero.
printf '40\n' > "$T/haslight/intel_backlight/brightness"     # exactly max/10
[ "$(_run sleep 0.276981)" = 0 ] || fail "a backlight at max/10 was called lit;
hooklib treats that as dark, and two tiers disagreeing about the word is how a
box reports drift and a fix that cannot clear it"

# --- BUT A LIT BACKLIGHT STILL JUDGES THE FRAMEBUFFER -----------------------
# Without this, "always pass when a backlight exists" would satisfy the case
# above while switching the hook off entirely on every laptop in the fleet.
printf '400\n' > "$T/haslight/intel_backlight/brightness"
[ "$(_run sleep 0.276981)" = 1 ] || fail "with the backlight at FULL and a lit
framebuffer, the screen is emitting and the rung claims dark. Passing that
would disable this check on every box that has a backlight"
BL_ROOT=

pass
