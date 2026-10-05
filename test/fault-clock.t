#!/bin/sh
# test/fault-clock.t - step a REAL clock backward under a running ladder.
#
# FAULT: clock-jumped-backward.
#
# WHY THIS EXISTS RATHER THAN MORE STUB CASES. Fixing the backward-clock defect
# meant auditing twelve elapsed-time computations: I MEASURED three and REASONED
# about nine. The three are held down in the stub tier, and reasoning is exactly
# what this project keeps paying for. Stepping a real clock exercises all twelve
# at once with no judgement of mine in the loop, which is the only way to find a
# site I misclassified.
#
# THE DEFECT IT GUARDS. A wall clock is not monotonic: an NTP step, an RTC left
# in local time after a dual boot, or a VM restore makes `now - then` NEGATIVE,
# and a negative satisfies every `-lt <bound>` and `-le <bound>` in the package.
# Three mechanisms switched themselves off for the length of the skew, silently:
# phantom-guard blocked every idle lock so the screen never locked,
# _alert_repeat deduplicated every alert so nobody was told, and
# _crossing_inflight believed a stale marker so the standing recheck stopped
# judging.
#
# ONLY IN THE THROWAWAY GUEST, and the session tier's VM marker is what enforces
# that. Setting a machine's clock backward is not something to do to a desk: it
# confuses every timer on the box, and on a laptop it can outlive the test.
#
# IT RESTORES THE CLOCK IN THE TRAP, including on an abort. This scenario shares
# a boot with every other scenario, so a clock left skewed would confound each
# of them afterwards, and it would look like their bug rather than this one's.
# Adding the offset BACK works without knowing how long the test took, because
# the clock kept running normally while it was skewed.
set -eu
_restore_machine() { :; }   # replaced once the stash exists; the trap needs it
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"
session_init fault-clock

OFFSET=${VIGILANCE_CLOCK_OFFSET:-3600}
# THE NET OFFSET, not a flag. This scenario steps the clock TWICE: back, and
# then forward past real time, and a restore that assumed one direction would
# leave the guest an hour out for every scenario after it in the same boot,
# looking like their bug.
CLOCK_NET=0
_unstep() {
  if [ "$CLOCK_NET" = 0 ]; then return 0; fi
  date -s "@$(( $(date +%s) - CLOCK_NET ))" >/dev/null 2>&1 || true
  timedatectl set-ntp true >/dev/null 2>&1 || true
  CLOCK_NET=0
}
trap '_unstep; _restore_machine; session_done; rm -rf "$T"' EXIT INT TERM HUP

command -v timedatectl >/dev/null 2>&1 \
  || fail "no timedatectl; this scenario cannot control the clock and would
assert against an unstepped one, passing for the wrong reason"

mkdir -p "$HOOKS/alert.d" "$HOOKS/lock.block.d"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> %s\n' "$T/alerts" \
  > "$HOOKS/alert.d/10-sink"
chmod +x "$HOOKS/alert.d/10-sink"
ln -sf "$PLUGINS/hooks/phantom-guard" "$HOOKS/lock.block.d/10-phantom"
wire lock '' systemd-locker
wire lock .verify locker-up

