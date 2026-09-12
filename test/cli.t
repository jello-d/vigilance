#!/bin/sh
# test/cli.t - the COMMAND SURFACE itself: the verbs, the usage contract, and
# the exit codes units branch on.
#
# Everything else in this suite drives vigilant through the scenario helpers
# (go/force/only), which is right -- they test BEHAVIOUR. But that left the
# surface those helpers call through completely unasserted: `status` and `hooks`
# had no direct test, and neither did the exit-2 usage contract, despite the
# header declaring exit codes "a contract, because units and the patch branch on
# them". A contract nothing checks is a comment.
#
# WHY THIS MATTERS HERE SPECIFICALLY: `check` shipped as a stub aliased to
# `status` while three documents described it as a wiring audit. No test could
# have caught that -- none of them asked what the verbs were.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init cli

# --- status reports the rung, and the roots of BOTH scopes -------------------
# Two scopes is a core design property, and `status` is where a human confirms
# which trees are live. A status naming only the user root would hide a machine
# hook tree entirely.
_out=$("$VIGILANT" status 2>>"$T/stderr") || fail "status exited non-zero"
case "$_out" in
  *"depth: open"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "status did not report the depth" ;;
esac
case "$_out" in
  *"$VIGILANCE_HOOK_ROOT"*) ;;
  *) fail "status did not name the USER hook root" ;;
esac
case "$_out" in
  *"$VIGILANCE_MACHINE_HOOKS"*) ;;
  *) fail "status did not name the MACHINE hook root" ;;
esac

# --- hooks lists every KIND, resolved, with its scope -----------------------
# The antidote to silent misconfiguration: a hook parked in the wrong tier is
# invisible until the edge it was meant for does nothing. So `hooks` has to show
# the tier and the scope, not just the name.
hook lock 10-act
mhook lock 20-machine-act
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.verify.d" \
         "$VIGILANCE_HOOK_ROOT/lock.due.d" \
         "$VIGILANCE_HOOK_ROOT/lock.block.d" \
         "$VIGILANCE_HOOK_ROOT/lock.report.d"
for _k in verify due block report; do
  printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/lock.$_k.d/30-$_k"
  chmod +x "$VIGILANCE_HOOK_ROOT/lock.$_k.d/30-$_k"
done
_out=$("$VIGILANT" hooks lock 2>>"$T/stderr") || fail "hooks exited non-zero"
# EVERY per-edge kind must appear. This is the assertion that catches a tier
# added to the runner but left out of the inspector.
for _k in verify due block report; do
  case "$_out" in
    *"[$_k]"*"30-$_k"*) ;;
    *) printf '%s\n' "$_out" >&2
       fail "hooks did not list the '$_k' tier; a hook parked there would be
invisible to the command whose whole job is showing what runs" ;;
  esac
done
case "$_out" in
  *"10-act [user]"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "hooks did not mark the user scope" ;;
esac
case "$_out" in
  *"20-machine-act [machine]"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "hooks did not mark the machine scope" ;;
esac

# An edge with nothing wired says so EXPLICITLY rather than printing a bare
# heading, for the same reason the empty verify tier reports n/a: silence reads
# as "fine" when it means "nothing is wired".
_out=$("$VIGILANT" hooks wake 2>>"$T/stderr") || fail "hooks wake failed"
case "$_out" in
  *"(none)"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "an edge with no hooks did not announce itself as empty" ;;
esac

# --- the CROSS-CUTTING tiers, and the trap that hid them --------------------
# THE RUNNER AND THE INSPECTOR DISAGREED ABOUT WHERE THIS TIER LIVES, which is
# the worst possible split to have in the one command whose entire purpose is
# showing what is wired. It was wrong in both directions at once:
#
#   a hook in <edge>.audit.d   `hooks` reported it WIRED; `audit` never ran it
#   a hook in audit.d          `audit` ran it; `hooks` said it did not exist
#
# Both halves are asserted here, because fixing either one alone would leave a
# reader trusting the other.
mkdir -p "$VIGILANCE_HOOK_ROOT/audit.d"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/audit.d/10-real-src"
chmod +x "$VIGILANCE_HOOK_ROOT/audit.d/10-real-src"
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.audit.d"
printf '#!/bin/sh\nexit 0\n' > "$VIGILANCE_HOOK_ROOT/lock.audit.d/10-never-runs"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.audit.d/10-never-runs"

