#!/bin/sh
# test/sway-dpms.t - blanking the GREETER, which has no locker to signal.
#
# THE GAP. A greeter's `sleep` edge runs machine-scope hooks only. On a panel
# that advertises no DPMS standby, ddc-monitor can only DIM (measured on an
# AW2725Q: VCP 10 = 0 is dim, not black), panel-backlight is n/a on an external
# monitor, and lock-blank cannot help twice over -- it is user scope, and it
# signals a locker a greeter does not have. So the keyboard went dark and the
# screen stayed lit, on the one session nobody is present to notice.
#
# WHY A SECOND HOOK RATHER THAN CHANGING `dpms`. That one is ON-only and stays
# so: it is written for the Wayfire user session where powering an output off
# re-modesets and was observed to DESTROY VIEWS, and test/dpms.t asserts
# mechanically that no edge ever issues an off there. This is a different hook
# for a different compositor, and that assertion is untouched.
#
# SELF-LIMITING BY CONSTRUCTION, which is the design point. The gate IS the
# tool: swaymsg can only talk to sway, so in a Wayfire session the hook simply
# cannot act and declines. That is what makes it safe to wire in MACHINE scope,
# where the greeter and the user session are offered the same hooks -- the one
# it must not act in cannot answer it. No host list to keep in sync.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init sway-dpms

HOOK=$HERE/libexec/vigilance/hooks/sway-dpms
mkdir -p "$T/bin"

# A swaymsg that can be made absent, unreachable, or answerable on demand, and
# that records every command so "what did it ask the compositor" is a fact
# rather than an inference.
cat > "$T/bin/swaymsg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SWAY_CMDS"
[ -n "${SWAY_UNREACHABLE:-}" ] && exit 1
case "$*" in
  *get_version*) echo '{"major":1}'; exit 0 ;;
  *get_outputs*) cat "$SWAY_OUTPUTS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/swaymsg"
PATH="$T/bin:$PATH"; export PATH
SWAY_CMDS=$T/cmds; SWAY_OUTPUTS=$T/outputs; export SWAY_CMDS SWAY_OUTPUTS
printf '[{"name":"DP-1","dpms":true},{"name":"DP-2","dpms":true}]\n' \
  > "$SWAY_OUTPUTS"

_run() {   # <edge> [kind]
  : > "$SWAY_CMDS"
  _r=0
  VIGILANCE_EDGE="$1" VIGILANCE_KIND="${2:-act}" sh "$HOOK" "$1" \
    2>>"$T/stderr" || _r=$?
  printf '%s' "$_r"
}
_asked() { cat "$SWAY_CMDS" 2>/dev/null; }

# --- 1. a DARK rung powers the outputs off ----------------------------------
[ "$(_run sleep)" = 0 ] || fail "the hook failed on a dark edge in a reachable
sway session"
case "$(_asked)" in
  *"output * dpms off"*) ;;
  *) fail "a dark rung did not ask sway to power the outputs off (asked:
$(_asked))" ;;
esac

# --- 2. a LIT rung brings them back -----------------------------------------
[ "$(_run wake)" = 0 ] || fail "the hook failed on a lit edge"
case "$(_asked)" in
  *"output * dpms on"*) ;;
  *) fail "a lit rung did not ask for dpms on. A greeter that goes dark with
nothing to bring it back is the failure this whole suite exists to prevent, and
nobody is sitting there to notice" ;;
esac
case "$(_asked)" in
  *"dpms off"*) fail "a lit rung asked for dpms OFF" ;;
esac

# --- 3. NOT SWAY: decline, and say so with 78 -------------------------------
# The load-bearing case. This hook is wired in MACHINE scope, so it is offered
# to the Wayfire user session too -- where powering an output off destroys
# views. It must be incapable of acting there, and it must not report success
# either, or an edge where nothing could blank reads like one where it did.
SWAY_UNREACHABLE=1; export SWAY_UNREACHABLE
[ "$(_run sleep)" = 78 ] || fail "with sway unreachable the hook returned
$(_run sleep), not 78. Anything else is wrong in a different way: 0 would claim
a blank that never happened, non-zero would fail every edge in a Wayfire
session where this hook is correctly inert"
case "$(_asked)" in
  *"dpms"*) fail "the hook issued a dpms command against an unreachable
compositor. The probe must gate the action, not follow it" ;;
esac
SWAY_UNREACHABLE=; export SWAY_UNREACHABLE

# --- 4. no swaymsg at all is the same answer --------------------------------
mv "$T/bin/swaymsg" "$T/bin/swaymsg.off"
[ "$(_run sleep)" = 78 ] || fail "with swaymsg absent the hook did not decline"
mv "$T/bin/swaymsg.off" "$T/bin/swaymsg"

# --- 5. VERIFY reads the state back, both directions ------------------------
printf '[{"name":"DP-1","dpms":false},{"name":"DP-2","dpms":false}]\n' \
  > "$SWAY_OUTPUTS"
[ "$(_run sleep verify)" = 0 ] || fail "verify called genuinely-off outputs
drift at a dark rung"
[ "$(_run wake verify)" != 0 ] || fail "verify passed outputs that are still
OFF at a lit rung. That is a dark greeter with the machine believing it is lit"

printf '[{"name":"DP-1","dpms":true},{"name":"DP-2","dpms":true}]\n' \
  > "$SWAY_OUTPUTS"
[ "$(_run wake verify)" = 0 ] || fail "verify called genuinely-on outputs drift
at a lit rung"
[ "$(_run sleep verify)" != 0 ] || fail "verify passed outputs still ON at a
dark rung -- the exact symptom that started this: keyboard dark, screen lit"

# --- 6. EVERY output is checked, not just the last one ----------------------
# swaymsg pretty-prints by default but not in every version. A compact one-line
# object would put every field on one awk record and the last "dpms" would win,
# so the check would silently examine ONE output and pass a lit second screen.
printf '[{"name":"DP-1","dpms":true},{"name":"DP-2","dpms":false}]\n' \
  > "$SWAY_OUTPUTS"
[ "$(_run wake verify)" != 0 ] || fail "one output OFF at a lit rung was missed.
A multi-head greeter with one dark screen is exactly the half-blind state this
must catch"
[ "$(_run sleep verify)" != 0 ] || fail "one output ON at a dark rung was
missed"

# --- 7. an edge with no darkness intent is a no-op --------------------------
printf '[{"name":"DP-1","dpms":true}]\n' > "$SWAY_OUTPUTS"
[ "$(_run lock)" = 0 ] || fail "the hook failed on the lock edge"
case "$(_asked)" in
  *"dpms"*) fail "the hook drove dpms at the LOCK rung, which is LIT. A greeter
sits at that rung permanently, so this would black the login screen and leave
it that way" ;;
esac

pass
