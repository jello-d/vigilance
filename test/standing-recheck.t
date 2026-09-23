#!/bin/sh
# test/standing-recheck.t - verification as a STANDING question, not an event.
#
# THE GAP. Verification only ever happened when an edge was crossed. So a
# machine that reached a rung correctly and then DRIFTED out of it went
# unnoticed until the next crossing -- at `sleep`, possibly hours. And a
# mechanism that never worked at all was asked exactly once, at the moment it
# was least likely to have failed yet.
#
# Every miss in this project's history had that shape: a single green verdict at
# crossing time, and then nothing ever asked again. So the supervision timer,
# which already runs every minute, now re-asks "is the machine still where it
# says it is" on every pass. Two independent paths to one truth: the edge-time
# verify says a crossing went well, this says the state is STILL true.
#
# IT IS ONLY SAFE BECAUSE ALERTS DEDUP. Without onset-deduplication a persistent
# fault would notify every minute, and the enforce timer would be switched off
# by hand -- which is not hypothetical, it happened on a live box, and every
# subsequent report was green because nothing was running.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init standing-recheck

mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.verify.d" "$VIGILANCE_HOOK_ROOT/alert.d"
cat > "$VIGILANCE_HOOK_ROOT/alert.d/10-sink" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> $T/alerts
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/alert.d/10-sink"
_verifier() { printf '#!/bin/sh\nexit %s\n' "$1" \
                > "$VIGILANCE_HOOK_ROOT/sleep.verify.d/10-probe"
              chmod +x "$VIGILANCE_HOOK_ROOT/sleep.verify.d/10-probe"; }
_enforce() { _r=0; "$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || _r=$?
             printf '%s' "$_r"; }
_alerts() { wc -l < "$T/alerts" 2>/dev/null | tr -d ' '; }

# The dedup IS the subject here, so turn it back on: scenario_init disables it
# so ordinary tests can assert on alerts without depending on what an earlier
# case raised.
VIGILANCE_ALERT_COOLDOWN=3600; export VIGILANCE_ALERT_COOLDOWN

go sleep

# --- 1. a healthy rung is quiet --------------------------------------------
# The first requirement of any standing check: it must say nothing when there
# is nothing to say, or it becomes noise and then it becomes disabled.
: > "$T/alerts"
_verifier 0
[ "$(_enforce)" = 0 ] || fail "a healthy rung made the supervision pass fail.
A standing check that cries on a correct machine is one that gets turned off"
[ "$(_alerts)" = 0 ] || fail "a healthy rung raised an alert"

# --- 2. DRIFT between crossings is found ------------------------------------
# The whole point: nothing crossed an edge here. The machine reached `sleep`
# legitimately and then stopped matching it, which used to be invisible until
# the next crossing hours later.
: > "$T/alerts"
_verifier 1
[ "$(_enforce)" != 0 ] || fail "the machine stopped matching the rung it claims
and the supervision pass reported success. Nothing crossed an edge, so nothing
else would have asked -- that is the window every miss in this project has
lived in"
# The DRIFT alert specifically, not just "an alert". A failing verify hook also
# raises hook-failed from inside the runner, so counting alerts cannot tell
# whether the standing check reported anything of its own -- and a test that
# cannot tell passes with that alert deleted.
grep -q '^drift$' "$T/alerts" || fail "the standing check raised no DRIFT alert
of its own. hook-failed says which hook returned non-zero; drift says the
machine is no longer in the state it claims, which is the finding here"
grep -q "STILL-DRIFTED" "$VIGILANCE_LOG" \
  || fail "the drift was not recorded in the log under a name the audit tier
can find"

# --- 3. REPEATS ARE DEDUPED, or the timer gets switched off -----------------
# This is what makes checking every minute safe at all. A live box had its
# enforce timer stopped by hand to quiet a storm, and it stayed stopped.
: > "$T/alerts"
for _i in 1 2 3 4 5 6; do _enforce >/dev/null; done
[ "$(_alerts)" -le 1 ] || fail "six passes over the SAME unchanged fault raised
$(_alerts) notifications. A notifier that fires every minute about a fact that
has not changed is one people silence -- and the timer goes with it"