# The REAL location is listed, in its own section, when listing everything.
_out=$("$VIGILANT" hooks 2>>"$T/stderr") || fail "hooks (all edges) failed"
case "$_out" in
  *"audit.d:"*"10-real-src"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "hooks did not list the audit.d tier, so the one event source that
audit actually runs was invisible to the wiring inspector" ;;
esac
case "$_out" in
  *"alert.d:"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "hooks did not list the alert.d tier either" ;;
esac

# And the per-edge location is NOT reported as wired, because nothing runs it.
# Reporting it would be worse than silence: it confirms a hook that never fires.
_out=$("$VIGILANT" hooks lock 2>>"$T/stderr") || fail "hooks lock failed"
case "$_out" in
  *"10-never-runs"*)
    printf '%s\n' "$_out" >&2
    fail "hooks reported a hook in <edge>.audit.d as wired, but cmd_audit reads
plain audit.d and will never run it; a confirmed hook that never fires is worse
than a missing one" ;;
esac

# --- THE USAGE CONTRACT: exit 2, and never a silent success -----------------
# The header calls the exit codes a contract because units branch on them. 2 is
# "you asked wrong", and the dangerous failure is a malformed invocation that
# exits 0: a unit would record a clean crossing for an edge it never crossed.
_rc=0; "$VIGILANT" go >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "'go' with no state exited $_rc, want 2"
_rc=0; "$VIGILANT" force >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "'force' with no state exited $_rc, want 2"
_rc=0; "$VIGILANT" only >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "'only' with no state exited $_rc, want 2"
_rc=0; "$VIGILANT" nonsense >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown command exited $_rc, want 2"
_rc=0; "$VIGILANT" >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "no command at all exited $_rc, want 2"

# An unknown STATE is also a usage error, and must not move the machine.
_rc=0; "$VIGILANT" go nowhere >/dev/null 2>>"$T/stderr" || _rc=$?
[ "$_rc" = 2 ] || fail "'go nowhere' exited $_rc, want 2"
expect_depth open

# --help is a SUCCESS, because a script asking for usage did nothing wrong.
"$VIGILANT" --help >/dev/null 2>>"$T/stderr" || fail "--help exited non-zero"
"$VIGILANT" help >/dev/null 2>>"$T/stderr" || fail "help exited non-zero"

# --- `check` is gone, and says where the real audit is ----------------------
# It shipped as a stub aliased to `status` with a "stage 4 replaces this"
# comment, while the README, the man page and this tool's own header all called
# it a wiring audit. A command quietly answering a DIFFERENT question than its
# documentation is worse than a missing one: the missing one fails loudly. So it
# fails loudly, and names the thing that does the job.
_rc=0; _out=$("$VIGILANT" check 2>&1) || _rc=$?
[ "$_rc" = 2 ] || fail "'check' exited $_rc, want 2 (it is not a verb)"
case "$_out" in
  *"setup.sh check"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "'check' did not point at the command that IS the wiring audit" ;;
esac

# --- a bad initial depth is LOUD, and falls back safely ---------------------
# VIGILANCE_INITIAL_DEPTH exists for a greeter, which starts AT `lock` rather
# than at the top. A typo there must not silently pick a rung: believing the
# machine is deeper than it is means skipping the very edges that secure it.
_out=$(VIGILANCE_INITIAL_DEPTH=bogus "$VIGILANT" status 2>&1) \
  || fail "a bad VIGILANCE_INITIAL_DEPTH made status fail outright"
case "$_out" in
  *"ignoring bad VIGILANCE_INITIAL_DEPTH"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a bad VIGILANCE_INITIAL_DEPTH was accepted silently" ;;
esac
case "$_out" in
  *"depth: open"*) ;;
  *) fail "a bad VIGILANCE_INITIAL_DEPTH did not fall back to 'open'" ;;
esac

# And a GOOD one is honoured, with no crossing: it is an initialisation, not an
# edge. A greeter whose `go sleep` traversed open -> lock would fire lock.d and
# try to start a lock screen on a session that already is one.
: > "$RECORD"
rm -f "$VIGILANCE_RUN_DIR/depth"
_got=$(VIGILANCE_INITIAL_DEPTH=lock "$VIGILANT" status 2>>"$T/stderr" \
         | awk '/^depth:/ {print $2}')
[ "$_got" = lock ] || fail "VIGILANCE_INITIAL_DEPTH=lock gave depth '$_got'"
[ ! -s "$RECORD" ] || fail "initialising at a rung fired hooks; it is not an
edge and nothing was traversed"

pass
