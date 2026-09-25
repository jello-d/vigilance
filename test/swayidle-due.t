#!/bin/sh
# test/swayidle-due.t - the hook answering "when SHOULD this edge have fired?"
#
# IT HAD NO BEHAVIOUR TEST. `claims.t` names it, but that is a documentation
# ratchet: it asserts the hook exists, not that it computes anything. The
# deadline this hook reports is the input to the overdue detector, which is the
# mechanism that replaced `enforce` and produced this project's only true
# positive, so a wrong number here is a false alert or a missed one.
#
# IT COULD NOT BE TESTED AT ALL, which is why. It read `ps -o args= -C swayidle`
# with no override, so any test would have measured the DEVELOPER's running
# swayidle: the mistake behind three separate defects in these notes. It
# honours VIGILANCE_IDLE_CMDLINE now, the same knob `report` already uses for
# that fact: one mechanism instead of two that could disagree.
#
# TWO DEFECTS FIXED ALONGSIDE, both found by reading and then measured:
#
# 1. THE EDGE WAS MATCHED AS A BARE SUBSTRING of the whole command, paths
#    included. `index(cmd, "lock")` also matches "unlock" and "lockdown", and on
#    a box whose home is /home/sleepy EVERY command contains "sleep", so the
#    sleep deadline would come back as whichever timeout is listed first. The
#    suite already paid for this class once and fixed it by anchoring.
# 2. `ps -C swayidle | head -1` TAKES WHICHEVER INSTANCE IS FIRST, so a foreign
#    idle client would have its timeout reported as vigilance's deadline.
#    swayidle-mgr tracks its own pid, so the hook prefers that.
#
# THE ARGV FIXTURES ARE THE REAL ONE from this fleet, not an invention. A
# simplified argv would not contain `swayidle-mgr event idle-lock`, where the
# edge name sits behind a HYPHEN, nor `suspend-if-battery`, which is the case my
# first anchor wrongly excluded.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init swayidle-due

HOOK=$HERE/libexec/vigilance/hooks/swayidle-due

# The live argv from manifold, verbatim.
{
  printf '%s' 'swayidle -w timeout 60 '
  printf '%s' '/home/jello/.local/bin/swayidle-mgr event idle-tick '
  printf '%s' 'resume /home/jello/.local/bin/swayidle-mgr event active '
  printf '%s' 'timeout 480 /home/jello/.local/bin/swayidle-mgr event idle-lock '
  printf '%s' 'timeout 600 /usr/local/bin/vigilant go sleep '
  printf '%s' 'resume /usr/local/bin/vigilant go lock '
  printf '%s' 'timeout 1200 /home/jello/bin/suspend-if-battery'
  printf '\n'
} > "$T/real"

_due() {   # <edge> <argv-file> -> prints the hook's answer, asserts exit 0
  _rc=0
  _o=$(VIGILANCE_IDLE_CMDLINE=$2 sh "$HOOK" "$1" 2>>"$T/stderr") || _rc=$?
  # ALWAYS 0. A due hook that exits non-zero is a BROKEN SOURCE to the runner,
  # which is a different finding from "no opinion" -- and "no opinion" is the
  # answer for most edges on any real wiring, so a non-zero here would make the
  # tier look broken on every healthy box.
  [ "$_rc" = 0 ] || fail "the hook exited $_rc for edge '$1'. A due source must
always exit 0: no output means no opinion, and that is not an error"
  printf '%s' "$_o"
}

# --- 1. the three edges swayidle actually arms ------------------------------
[ "$(_due lock "$T/real")" = "480 idle" ] \
  || fail "edge 'lock' reported '$(_due lock "$T/real")', not '480 idle'.
That number is the idle-lock timeout, and it reaches the overdue detector"
[ "$(_due sleep "$T/real")" = "600 idle" ] \
  || fail "edge 'sleep' reported '$(_due sleep "$T/real")', not '600 idle'"

# SUSPEND MATTERS ON ITS OWN, because the command is `suspend-if-battery` so
# the edge name is followed by a HYPHEN. My first anchor demanded a space
# or end-of-string and silently dropped this correct answer, which is how an
# over-tight fix loses a deadline rather than fixing one.
[ "$(_due suspend "$T/real")" = "1200 idle" ] \
  || fail "edge 'suspend' reported '$(_due suspend "$T/real")', not '1200 idle'.
The command is 'suspend-if-battery', so the edge name is followed by a hyphen: a
boundary that demands whitespace throws this away"

# --- 2. the edges it arms nothing for have NO OPINION -----------------------
# Not zero, and not an error. Zero would read as "it should have fired already"
# and manufacture an overdue on every ascent edge, forever.
for _e in unlock wake resume; do
  [ -z "$(_due "$_e" "$T/real")" ] \
    || fail "edge '$_e' claimed a deadline of '$(_due "$_e" "$T/real")'.
