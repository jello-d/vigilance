#!/bin/sh
# test/concur.t - does the idle timer AGREE that the seat has been quiet?
#
# An idle deadline is built from two halves that come from DIFFERENT PLACES:
# the DEADLINE belongs to the idle timer and the IDLENESS to `idle.d`. So a
# deadline that passes with its edge unfired is only a FAULT if both halves
# agree, and this hook is the half that was missing.
#
# LIVE ON 2026-10-14. A browser in a video call took the compositor's own idle
# inhibitor, so the compositor reported the seat ACTIVE and swayidle correctly
# never fired the 480s lock: zero heartbeat ticks in 22 minutes with a 60s tick
# armed. The input counters, which see no inhibitor of any kind, read 1166s of
# idle. The two halves disagreed, nothing asked, and a screen somebody was
# working at got locked.
#
# THE THREE ANSWERS ARE THE POINT. Concurrence makes the overdue finding TRUE
# and specific; non-concurrence makes it a DEFERRAL; and "cannot tell" has to
# leave every caller exactly as it was, or wiring this tier would change the
# behaviour of boxes it cannot answer for.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init concur

HOOK=$HERE/libexec/hooks/swayidle-concur
mkdir -p "$T/bin" "$T/state/swayidle-mgr"
LOG=$T/state/swayidle-mgr/events.log

# THE PRECONDITIONS ARE FIXTURES, not assumptions. swayidle must look present
# AND running or the hook declines before reaching the question under test, and
# every case below would then pass for the wrong reason. That is the mistake
# this suite has made four times: a stub moved aside while the REAL binary sat
# two PATH entries later.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/swayidle"; chmod +x "$T/bin/swayidle"
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
[ -n "${PGREP_FOUND:-}" ] && exit 0
exit 1
EOF
chmod +x "$T/bin/pgrep"
PATH="$T/bin:$PATH"; export PATH
PGREP_FOUND=1; export PGREP_FOUND
SWAYIDLE_LOG_DIR=$T/state/swayidle-mgr; export SWAYIDLE_LOG_DIR

# THE ARMED COMMAND LIST IS PINNED, for the reason the watchdog pins it: A
# DAEMON PINS ITS ARGV AT START, so the heartbeat this hook reads exists only
# in an instance launched after it was added. Unpinned, every case would judge
# whatever the developer's own swayidle happens to be armed with.
VIGILANCE_IDLE_CMDLINE=$T/cmdline; export VIGILANCE_IDLE_CMDLINE
printf 'swayidle\0timeout\060\0swayidle-mgr event idle-tick\0' > "$T/cmdline"

_run() {   # <quiet-secs> -> sets RC, output in $T/out
  RC=0
  VIGILANCE_KIND=concur VIGILANCE_QUIET_SECS="${1:-}" \
    sh "$HOOK" >"$T/out" 2>>"$T/stderr" || RC=$?
}
_out() { cat "$T/out" 2>/dev/null || true; }

# EVENTS ARE WRITTEN WITH REAL TIMESTAMPS, because the hook PARSES them rather
# than reading the file's mtime, and that distinction is the subject of case 3.
_ev() {   # <seconds ago> <event>
  printf '%s %s\n' \
    "$(date -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%S.000000000)" "$2" \
    >> "$LOG"
}

# --- 1. the timer saw idle INSIDE the stretch: it AGREES ---------------------
# And the consequence matters as much as the answer: a concurrence is what
# makes "the timer is alive and its acting arm is broken" a true sentence, so
# the overdue tier may accuse. That is the 2026-09-12 outage, where a running
# timer was armed with a path that had been swept.
printf '' > "$LOG"; _ev 300 idle-tick
_run 900
[ "$RC" = 0 ] || fail "the timer observed the seat go idle 300s ago, inside a
900s stretch, and this did not read as agreement (rc=$RC): $(_out)"

# --- 2. the timer last saw idle BEFORE the stretch: it does NOT agree -------
printf '' > "$LOG"; _ev 3000 idle-tick
_run 900
[ "$RC" = 1 ] || fail "the timer has seen none of a 900s quiet stretch (its
last idle record is 3000s old) and this did not read as disagreement (rc=$RC).
That is the live 2026-10-14 case: the counters saw quiet and the timer did
not: $(_out)"

# --- 3. AN `active` RESUME IS NOT AGREEMENT ---------------------------------
# THE CASE THAT RULES OUT THE SIMPLER IMPLEMENTATION. Reading the log's MTIME
# would have been one line instead of a parse, and an `active` record updates
# the mtime: a RESUME would then read as the timer agreeing the seat was quiet,
# which is the opposite of what it means.
printf '' > "$LOG"; _ev 3000 idle-tick; _ev 10 active
_run 900
[ "$RC" = 1 ] || fail "an 'active' RESUME 10s ago was read as the timer
agreeing the seat had been quiet for 900s (rc=$RC). Only idle-direction records
are observations of idleness; this is what the mtime shortcut gets wrong:
$(_out)"

# --- 4. no idle record at all: it has seen nothing --------------------------
# SAFE ONLY BECAUSE THE FRAMEWORK CAPS THE STRETCH at the timer's own age
# (_idle_bound), so a window the timer could not have watched cannot reach
# here. Without that cap this answer would defer every deadline on a freshly
# restarted timer.
printf '' > "$LOG"; _ev 3000 start; _ev 20 active
_run 900
[ "$RC" = 1 ] || fail "a timer that has never recorded the seat going idle was
not reported as disagreeing (rc=$RC): $(_out)"

