#!/bin/sh
# test/environment.t - the primitives this code rests on actually behave.
#
# WHY THIS FILE EXISTS. A whole class of defect here came from a fact that
# "everyone knows" being false on this fleet, and nothing checked:
#
#   `mkdir` is atomic                 uutils coreutils 0.10.0 checks for
#                                     existence and THEN creates, so a racing
#                                     pair both succeed. 14 of 20 concurrent
#                                     rounds. It was the crossing lock's first
#                                     primitive and it did not work.
#   swaylock ignores unknown config   it prints the option and its whole usage,
#                                     and the provider returned 1 -- an alert
#                                     on the lock edge from a dead config key.
#   `fx:mean` measures luminance      it averages ALPHA too, so an opaque
#                                     all-black frame reads 0.25, and the
#                                     verify that measured it called a working
#                                     blank broken.
#   `is-active` means "not down"      it is FALSE while a unit is ACTIVATING,
#                                     which shipped a lock-edge alert twice.
#
# None was a logic error. Each was an assumption about a TOOL, and every one
# reached a live box because the assumption was never written down as a check.
# So: one assertion per primitive the shipped code genuinely depends on, run on
# every box, failing loudly when the ground moves.
#
# SCOPE RULE: only primitives the product actually uses. A survey of interesting
# shell trivia would rot, and a test nobody trusts is worse than none. Each case
# below names the file that depends on it.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init environment

_skip=

# --- 1. `set -C` + `>` IS EXCLUSIVE (bin/vigilant, the crossing lock) -------
# The whole one-writer mechanism rests on this. It is IN-SHELL precisely
# because the external tool that should have done the job does not, so if this
# ever stops holding there is no fallback and the crossing lock is decoration.
#
# 4 racers x 25 rounds. A single round proves nothing: mkdir passed 200/200
# sequentially and still lost 14 of 20 concurrent rounds, which is exactly the
# shape a one-shot check cannot see.
_bad=0
for _r in $(seq 1 25); do
  _d=$T/excl/$_r; mkdir -p "$_d"
  for _i in 1 2 3 4; do
    ( if ( set -C; printf 'x\n' > "$_d/lk" ) 2>/dev/null; then
        echo w >> "$_d/res"
      fi ) &
  done
  wait
  _w=$(grep -c w "$_d/res" 2>/dev/null || echo 0)
  [ "$_w" = 1 ] || _bad=$((_bad + 1))
done
[ "$_bad" = 0 ] || fail "'set -C' with a redirect was not exclusive in $_bad of
25 concurrent rounds. This shell's noclobber is not O_EXCL, so the crossing
lock cannot serialise anything and every hook is back to racing its own twin"

# --- 2. `timeout -k` KILLS A CHILD THAT IGNORES SIGTERM (bin/vigilant) ------
# The per-hook bound is the only thing stopping a wedged hook holding the lock
# edge open until systemd reaps the unit and the box sleeps unlocked. A hook
# that TRAPS TERM is the realistic case, and plain `timeout` cannot tell that
# apart from a polite one -- which is why a mutation dropping `-k` once looked
# covered.
if command -v timeout >/dev/null 2>&1; then
  _t0=$(date +%s)
  timeout -k 1 1 sh -c 'trap "" TERM; sleep 30' >/dev/null 2>&1 || true
  _el=$(( $(date +%s) - _t0 ))
  [ "$_el" -le 5 ] || fail "timeout -k took ${_el}s to kill a child that
ignores SIGTERM. The hook bound is then advisory, and a hook that traps TERM
can hold the lock edge open past the suspend unit's deadline"
else
  _skip="$_skip timeout"
fi

# --- 3. CAPTURING THROUGH A FILE KEEPS THE BOUND (bin/vigilant) ------------
# The runner captures hook output through a FILE and never `$(...)`, because a
# command substitution waits for the PIPE to close rather than for the command
# to exit: a hook leaving a child on stdout outlived its timeout entirely,
# measured at 21s against a 2s bound, and it defeated the bound in four places.
#
# THIS ASSERTS THE PATH THE CODE TAKES, not the defect it avoids. The first
# draft asserted that `$(...)` IS still defeated, and the VM failed it
# immediately -- correctly. Measured:
#
#   host (uutils timeout 0.10.0)   $(...) defeated, ~8s against a 1s bound
#   VM   (GNU coreutils)           $(...) bounded, 2s
#
# So the defect is implementation-specific, and a test demanding it would go
# red on a machine where the underlying problem does not exist. A check that
# fails on a correct system is the cry-wolf this suite bans. What the code
# RELIES on is the file path being bounded, and that holds on both.
if command -v timeout >/dev/null 2>&1; then
  _t0=$(date +%s)
  timeout -k 1 1 sh -c 'trap "" TERM; sleep 8 &
                        sleep 30' > "$T/cap" 2>&1 || true
  _el=$(( $(date +%s) - _t0 ))
  [ "$_el" -le 5 ] || fail "a bounded command captured THROUGH A FILE still took
