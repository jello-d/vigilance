#!/bin/sh
# test/not-applicable.t - "I couldn't look" is not "I looked and it's fine".
#
# THE SHAPE BEHIND ALMOST EVERY DEFECT THIS SUITE HAS FOUND. Exit 0 used to mean
# both "I did the work" and "not applicable here", so nothing downstream could
# tell them apart.
#
# Measured on a real desktop: its monitor advertises no DPMS standby and it has
# no sysfs backlight, so BOTH screen checkers on the `sleep` edge quietly
# declined -- ddc-monitor because the panel offers no off code, panel-backlight
# because there is no such device. `verify sleep` reported OK. The screen was
# verified by nothing, and the tier whose entire job is to catch that reported
# green while a lit wallpaper sat on an OLED.
#
# So a hook may now exit 78 for NOT APPLICABLE. The runner counts those apart
# from success and failure, and an edge where EVERY hook declined is reported as
# having no verdict rather than a good one.
#
# BACKWARD COMPATIBLE BY CONSTRUCTION: a hook that never uses 78 exits 0 and is
# counted as having CHECKED, exactly as before. The signal only adds
# information; it cannot turn a working integration into a failing one.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init not-applicable

_mk() {   # <dir> <name> <exit>
  mkdir -p "$VIGILANCE_HOOK_ROOT/$1"
  printf '#!/bin/sh\nexit %s\n' "$3" > "$VIGILANCE_HOOK_ROOT/$1/$2"
  chmod +x "$VIGILANCE_HOOK_ROOT/$1/$2"
}
_vrc() {   # <edge> -> exit code of verify
  _r=0; "$VIGILANT" verify "$1" >/dev/null 2>>"$T/stderr" || _r=$?
  printf '%s' "$_r"
}
_vout() { "$VIGILANT" verify "$1" 2>>"$T/stderr" || true; }

go lock

# --- 1. a mix: the n/a ones are NAMED, the verdict still stands -------------
# The point is not to fail here -- something WAS checked. It is that a reader
# can see at a glance which questions went unanswered.
_mk lock.verify.d 10-real 0
_mk lock.verify.d 20-declines 78
[ "$(_vrc lock)" = 0 ] || fail "a verify with one real check and one n/a was
reported as a failure; something WAS confirmed"
case "$(_vout lock)" in
  *"1 checked"*"1 n/a"*"20-declines"*) ;;
  *) printf '%s\n' "$(_vout lock)" >&2
     fail "the n/a hook was not named in the verdict. 'ok' on its own reads the
same whether every hook confirmed or every hook declined, which is the entire
distinction this contract exists to draw" ;;
esac

# --- 2. EVERY hook declining is NOT a pass ---------------------------------
# The live failure, reduced. This must not read as success, and it must not
# read as drift either: there is no verdict at all.
rm -f "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-real"
[ "$(_vrc lock)" != 0 ] || fail "every verify hook declined and the edge still
reported success. That is the exact state a desktop with no DPMS standby and no
sysfs backlight was in while its screen burned: nothing checked, everything
green"
case "$(_vout lock)" in
  *"NOTHING CHECKED"*) ;;
  *) printf '%s\n' "$(_vout lock)" >&2
     fail "an edge where nothing could be checked did not say so. A reader
needs to know the difference between a confirmed machine and an unexamined
one" ;;
esac

# --- 3. and REPORT carries it as a FAIL, not as drift ----------------------
# Different findings need different words: 'drift' means we looked and the
# machine was wrong. Here we never looked.
_out=$("$VIGILANT" report 2>>"$T/stderr") || true
case "$_out" in
  *"[FAIL]"*"NOTHING CHECKED"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "report did not carry an unverifiable edge as a FAIL" ;;
esac
case "$_out" in
  *"reports drift"*"NOTHING CHECKED"*)
     fail "report called it DRIFT. Drift means we looked and the machine was
wrong; this is the absence of a verdict, and mislabelling it sends the reader
looking for a hardware fault that may not exist" ;;
esac

# --- 4. BACKWARD COMPATIBILITY: a plain exit 0 still counts as checked ------
# Every third-party hook in existence predates this contract. If they stopped
# counting, the check would fire on healthy integrations everywhere and be
# switched off within a day.
rm -f "$VIGILANCE_HOOK_ROOT/lock.verify.d/20-declines"
_mk lock.verify.d 10-legacy 0
[ "$(_vrc lock)" = 0 ] || fail "a hook that exits 0 without knowing about the
n/a contract was not counted as having checked. Every pre-existing hook does
that, so this would fire on healthy integrations everywhere"
case "$(_vout lock)" in
  *"1 checked"*) ;;
  *) fail "a legacy hook was not counted" ;;
esac

# --- 5. n/a is NOT a failure, and raises no alert --------------------------
# A declining hook is doing the right thing. If it alerted, a desktop without a
# panel backlight would toast its owner on every single edge.
: > "$T/alerts"
mkdir -p "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-sink" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/alerts"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-sink"
rm -f "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-legacy"
_mk lock.verify.d 20-declines 78
_vrc lock >/dev/null
[ ! -s "$T/alerts" ] || fail "a hook declining raised an ALERT. It is doing the
right thing: a desktop with no panel backlight would toast its owner on every
edge, and that is how people learn to ignore alerts"

# --- 6. the ACT tier treats n/a as success, not failure --------------------
# Actuators decline too (no such device). An n/a there must not degrade the
# crossing: the edge did everything that could be done.
_mk sleep.d 10-declines 78
go open
"$VIGILANT" go sleep >/dev/null 2>>"$T/stderr" \
  || fail "an actuator declining made the whole crossing report degraded. The
edge did everything that could be done; a device that is not present is not a
failure to act"

pass