# --- 5. no stretch supplied: there is nothing to agree ABOUT ----------------
_run ''
[ "$RC" = 78 ] || fail "with no VIGILANCE_QUIET_SECS the hook answered $RC
instead of declining. The framework owns the clock; a hook that invented its
own window would answer a different question from the one the deadline asks"
_run 0
[ "$RC" = 78 ] || fail "a zero-second stretch is not a quiet seat by anyone's
reckoning and must be declined, not answered (rc=$RC): $(_out)"
_run banana
[ "$RC" = 78 ] || fail "a non-numeric stretch was not declined (rc=$RC). This
value crosses a process boundary, so it is third-party input: $(_out)"

# --- 6. NO HEARTBEAT ARMED: the decisive precondition ----------------------
# A DAEMON PINS ITS ARGV AT START, so an instance predating the heartbeat emits
# nothing however healthy it is. Reading THAT silence as disagreement would
# defer every idle deadline on the box, which is the unsafe direction: it
# suppresses the finding this whole tier exists to enable. The watchdog learned
# the same lesson within a day of shipping.
printf '' > "$LOG"; _ev 3000 idle-tick
printf 'swayidle\0-w\0timeout\0480\0lock\0' > "$T/noheart"
VIGILANCE_IDLE_CMDLINE=$T/noheart _run 900
[ "$RC" = 78 ] || fail "with no heartbeat armed in the running timer the hook
answered $RC. Its silence then carries no information at all, and reading it as
disagreement would defer every deadline on the box: $(_out)"
case "$(_out)" in
  *restart*) ;;
  *) fail "the no-heartbeat decline must name the remedy (a restart), because
it is the one precondition an operator can actually fix: $(_out)" ;;
esac

# --- 7. the subject is absent or not running: another tier's finding --------
printf '' > "$LOG"; _ev 3000 idle-tick
PGREP_FOUND= _run 900
[ "$RC" = 78 ] || fail "with the idle timer not running the hook answered $RC.
That is report's finding, and two tiers accusing in different words is how a
reader learns to discount both: $(_out)"
# A MINIMAL PATH, not a renamed stub: moving $T/bin/swayidle aside leaves the
# REAL binary reachable two entries later, which is the fourth instance of that
# trap in this suite.
mkdir -p "$T/min"
cp "$T/bin/pgrep" "$T/min/"
for _c in sh date grep tail cut tr head printf; do
  _p=$(command -v "$_c" 2>/dev/null) || continue
  cp "$_p" "$T/min/" 2>/dev/null || true
done
_saved=$PATH
PATH=$T/min; export PATH
command -v swayidle >/dev/null 2>&1 \
  && { PATH=$_saved; export PATH; fail "setup wrong: swayidle is still
reachable on the minimal PATH, so the next case proves nothing"; }
_run 900
_rcmin=$RC
PATH=$_saved; export PATH
[ "$_rcmin" = 78 ] || fail "with no swayidle on PATH at all the hook answered
$_rcmin instead of declining"

# --- 8. an unreadable or unparseable log: ABSTAIN, never disagree ----------
# A record this cannot read is a reason to abstain. Asserting disagreement
# there would defer a real deadline, which is the one direction that hides a
# fault rather than merely annoying somebody.
SWAYIDLE_LOG_DIR=$T/state/nothing _run 900
[ "$RC" = 78 ] || fail "with no event log the hook answered $RC. The heartbeat
is not wired, so silence carries no information: $(_out)"
printf 'not-a-timestamp idle-tick\n' > "$LOG"
_run 900
[ "$RC" = 78 ] || fail "an unparseable record was not abstained on (rc=$RC).
Reading it as disagreement would defer a real deadline: $(_out)"

# --- 9. A STAMP FROM THE FUTURE IS NOT A RECENT OBSERVATION ----------------
# A wall clock is not monotonic. Without this guard a backward step makes every
# stale record look fresh and MANUFACTURES a concurrence, which is the
# direction that cries wolf: the overdue tier would then accuse a timer that
# had seen nothing. Same family as every other elapsed guard in this package.
printf '' > "$LOG"; _ev -600 idle-tick
_run 900
[ "$RC" = 78 ] || fail "a record stamped 600s in the FUTURE was not refused
(rc=$RC). A stepped clock must not be able to manufacture agreement: $(_out)"

# --- 10. THE RELATION WITH THE WATCHDOG, which neither file can keep alone -
# Two hooks read ONE heartbeat. If they come to disagree about where it is or
# what marks it, one of them is silently answering about a file nobody writes,
# and no test of either file alone can see that. So the relation is the
# assertion: the shared facts are declared identically in both.
WD=$HERE/libexec/hooks/swayidle-watchdog
[ -r "$WD" ] || fail "the watchdog hook is missing, so this relation cannot be
checked: $WD"
for _pat in 'SWAYIDLE_LOG_DIR' 'VIGILANCE_HEARTBEAT_MARK'; do
  _a=$(grep -F "$_pat" "$HOOK" | head -1)
  _b=$(grep -F "$_pat" "$WD" | head -1)
  [ -n "$_a" ] || fail "swayidle-concur no longer derives $_pat, so it and the
watchdog cannot be compared and one of them may be reading a file nobody writes"
  [ "$_a" = "$_b" ] || fail "swayidle-concur and swayidle-watchdog derive
$_pat differently, so the two readers of one heartbeat disagree about it:
  concur:   $_a
  watchdog: $_b"
done

pass "agrees when the timer saw idle inside the stretch, disagrees when it saw\
 none of it, a resume is not agreement, the heartbeat-armed precondition, an\
 absent subject left to report, abstention on an unreadable or future record,\
 and the heartbeat facts shared with the watchdog"
