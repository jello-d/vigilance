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

_run() {   # <edge> <luma|-> [kind]
  _r=0
  if [ "$2" = - ]; then
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
      sh "$HOOK" "$1" 2>>"$T/stderr" || _r=$?
  else
    VIGILANCE_EDGE="$1" VIGILANCE_KIND="${3:-verify}" \
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

pass
