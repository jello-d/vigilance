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
# ...and bus 5 is LEFT ALONE. It offers no shallow standby, only deeper off
# states, and none of those promises the monitor is still listening to I2C
# afterwards. This exact panel proved it: driven off, it stopped answering DDC
# and needed a power cycle. The absence of 02 IS the signal.
[ -z "$(_wrote 5)" ] || fail "bus 5 offers no DPMS standby (02) and was written
'$(_wrote 5)' anyway. Deeper D6 codes carry no guaranteed DDC wake channel, and
this is the panel that proved it -- it stopped answering DDC entirely and needed
a power cycle at the monitor. Nothing may be put into a dark state unless its
way back is armed"

# The skip must be EXPLAINED, or an operator sees one monitor sleeping and the
# other not, with nothing saying why.
: > "$DDC_WRITES"
VIGILANCE_EDGE=sleep VIGILANCE_KIND=act sh "$HOOK" sleep 2>"$T/err" || :
grep -q "bus 5" "$T/err" || fail "the skipped monitor was not named"
grep -q "STANDBY" "$T/err" || fail "the reason for skipping was not given, so
the operator cannot tell a deliberate policy from a broken monitor"
grep -q "VIGILANCE_DDC_DEEP_OFF" "$T/err" || fail "the escape hatch was not
named, so an operator who HAS verified their panel has no way to find it"

# --- 1b. the DEEP-OFF opt-in, for hardware the operator has verified -------
# The default is conservative because being wrong costs a walk to the power
# button. An operator who has checked their own panel can still have it.
: > "$DDC_WRITES"
VIGILANCE_DDC_DEEP_OFF=1 VIGILANCE_EDGE=sleep VIGILANCE_KIND=act \
  sh "$HOOK" sleep 2>>"$T/stderr" \
  || fail "the deep-off opt-in errored"
[ "$(_wrote 5)" = 04 ] || fail "with VIGILANCE_DDC_DEEP_OFF=1 the monitor was
still not powered down; the opt-in does nothing and the operator has no way to
use hardware they have verified"
[ "$(_wrote 4)" = 02 ] || fail "the opt-in changed the value for a monitor that
DOES offer standby. 02 is preferred whenever it exists: it is the only state
with a guaranteed wake channel, so the opt-in must only affect panels without
one"

# --- 2. the ASCENT is 01 everywhere, which every monitor implements ---------
_act wake || fail "the hook failed bringing the monitors back"
[ "$(_wrote 4)" = 01 ] || fail "bus 4 was not restored with 01"
[ "$(_wrote 5)" = 01 ] || fail "bus 5 was not restored with 01"

# --- 3. VERIFY expects what was WRITTEN, not a constant --------------------
# The two tiers must agree by construction. If verify kept its own idea of the
# dark value it would report drift on bus 5 forever, on a monitor that did
# exactly as it was told -- and a verifier that cries wolf is one you stop
# reading.
export DDC_STATE_4=02 DDC_STATE_5=01
_verify sleep || fail "verify reported drift on monitors sitting in precisely
the state the act tier put them in. Bus 4 was told 02 and is at 02; bus 5 was
deliberately NOT powered down, so it being ON is correct, not drift"

# ...and it still catches a monitor that WAS driven and did NOT obey. Asserted
# on bus 4, the one actually driven: bus 5 is skipped by policy now, so a
# disobedient-monitor case there would be testing nothing.
export DDC_STATE_4=01
_verify sleep && fail "verify passed a monitor that was commanded to standby
and is still powered ON. Loosening the comparison to make the case above pass
would blind the one check that proved a monitor had been dark for two days" || :
export DDC_STATE_4=02

# --- 4. a WRITE-ONLY code cannot be read back, and that is not drift -------
# MCCS marks 05 write-only. A monitor offering only 01 and 05 does as it is
# told and can never confirm it, so reporting drift there would fail every
# verify forever on a panel behaving correctly.
export DDC_BUSES="6"
export DDC_CAPS_6="01 05"

# By DEFAULT such a panel is left alone: 05 is "turn off display", the deepest
# state of all, with no promise it is still listening afterwards.
_act sleep || fail "the hook failed on a monitor offering only 01 and 05"
[ -z "$(_wrote 6)" ] || fail "a monitor whose only off code is the write-only
05 was powered down by default. That is the deepest state in the table and the
least likely to leave a wake channel"

