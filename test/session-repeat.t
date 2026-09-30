#!/bin/sh
# test/session-repeat.t - every acting hook must survive being run twice.
#
# THE GAP THIS CLOSES, quoting THEORY.md's own shortfall list: "A hook must
# survive being run twice in sequence. The crossing lock serialises concurrent
# requests; it does nothing about a second press five seconds later... every
# actuator that keeps a LEVEL is now covered. A hook with no level to restore is
# still discipline only."
#
# THIS IS THAT POPULATION. `sway-dpms` and `x11-dpms` keep no save file, so
# level-rules.t cannot reach them, and the historical bug shape is exactly what
# they are exposed to: hook_dark returned 0 outright when its save file existed,
# so every later descent was a SILENT NO-OP THAT REPORTED SUCCESS, and the same
# defect shipped a second time in ddc-monitor's hand-written copy. Twice, in the
# hooks that did have a level. Nothing had ever asked the ones that do not.
#
# WHY A GENERIC RATCHET WAS REJECTED, and why this is not that. In a sandbox
# most hooks correctly decline with 78, so "run them all twice" passes over an
# empty set and reads as coverage it does not have. Two things fix it here: the
# session tier has REAL devices, so a decline means something is genuinely
# absent rather than stubbed; and this file carries a DENOMINATOR, refusing to
# pass if nothing actually acted. A vacuous run is a failure, not a green line.
#
# THE DISTURBANCE IS THE HOOK'S OWN VOCABULARY, which is what makes it generic:
#
#     act dark -> act lit -> act dark AGAIN -> is it really dark?
#
# No per-hook knowledge of how to break a device is needed, because the ascent
# already puts it in the wrong state for the second descent. A hook that
# short-circuits on its own state no-ops that second descent, returns 0, and is
# caught by the readback.
#
# AND THE READBACK IS INDEPENDENT of the hook, per row, because a hook that both
# acts and reports on itself can be wrong and agree with itself. The hook's own
# verify is asserted too, but after the independent answer, so a disagreement
# between them is attributable.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init session-repeat
require compositor

PLUG=$PLUGINS/hooks
STATE=$T/state
mkdir -p "$STATE"
# The verify tier must answer for real on every call here, or the second and
# third readings would be a throttle's "not due" rather than an observation.
VIGILANCE_PERIPHERAL_EVERY=0; export VIGILANCE_PERIPHERAL_EVERY

_cleanup() {
  swaymsg "output * dpms on" >/dev/null 2>&1 || true
  DISPLAY=:98 xset +dpms >/dev/null 2>&1 || true
  DISPLAY=:98 xset dpms force on >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

_sway_read() {
  swaymsg -t get_outputs 2>/dev/null | tr ',' '\n' \
    | awk '/"dpms"/ { print ($0 ~ /true/) ? "on" : "off"; exit }'
}
_x11_read() {
  case "$(DISPLAY=:98 xset q 2>/dev/null \
          | sed -n 's/.*Monitor is *//p' | head -1)" in
    On) echo on ;;
    Off|Standby|Suspend) echo off ;;
    *) echo unknown ;;
  esac
}

# ONE ROW PER HOOK, so adding one is a line rather than a case. Each names its
# dark edge, its lit edge, the capability it needs, the reader that answers
# independently, and any environment the hook needs to reach its device.
_rows='sway-dpms sleep wake compositor _sway_read
x11-dpms sleep wake x11dpms _x11_read'

# CREATED UP FRONT. The loop writes its tally through files because it runs in a
# pipeline subshell, and a run where every row skips would otherwise leave these
# missing: `awk` exits non-zero on a file that is not there, and an empty count
# compared against 0 fails about nothing at all.
: > "$T/tally"
: > "$T/counts"

_run() {   # <hook> <edge> <kind> -> rc, output in $T/out
  _r_rc=0
  env VIGILANCE_STATE_DIR="$STATE/$1" VIGILANCE_KIND="$3" DISPLAY="${DISP:-}" \
    sh "$PLUG/$1" "$2" >"$T/out" 2>&1 || _r_rc=$?
  return "$_r_rc"
}

