#!/bin/sh
# test/cadence.t - can a reader tell the throttled tier is still looking?
#
# A deferring verifier reports `not due` and nothing else, so `ok (2 checked, 3
# not due)` reads identically on a box whose hourly pass ran twenty minutes ago
# and on one where it has not run since Tuesday. The cadence shipped with no way
# to observe it, and for this package that is the half that matters: a silent
# skip is how a cadence quietly becomes never.
#
# TWO CLAIMS, and the second is the one a future edit will break:
#
#   the AGES, which are evidence and never a verdict -- each hook picks its own
#   window, so a number report guessed at would be one no hook uses, and the
#   two things that could make a stamp stale are already `machinery`'s finding
#   and `wiring`'s;
#   the TRANSITION, which is the primary mechanism and the one fact no other
#   section reports: has the rung the machine is on had a full verify since it
#   was entered?
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init cadence

SR=$VIGILANCE_RUN_DIR/state
_cad() { _section "$("$VIGILANT" report 2>>"$T/stderr")" cadence; }
_backdate() {   # <rung> <seconds ago>
  printf '%s %s\n' "$1" "$(( $(date +%s) - $2 ))" \
    > "$VIGILANCE_RUN_DIR/depth"
  # THE ASCENT MARK MOVES WITH IT. An ascent is a ceiling on idle time, so a
  # fixture that ages only the depth record describes a machine that entered
  # its rung hours ago and was raised two seconds ago -- a state no real
  # machine can be in, which is the class this suite bans for hardware stubs.
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$VIGILANCE_RUN_DIR/last-ascent"
}

# --- 1. no deferring verifier is stated, not implied ------------------------
# An empty section would read as "nothing to say here", which is the same shape
# as a tier that has silently stopped. The honest answer is that every pass
# checks everything, because that is the cadence in force.
go lock
_out=$(_cad)
case "$_out" in
  *"no verifier defers"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no hook keeping a stamp, the section said nothing about the
cadence in force. Silence here is indistinguishable from a tier that stopped" ;;
esac

# --- 2. a FRESH rung is pending, not missing --------------------------------
# The recheck has not run yet: it fires on a timer, so for up to one period
# after a crossing the full verify is owed rather than absent. A warning here
# would fire on every single crossing, which is how a report gets skipped.
case "$_out" in
  *"[WARN]"*)
     printf '%s\n' "$_out" >&2
     fail "a rung entered seconds ago was reported as never verified. That
fires on every crossing on every box, and a warning that is always on is how
a reader learns to scroll past the one that matters" ;;
esac
case "$_out" in
  *"the next supervision pass"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a freshly entered rung did not say the verify was still pending" ;;
esac

# --- 3. once a pass KEEPS a verdict, the transition is recorded -------------
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
_out=$(_cad)
case "$_out" in
  *"had a full verify"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a supervision pass verified the rung and the section still did not
say so. The stamp is the only evidence that the transition trigger -- the
primary mechanism behind a slow peripheral cadence -- ever fires" ;;
esac
_no_fail_in "$("$VIGILANT" report 2>>"$T/stderr")" cadence "the cadence
section raised a FAIL. Nothing here is a machine fault: the deferring
verifiers still run on their own interval, so the worst case is checked less
often rather than not at all"

# --- 4. THE AGES ARE READ BEFORE THE REPORT'S OWN VERIFY --------------------
# THE OBSERVER EFFECT, and this is the assertion that pins it. `report` runs a
# verify, and an explicit verify never throttles -- so every deferring hook is
# STAMPED on the way past. Stamps read afterwards answer "checked just now" on
# every box, alive or dead, and the section becomes a mirror.
#
# This command has already paid for that once: running `report` to watch a fix
# land was resetting the idle clock being measured.
#
# The hook is a REAL one using the shipped hook_throttle, not a fixture that
# writes the file itself, because the thing under test is the interaction
# between the stamp the library keeps and the order report reads it in.
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.verify.d"
cat > "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-throttled" <<EOF
#!/bin/sh
set -eu
. "$HERE/libexec/vigilance/hooklib.sh"
hook_throttle 3600 && exit 75
echo "checked"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/lock.verify.d/10-throttled"
"$VIGILANT" enforce >/dev/null 2>>"$T/stderr" || true
[ -f "$SR/10-throttled/.last-checked" ] \
  || fail "the shipped hook_throttle kept no stamp, so nothing below is about
report's reading order -- it is about a fixture that does not throttle"
printf '%s\n' "$(( $(date +%s) - 900 ))" > "$SR/10-throttled/.last-checked"
_out=$(_cad)
_age=$(printf '%s\n' "$_out" | sed -n 's/.*10-throttled=\([0-9]*\)s.*/\1/p')
[ -n "$_age" ] || { printf '%s\n' "$_out" >&2
  fail "the section named no age for a hook that keeps a stamp"; }
[ "$_age" -ge 800 ] || { printf '%s\n' "$_out" >&2
  fail "the reported age was ${_age}s against a stamp written 900s ago, so the
snapshot was taken AFTER report's own verify re-stamped it. Every box then
reads 'checked just now' and the section can never show a tier that stopped"; }

# --- 5. AND A STALE TRANSITION IS A WARNING --------------------------------
# The rung was entered long ago and no pass has recorded a full verify of it.
# Nothing else in report can see this: `verify` asks about now, `machinery`
# asks whether the timer is alive, and neither asks whether the event that
# forces a full check ever fired.
rm -f "$SR/recheck-verified"
_backdate lock 9999
_out=$(VIGILANCE_RECHECK_GRACE=300 "$VIGILANT" report 2>>"$T/stderr")
_sec=$(_section "$_out" cadence)
printf '%s\n' "$_sec" | grep -q '^ *\[WARN\].*no supervision pass' \
  || { printf '%s\n' "$_sec" >&2
       fail "a rung held for 9999s with no full verify ever recorded was not
reported. The transition is the primary mechanism behind an hourly peripheral
cadence, so a transition that never fires means the hourly interval is all
there is -- and nothing said so"; }

# ...and the GRACE is read live, because it is the integrator's to set: a box
# wired with a 15-minute supervision timer is not faulty for having gone a
# minute without verifying. Pinning the default here would keep warning on a
# correctly slow box.
_sec=$(_section "$(VIGILANCE_RECHECK_GRACE=20000 "$VIGILANT" report \
  2>>"$T/stderr")" cadence)
case "$_sec" in
  *"[WARN]"*)
     printf '%s\n' "$_sec" >&2
     fail "the same state warned with a grace wider than the rung's age, so
VIGILANCE_RECHECK_GRACE is not being read and a slower timer cannot be
accommodated" ;;
esac

pass
