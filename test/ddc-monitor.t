#!/bin/sh
# test/ddc-monitor.t - the power-down value is the MONITOR'S to declare.
#
# WHAT THIS FOUND, on manifestor, which runs an HP E243 beside a Dell AW2725Q
# QD-OLED:
#
#   HP E243      VCP D6: 01 02 03 04 05
#   Dell AW2725Q VCP D6: 01 04 05          <-- no 02
#
# The hook hardcoded `dark) _d6=02`. MCCS defines 02 as standby, and a monitor
# advertises which codes it actually implements -- but writing one it does not
# is NOT an error it reports back. `setvcp --noverify` sends the byte and
# returns 0, so the OLED stayed lit while the edge recorded a clean crossing and
# every tier agreed everything was fine.
#
# That is asserted-versus-actual drift living in the ACTUATOR rather than the
# record, and on the one panel where powering down actually matters: an OLED is
# the display with the burn-in cost.
#
# ddcutil is STUBBED, which the suite permits for an actuator: it is the only
# way to assert which code was written to which bus, and what was NOT written.
# Nothing here stands in for system state.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init ddc-monitor

HOOK=$HERE/libexec/vigilance/hooks/ddc-monitor
mkdir -p "$T/bin" "$T/state"

# Each bus declares its own D6 values through DDC_CAPS_<bus>, so one fixture
# models a machine with genuinely different monitors -- which is the case the
# hardcoded constant could never get right.
cat > "$T/bin/ddcutil" <<'EOF'
#!/bin/sh
_bus=
_prev=
for _a in "$@"; do
  if [ "$_prev" = --bus ]; then _bus=$_a; fi
  _prev=$_a
done
case "$*" in
  *detect*)
    for _b in $DDC_BUSES; do
      printf 'Display %s\n   I2C bus:  /dev/i2c-%s\n' "$_b" "$_b"
    done
    exit 0 ;;
  *capabilities*)
    eval "_caps=\${DDC_CAPS_$_bus:-}"
    echo "   Feature: D6 (Power mode)"
    echo "      Values:"
    for _v in $_caps; do echo "         $_v: whatever"; done
    echo "   Feature: DF (VCP Version)"
    exit 0 ;;
  *getvcp*)
    eval "_cur=\${DDC_STATE_$_bus:-01}"
    echo "VCP code 0xd6 (Power mode): DPM: x (sl=0x$_cur)"
    exit 0 ;;
  *setvcp*)
    printf '%s %s\n' "$_bus" "$(printf '%s' "$*" | awk '{print $NF}')" \
      >> "$DDC_WRITES"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/ddcutil"
PATH="$T/bin:$PATH"; export PATH
DDC_WRITES=$T/writes; export DDC_WRITES
VIGILANCE_STATE_DIR=$T/state; export VIGILANCE_STATE_DIR

_act() {   # <edge>
  : > "$DDC_WRITES"
  VIGILANCE_EDGE="$1" VIGILANCE_KIND=act sh "$HOOK" "$1" 2>>"$T/stderr"
}
_verify() {   # <edge>
  VIGILANCE_EDGE="$1" VIGILANCE_KIND=verify sh "$HOOK" "$1" 2>>"$T/stderr"
}
_wrote() {   # <bus> -> the value written to that bus, or empty
  awk -v b="$1" '$1 == b { print $2 }' "$DDC_WRITES"
}

# --- 1. TWO DIFFERENT MONITORS, each told what it understands ---------------
# Exactly manifestor: one panel that implements standby and one that does not.
# A single constant cannot be right for both, which is the whole finding.
export DDC_BUSES="4 5"
export DDC_CAPS_4="01 02 03 04 05"      # HP E243
export DDC_CAPS_5="01 04 05"            # Dell AW2725Q, no 02
_act sleep || fail "the hook failed against two healthy monitors"

[ "$(_wrote 4)" = 02 ] || fail "bus 4 advertises standby (02) and got
'$(_wrote 4)'. Standby is preferred when offered: it keeps the scaler warm and
wakes fastest"
[ "$(_wrote 5)" = 04 ] || fail "bus 5 does NOT advertise 02 and was written
'$(_wrote 5)'. This is the live bug: writing an unimplemented code is not an
error the monitor reports -- setvcp --noverify returns 0 -- so the OLED stayed
lit while the edge logged a clean crossing"

# --- 2. the ASCENT is 01 everywhere, which every monitor implements ---------
_act wake || fail "the hook failed bringing the monitors back"
[ "$(_wrote 4)" = 01 ] || fail "bus 4 was not restored with 01"
[ "$(_wrote 5)" = 01 ] || fail "bus 5 was not restored with 01"

# --- 3. VERIFY expects what was WRITTEN, not a constant --------------------
# The two tiers must agree by construction. If verify kept its own idea of the
# dark value it would report drift on bus 5 forever, on a monitor that did
# exactly as it was told -- and a verifier that cries wolf is one you stop
# reading.
export DDC_STATE_4=02 DDC_STATE_5=04
_verify sleep || fail "verify reported drift on monitors sitting in precisely
the state the act tier put them in. verify must resolve the expected value the
same way act did, per bus"

# ...and it still catches a monitor that did NOT obey.
export DDC_STATE_5=01
_verify sleep && fail "verify passed a monitor still powered ON at the sleep
rung. Loosening the comparison to make case 3 pass would blind the one check
that proved a monitor had been dark for two days" || :
export DDC_STATE_5=04

# --- 4. a WRITE-ONLY code cannot be read back, and that is not drift -------
# MCCS marks 05 write-only. A monitor offering only 01 and 05 does as it is
# told and can never confirm it, so reporting drift there would fail every
# verify forever on a panel behaving correctly.
export DDC_BUSES="6"
export DDC_CAPS_6="01 05"
_act sleep || fail "the hook failed on a monitor offering only 01 and 05"
[ "$(_wrote 6)" = 05 ] || fail "a monitor offering only 01 and 05 was written
'$(_wrote 6)'; 05 is the only off code it has"
_verify sleep || fail "verify reported drift for a write-only D6 value. It
cannot be read back by definition, so this fails every verify on a monitor that
is doing exactly as instructed"

# --- 5. a monitor with NO off value is LEFT ALONE -------------------------
# Guessing a code at a panel that advertises none is how the original bug
# worked. Better to do nothing and say so.
export DDC_BUSES="7"
export DDC_CAPS_7="01"
_act sleep || fail "the hook failed on a monitor that advertises no off value"
[ -z "$(_wrote 7)" ] || fail "a monitor advertising NO off code was written
'$(_wrote 7)'. Guessing a code the panel never claimed is exactly the bug this
fixes, and --noverify means nothing would report it"

# --- 6. one unusable monitor must not stop the others --------------------
# The peripherals rule: a monitor that will not sleep must not keep the rest of
# the edge from running.
export DDC_BUSES="4 7"
export DDC_CAPS_4="01 02 03 04 05"
_act sleep || fail "one monitor with no off value failed the whole edge"
[ "$(_wrote 4)" = 02 ] || fail "a usable monitor was skipped because another
one on the same edge had nothing to write"

pass
