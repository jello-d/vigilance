#!/bin/sh
# test/hook-bounds.t - EVERY tier that runs a hook must bound it, and the bound
# must actually be in force.
#
# The act tier was bounded first, after a hook in lock.d that hung was measured
# blocking the traversal forever with `50-provider` never running. Fixing one
# tier is not fixing the class: the runner executes hooks from FIVE places, and
# three of them had their own loop and inherited nothing.
#
#   _run_hooks      act / verify / report     bounded first
#   _alert          alert.d                   own loop, unbounded
#   _blocked        <edge>.block.d            own loop, unbounded
#   cmd_due         <edge>.due.d              own loop, unbounded
#   cmd_audit       audit.d                   own loop, unbounded
#
# _blocked is the sharpest of them: block hooks run BEFORE the depth is
# committed and before any actuator sees the edge, so a hook hanging there stops
# the lock EARLIER than one in lock.d does. Measured: `go lock` sat for as long
# as the hook did, and the provider never ran.
#
# THE SECOND BUG, WHICH THE FIRST FIX HID. Three of those tiers capture the
# hook's output, and they did it with `_out=$(... hook ...)`. A command
# substitution waits for the PIPE to close, not for the hook to exit -- so a
# hook that leaves a child holding stdout blocks the substitution for as long as
# the CHILD lives, with the bound not in force at all. Measured at 21s against a
# 2s bound, with timeout(1) having correctly killed the hook at 4s.
#
# Isolated:
#   timeout -k 2 2 sh -c 'trap "" TERM; sleep 20'          -> 4s   (correct)
#   x=$(timeout -k 2 2 sh -c 'trap "" TERM; sleep 20')     -> 21s  (defeated)
#   x=$(timeout -k 2 2 sh -c 'sleep 20')                   -> 2s   (correct)
#
# The third line is why it survived: a hook that dies politely behaves
# identically either way. EVERY hook here therefore both IGNORES SIGTERM and
# leaves a child holding stdout, because that is the only shape that tells a
# real bound from a decorative one.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init hook-bounds

# `sleep` is a CHILD of the hook shell, so it survives the shell being killed
# and keeps stdout open. Combined with the trap, this defeats both a missing
# bound and a bound applied through a command substitution.
_stubborn() {   # <path>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\ntrap "" TERM INT\nsleep 25\n' > "$1"
  chmod +x "$1"
}

# The hook sleeps 25s and the bound is 2s, so a tier that takes anywhere near
# the sleep is unbounded. 15s is far from both numbers: it cannot pass by the
# hook finishing, and it will not fail on a loaded machine.
_bounded() {   # <label> <seconds-taken>
  [ "$2" -lt 15 ] || fail "the $1 tier took $2s with a 2s hook bound. Either
nothing bounds it, or the bound is being applied through a command substitution
that waits on the hook's CHILD rather than on the hook"
}

# --- 1. the BLOCK tier, which gates the lock before anything else -----------
_stubborn "$VIGILANCE_HOOK_ROOT/lock.block.d/10-hangs"
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.d"
printf '#!/bin/sh\ntouch %s/provider-ran\n' "$T" \
  > "$VIGILANCE_HOOK_ROOT/lock.d/50-provider"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.d/50-provider"

go open
_s=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" go lock >/dev/null 2>>"$T/stderr" || true
_bounded block "$(( $(date +%s) - _s ))"

# The assertion that matters is not that the hook died, it is that the LOCK
# still happened. A block hook runs before any actuator, so hanging there is the
# earliest possible way to stop the screen locking.
[ -e "$T/provider-ran" ] || fail "the lock provider never ran because a BLOCK
hook hung. block.d is consulted before the depth is committed and before any
actuator, so it is the earliest point at which a plugin can stop the screen
locking -- and under lock-on-sleep the box then suspends unlocked"

# A timed-out block must ALLOW, never block. The tier fails OPEN by design:
# suppressing a lock is a security failure, allowing a redundant one is noise.
# A bound that turned a wedged hook into a veto would invert that.
grep -q "TIMED OUT; ALLOWING" "$VIGILANCE_LOG" \
  || fail "a block hook that timed out was not recorded as ALLOWING. This tier
fails open by design; a wedged guard must never be able to suppress a lock"
rm -rf "$VIGILANCE_HOOK_ROOT/lock.block.d" "$T/provider-ran"

# --- 2. the DUE tier, read by the minutely enforce timer --------------------
_stubborn "$VIGILANCE_HOOK_ROOT/lock.due.d/10-hangs"
_s=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" due lock >/dev/null 2>>"$T/stderr" || true
_bounded due "$(( $(date +%s) - _s ))"

# ...and through `enforce`, which is the caller that actually matters: it runs
# every minute forever, and a wedged due hook stops the supervision loop whose
# whole job is noticing that something did not happen.
_s=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=2 "$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
_bounded enforce "$(( $(date +%s) - _s ))"
rm -rf "$VIGILANCE_HOOK_ROOT/lock.due.d"

# --- 3. the AUDIT tier, on its OWN larger budget ----------------------------
_stubborn "$VIGILANCE_HOOK_ROOT/audit.d/10-hangs"
_s=$(date +%s)
VIGILANCE_AUDIT_TIMEOUT=2 "$VIGILANT" audit >/dev/null 2>>"$T/stderr" || true
_bounded audit "$(( $(date +%s) - _s ))"

# The audit budget is SEPARATE from the edge budget, and that separation is
# deliberate rather than incidental: an audit source reads an external event log
# (the shipped one runs journalctl over a day of records) and legitimately takes
# longer than anything on the lock path may. Sharing the edge bound would turn a
# healthy slow read into "audit BROKEN" and retire the forensic tier by crying
# wolf. Asserted, so the two cannot be quietly merged.
_s=$(date +%s)
VIGILANCE_HOOK_TIMEOUT=1 VIGILANCE_AUDIT_TIMEOUT=8 \
  "$VIGILANT" audit >/dev/null 2>>"$T/stderr" || true
_el=$(( $(date +%s) - _s ))
[ "$_el" -ge 6 ] || fail "audit finished in ${_el}s while its own budget was 8s
and the edge budget was 1s, so it is sharing the edge bound. A journal read is
legitimately slower than the lock path allows, and reporting that as a broken
source is how a forensic tier stops being read"
rm -rf "$VIGILANCE_HOOK_ROOT/audit.d"

# --- 4. AND THE RATCHET: no new exec site may appear unbounded --------------
# Four of the five tiers were found by reading the source, not by a failing
# test, because each looked fine in isolation. A fifth loop added later would
# look just as fine. This is the part that compounds: a hook executed without a
# bound fails the suite until it gets one.
_unbounded=$(awk '
  /^[[:space:]]*#/ { next }
  /"\$_(h|bh|ah|dh)"/ {
    # The non-executing uses: listing, filtering, naming.
    if ($0 ~ /basename|dirname|\[ |case |printf|echo |_sd=/) next
    if ($0 ~ /HOOK_TMO|AUDIT_TMO/) next
    printf "%d: %s\n", FNR, substr($0, 1, 60)
  }' "$HERE/bin/vigilant")
if [ -n "$_unbounded" ]; then
  printf '%s\n' "$_unbounded" >&2
  fail "a hook is executed without a timeout bound. Every tier that runs a hook
must bound it: four of the five loops in this file were written unbounded, each
one looking correct on its own, and a hook that hangs in any of them stops the
edge it is part of. Add \$HOOK_TMO (or \$AUDIT_TMO for the audit tier), and
capture its output through a FILE rather than \$(...), which waits on the
hook's children and silently defeats the bound"
fi

pass