${_el}s. Then no hook is bounded on this box: one that leaves a child holding
stdout can hold the lock edge open until systemd reaps the suspend unit, and
the machine sleeps unlocked"
fi

# --- 4. `fx:mean` AVERAGES ALPHA (libexec/vigilance/hooklib.sh) -------------
# hook_screen_luma passes `-alpha off` for exactly one reason, and it is not
# tidiness: without it an opaque all-black grab reads 0.25, and the tier that
# measures a blanked screen called a working mechanism broken while the user was
# looking at a black panel. Both halves asserted, so the flag cannot be dropped
# as redundant.
if command -v magick >/dev/null 2>&1; then
  magick -size 8x8 xc:black -alpha set "PNG32:$T/black.png"
  _with=$(magick "$T/black.png" -colorspace Gray -format '%[fx:mean]' info:)
  _off=$(magick "$T/black.png" -alpha off -colorspace Gray \
           -format '%[fx:mean]' info:)
  case "$_off" in 0|0.0|0e+00) ;; *)
    fail "an opaque all-black frame measured '$_off' WITH -alpha off. The dark
threshold is 0.01, so either black is no longer 0 or the option changed
meaning; hook_screen_luma's verdict is not about the screen either way" ;;
  esac
  # And the flag must still be NECESSARY. If a future ImageMagick stops
  # averaging alpha, the guard is harmless but its comment is a fiction, and a
  # reader who believes the fiction removes the next one that matters.
  case "$_with" in 0|0.0) fail "alpha no longer affects fx:mean (both readings
are 0). The -alpha off guard in hook_screen_luma is now unnecessary; confirm
that before its comment misleads someone" ;; esac
else
  _skip="$_skip magick"
fi

# --- 5. `stat -c %Y` IS AN INTEGER (bin/vigilant, the stale-lock age) -------
# The crossing lock decides whether a pid-less claim is a crash or a claim in
# progress by its AGE, and an unparseable mtime reads as epoch 0 -- ancient,
# therefore breakable, therefore the lock gets stolen from a live holder.
_st=$(stat -c %Y "$T" 2>/dev/null || echo)
case "${_st:-}" in
  ''|*[!0-9]*) fail "stat -c %Y printed '$_st', not an integer. The crossing
lock then reads every fresh claim as epoch 0 and steals the lock from a holder
that is microseconds old" ;;
esac
[ "$_st" -gt 1700000000 ] || fail "stat -c %Y returned $_st, which is not a
plausible recent epoch; the age arithmetic in the crossing lock is meaningless"

# --- 6. `date -r FILE +%s` IS AN INTEGER (hooks/swayidle-watchdog) ----------
# The watchdog measures how long the idle timer has been silent from the event
# log's mtime. A non-numeric answer there makes it decline for ever, which is
# the quiet failure this whole tier exists to avoid.
_dr=$(date -r "$T" +%s 2>/dev/null || echo)
case "${_dr:-}" in
  ''|*[!0-9]*) fail "date -r FILE +%s printed '$_dr'. The watchdog cannot then
measure silence at all, and a watchdog that always declines is indistinguishable
from one that is working" ;;
esac

# --- 7. A FAILED REDIRECT ON `printf` DOES NOT EXIT THE SHELL --------------
# `:` is a SPECIAL builtin and a redirection error on one exits the shell
# outright, which once aborted a hook before it drove either monitor. The
# crossing lock's claim deliberately uses `printf` instead, and that choice is
# only safe while this holds.
( printf 'x\n' > "$T/nonexistent-dir/f" ) 2>/dev/null || true
echo alive > "$T/alive"
[ -f "$T/alive" ] || fail "the shell did not survive a failed redirect on
printf. Every guarded write in this codebase assumes a REGULAR builtin merely
returns non-zero"

# --- 8. ...AND ON `:` IT DOES, which is why nothing uses `: >` --------------
# Asserted so the ban reads as a measurement rather than folklore. Under dash
# this kills the subshell; bash survives. Either way the lesson is the same:
# never `: >`.
_sub=$( ( : > "$T/nonexistent-dir/f"; echo survived ) 2>/dev/null || true )
case "$_sub" in
  survived) ;;    # bash-like: tolerant, but the ban still holds for dash
  '')       ;;    # dash-like: the shell exited, exactly as documented
  *) fail "unexpected output '$_sub' from a failed redirect on ':'" ;;
esac

[ -z "$_skip" ] && pass || pass "not checked:$_skip"
