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
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
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
# A one-edge target could not tell those apart: open -> lock is one step
# either way, and the first draft of this file used one. The mutation that
# leaked `only` through survived it.
_atleast sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-rec
sleep lock 10-rec"

# --- 2. AT THE RUNG IT IS A NO-OP, AND SAYS SO PLAINLY ---------------------
# EQUAL IS NOT DEEPER. Folding the two into one message printed "already at
# 'lock', deeper than 'lock'; not raising" on a live box: a sentence that
# contradicts itself and describes a raise that was never possible. At the rung
# this is the ordinary no-op, worded as every other caller words it.
true > "$T/vigilant.log"
_atleast sleep
expect_rc 0
expect_depth sleep
expect_record "lock open 10-rec
sleep lock 10-rec"
grep -q "already at 'sleep'; nothing to do" "$T/vigilant.log" \
  || fail "at the target rung the decline did not log the plain no-op. Got:
$(cat "$T/vigilant.log")"
grep -q "deeper than" "$T/vigilant.log" \
  && fail "a request for the rung the machine is ALREADY AT was logged as
'deeper than' it, which is a claim about nothing"

# --- 3. FROM BELOW IT DECLINES, AND SAYS SO --------------------------------
# The whole finding. At `sleep` the session is already locked: every route
# there crosses the lock edge on the way, so raising achieves nothing and
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
# sleeping box would be reported as a MISS, and a forensic tier whose output
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
# mode it did not have would silently get the DEFAULT, and the default is the
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

# --- 5. A DECLINE RESTS ON A PREMISE, AND THE PREMISE IS CHECKED ------------
# "Already at 'lock', so the session is already secured" is sound only while the
# record and the world AGREE, and a record can be AHEAD of the world.
#
# MEASURED LIVE 2026-10-04: a layout change left the provider a dangling
# symlink, the lock edge crossed and committed `lock` with nothing wired that
# could run, no locker came up, and nothing ever unwound the record. Every later
# security request was then correctly declined against a FALSE premise. The log
# reads `already at 'lock'; nothing to do` twelve times, which is the hotkey
# being refused, and the box could not be locked for 84 minutes.
#
# SO THE RUNG IS CONFIRMED BEFORE IT IS STOOD ON, and the edge is RE-ASSERTED
# rather than declined: save once, ASSERT EVERY TIME, which is the discipline
# hooklib already applies to a device level, applied to the ladder's own record.
go open
hook lock 50-prov
: > "$RECORD"
# The record claims the rung while the probe says no locker exists, which is
# exactly the live state. VIGILANCE_LOCKER_UP is the shipped probe override.
go lock
expect_depth lock
: > "$RECORD"
VIGILANCE_LOCKER_UP=0 "$VIGILANT" go lock atleast >>"$T/out" 2>>"$T/stderr" \
  || true
grep -q '50-prov' "$RECORD" \
  || fail "with the record at 'lock' and NO locker up, a security request was
DECLINED instead of re-asserting the edge. That is the live lockout: a
transient wiring fault becomes a permanent inability to secure the session,
and nothing self-heals it.
record: $(cat "$RECORD")"

# --- 6. AND IT MUST STILL DECLINE WHEN THE RUNG GENUINELY HOLDS -------------
# The half that keeps this from re-raising the locker on every request. Without
# it the fix is indistinguishable from deleting the decline, which would make
# every lid close and every idle tick re-run the lock provider.
: > "$RECORD"
VIGILANCE_LOCKER_UP=1 "$VIGILANT" go lock atleast >>"$T/out" 2>>"$T/stderr" \
  || true
if grep -q '50-prov' "$RECORD"; then
  fail "with a locker genuinely UP, a security request re-ran the lock edge.
The decline exists so a lid close on an already-locked session is free; losing
it means re-raising the locker on every request:
record: $(cat "$RECORD")"
fi

# --- 7. A GREETER HAS NO PROVIDER, SO THE RUNG HOLDS VACUOUSLY --------------
# A greeter IS the locked state: it sits at `lock` with no user session, no
# provider and no locker, forever and correctly. Re-asserting there would run an
# empty tier on every request for ever, and asserting a locker would be
# demanding what no mechanism in that session can satisfy. Same carve-out
# `_rep_coherence` makes, from the same predicate.
# THE WHOLE TIER GOES, not just the provider: `_lock_holds` asks the same
# question `_rep_coherence` does, which is whether ANY lock.d hook is wired, so
# leaving the recorder behind leaves a non-empty tier and models nothing. My
# first version of this case did exactly that and failed about the product.
rm -f "$VIGILANCE_HOOK_ROOT/lock.d/50-prov" \
      "$VIGILANCE_HOOK_ROOT/lock.d/10-rec"
: > "$RECORD"
VIGILANCE_LOCKER_UP=0 "$VIGILANT" go lock atleast >/dev/null 2>&1 || true
[ ! -s "$RECORD" ] \
  || fail "with NO lock provider wired (the greeter shape), a security request
still tried to re-assert. Nothing there could raise a locker, so this would be
an empty tier run once a minute for ever:
record: $(cat "$RECORD")"

# --- 8. `atmost` IS THE MIRROR, AND BOTH HALVES MATTER ----------------------
# `atleast` exists because a SECURITY gesture must never ascend. A RESTORE
# gesture has the opposite hazard and had no qualifier at all for a year: given
# the plain verb, a key meaning "turn the display back on" LOCKS a machine that
# is already lit, because `go` travels whichever way reaches the target.
#
# NOT HYPOTHETICAL. This fleet's compositor config binds
# `command_display_on = vigilant go lock` to <ctrl><super> KEY_P as an
# always_binding, so it fires even under a fullscreen client, and at rung `open`
# it locks. On 2026-10-05 a user was typing and the screen locked with no idle
# event, no logind Lock, and nothing in the record able to say what asked.
_atmost() {   # <state>
  CROSS_RC=0
  "$VIGILANT" go "$1" atmost >>"$T/out" 2>>"$T/stderr" || CROSS_RC=$?
}

# FROM A SHALLOWER RUNG IT MUST NOT DESCEND. This is the defect itself: a lit
# machine asked to light itself must not lock.
go open
expect_depth open
true > "$RECORD"
true > "$T/stderr"
_atmost lock
expect_rc 0
expect_depth open
expect_record ""
grep -q "shallower than 'lock'; not descending" "$T/stderr" \
  || fail "the decline was silent. A refused restore gesture must say so, for
the same reason a refused security request must. stderr held:
$(tail -3 "$T/stderr")"

# ...AND FROM A DEEPER RUNG IT MUST STILL ASCEND, or "never descends" is
# satisfied by a mode that does nothing at all, which leaves a dark machine dark
# and the key dead. The pair is the test, exactly as for `atleast`.
go sleep
expect_depth sleep
true > "$RECORD"
_atmost lock
expect_rc 0
expect_depth lock
expect_record "wake sleep 10-rec"

# THE EQUAL CASE TAKES NO BRANCH OF ITS OWN, asserted rather than assumed: `-le`
# instead of `-lt` would print a sentence contradicting itself about a descent
# that was never on the table, which is the live defect 79859db fixed on the
# other side. It must reach the shared no-op wording instead.
true > "$T/stderr"
_atmost lock
expect_rc 0
expect_depth lock
grep -q "already at 'lock'; nothing to do" "$T/stderr" \
  || fail "the equal case did not reach the shared no-op message:
$(tail -3 "$T/stderr")"
grep -q 'shallower' "$T/stderr" \
  && fail "the equal case took the shallower branch and described a descent
that was never on the table: the 79859db defect, mirrored"

pass