# A DETERMINISTIC FINDING, with a STABLE message. The dedup key is the message
# text, so the suppression case only means anything if the alert raised before
# step and the one after are THE SAME finding. My first draft stopped the locker
# to manufacture one, which taught me two things the hard way: stopping
# screen-lock.service fires its ExecStopPost and CROSSES UNLOCK, so the machine
# does not stay at `lock` at all, and whatever alert that did raise had an
# identity I never established. THE TIER IS REDUCED TO THIS HOOK ALONE, IN BOTH
# SCOPES, because the dedup key is the alert TEXT and the alert carries the
# whole verify output. Every other wired verifier contributes a note to that
# text, and a PERIPHERAL one that DEFERS (they check hourly now) drops its note
# from the next pass, so the armed finding and the later one differ and the
# cooldown comparison is never exercised. Observed exactly that way:
# `ddc-monitor: ddcutil is not installed` in the armed message and gone an
# instant later.
#
# THE MACHINE SCOPE IS MOVED ASIDE, NOT DELETED, and restored in the trap: those
# symlinks are the integrator's, every later scenario in this boot needs them,
# and a scenario that consumes another's fixture is the trap this suite keeps
# paying for.
MACHINE_V=/etc/vigilance/hooks/lock.verify.d
STASH=$T/machine-verify
if [ -d "$MACHINE_V" ]; then
  mkdir -p "$STASH"
  for _mv in "$MACHINE_V"/*; do
    [ -e "$_mv" ] || continue
    mv "$_mv" "$STASH/" 2>/dev/null || true
  done
fi
_restore_machine() {
  [ -d "$STASH" ] || return 0
  for _mv in "$STASH"/*; do
    [ -e "$_mv" ] || continue
    mv "$_mv" "$MACHINE_V/" 2>/dev/null || true
  done
}
rm -f "$HOOKS"/lock.verify.d/* 2>/dev/null || true
mkdir -p "$HOOKS/lock.verify.d"
{ printf '#!/bin/sh\n'
  printf 'echo "a fixed finding, so the dedup key never moves" >&2\n'
  printf 'exit 1\n'
} > "$HOOKS/lock.verify.d/90-fixed"
chmod +x "$HOOKS/lock.verify.d/90-fixed"

# --- arm it: real crossings, so every record is stamped by the REAL clock ----
# THE ANOMALY IS ONLY EVER "A RECORD WRITTEN BEFORE THE STEP, READ AFTER IT".
# That is obvious in hindsight and my first draft got it wrong: every crossing
# AFTER the step re-stamps the depth record with the skewed clock, so it is
# consistent with it again and there is nothing ahead to find. The guest caught
# the mistake by failing an assertion the product was right about. So each case
# below runs in the window where a PRE-step record is still being read, and the
# arming here is what puts records there.
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
await 15 locker_up || fail "fixture: no locker came up, so the records this
scenario is about were never written by a real crossing"

# A DEDUP STAMP, written by a REAL alert at the real clock, AT THE RUNG CASE 3
# WILL USE. Without one there is nothing for a skewed cooldown to suppress and
# the alert case passes vacuously: the arming crossings succeed, so they raise
# nothing themselves.
#
# THE RUNG IS THE WHOLE POINT, and the first version of this got it wrong in a
# way that made case 3 prove NOTHING. It armed AFTER stopping the locker, which
# crosses `unlock`, so the stamp belonged to a drift at 'open' while case 3
# raises one at 'lock'. The key is a cksum over kind+message, so those are
# different findings and there was never anything suppressible. MEASURED, which
# is how it was found: a mutation removing the guard in `_alert_repeat`
# SURVIVED, and printing both lines said why:
#
#   armed:  drift|... at 'open' ... verify unlock: NOTHING CHECKED ...
#   case 3: drift|... at 'lock' ... a fixed finding ... verify lock: FAIL
#
: > "$T/alerts"
VIGILANCE_ALERT_COOLDOWN=3600 "$VIGILANT" enforce >>"$T/out" 2>&1 || true
_armed=$(head -1 "$T/alerts" 2>/dev/null || true)
[ -n "$_armed" ] || fail "fixture: no alert fired before the step, so no dedup
stamp exists and the suppression case below would prove nothing"
# AND IT IS THE PLANTED FINDING, not whatever the substrate happened to raise.
# This guest has no brightnessctl, ddcutil or wlopm, so its verify tiers produce
# findings of their own, one of which is exactly what armed the wrong key.
case "$_armed" in
  *"a fixed finding"*) ;;
  *) fail "fixture: the armed alert is not the deterministic finding this
scenario plants, so its dedup key is not the one case 3 exercises:
$_armed" ;;
esac

# ...and NOW leave the machine at `open` with a PRE-STEP stamp, which is the
# state phantom-guard reads: it only considers blocking at that rung. Stopping
# the locker crosses `unlock`, which is precisely why it cannot come first.
systemctl --user stop screen-lock.service >/dev/null 2>&1 || true
"$VIGILANT" force open >/dev/null 2>&1 || true
[ "$(depth)" = open ] || fail "fixture: depth is '$(depth)', not open"

_before_bad=$("$VIGILANT" report 2>&1 | grep -c '^\[FAIL\]' || true)

# --- THE STEP ----------------------------------------------------------------
timedatectl set-ntp false >/dev/null 2>&1 || true
_t_pre=$(date +%s)
date -s "@$(( _t_pre - OFFSET ))" >/dev/null 2>&1 \
  || fail "could not set the clock; the fault cannot be injected here"
CLOCK_NET=$(( CLOCK_NET - OFFSET ))
_t_post=$(date +%s)
# THE PRECONDITION, ASSERTED. A step that silently did not take makes every
# assertion below pass for the wrong reason, which is the rule every other cell
# in the matrix follows.
[ "$_t_post" -lt "$_t_pre" ] || fail "the clock did not move:
$_t_pre -> $_t_post. NTP may have stepped it straight back, in which case this
scenario proves nothing and must say so rather than report a pass"

# --- 1. NOTHING ELSE BROKE, which is the point of a real step ---------------
# FIRST, while the depth record is still the PRE-STEP one: this is the only
# window in which anything is ahead of the clock.
# The nine sites I reasoned about rather than measured all run here, at once,
# under the same skew. A before-and-after comparison rather than an absolute
# count, because this guest has its own baseline and an absolute assertion would
# be about the substrate.
_after_bad=$("$VIGILANT" report 2>&1 | grep -c '^\[FAIL\]' || true)
[ "$_after_bad" -le "$_before_bad" ] || fail "report gained $(( _after_bad -
_before_bad )) new FAIL(s) purely from the clock moving backward. A skewed clock
is not a broken machine, and a report that says otherwise sends its reader after
a hardware fault that does not exist"

# AND NO COMMAND MAY PRINT A NEGATIVE ELAPSED TIME. `status` said
# "since: -3600s ago" and report said "depth=lock (-3600s ago)", which is the
# instrument announcing it is broken in the two commands an operator reads most.
# Clamping to 0 would have been worse: it claims the rung was entered just now.
for _cmd in status report; do
  "$VIGILANT" "$_cmd" > "$T/$_cmd.out" 2>&1 || true
  if grep -qE '\(-[0-9]+s ago\)|: -[0-9]+s ago' "$T/$_cmd.out"; then
    fail "'$_cmd' printed a NEGATIVE elapsed time under a skewed clock:
$(grep -E '\(-[0-9]+s ago\)|: -[0-9]+s ago' "$T/$_cmd.out" | head -2)"
  fi
done
grep -q 'skew' "$T/status.out" || fail "status did not NAME the clock skew. A
record ahead of the clock is a diagnosis worth stating, and this is a diagnostic
surface: silence here leaves a reader to wonder why 'since' is unknown"

# --- 2. phantom-guard MUST NOT BLOCK ----------------------------------------
# The measured defect: `now - entered_at` went negative, satisfied the cooldown,
# and every idle-sourced lock was refused. THE SCREEN NEVER LOCKS is the
# outcome, on the one hook whose job is to suppress locks.
_rc=0
VIGILANCE_SOURCE=idle "$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || _rc=$?
[ "$_rc" != 3 ] || fail "with the clock stepped back ${OFFSET}s, an idle-sourced
lock was REFUSED by a block hook. That is the screen never locking for as long
as the skew lasts, and it is silent: rc=3 reaches a keybind's stderr and
nowhere else"
await 15 locker_up || fail "the idle lock was not refused outright but no locker
came up either; the edge did not take under a skewed clock"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after a skewed idle lock"

# --- 3. AN ALERT MUST STILL REACH A SINK ------------------------------------
# `_alert_repeat` compares `now - stamped` against the cooldown, so a negative
# made every alert read as a suppressible repeat. The dedup is deliberately ON
# here: that is the configuration in which the defect bites.
: > "$T/alerts"
# THE SAME finding as the arming one, so it hashes to the same dedup key and the
# cooldown comparison is the thing under test. Its stamp is PRE-STEP, so
# `now - stamped` is negative.
[ "$(depth)" = lock ] || fail "fixture: depth is '$(depth)', not lock"
_erc=0
VIGILANCE_ALERT_COOLDOWN=3600 "$VIGILANT" enforce >>"$T/out" 2>&1 || _erc=$?
[ "$_erc" != 0 ] || fail "with the locker stopped at the lock rung, the recheck
reported success under a skewed clock. Nothing moved underneath it, so there was
nothing to discard"
grep -q . "$T/alerts" || fail "a real finding raised NO alert under a skewed
clock. Every dedup stamp is ahead of the clock, so each alert reads as a repeat
and the whole notification path goes silent while the log fills"
# AND IT IS THE FINDING WHOSE STAMP IS PRE-STEP. Without this the case passes
# on any alert at all, including one whose key was never stamped and so could
# not be suppressed by any clock, which is how it passed with the guard
# removed. An assertion about suppression has to name what should have been
# suppressed.
grep -Fq "$_armed" "$T/alerts" || fail "an alert got through, but NOT the one
whose dedup stamp predates the step, so the cooldown comparison was never
exercised and this case would pass whatever the clock did.
armed: $_armed
got:   $(head -1 "$T/alerts")"

# --- 4. THE STANDING RECHECK MUST STILL JUDGE -------------------------------
# Asserted through the alert above: a suppressed recheck raises nothing at all.
# THE MARKER CASE IS NOT REACHABLE FROM A CLOCK STEP ALONE and is not pretended
# at here: a crossing marker exists only DURING a crossing, so a future-stamped
# one needs the step to land inside that window. standing-recheck.t section 9b
# covers it by planting the marker, which is vigilance's own state rather than a
# machine fact, and is therefore honest in the stub tier.

# --- 5. AND THE LADDER STILL WORKS AFTER THE CLOCK COMES BACK --------------
# A transient fault that leaves permanent wreckage is not handled. Records
# written while skewed are an hour in the future once the clock is restored,
# which is the same anomaly pointing the other way.
_unstep
"$VIGILANT" force open >/dev/null 2>&1 || true
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
await 15 locker_up || fail "after the clock was restored, the ladder could not
lock. The records written during the skew outlived it, turning a transient fault
into a permanent one"
[ "$(depth)" = lock ] || fail "depth is '$(depth)' after the clock was restored"

# --- 6. AND NOW FORWARD, which is the OTHER declared fault ------------------
# FAULT: clock-jumped-forward. Same machine, opposite direction, and the two are
# not symmetric: backward made `now - then` NEGATIVE and disabled three
# mechanisms, while forward makes every record look OLD. That expires things
# early rather than never: a dedup cooldown, a phantom cooldown, so the
# failure mode is a burst, not a silence, and the matrix asks for DEGRADE.
#
# WHAT IS NOT ASSERTED HERE, deliberately: the idle clock's ceiling. A forward
# jump looks exactly like a long gap between samples, which
# input-counters.t already holds down ("A GAP IN SAMPLING IS NOT A QUIET SEAT")
# against pinned counter files, and this guest has no countable input device
# at scenario time anyway, so the source declines and the assertion would be
# vacuous. A cell that restates another test's claim about a fixture it does not
# have is the coverage-shaped nothing this matrix exists to avoid.
: > "$T/alerts"
_fwd_bad=$("$VIGILANT" report 2>&1 | grep -c '^\[FAIL\]' || true)
_f_pre=$(date +%s)
date -s "@$(( _f_pre + OFFSET ))" >/dev/null 2>&1 \
  || fail "could not step the clock forward; the fault cannot be injected"
CLOCK_NET=$(( CLOCK_NET + OFFSET ))
[ "$(date +%s)" -gt "$_f_pre" ] || fail "the clock did not move forward. NTP may
have stepped it back, in which case nothing below is a measurement"

# A forward jump makes the depth record look an hour old. That is not a fault,
# and report must not invent one: every elapsed time is positive and nothing is
# ahead of the clock, so the skew diagnosis belongs to the OTHER direction.
"$VIGILANT" status > "$T/fwd-status.out" 2>&1 || true
grep -q 'skew' "$T/fwd-status.out" && fail "status claimed a clock SKEW after a
FORWARD jump. Skew means a record is ahead of the clock; here every record is
behind it, which is an ordinary old machine, and a diagnosis that fires in
both directions tells a reader nothing about either:
$(grep -i skew "$T/fwd-status.out" | head -2)" || :
_fwd_after=$("$VIGILANT" report 2>&1 | grep -c '^\[FAIL\]' || true)
[ "$_fwd_after" -le "$_fwd_bad" ] || fail "report gained $(( _fwd_after -
_fwd_bad )) FAIL(s) purely from the clock moving FORWARD an hour"

# AND THE ALERTS SETTLE. Every dedup stamp now reads an hour old, so the first
# pass after the jump is ENTITLED to notify: the cooldown genuinely expired.
# What must not happen is that it keeps happening.
#
# SO THE CLAIM IS ABOUT THE LATER PASSES, not a ceiling on the total. My first
# version guessed "at most 2" and the guest said 3, and the guess was the
# wrong shape rather than the wrong number: this tier raises TWO kinds for one
# fault (hook-failed from the planted verifier, drift from the recheck's own
# verdict), so the entitled round is two or three notifications and a ceiling
# either passes vacuously or fails a correct machine. Splitting the passes needs
# no magic number and states the actual property.
_pass() { VIGILANCE_ALERT_COOLDOWN=3600 "$VIGILANT" enforce >>"$T/out" 2>&1 \
            || true; }
_pass
_pass
_fwd_round=$(wc -l < "$T/alerts" | tr -d ' ')
_pass
_pass
_fwd_after=$(wc -l < "$T/alerts" | tr -d ' ')
[ "$_fwd_after" = "$_fwd_round" ] || fail "two further supervision passes
notified $(( _fwd_after - _fwd_round )) more times about an unchanging finding,
after the round the clock jump legitimately entitled it to. That is a storm
arriving by way of the clock, and it is the documented reason a live box had its
supervision timer stopped BY HAND, after which every report was green because
nothing was running.
alerts seen:
$(cat "$T/alerts")"
# ...AND THE ENTITLED ROUND DID HAPPEN, or the settling above is the silence of
# a tier that stopped rather than one that is satisfied.
[ "$_fwd_round" -gt 0 ] || fail "no alert at all after the clock jumped forward,
so the dedup cannot be shown to have settled: an expired cooldown must notify
once, and this case would pass identically against a sink nothing reaches"

# ...and the ladder still crosses with the clock ahead, then restored.
_unstep
"$VIGILANT" force open >/dev/null 2>&1 || true
"$VIGILANT" go lock >>"$T/out" 2>>"$T/stderr" || true
await 15 locker_up || fail "after a forward step and restore, the ladder could
not lock"

pass
