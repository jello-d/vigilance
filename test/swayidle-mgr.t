#!/bin/sh
# test/swayidle-mgr.t - `stop` must stop OURS, and say what else it found.
#
# It was a bare `pkill -x swayidle`: kill every process of that name on the
# box. That cannot tell ours from anyone else's, so it would silently take out
# an unrelated instance -- including any independent idle client, which is
# exactly the shape a second opinion on idle would take -- and leave no trace
# that it had.
#
# The sweep is KEPT, because leaving a foreign timer running would mean `stop`
# did not stop idle locking, which is the one thing it promises. What changes
# is that ours dies by pid and a foreign one is NAMED in the log.
#
# pgrep AND pkill ARE STUBBED, and that is not convenience: this suite runs on
# a developer's live desktop, where an unstubbed `pkill -x swayidle` would kill
# the real session's idle timer. Stubbing an ACTUATOR is the sanctioned side of
# the substrate rule; the trust root is never stubbed.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init swayidle-mgr

mkdir -p "$T/bin" "$T/run" "$T/state"
PIDFILE=$T/run/swayidle.pid
EVENT_LOG=$T/state/events.log
: > "$EVENT_LOG"

# A process whose comm really is "swayidle", so /proc agrees -- cmd_stop reads
# it to avoid signalling a RECYCLED pid, and a fake cannot exercise that.
#
# A PLAIN SCRIPT, which keeps comm from its own basename. Copying `sleep` does
# not work here: it is a multi-call coreutils binary that dispatches on argv[0]
# and exits with "unknown program 'swayidle'", so the fixture died instantly
# and case 2 passed by accident. `exec sleep` is no good either -- that
# replaces the process and comm becomes "sleep". Running it as a CHILD keeps
# the script itself alive under the name we need.
printf '#!/bin/sh\nsleep 20\n' > "$T/bin/swayidle"
printf '#!/bin/sh\nsleep 20\n' > "$T/bin/notswayidle"
chmod +x "$T/bin/swayidle" "$T/bin/notswayidle"
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
[ -n "${FOREIGN:-}" ] && { printf '%s\n' "$FOREIGN"; exit 0; }
exit 1
EOF
cat > "$T/bin/pkill" <<'EOF'
#!/bin/sh
printf 'pkill %s\n' "$*" >> "$PKILL_LOG"
EOF
chmod +x "$T/bin/pgrep" "$T/bin/pkill"
PATH="$T/bin:$PATH"; export PATH
PKILL_LOG=$T/pkill.log; export PKILL_LOG
: > "$PKILL_LOG"

# cmd_stop plus the logging it uses, lifted from the real script so the thing
# under test is the shipped code rather than a paraphrase of it.
stopfn=$(sed -n '/^ts() {/,/^}/p;/^log() {/,/^}/p;/^cmd_stop() {/,/^}/p' \
  "$HERE/bin/swayidle-mgr")
run_stop() {
  env PATH="$PATH" PIDFILE="$PIDFILE" EVENT_LOG="$EVENT_LOG" \
    FOREIGN="${FOREIGN:-}" PKILL_LOG="$PKILL_LOG" sh -c "set -eu
$stopfn
cmd_stop"
}

# --- 1. OURS dies by pid, with no sweep -------------------------------------
"$T/bin/swayidle" 60 &
_ours=$!
printf '%s\n' "$_ours" > "$PIDFILE"
: > "$PKILL_LOG"
run_stop >/dev/null 2>&1
sleep 1
kill -0 "$_ours" 2>/dev/null \
  && { kill "$_ours" 2>/dev/null || true
       fail "the instance we started survived 'stop'. Killing it by pid is the
whole point of recording one"; }
[ ! -s "$PKILL_LOG" ] || fail "a by-name sweep ran even though our own pid was
valid and killed. The blunt instrument must be the fallback, not the method --
it is what would take out an unrelated idle client"

# --- 2. A RECYCLED PID IS NOT SIGNALLED -------------------------------------
# A pidfile outlives its process and the number gets reused. Signalling it
# blind would kill whatever inherited the number, which on a busy box is a
# coin flip -- and the failure would look like something else entirely.
"$T/bin/notswayidle" 60 &
_other=$!
printf '%s\n' "$_other" > "$PIDFILE"
run_stop >/dev/null 2>&1
sleep 1
if ! kill -0 "$_other" 2>/dev/null; then
  fail "a pid whose process is NOT swayidle was signalled anyway. That is the
recycled-pid case, and killing a stranger because a stale file named them is
worse than failing to stop"
fi
kill "$_other" 2>/dev/null || true

# --- 3. A FOREIGN INSTANCE IS SWEPT, AND NAMED ------------------------------
# Silence here was the old behaviour's real cost: it killed things and told
# nobody, so "why did my idle client die" had no answer anywhere.
rm -f "$PIDFILE"
: > "$PKILL_LOG"; : > "$EVENT_LOG"
FOREIGN=4242; export FOREIGN
run_stop >/dev/null 2>&1
grep -q "swept swayidle we did not start" "$EVENT_LOG" \
  || fail "a swayidle we did not start was killed and nothing recorded it.
An unexplained death is how 'my other client keeps vanishing' becomes
unanswerable"
grep -q "4242" "$EVENT_LOG" \
  || fail "the sweep did not name the pid it took"
grep -q "pkill" "$PKILL_LOG" \
  || fail "a foreign instance was reported but NOT stopped. Leaving it running
means 'stop' did not stop idle locking, which is the one thing it promises"
FOREIGN=; export FOREIGN

pass