# The write-only case is only reachable through the opt-in, and THERE it must
# not be reported as drift: 05 cannot be read back by definition, so failing on
# it would fail every verify on a panel doing exactly as instructed.
: > "$DDC_WRITES"
VIGILANCE_DDC_DEEP_OFF=1 VIGILANCE_EDGE=sleep VIGILANCE_KIND=act \
  sh "$HOOK" sleep 2>>"$T/stderr" || fail "deep-off opt-in errored on a 01/05
monitor"
[ "$(_wrote 6)" = 05 ] || fail "with the opt-in set, a monitor offering only 01
and 05 was written '$(_wrote 6)'; 05 is the only off code it has"
VIGILANCE_DDC_DEEP_OFF=1 _verify sleep || fail "verify reported drift for a
write-only D6 value. It cannot be read back by definition, so this fails every
verify on a monitor that is doing exactly as instructed"

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

# --- 7. THE LIVE FAILURE: a monitor driven dark that DROPS OFF DDC ----------
# Observed on manifestor. The Dell was commanded into a power state it does not
# implement, stopped answering DDC, and `ddcutil detect` reclassified it from
# "Display N" to "Invalid display". The map EXCLUDES invalid displays -- that
# exclusion exists so a non-DDC eDP panel is not driven -- so the dark monitor
# DROPPED OUT OF THE MAP entirely.
#
# Everything downstream then agreed the machine was healthy: the ascent never
# sent it 01, verify never checked it, and the hook returned 0 because the one
# monitor it could still see was fine. One panel dark, nothing to bring it back,
# and every tier green. That is the exact failure this suite exists to catch,
# arriving through the one code path built to ignore a display.
#
# A vanished monitor is indistinguishable from one that was never there, UNLESS
# we wrote down that we put it to sleep. So the dark intent records it.
# Bus 5 advertises 02 HERE, so it is actually driven. A panel that offers no
# standby is now left alone entirely and could never reach this state -- which
# is the point of the policy above. The risk that remains is a monitor that DOES
# offer standby and still drops off DDC, and that is what this covers.
rm -f "$T/state/dark-buses"
export DDC_BUSES="4 5"
export DDC_CAPS_4="01 02 03 04 05"
export DDC_CAPS_5="01 02 04 05"
_act sleep || fail "setup: the dark edge failed"
[ -f "$T/state/dark-buses" ] || fail "the dark edge did not record which buses
it drove dark. Without that record a monitor that later vanishes cannot be told
from one that was never present"

# The Dell stops answering, so detect files it under "Invalid display" and the
# map no longer contains it -- exactly what happened live.
export DDC_BUSES="4"
_act wake && fail "a monitor driven DARK vanished from the map and the ascent
reported SUCCESS. That is one panel dark with nothing to bring it back, and
every tier green -- the failure this whole project exists to prevent" || :

# ...and it must say which bus, and that DDC cannot fix it. A reader who is
# told only "something failed" still has to find the dark monitor themselves.
# Called directly, not through _act: that helper redirects stderr into the
# run-wide capture, so a `2>` on the call itself never sees the hook's output.
: > "$DDC_WRITES"
VIGILANCE_EDGE=wake VIGILANCE_KIND=act sh "$HOOK" wake 2>"$T/err" || :
grep -q "bus 5" "$T/err" || fail "the vanished monitor was not named. A reader
told only that something failed still has to find the dark panel themselves"
grep -q "power cycle" "$T/err" || fail "the report did not say that DDC cannot
recover it. Without that the operator retries the thing that cannot work"

# --- 8. ...and the record CLEARS once the monitor is back ------------------
# Otherwise the warning is permanent and becomes the line nobody reads.
export DDC_BUSES="4 5"
export DDC_CAPS_5="01 02 04 05"
_act wake || fail "a monitor that came back was still reported as vanished"
[ ! -f "$T/state/dark-buses" ] || fail "the dark record survived a successful
ascent, so the next one would re-report a monitor that is demonstrably fine"

