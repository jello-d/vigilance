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
mkdir -p "$T/bin"

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

_run() {   # <edge> [kind]
  : > "$SIGNALS"
  VIGILANCE_EDGE="$1" VIGILANCE_KIND="${2:-act}" sh "$HOOK" "$1" 2>>"$T/stderr"
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

# --- 4. VERIFY asserts NOTHING, deliberately --------------------------------
# swaylock exposes no way to ask what it is painting. A verify tier that
# "confirmed" the blank would be asserting something it cannot observe, which is
# precisely the false green this project exists to catch. Saying nothing is the
# honest answer; the act tier is idempotent, so re-asserting is the remedy.
_run sleep verify || fail "the verify tier failed"
[ -z "$(_sent)" ] || fail "the verify tier SENT A SIGNAL. Verify must observe,
not actuate: a tier that changes the thing it is checking cannot be trusted to
report on it"

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

pass