# --- 4. ...but the LOG is never suppressed ---------------------------------
# Throttling is a courtesy to the human, never a gap in the record: the log is
# the audit tier's input, and a thinned record would make the forensic pass
# lie about how long something was broken.
# Count the ALERT lines, which is what suppression actually touches. Counting
# STILL-DRIFTED instead proved nothing: that is written by the recheck before
# _alert is ever called, so it survives however badly the log is throttled.
_n=$(grep -c "^.*ALERT \[" "$VIGILANCE_LOG")
[ "$_n" -ge 6 ] || fail "the log holds only $_n ALERT records for seven
observations. Suppression must be about NOTIFYING, never about recording: the
audit tier reads this to say how long a fault lasted, and a thinned log makes
the forensic pass understate it"
grep -q "logged, not notified" "$VIGILANCE_LOG" || fail "a suppressed repeat
was not marked as such in the log; a reader cannot tell a quiet period from an
unobserved one"

# --- 5. the cooldown is a knob, and 0 disables it --------------------------
: > "$T/alerts"
for _i in 1 2 3; do
  VIGILANCE_ALERT_COOLDOWN=0 "$VIGILANT" enforce >/dev/null 2>&1 || true
done
[ "$(_alerts)" -ge 3 ] || fail "with the cooldown disabled, repeats were still
suppressed; an operator debugging a notifier has no way to see every event"

# --- 6. a DIFFERENT fault still gets through -------------------------------
# Dedup keyed too broadly would swallow a new problem because an old one is
# still open, which is worse than the storm it prevents.
: > "$T/alerts"
_verifier 4                       # a different failing exit == a different msg
[ "$(_enforce)" != 0 ] || fail "a second, different fault was not reported"
[ "$(_alerts)" != 0 ] || fail "a DIFFERENT fault was swallowed because an
earlier one was still within its cooldown. Dedup must key on the fault, not on
the subsystem, or one open problem hides every later one"

# --- 6b. the verdict survives the NOT-DUE-YET path -------------------------
# Every early return in the enforcement path has to carry the standing check's
# finding, and "not due yet" is the one a healthy machine takes most often. A
# drift discovered on a pass that then returns 0 for an unrelated reason is a
# drift thrown away.
# AT `lock`, NOT `sleep`. The enforcement target is the edge BELOW the current
# rung, and below `sleep` is `suspend` -- which is deliberately excluded as a
# target, so `sleep` never reaches the not-due-yet path at all. `lock` has
# `sleep` below it, which is enforceable.
go open
go lock
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.due.d" \
         "$VIGILANCE_HOOK_ROOT/lock.verify.d"
cat > "$VIGILANCE_HOOK_ROOT/sleep.due.d/10-far" <<'DUE'
#!/bin/sh
echo 99999
DUE
printf '#!/bin/sh\nexit 1\n' > "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-probe"
chmod +x "$VIGILANCE_HOOK_ROOT/sleep.due.d/10-far" \
         "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-probe"
_out=$("$VIGILANT" enforce 2>&1) || _r6=$?
case "$_out" in
  *"not due yet"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "setup wrong: this case is meant to take the not-due-yet path" ;;
esac
[ "${_r6:-0}" != 0 ] || fail "drift was found and then discarded by the
not-due-yet return. That is the path a healthy machine takes on almost every
pass, so a finding lost there is a finding lost nearly always"
rm -rf "$VIGILANCE_HOOK_ROOT/sleep.due.d" \
       "$VIGILANCE_HOOK_ROOT/lock.verify.d"
go sleep

# --- 7. it runs even when there is NO deadline to enforce ------------------
# The recheck and the deadline logic answer different questions. Every early
# return in the enforcement path -- no target, no deadline, not due yet,
# blocked -- would otherwise skip the standing check entirely, which is most
# of the time on a healthy machine.
rm -rf "$VIGILANCE_HOOK_ROOT/sleep.due.d"
: > "$T/alerts"
_verifier 1
[ "$(_enforce)" != 0 ] || fail "with no deadline declared, the standing recheck
was skipped. 'Is anything overdue' and 'is the machine still where it says it
is' are different questions, and the second one must not depend on the first
having an answer"

# --- 8. A VERIFY THAT COULD NOT LOOK IS NOT DRIFT --------------------------
# DRIFT means we looked and the machine was wrong. 78 means nothing was wired
# to look. Raising the first for the second alerts every minute about a static
# wiring fact -- and an alert that fires on a correct machine is how the
# enforce timer got stopped by hand on a live box, after which every report was
# green because nothing was running.
: > "$T/alerts"
rm -rf "$VIGILANCE_HOOK_ROOT/sleep.verify.d"
[ "$(_enforce)" = 0 ] || fail "with NO verify hook wired for the current rung,
the supervision pass failed. `verify` answers 78 there -- nobody asked -- and
treating that as drift means a permanent alert about a wiring gap"
[ "$(_alerts)" = 0 ] || fail "an edge with no verify hooks raised an alert:
$(_alerts). 'I could not look' must not be reported as 'the machine is wrong'"
grep -q "STILL-DRIFTED" "$VIGILANCE_LOG" && \
  [ "$(grep -c 'STILL-DRIFTED' "$VIGILANCE_LOG")" -gt 0 ] || true