# --- 9. SILENCE means opposite things at the two ends of the ladder --------
# At a DARK rung a monitor that will not answer is COMPLYING: several power
# states take the scaler down with the panel. At a LIT rung the same silence is
# a panel that was told to come on and did not. Treating them alike is what let
# an evening pass with one screen dark.
export DDC_BUSES="4"
export DDC_CAPS_4="01 02 03 04 05"
unset DDC_STATE_4
DDC_NOANSWER=1
_act sleep >/dev/null 2>&1 || :

# A dark rung, monitor silent: expected, not drift.
cat > "$T/bin/ddcutil" <<'STUB'
#!/bin/sh
_bus=; _prev=
for _a in "$@"; do
  if [ "$_prev" = --bus ]; then _bus=$_a; fi
  _prev=$_a
done
case "$*" in
  *detect*) for _b in $DDC_BUSES; do
              printf 'Display %s\n   I2C bus:  /dev/i2c-%s\n' "$_b" "$_b"
            done; exit 0 ;;
  *capabilities*) eval "_c=\${DDC_CAPS_$_bus:-}"
            echo "   Feature: D6 (Power mode)"; echo "      Values:"
            for _v in $_c; do echo "         $_v: x"; done
            echo "   Feature: DF (VCP Version)"; exit 0 ;;
  *getvcp*) exit 1 ;;                      # silent monitor
  *setvcp*)
    # RECORDS THE WRITE, like the main stub. Omitting it here made every
    # _wrote check after this point read empty, so a later section reported
    # "the monitor was never driven" about a stub that simply was not
    # listening. A replacement fixture has to keep the observations the
    # original one made.
    printf '%s %s\n' "$_bus" "$(printf '%s' "$*" | awk '{print $NF}')" \
      >> "$DDC_WRITES"
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/ddcutil"
rm -f "$T/state/dark-buses"
_verify sleep || fail "a monitor silent at a DARK rung was reported as drift.
Several power states take the scaler down with the panel, so silence there is
compliance; failing on it cries wolf about a display doing as it was told"

_verify wake && fail "a monitor silent at a LIT rung was accepted. It was just
commanded ON and will not speak, which is the precise shape of a panel that is
dark with no way back" || :

# --- 10. AN UNWRITABLE STATE DIR MUST NOT SUPPRESS THE ACTUATOR ------------
# Found by running the hook for real with a state dir that could not be created.
# This hook runs under `set -eu`, and the dark-record writes sit BEFORE the
# loop, so the failed redirect aborted it outright: NEITHER monitor was driven,
# and the edge simply looked like it had not worked.
#
# That is the bug _set_depth in bin/vigilant carries a comment about, one layer
# out -- a failure to WRITE A FILE must never suppress the thing the edge exists
# to do. A wrong record is a reporting problem; a monitor that never got its
# command is the job not happening.
export DDC_BUSES="4"
export DDC_CAPS_4="01 02 03 04 05"
VIGILANCE_STATE_DIR=$T/state/nonexistent/deeper/still
export VIGILANCE_STATE_DIR
# A FILE where the state dir's parent must be, so mkdir -p genuinely cannot
# succeed. Without this the sandbox would happily create the tree and the case
# would test nothing.
mkdir -p "$T/blocked"
: > "$T/blocked/parent"
VIGILANCE_STATE_DIR=$T/blocked/parent/state
export VIGILANCE_STATE_DIR

: > "$DDC_WRITES"
VIGILANCE_EDGE=sleep VIGILANCE_KIND=act sh "$HOOK" sleep 2>"$T/err" || _rc10=$?
[ "$(_wrote 4)" = 02 ] || fail "an unwritable state dir stopped the monitor from
being driven at all. Bookkeeping must never suppress the actuator: a wrong
record is a reporting problem, a monitor that never got its command is the edge
not happening"

# ...and the blind watchdog is REPORTED, not swallowed. Without the record, a
# monitor that goes dark and drops off DDC cannot be noticed on the way back --
# the check silently gone, which is this project's signature failure.
grep -q "cannot write" "$T/err" || fail "the hook could not keep its dark
record and said nothing. The vanished-monitor check is then blind, and nothing
anywhere says so"
[ "${_rc10:-0}" != 0 ] || fail "the hook returned SUCCESS while unable to keep
the record its own safety check depends on. stderr goes nowhere under a
keybind, so the exit status is the only thing that carries this"

VIGILANCE_STATE_DIR=$T/state; export VIGILANCE_STATE_DIR

pass
