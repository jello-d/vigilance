#!/bin/sh
# test/atleast.t - a security request may deepen the machine, never raise it.
#
# THE LIVE FAILURE THIS ENCODES. Closing the laptop lid on AC makes logind emit
# Session.Lock. The trigger ran plain `vigilant go lock`; the machine was at the
# `sleep` rung, and `go` travels in whichever direction reaches its target, so
# it crossed `wake` and LIT THE PANEL. Nothing brought it back down: swayidle
# had already spent its `timeout 600` and never saw a resume, because a lid
# switch is not seat input to the compositor. The box sat lit with the lid shut
# for 30 minutes, and a human opening the lid again was what ended it.
#
# Two requests wear the same verb and mean opposite things:
#
#   resume        "the user is back, come UP to lock"     must ascend
#   Session.Lock  "secure this session"                   must NEVER ascend
#
# So BOTH halves are asserted here. A fix that stopped `go lock` ascending
# outright would strand every resume on the fleet at a dark rung while looking
# like a hardening, which is why the plain-`go` case below is not decoration.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init atleast

_atleast() {   # <state>
  CROSS_RC=0
  "$VIGILANT" go "$1" atleast >>"$T/out" 2>>"$T/stderr" || CROSS_RC=$?
}

hook lock  10-rec
hook sleep 10-rec
hook wake  10-rec

# --- 1. FROM ABOVE IT STILL DESCENDS, AND STILL TRAVERSES ------------------
# The mode restricts DIRECTION, not the edge and not the distance. Two ways to
# get this wrong, and the multi-rung target catches both: suppressing the
# descent outright (the lock stops happening, far worse than the bug being
# fixed) and downgrading it to a single step (the `only` semantics, which would
# leave `sleep` recorded with the lock edge never crossed).
#
# A one-edge target could not tell those apart -- open -> lock is one step
# either way -- and the first draft of this file used one. The mutation that
# leaked `only` through survived it.
_atleast sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-rec
sleep lock 10-rec"

# --- 2. AT THE RUNG IT IS A NO-OP ------------------------------------------
_atleast sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-rec
sleep lock 10-rec"

# --- 3. FROM BELOW IT DECLINES, AND SAYS SO --------------------------------
# The whole finding. At `sleep` the session is already locked -- every route
# there crosses the lock edge on the way -- so raising achieves nothing and
# costs the screen.
true > "$RECORD"
# A CLEAN LOG, so the audit case below can only be satisfied by the DECLINE.
# Section 1 already logged `cross lock`, which satisfies a lock assertion by
# itself: left in place, section 4 would pass with the new reconciliation route
# deleted. Asserting the precondition, not just the outcome.
true > "$T/vigilant.log"
_atleast lock
expect_rc 0
expect_depth sleep
expect_record ""
grep -q "deeper than 'lock'" "$T/vigilant.log" \
  || fail "a declined lock request left no trace. A security request that was
refused is precisely the thing that must not be silent, and the audit tier
reconciles on that line"
grep -q "cross " "$T/vigilant.log" \
  && fail "the decline crossed an edge; nothing may be traversed when the
machine is already deeper than the request"

# --- 4. ...AND THE AUDIT TIER COUNTS THE DECLINE AS SATISFIED ---------------
# THE FALSE-MISS CLASS, which this project has already shipped twice. An audit
# assertion names an EDGE but is really about the RUNG, and a decline means the
# rung was already at least that deep. Left unreconciled, every lid-close on a
# sleeping box would be reported as a MISS -- and a forensic tier whose output
# is mostly noise is one a human stops reading, which is how the original bug
# survived a refactor.
mkdir -p "$VIGILANCE_MACHINE_HOOKS/audit.d"
cat > "$VIGILANCE_MACHINE_HOOKS/audit.d/10-src" <<'EOF'
#!/bin/sh
printf '%s lock lid-close\n' "$(date +%s)"
EOF
chmod +x "$VIGILANCE_MACHINE_HOOKS/audit.d/10-src"
_arc=0
"$VIGILANT" audit >"$T/audit.out" 2>>"$T/stderr" || _arc=$?
grep -q "MISS" "$T/audit.out" && {
  cat "$T/audit.out" >&2
  fail "audit called a correctly-declined lock request a MISS. The machine was
at 'sleep', which is deeper than 'lock' and so already locked"
}
[ "$_arc" = 0 ] || fail "audit exited $_arc on a satisfied assertion"
rm -f "$VIGILANCE_MACHINE_HOOKS/audit.d/10-src"

# --- 5. PLAIN `go` MUST STILL ASCEND ---------------------------------------
# THE OTHER HALF. The resume path is `vigilant go lock` from `sleep`, and it is
# the only way a woken box gets its screen back.
true > "$RECORD"
go lock
expect_rc 0
expect_depth lock
expect_record "wake sleep 10-rec"

# --- 6. A MISSPELT MODE IS LOUD --------------------------------------------
# `go` used to drop every argument after the state, so a caller asking for a
# mode it did not have would silently get the DEFAULT -- and the default is the
# one that raises. A safety qualifier that can be typed wrong into nothing is
# not a safety qualifier. Same class as the `blank-after` key that sat in a
# shipped config for three days meaning nothing at all.
CROSS_RC=0
"$VIGILANT" go lock atleastt >>"$T/out" 2>>"$T/stderr" || CROSS_RC=$?
expect_rc 2

# And the mode must REACH cmd_go rather than being accepted and dropped: at
# `sleep`, an accepted-but-ignored `atleast` ascends, which is the bug.
go sleep
expect_depth sleep
_atleast lock
expect_depth sleep

pass
