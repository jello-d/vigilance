#!/bin/sh
# test/fault-actuator.t - something ELSE drives the device vigilance darkened.
#
# THE FAULT CLASS THIS SUITE HAS ALREADY PAID FOR, and the bill was twelve
# hours: `mute-leds` darkened an LED at the `sleep` rung while `mute-on-lock`
# muted audio at `lock`, the audio driver relit that LED because the LED IS the
# mute state, and vigilance raised 278 drift alerts across one twelve-hour sleep
# about a fight it could not win. Nothing has ever held that shape down.
#
# TWO ACTUATORS, ONE DEVICE, and the second one is REAL here: a process issuing
# `swaymsg output * dpms on` against the same compositor `sway-dpms` drives. No
# device, process, filesystem or clock is faked, which is the rule this tier
# lives by. It is not xfce4-power-manager, and the reason is measured rather
# than chosen: the guest's X servers have no DPMS extension at all (Xvfb and
# Xephyr both answer "Server does not have the DPMS Extension", and `xset s` is
# silently ignored with the timeout pinned at 600), so an X-side power manager
# would install a real actuator with no device to contend for and every
# assertion below would pass vacuously. The contended device has to be one the
# substrate actually has.
#
# WHAT MUST BE TRUE, and each half is a separate way to fail:
#
#   ACT      the edge still crosses. A fight must never suppress the thing the
#            edge exists to do.
#   ALERT    verify must NOTICE. Reporting clean while the screen is lit at a
#            dark rung is this project's signature false green.
#   bounded  one unchanging fight is ONE finding, however often it is observed,
#            while the LOG keeps every occurrence. This is the half the
#            mute-leds episode actually cost.
#   RECOVER  when the other actuator stops, the next pass goes clean. A fight
#            must not leave a marker that outlives it.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-actuator

require compositor
command -v swaymsg >/dev/null 2>&1 \
  || fail "no swaymsg despite the compositor capability; there is no contended
device here and nothing below would be a measurement"
swaymsg -t get_version >/dev/null 2>&1 \
  || fail "swaymsg cannot reach sway (SWAYSOCK=${SWAYSOCK:-<unset>}). sway-dpms
declines 78 in that case, so the fight would be between a stub and nothing"

MACHINE=/etc/vigilance/hooks
_restore=
_rival=

# THE RIVAL IS STOPPED FIRST in the trap, before anything reads the device or
# unwinds the wiring: a surviving loop would keep driving the compositor for
# every later scenario in this boot, which is the same reason the greeter
# scenario removes its machine-scope wires.
_cleanup() {
  [ -z "$_rival" ] || kill "$_rival" 2>/dev/null || true
  for _p in $_restore; do rm -f "$_p" 2>/dev/null || true; done
  swaymsg "output * dpms on" >/dev/null 2>&1 || true
  session_done
  rm -rf "$T"
}
trap '_cleanup' EXIT INT TERM HUP

_mwire() {   # <edge> <tier> <hook> <order>
  _md=$MACHINE/$1$2.d
  mkdir -p "$_md"
  [ -f "$PLUGINS/hooks/$3" ] || fail "no shipped hook named '$3'"
  ln -sf "$PLUGINS/hooks/$3" "$_md/$4-$3"
  _restore="$_restore $_md/$4-$3"
}
_mwire sleep ''       sway-dpms 05
_mwire sleep .verify  sway-dpms 05
_mwire wake  ''       sway-dpms 05
_mwire wake  .verify  sway-dpms 05

# READ INDEPENDENTLY OF THE HOOK, because a hook that both acts and reports on
# itself can be wrong and agree with itself.
_dpms() {
  swaymsg -t get_outputs 2>/dev/null | tr ',' '\n' \
    | awk '/"dpms"/ { print ($0 ~ /true/) ? "on" : "off"; exit }'
}
# FUNCTIONS, because `await` takes a COMMAND and its arguments rather than a
# string to evaluate: `await 10 '[ "$(_dpms)" = off ]'` looks for a program of
# that name, never finds one, and times out into a failure about the product.
_dark() { [ "$(_dpms)" = off ]; }
_lit()  { [ "$(_dpms)" = on ]; }

_alerts() { grep -c . "$T/alerts" 2>/dev/null || true; }
_drifts() { grep -c '^drift|' "$T/alerts" 2>/dev/null || true; }

_recheck() { "$VIGILANT" enforce >>"$T/enforce.out" 2>&1 || true; }

# THE RIVAL: a real second actuator, re-lighting what vigilance darkened, on its
# own schedule and with no knowledge of the ladder. One second is far tighter
# than the two a mute LED took to bounce back, which makes the fight certain
# rather than likely.
_rival_start() {
  ( while :; do
      swaymsg "output * dpms on" >/dev/null 2>&1 || true
      sleep 1
    done ) &
  _rival=$!
}
_rival_stop() {
  [ -z "$_rival" ] || kill "$_rival" 2>/dev/null || true
  _rival=
  # DRAIN: the loop may be mid-swaymsg, so a readback taken immediately can
  # still catch its last write and the recovery case would fail about a rival
  # that had already been asked to stop.
  sleep 2
}