echo "$_rows" | while IFS=' ' read -r _hook _dark _lit _cap _reader; do
  [ -n "$_hook" ] || continue
  case " $SCENARIO_CAPS " in
    *" $_cap "*) ;;
    *) echo "  $_hook: SKIP (no $_cap capability here)" >> "$T/tally"
       printf 'skipped\n' >> "$T/counts"; continue ;;
  esac
  # The X11 hooks need a DISPLAY; the Wayland ones must NOT see one, or xset
  # would answer for a server that is not the device under test.
  DISP=
  if [ "$_cap" = x11dpms ]; then DISP=:98; fi
  export DISP
  mkdir -p "$STATE/$_hook"

  # --- the first descent, which is what every other test already covers -----
  _rc=0; _run "$_hook" "$_dark" act || _rc=$?
  if [ "$_rc" = 78 ]; then
    echo "  $_hook: DECLINED 78 (nothing here to drive)" >> "$T/tally"
    printf 'declined\n' >> "$T/counts"; continue
  fi
  [ "$_rc" = 0 ] || { echo "FAILROW $_hook first descent rc=$_rc: $(cat \
    "$T/out")" >> "$T/tally"; printf 'failed\n' >> "$T/counts"; continue; }
  [ "$($_reader)" = off ] || { echo "FAILROW $_hook did not darken its device \
on the FIRST descent, so nothing below is about repetition" >> "$T/tally"
    printf 'failed\n' >> "$T/counts"; continue; }

  # --- the ascent, which is the disturbance ---------------------------------
  _rc=0; _run "$_hook" "$_lit" act || _rc=$?
  [ "$_rc" = 0 ] || { echo "FAILROW $_hook ascent rc=$_rc: $(cat "$T/out")" \
    >> "$T/tally"; printf 'failed\n' >> "$T/counts"; continue; }
  [ "$($_reader)" = on ] || { echo "FAILROW $_hook did not relight its device, \
so the second descent has nothing to re-assert" >> "$T/tally"
    printf 'failed\n' >> "$T/counts"; continue; }

  # --- THE SECOND DESCENT, which is the whole point -------------------------
  _rc=0; _run "$_hook" "$_dark" act || _rc=$?
  [ "$_rc" = 0 ] || { echo "FAILROW $_hook SECOND descent rc=$_rc: $(cat \
    "$T/out")" >> "$T/tally"; printf 'failed\n' >> "$T/counts"; continue; }
  if [ "$($_reader)" != off ]; then
    echo "FAILROW $_hook returned 0 on its SECOND descent and the device is \
still lit. That is a silent no-op reporting success, the exact defect that \
shipped twice in the hooks that DO keep a level" >> "$T/tally"
    printf 'failed\n' >> "$T/counts"; continue
  fi
  # ...and the hook's own verify agrees with the independent reader. Asserted
  # second, so a disagreement is attributable to the verify rather than mixed up
  # with the act.
  _rc=0; _run "$_hook" "$_dark" verify || _rc=$?
  [ "$_rc" = 0 ] || { echo "FAILROW $_hook verify rc=$_rc after a second \
descent the device obeyed: $(cat "$T/out")" >> "$T/tally"
    printf 'failed\n' >> "$T/counts"; continue; }

  echo "  $_hook: acted twice, device obeyed both times" >> "$T/tally"
  printf 'acted\n' >> "$T/counts"
done

# A SUBSHELL CANNOT RETURN A COUNT. The loop body runs in a pipeline, so every
# variable it set is gone by here: the tally goes through FILES, which is the
# same subshell trap that once defeated a timeout bound in the runner itself.
_tally() { cat "$T/tally" 2>/dev/null || true; }
_count() { awk -v k="$1" '$0 == k { n++ } END { print n + 0 }' "$T/counts"; }
_acted=$(_count acted)
_declined=$(_count declined)
_skipped=$(_count skipped)
_failed=$(_count failed)

[ "$_failed" = 0 ] || fail "a hook did not survive being run twice:
$(_tally)"

# THE DENOMINATOR, and the reason this file is not the vacuous ratchet that was
# rejected. If every row declined or skipped, the run proved nothing and must
# say so rather than printing a green line.
[ "$_acted" -ge 1 ] || fail "NOTHING ACTED. $_declined declined, $_skipped
skipped, so this scenario verified repeat-safety for no hook at all. That is the
vacuous pass a generic every-hook ratchet was rejected for, and a green line
here would be the same claim without the evidence:
$(_tally)"

pass "repeat-safe: $_acted acted, $_declined declined, $_skipped skipped"