# --- 9. A CROSSING IN FLIGHT IS NOT DRIFT ----------------------------------
# THE RACE, observed on manifold. The verify tier takes a second or more (a
# ddcutil round trip, a screen capture) and this runs on a one-minute timer, so
# a crossing can start and finish inside a single recheck. The verdict then
# describes a rung the machine has already LEFT, against hardware correctly
# matching the new one:
#
#   22:24:01  cross wake: sleep -> lock      (hooks restore the LEDs to lit)
#   22:24:02  HOOK FAILED: sleep.verify 30-kbd-backlight
#   22:24:02  HOOK FAILED: sleep.verify 40-mute-leds
#   22:24:03  STILL-DRIFTED at 'sleep'
#
# The minute before was CLEAN, which is what ruled out genuinely-lit LEDs. A
# few percent of wakes land in that window -- often enough to teach a reader
# that drift alerts are noise, which is the one thing this tier cannot afford.
#
# Reproduced by a verify hook that CROSSES AN EDGE while it runs, which is what
# a real wake does to a recheck already in progress.
: > "$T/alerts"
# case 8 removed this tree to test the no-verify-hooks path; put it back
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.verify.d"
go sleep
cat > "$VIGILANCE_HOOK_ROOT/sleep.verify.d/10-probe" <<EOF
#!/bin/sh
# the machine moves out from under the recheck, exactly as a wake does
"$VIGILANT" go lock >/dev/null 2>&1
exit 1
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/sleep.verify.d/10-probe"
[ "$(_enforce)" = 0 ] || fail "a verify that FAILED while the machine crossed
an edge was reported as drift. The answer is about the rung we left, and the
hardware it judged had already moved on -- so the verdict is not about
anything. This fired on a live box one second after a wake"
# grep the FILE, not `_alerts` -- that helper returns a COUNT, so matching it
# against a kind name is an assertion that can never fire either way.
if grep -q '^drift$' "$T/alerts" 2>/dev/null; then
  fail "a crossing in flight raised a DRIFT alert. A few percent of wakes land
inside a recheck, and an alert that fires on a correct machine is how the
enforce timer got stopped by hand once already"
fi

# ...AND A REAL DRIFT STILL LANDS. Without this the fix could be "never report
# anything", which passes the case above and switches the tier off entirely.
#
# THE COOLDOWN GOES OFF FOR THIS ONE. Earlier cases in this file raised the
# same drift message and case 3 deliberately turned dedup ON, so a correct
# alert here is suppressed as a repeat -- and the assertion would then be about
# what its NEIGHBOURS did rather than about the guard. That is the trap this
# file's own header warns about.
: > "$T/alerts"
go open
go sleep
_verifier 1
VIGILANCE_ALERT_COOLDOWN=0; export VIGILANCE_ALERT_COOLDOWN
[ "$(_enforce)" != 0 ] || fail "with the machine sitting still, a failing
verify was not reported. Discarding a verdict is only correct when an edge
moved underneath it"
grep -q '^drift$' "$T/alerts" 2>/dev/null \
  || fail "a genuine drift raised no alert after the race guard was added.
Discarding a verdict is only correct when an edge moved underneath it; doing it
always would pass the case above and switch the tier off"

# --- 9b. A CROSSING STILL RUNNING IS NOT DRIFT EITHER ----------------------
# THE SECOND RACE, and the depth-moved guard above is structurally blind to it.
# _cross_one commits the depth BEFORE running the act tier -- deliberately, so
# a hook can read the rung it is acting for -- so mid-crossing the record is
# ahead of the machine and perfectly STILL. Nothing moves for the guard to see.
#
# Observed on manifestor, on a hotkey press that worked:
#
#   23:51:13  vigilance-enforce.service starts (the recheck)
#   23:51:13  HOOK FAILED: lock.verify 50-locker-up
#   23:51:13  Starting screen-lock.service ... swaylock   <- AFTER the verify
#   23:51:14  STILL-DRIFTED at 'lock': no locker is up
#
# Two alerts about a lock that was coming up normally.
#
# THE GUARD MUST RUN BEFORE THE VERIFY, not after. The hook-failure alert is
# raised from INSIDE cmd_verify, so discarding the verdict afterwards would
# still have toasted -- which is what the user actually saw.
: > "$T/alerts"
go open
go sleep
_verifier 1
_mark=$VIGILANCE_RUN_DIR/crossing
printf '%s %s\n' "$$" "$(date +%s)" > "$_mark"
[ "$(_enforce)" = 0 ] || fail "a recheck judged the machine while a crossing was
still running. The depth is committed before the act tier, so mid-crossing the
record is ahead of the machine ON PURPOSE and the gap is guaranteed"
if grep -q '^hook-failed$' "$T/alerts" 2>/dev/null; then
  fail "the verify RAN during a crossing, raising a hook-failed alert from