session_reset
# THE SINK IS CREATED AFTER THE RESET, and that ordering is the whole of it:
# `session_reset` does `rm -rf "$HOOKS"` to give the scenario a clean user tree,
# so a sink written before it is deleted and `_hooks_for alert` then finds
# nothing. The symptom was an alert the LOG recorded and no sink received, which
# reads exactly like a product bug in the alert path.
mkdir -p "$HOOKS/alert.d"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> %s\n' "$T/alerts" \
  > "$HOOKS/alert.d/10-sink"
chmod +x "$HOOKS/alert.d/10-sink"

swaymsg "output * dpms on" >/dev/null 2>&1 || true
[ "$(_dpms)" = on ] || fail "fixture: the output is not on to begin with, so a
later 'off' would prove nothing about the descent"

# --- 1. THE PRECONDITION: vigilance can darken this device UNOPPOSED ---------
# Without this the rest measures a hook that never worked here, which is how a
# fault cell comes to pass for its substrate's reasons.
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" \
  || fail "the descent to sleep failed before any rival existed:
$(tail -3 "$T/stderr" 2>/dev/null)"
[ "$(depth)" = sleep ] || fail "depth is '$(depth)' after go sleep"
await 10 _dark \
  || fail "sway-dpms did not darken the output with nothing opposing it, so this
scenario has no contended device. Read as a verdict about the hook, not the
fight: everything below would pass for the wrong reason"

# ...and the tier agrees, unopposed, AND IT ACTUALLY LOOKED. "No drift" is not
# enough on its own: a hook that declines (78) or defers (75) also says nothing
# about drift, so an assertion that only rules out the drift WORD would pass
# against a tier that never ran. That is the same "I could not look" conflation
# the exit-78 contract exists to break, arriving in a test of it.
: > "$T/alerts"
VIGILANCE_PERIPHERAL_EVERY=0; export VIGILANCE_PERIPHERAL_EVERY
_vrc=0
_vout=$(VIGILANCE_RECHECK=1 "$VIGILANT" verify sleep 2>&1) || _vrc=$?
# RC 0, not merely "no drift in the words". The first version of this case
# accepted any output without "not off" in it, and the hook was dying with
# rc=2 and "want: parameter not set" the whole time: a FAIL whose text happened
# not to contain the phrase being looked for. The failure surfaced two cases
# later, as a missing alert, which is a much worse place to read it from.
[ "$_vrc" = 0 ] || fail "unopposed, with the output verifiably dark, the sleep
verify exited $_vrc. Nothing is fighting yet, so this is the tier failing on its
own account and every later assertion would be about that instead:
$_vout"
case "${_vout:-}" in
  *"1 checked"*|*"2 checked"*|*"3 checked"*) ;;
  *) fail "unopposed, the sleep verify did not CHECK anything. It said:
$_vout
A tier that declined or deferred cannot notice the fight this scenario is about,
so every assertion below would be measuring silence. VIGILANCE_PERIPHERAL_EVERY
is '${VIGILANCE_PERIPHERAL_EVERY:-<unset>}', which is what defeats the hourly
throttle; 78 instead means sway-dpms cannot reach sway from here" ;;
esac

# --- 2. THE FAULT, and the rival must actually WIN --------------------------
# A rival that loses is not a fault. This is the assert-the-precondition rule:
# `chmod a-w` as root injected nothing once, and every assertion after it passed
# for that reason.
_rival_start
await 10 _lit \
  || fail "the rival did not win: the output is still off at the sleep rung, so
no fight is happening and the drift assertions below would be vacuous"

# --- 3. THE TIER NOTICES, and the RECORD is where that is guaranteed --------
# THE LOG, NOT THE SINK, and the distinction is the whole design: "the log is
# never suppressed. Throttling is a courtesy to the human, never a gap in the
# record", because the audit tier reads this file to say how long a fault
# lasted. Asking the SINK whether the tier noticed conflates noticing with
# notifying, and dedup is entitled to swallow the second of those. The first
# version of this case asked the sink and failed with an empty file while
# `enforce` had plainly printed the drift, which is a verdict about dedup
# wearing the costume of a missed fault.
_recheck
said "STILL-DRIFTED at 'sleep'" || fail "the screen is LIT at the sleep rung and
the standing recheck recorded no drift. That is the false green this package
exists to prevent: a per-device verifier satisfied while the rung is a lie.

THE EVIDENCE TRAVELS WITH THE VERDICT, because \$T is removed on the way out.

