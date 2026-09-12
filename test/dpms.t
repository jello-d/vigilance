#!/bin/sh
# test/dpms.t - the ASYMMETRY IS THE SAFETY RULE, so assert it.
#
# `dpms` re-asserts outputs ON and must NEVER turn one off: on this Wayfire /
# wlroots build, powering an output off is a connector change that re-modesets
# and was observed to DESTROY VIEWS. The hook's own header warns, in capitals,
# that a future reader must not "complete" the half-implemented-looking thing
# into an off-switch.
#
# A WARNING IN A COMMENT IS NOT A GUARD. That is the lesson this project keeps
# paying for: the `vigilant` group requirement was a comment, the exit-code
# contract was a comment, and `audit covers it` was a comment. So the property
# is asserted mechanically, and anyone adding an `--off` breaks this test.
#
# STUBBING wlopm IS WITHIN THE RULES. The substrate rule is that actuators may
# be stubbed and the TRUST ROOT may not: a stubbed `systemctl` lies about system
# state, but a stubbed `wlopm` is a recorder standing in for hardware, which is
# what every other hook test does. It is also the only way to assert what was
# NOT called.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init dpms

DPMS=$HERE/libexec/vigilance/hooks/dpms
CALLS=$T/wlopm-calls

# A recorder wlopm. With no arguments it LISTS (the hook uses a bare `wlopm` as
# its "can we talk to a compositor at all" probe); with arguments, it records.
_stub_wlopm() {   # <listing>
  mkdir -p "$T/stub"
  cat > "$T/stub/wlopm" <<EOF
#!/bin/sh
if [ \$# -eq 0 ]; then printf '%s\n' "$1"; exit 0; fi
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
  chmod +x "$T/stub/wlopm"
}

_run() {   # <edge> [kind]
  VIGILANCE_EDGE="$1" VIGILANCE_KIND="${2:-act}" \
    VIGILANCE_INTENT="$(_intent "$1")" \
    PATH="$T/stub:$PATH" "$DPMS" "$1" 2>>"$T/stderr"
}

# The intent table, stated here independently so the test is not merely agreeing
# with whatever the runner exports. If these two ever disagree, that is the bug.
_intent() {
  case "$1" in
    sleep|suspend|resume) echo dark ;;
    wake|lock|unlock)     echo lit ;;
    *)                    echo none ;;
  esac
}

# --- THE SAFETY PROPERTY: no edge, in any direction, ever powers an output off
: > "$CALLS"
_stub_wlopm "DP-1 on
DP-2 on"
for _e in lock unlock sleep wake suspend resume; do
  _run "$_e" || fail "dpms exited non-zero on the '$_e' edge"
done
if grep -q -- "--off" "$CALLS" 2>/dev/null; then
  printf 'calls:\n%s\n' "$(cat "$CALLS")" >&2
  fail "dpms issued a wlopm --off. On this wlroots build that is a connector
change which re-modesets and can destroy every view in the session. The
asymmetry (ON only, never OFF) is the whole safety property of this hook and it
must not be 'completed' into a symmetric one"
fi

# --- the LIT half is actually done, or the hook is decorative ---------------
# The other way to pass the assertion above is to do nothing at all, which would
# be just as broken: this hook IS the cheap idempotent recovery for an output
# something outside vigilance switched off.
: > "$CALLS"
_run wake || fail "dpms failed on wake"
grep -q -- "--on" "$CALLS" \
  || fail "dpms did not assert outputs ON at a lit edge, so the recovery path
that justifies wiring it at all does nothing"

# --- a DARK edge does nothing, rather than something harmless --------------
: > "$CALLS"
_run sleep || fail "dpms failed on sleep"
[ ! -s "$CALLS" ] || fail "dpms called wlopm on a dark edge; darkness belongs to
the backlight and DDC hooks, which reach it without a modeset"

# --- VERIFY reads the listing back, and an `off` output at a lit rung is drift
: > "$CALLS"
_stub_wlopm "DP-1 on
DP-2 off"
if _run lock verify; then
  fail "dpms verify passed with an output 'off' at a lit rung; that is exactly
the drift this tier exists to report"
fi
[ ! -s "$CALLS" ] || fail "dpms verify WROTE to the compositor; a verify must
change nothing, it only reads"

# ...and agrees when every output is on.
_stub_wlopm "DP-1 on
DP-2 on"
_run lock verify || fail "dpms verify failed with all outputs on"

# --- NO REACHABLE COMPOSITOR IS n/a, NOT FAILURE ---------------------------
# These hooks also run in MACHINE scope, where the greeter's session may not be
# ours to talk to. A hook that failed there would alert on every greeter edge,
# which is how a supervisor teaches its human to ignore it.
mkdir -p "$T/stub"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/wlopm"
chmod +x "$T/stub/wlopm"
_run wake || fail "dpms treated an unreachable compositor as a FAILURE; a
device that will not answer is absent, not drift"

# An empty listing is the same case: talking to something that reports no
# outputs is not a compositor we can act on.
printf '#!/bin/sh\n[ $# -eq 0 ] && exit 0\nexit 0\n' > "$T/stub/wlopm"
chmod +x "$T/stub/wlopm"
_run wake || fail "dpms failed on an empty output listing"

# --- wlopm ABSENT entirely degrades gracefully -----------------------------
# wlopm lives in /usr/bin next to coreutils here, so "absent" cannot be arranged
# by trimming PATH: doing that removes readlink and dirname too, and the hook
# fails in its own preamble rather than on the thing under test. (It did exactly
# that on the first run of this file.) So build a PATH holding precisely the
# tools the hook needs and nothing else.
mkdir -p "$T/nowlopm"
for _t in readlink dirname awk cat rm; do
  _p=$(command -v "$_t") || fail "the test host lacks $_t"
  ln -sf "$_p" "$T/nowlopm/$_t"
done
[ ! -e "$T/nowlopm/wlopm" ] || fail "the no-wlopm PATH still has wlopm"
VIGILANCE_EDGE=wake VIGILANCE_KIND=act VIGILANCE_INTENT=lit \
  PATH="$T/nowlopm" "$DPMS" wake 2>>"$T/stderr" \
  || fail "dpms failed when wlopm was not installed at all; every shipped plugin
is declared to degrade gracefully when its tool is absent"

pass