inside cmd_verify. The guard has to come before the verify, not after it"
fi

# A LEAKED MARKER MUST NOT SILENTLY DISABLE THE TIER. vigilant killed
# mid-crossing -- systemd reaping lock-on-sleep on its 25s timeout is the
# realistic case -- would otherwise leave a file that switches off the only
# check watching a settled machine. That is a far worse bug than the one being
# fixed, and it would be invisible: every report green, forever.
: > "$T/alerts"
printf '%s %s\n' 999999 "$(date +%s)" > "$_mark"       # a pid that is not alive
[ "$(_enforce)" != 0 ] || fail "a marker naming a DEAD process suppressed the
recheck. A crash mid-crossing would then disable drift detection permanently"

# ...and so must a STALE one, in case the pid was recycled.
: > "$T/alerts"
printf '%s %s\n' "$$" "$(( $(date +%s) - 100000 ))" > "$_mark"
[ "$(_enforce)" != 0 ] || fail "a marker older than VIGILANCE_CROSSING_MAX
suppressed the recheck. The pid check alone cannot survive recycling"
rm -f "$_mark"

# --- 9c. AND A REAL CROSSING CLEARS ITS OWN MARKER -------------------------
# Otherwise the first edge of the session disables the tier for good, and every
# case above would still pass.
go open
go sleep
[ ! -e "$_mark" ] || fail "a completed crossing left its in-flight marker
behind, which suppresses every future recheck"

# --- 10. A MESSAGE THAT COUNTS UPWARD MUST STILL DEDUP ---------------------
# THE STORM THE DEDUP EXISTS TO PREVENT, caused by the dedup's own key. It
# hashes the message text, and a watchdog says "emitted nothing for 45252s"
# then a minute later "45317s": the same finding, different text, so every pass
# hashed as a fresh onset. Measured on a live box: 39 notified, ZERO
# suppressed, one alert a minute about a condition that had not changed.
#
# That is the documented reason an enforce timer once got stopped by hand, and
# it was reintroduced by writing an elapsed time into an alert.
VIGILANCE_ALERT_COOLDOWN=3600; export VIGILANCE_ALERT_COOLDOWN
mkdir -p "$VIGILANCE_HOOK_ROOT/watchdog.d"
: > "$T/alerts"
_n=0
for _s in 45252 45317 45382 45447; do
  printf '#!/bin/sh\necho "emitted nothing for %ss"\nexit 1\n' "$_s" \
    > "$VIGILANCE_HOOK_ROOT/watchdog.d/10-count"
  chmod +x "$VIGILANCE_HOOK_ROOT/watchdog.d/10-count"
  "$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
done
_n=$(grep -c '^watchdog$' "$T/alerts" 2>/dev/null || echo 0)
[ "$_n" -le 1 ] || fail "four passes over ONE unchanged finding notified $_n
times, because the elapsed second count made each message unique. A dedup that
hashes the message is defeated by any alert that counts upward -- which is
every alert about a duration, and those are the ones that repeat forever"

# ...and two GENUINELY different findings still both get through, or the fix
# would be "suppress everything that contains a number".
: > "$T/alerts"
VIGILANCE_ALERT_COOLDOWN=3600
for _b in 4 5; do
  printf '#!/bin/sh\necho "bus %s will not wake"\nexit 1\n' "$_b" \
    > "$VIGILANCE_HOOK_ROOT/watchdog.d/10-count"
  chmod +x "$VIGILANCE_HOOK_ROOT/watchdog.d/10-count"
  "$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
done
_n=$(grep -c '^watchdog$' "$T/alerts" 2>/dev/null || echo 0)
[ "$_n" -ge 2 ] || fail "two DIFFERENT findings (bus 4 and bus 5) collapsed to
$_n notification(s). A number that identifies a thing is not a measurement of
it, and merging those hides the second fault behind the first"
rm -rf "$VIGILANCE_HOOK_ROOT/watchdog.d"

pass