enforce said: $(tail -5 "$T/enforce.out" 2>/dev/null)
status:       $("$VIGILANT" status 2>&1 | head -2 | tr '\n' ' ')
dpms now:     $(_dpms)
log tail:     $(logsince | tail -4 | tr '\n' ' ')"
logsince | grep -q 'not off' || fail "the drift was recorded but does not name
the device or its state. 'something drifted' sends a reader hunting; sway-dpms
says which output and what it reads. log tail:
$(logsince | tail -4)"

# --- 3b. AND A HUMAN IS ACTUALLY TOLD, at least once -----------------------
# Separated deliberately. With the cooldown at its shipped hour, whether THIS
# pass notifies depends on what else in this boot raised the same finding, so a
# sink assertion at the default is a test of its neighbours. Zeroed here, the
# claim is the one that matters: a fresh finding reaches the alert tier.
: > "$T/alerts"
VIGILANCE_ALERT_COOLDOWN=0; export VIGILANCE_ALERT_COOLDOWN
_recheck
[ "$(_drifts)" -ge 1 ] || fail "with dedup off, a drift the log records reached
no alert sink at all. The log keeps the record and the sinks tell the human;
losing the second means the fault is only ever found by someone reading files.
alerts: $(cat "$T/alerts" 2>/dev/null)
log tail: $(logsince | tail -3 | tr '\n' ' ')"
grep -q 'not off' "$T/alerts" || fail "the alert reached the sink without the
device in it: $(cat "$T/alerts")"

# --- 4. ACT IS NEVER SUPPRESSED -------------------------------------------
# The rival is still running. An edge that stops crossing because a fight is in
# progress would convert a reporting problem into a security one.
_before=$(crossed wake)
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
[ "$(crossed wake)" -gt "$_before" ] || fail "the wake edge did not cross
while another actuator was driving the output. A fight must never stop the
ladder from moving"
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" || true
[ "$(depth)" = sleep ] || fail "the ladder could not return to sleep during the
fight; depth is '$(depth)'"

# --- 5. BOUNDED: one unchanging fight is ONE finding ------------------------
# THE HALF THAT COST TWELVE HOURS. The dedup key is a cksum of kind + message,
# and sway-dpms's message names the output and its state rather than a duration,
# so every pass must hash the same. A key per observation is both a file leak
# and a storm.
#
# THE THROTTLE IS DEFEATED HERE, deliberately (VIGILANCE_PERIPHERAL_EVERY=0
# above). At the shipped hour it would answer "not due" after the first pass and
# this case would pass on the throttle alone, leaving the dedup untested: two
# guards, and the outcome cannot tell them apart unless one is removed.
#
# AND THE COOLDOWN GOES BACK ON, which case 3b turned off. Without this the case
# would count eight notifications and fail about a dedup this file had just
# disabled, i.e. a verdict about its own neighbour. Exported and restored rather
# than prefixed, because an assignment in front of a shell FUNCTION leaks into
# the rest of the file.
VIGILANCE_ALERT_COOLDOWN=3600; export VIGILANCE_ALERT_COOLDOWN
: > "$T/alerts"
_logbefore=$(logsince | grep -c . || true)
_i=0
while [ "$_i" -lt 8 ]; do _recheck; _i=$((_i + 1)); done
_n=$(_alerts)
[ "$_n" -le 2 ] || fail "one unchanging fight notified $_n times across 8
supervision passes. That is the mute-leds storm, which taught a human to
distrust drift alerts and ended with a live box having its supervision timer
stopped BY HAND: every later report was then green because nothing ran"
# AND THE LOG KEPT EVERY ONE, which is what makes throttling a courtesy rather
# than a gap: the audit tier reads this file to say how long a fault lasted.
_logafter=$(logsince | grep -c . || true)
[ "$(( _logafter - _logbefore ))" -ge 8 ] || fail "the log gained
$(( _logafter - _logbefore )) records across 8 passes that each found the same
drift. Suppression must never reach the record"

# --- 6. RECOVER: the finding does not outlive the fight ---------------------
# A marker that stops the tier re-litigating a lost fight is the right fix, and
# it is also how a tier goes permanently quiet about a device that came back.
# This is the stale-save shape, one layer out.
_rival_stop
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
"$VIGILANT" go sleep >>"$T/out" 2>>"$T/stderr" || true
await 10 _dark \
  || fail "with the rival gone, vigilance could not darken the output again.
A transient fight has become a permanent failure"
: > "$T/alerts"
_recheck
[ "$(_drifts)" = 0 ] || fail "the recheck still reports drift after the rival
stopped and the output really is off. A finding that outlives its cause is the
stale-save bug in the reporting tier:
$(cat "$T/alerts")"

pass "rival won at sleep, drift named the output, $_n alerts over 8 passes, \
recovered clean"