swayidle arms no timeout for it, and inventing one makes the overdue detector
fire about an edge nothing is waiting for"
done

# --- 3. AN EDGE NAME INSIDE A PATH MUST NOT HIJACK THE ANSWER ---------------
# The bug, made concrete. Every command below contains the letters "sleep"
# because of the HOME DIRECTORY, and the only real sleep timeout is the 600.
{
  printf '%s' 'swayidle -w timeout 60 '
  printf '%s' '/home/sleepy/.local/bin/swayidle-mgr event idle-tick '
  printf '%s' 'timeout 600 /home/sleepy/.local/bin/vigilant go sleep'
  printf '\n'
} > "$T/sleepy"
[ "$(_due sleep "$T/sleepy")" = "600 idle" ] \
  || fail "with a home directory named /home/sleepy the hook answered
'$(_due sleep "$T/sleepy")' instead of '600 idle'. A bare substring match reads
the PATHS, so the 60s tick wins and the sleep deadline is wrong by a factor of
ten -- which the overdue detector then reports as a fault"

# --- 4. ...nor may one edge name match another ------------------------------
# "lock" is a substring of "unlock" and of "lockdown". Only a whole-word match
# tells them apart, and this suite has already fixed the identical class once.
{
  printf '%s' 'swayidle -w timeout 30 /usr/local/bin/vigilant go unlock '
  printf '%s' 'timeout 90 /usr/local/bin/vigilant go lockdown '
  printf '%s' 'timeout 480 /usr/local/bin/vigilant go lock'
  printf '\n'
} > "$T/confuse"
[ "$(_due lock "$T/confuse")" = "480 idle" ] \
  || fail "edge 'lock' matched '$(_due lock "$T/confuse")' against an argv whose
earlier timeouts say 'unlock' and 'lockdown'. Both contain the letters of
'lock', and taking the first match reports another edge's deadline"

# --- 5. no swayidle, no opinion --------------------------------------------
# Emphatically NOT "overdue". A box with no idle timer has no idle deadline, and
# saying otherwise would alarm every greeter-only and headless machine.
: > "$T/empty"
[ -z "$(_due lock "$T/empty")" ] || fail "an empty argv produced a deadline"
_rc=0
_o=$(VIGILANCE_IDLE_CMDLINE=$T/nosuchfile sh "$HOOK" lock 2>>"$T/stderr") \
  || _rc=$?
[ "$_rc" = 0 ] || fail "an unreadable argv source exited $_rc, not 0"
[ -z "$_o" ] || fail "an unreadable argv source produced '$_o'"

# --- 6. a non-numeric timeout is not a deadline ----------------------------
# swayidle would reject it, but this hook must not turn it into a number either:
# awk reads garbage as 0, and 0 is the one answer that means "fire now".
{
  printf '%s' 'swayidle -w timeout abc /usr/local/bin/vigilant go lock'
  printf '\n'
} > "$T/junk"
[ -z "$(_due lock "$T/junk")" ] \
  || fail "a non-numeric timeout produced '$(_due lock "$T/junk")'. Read as a
number that becomes 0, which the overdue detector treats as already due"

# --- 7. a `resume` command belongs to no timeout ---------------------------
# swayidle's grammar puts `resume <cmd>` after a timeout, and that command is
# NOT the timeout's. Attributing it would make the resume arm's edge inherit a
# deadline it never had.
{
  printf '%s' 'swayidle -w timeout 600 /usr/local/bin/vigilant go sleep '
  printf '%s' 'resume /usr/local/bin/vigilant go lock'
  printf '\n'
} > "$T/resumeonly"
[ -z "$(_due lock "$T/resumeonly")" ] \
  || fail "edge 'lock' took '$(_due lock "$T/resumeonly")' from a RESUME arm.
The only timeout there is the 600 for sleep; the lock appears solely as what to
run on resume, and it has no deadline of its own"
[ "$(_due sleep "$T/resumeonly")" = "600 idle" ] \
  || fail "the sleep deadline was lost while excluding the resume command"

# --- 8. the answer is anchored to IDLE, not to rung entry -------------------
# The second field is load-bearing: swayidle measures from the last INPUT, and
# saying so is what stops the supervision loop calling a busy machine overdue.
# Dropping it would leave the deadline read against time-since-entry, which
# over-reports on a machine in use -- it once called `lock` 1616s overdue while
# the box was being typed on.
case "$(_due lock "$T/real")" in
  *" idle") ;;
  *) fail "the deadline did not declare its anchor: '$(_due lock "$T/real")'.
Without 'idle' it is read against rung entry, which over-reports on a machine
somebody is using" ;;
esac

pass
