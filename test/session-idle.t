#!/bin/sh
# test/session-idle.t - the idle mechanism, with a REAL swayidle.
#
# THE MECHANISM THIS PACKAGE IS ABOUT, and until now it was tested nowhere. The
# founding failure is "swayidle WEDGES on this Wayfire build: it resumed a
# suspend UNLOCKED and silently dropped a Session.Lock that fired" -- and no
# tier has ever started a swayidle, let alone watched it drive the ladder. Every
# assertion about idle locking has been about a recorder hook or a stubbed argv.
#
# A HEADLESS COMPOSITOR IS PERMANENTLY IDLE, which makes this deterministic
# rather than flaky: with no seat input device there is nothing to reset the
# timer, so every timeout fires in order at exactly its threshold. The thing
# that makes idle behaviour hard to test on a desk is what makes it easy here.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/session.sh"
session_init session-idle
trap 'session_done; rm -rf "$T"' EXIT INT TERM HUP

NOTCHECKED=

wire lock ''        swaylock
wire lock   .verify locker-up
wire_cross idle     input-counters
wire_cross watchdog swayidle-watchdog

# --- 1. THE IDLE LADDER, END TO END ----------------------------------------
# lock at 4s, sleep at 8s. The real swayidle, the real provider, the real
# ladder: the sequence the package exists to perform, performed once.
session_idle_start 4 8

_at_lock() { [ "$(depth)" = lock ]; }
await 20 _at_lock || fail "a real swayidle with a 4s idle-lock never reached
the lock rung in 20s of guaranteed idleness. This is the primary mechanism of
the entire package, and nothing has ever tested it: every previous assertion
about idle locking was about a recorder or a stubbed argv"
await 10 locker_up || fail "the idle lock crossed the edge but no swaylock is
running. The edge fired and the session is NOT secured, which is the exact
shape of the founding failure"
[ "$(crossed lock)" -ge 1 ] || fail "the lock edge was never logged"

_at_sleep() { [ "$(depth)" = sleep ]; }
await 25 _at_sleep || fail "the idle timer locked but never reached 'sleep'
after its blank delay; depth is '$(depth)'. The peripherals stay lit on a
machine nobody is at"

# --- 2. THE HEARTBEAT MAKES THE WATCHDOG ANSWERABLE ------------------------
# The watchdog declines (78) until the running argv carries the tick, because
# without it silence is ordinary rather than evidence. That precondition took
# three live failures to get right; this is the first time anything has
# confirmed it from the daemon's own argv rather than a fixture's.
_argv=$(tr '\0' '\n' < "/proc/$(pgrep -x swayidle | head -1)/cmdline")
printf '%s\n' "$_argv" | grep -q idle-tick || fail "the running swayidle has no
idle-tick heartbeat. The watchdog is then unanswerable by construction, and it
accused a healthy timer three separate times for exactly this reason"

# UPTIME PINNED BEFORE THE RUN, not after. The watchdog declines when the box
# has not been up longer than its quiet window, and a fresh VM has been up for
# seconds -- so an unpinned reading makes this case decline and prove nothing.
# The first draft wrote the file AFTER using it, which is the same mistake with
# no excuse.
printf '%s\n' "999999" > "$T/uptime"
_wrc=0
VIGILANCE_KIND=watchdog VIGILANCE_UPTIME_FILE=$T/uptime \
  sh "$PLUGINS/hooks/swayidle-watchdog" >"$T/wd.out" 2>&1 || _wrc=$?
[ "$_wrc" != 1 ] || fail "the watchdog called a swayidle that has just driven
two edges WEDGED: $(head -1 "$T/wd.out")"

# --- 3. RESTARTING THE TIMER MUST NOT MANUFACTURE AN OVERDUE ---------------
# swayidle RUNS ALL PENDING RESUME COMMANDS ON SIGTERM -- documented, and there
# so a killed timer does not leave a dimmed screen. So stopping it from the
# `sleep` rung ascends the ladder, while the input counters have not moved: our
# clock keeps counting from the last keystroke and reports the machine as long
# idle against a timer that has only just rearmed. Nine false alerts on a live
# box, one a minute, from a tackup run doing exactly this.
[ "$(depth)" = sleep ] || fail "setup: case 3 needs the sleep rung"
_before_wake=$(crossed wake)
session_stop_idle
await 10 _at_lock || fail "stopping the idle timer did not run its pending
resume, so this case did not reach the state it exists to test"
[ "$(crossed wake)" -gt "$_before_wake" ] || fail "no wake edge was crossed"

# THE CEILING: the ascent bounds the idle estimate. Only assertable where the
# clock can answer at all -- a substrate with no countable input device
# correctly declines, and demanding a number there would be a verdict about the
# VM rather than about the code.
_idle=$("$VIGILANT" report 2>/dev/null \
        | sed -n 's/.*idle clock: \([0-9]*\)s.*/\1/p' | head -1)
if [ -n "$_idle" ]; then
  [ "$_idle" -le 60 ] || fail "after an ascent the idle clock still reads
${_idle}s. Whatever raised the machine also rearmed the timer being judged, so
an unbounded reading here is what produced nine false overdue alerts in nine
minutes on a live box"
else
  NOTCHECKED="$NOTCHECKED idle-ceiling(no-countable-input-device)"
fi

pass "${NOTCHECKED:+not checked:$NOTCHECKED}"
