#!/bin/sh
# test/greeter.t - the session that runs when NOBODY IS LOGGED IN.
#
# The greeter is the most architecturally distinctive path in this package and
# the least exercised: it is a different uid, with no user hook tree, no lock
# provider, no audio, and no home the rest of the system can read. It is also
# the one nobody watches, because by definition there is no one at the machine.
#
# WHAT MAKES IT WORK IS AN ABSENCE. A greeter needs no configuration of its own:
# it simply has no user scope, so it gets the machine hooks and nothing else.
# Every assertion here is really about that absence behaving correctly.
#
# AND IT BEGINS AT `lock`, NOT `open`. A greeter IS the locked state -- there is
# no user session to protect -- so it is INITIALISED at that rung rather than
# traversing to it. Without that, `go sleep` would traverse open -> lock ->
# sleep and fire lock.d, whose provider would try to start a lock screen on top
# of a session that already is one.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init greeter

# NO USER TREE AT ALL. Not an empty one -- absent, which is the greeter's actual
# situation and a different code path from "present but empty".
export VIGILANCE_HOOK_ROOT="$T/no-such-user-tree"

_mrec=$T/machine-ran
: > "$_mrec"
_mhook() {   # <edge-dir> <name>
  mkdir -p "$VIGILANCE_MACHINE_HOOKS/$1"
  cat > "$VIGILANCE_MACHINE_HOOKS/$1/$2" <<EOF
#!/bin/sh
printf '%s %s %s\\n' "\$VIGILANCE_EDGE" "\$VIGILANCE_FROM" "$2" >> "$_mrec"
EOF
  chmod +x "$VIGILANCE_MACHINE_HOOKS/$1/$2"
}

# The peripherals (machine scope, correct) and a stand-in for the lock PROVIDER
# wired where it must never be: if the greeter ever crossed `lock`, this fires.
_mhook sleep.d 10-peripherals
_mhook wake.d  10-peripherals
# The lock-crossing sentinel goes in the REPORT tier, not the act tier, and the
# distinction is faithful rather than convenient. A real greeter's machine scope
# has NO lock.d at all -- the provider is user-scope only -- and `report` uses
# exactly that emptiness to decide a locker is not expected here. A sentinel in
# lock.d would masquerade as a provider and make this fixture unlike the thing
# it models. The report tier still fires on a lock crossing, so it detects the
# case just as well.
_mhook lock.report.d 50-provider-must-not-run

# --- 1. a greeter starts AT the lock rung -----------------------------------
export VIGILANCE_INITIAL_DEPTH=lock
expect_depth lock
[ ! -s "$_mrec" ] || fail "initialising at a rung fired hooks. It is an
INITIALISATION, not a crossing: nothing was traversed, so nothing may run"

# --- 2. descending fires ONLY the edge below, never `lock` ------------------
# The load-bearing assertion. If the greeter traversed from `open` it would
# cross `lock` on the way past, and the provider would try to raise a lock
# screen over the greeter itself.
go sleep
expect_rc 0
expect_depth sleep
grep -q 'sleep lock 10-peripherals' "$_mrec" \
  || fail "the greeter's peripherals hook did not run on the sleep edge"
grep -q 'provider-must-not-run' "$_mrec" \
  && fail "the greeter crossed the LOCK edge and fired the lock provider. It is
already the locked state; raising a locker over it is the bug that starting at
the lock rung exists to prevent" || :

# --- 3. and it comes back up, with no user tree to help ---------------------
go lock
expect_depth lock
grep -q 'wake sleep 10-peripherals' "$_mrec" \
  || fail "the greeter did not cross 'wake' coming back; its screen stays dark
with nobody present to notice"

# --- 4. a MISSING user tree is not an error --------------------------------
# Every command must work with the user root absent, because that IS the
# greeter. An error would make a greeter noisy or dead at the login screen.
for _c in status hooks verify audit due; do
  "$VIGILANT" "$_c" >/dev/null 2>>"$T/stderr" \
    || fail "'$_c' failed with no user hook tree. That is the greeter's normal
state, not an error condition"
done

# `report` is asserted DIFFERENTLY, and the difference is not a loophole. Its
# exit code folds in the machinery section, which reads the HOST's real systemd
# -- are vigilance's units enabled -- and that legitimately differs between the
# stub substrate and the VM. Demanding rc=0 asserts the host is healthy, not
# that a greeter can run report; it was red in the VM on units this file never
# meant to test.
#
# So assert it RAN: a missing user tree must not stop it producing its sections.
_rep=$("$VIGILANT" report 2>>"$T/stderr") || true
for _sec in session "recorded state" coherence wiring; do
  case "$_rep" in
    *"-- $_sec --"*) ;;
    *) printf '%s\n' "$_rep" >&2
       fail "report did not emit its '$_sec' section with no user hook tree;
it stopped short rather than reporting on a greeter" ;;
  esac
done
case "$_rep" in
  *"no lock provider wired"*) ;;
  *) printf '%s\n' "$_rep" >&2
     fail "report did not recognise a greeter (lock rung, no provider) and so
would sit permanently RED on the one session nobody is present to watch" ;;
esac

# --- 5. a user-scope hook wired in MACHINE scope breaks the greeter ---------
# This is why locker-up is documented USER-SCOPE ONLY, asserted rather than left
# as a comment. A greeter has no locker and never will: it IS the locked state.
# Wired machine-side, its verify fails on every greeter edge and teaches whoever
# reads the alerts to ignore them.
cp "$HERE/libexec/vigilance/hooks/locker-up" \
   "$VIGILANCE_MACHINE_HOOKS/lock.verify.d/50-locker-up" 2>/dev/null \
  || { mkdir -p "$VIGILANCE_MACHINE_HOOKS/lock.verify.d"
       cp "$HERE/libexec/vigilance/hooks/locker-up" \
          "$VIGILANCE_MACHINE_HOOKS/lock.verify.d/50-locker-up"; }
chmod +x "$VIGILANCE_MACHINE_HOOKS/lock.verify.d/50-locker-up"
VIGILANCE_LOCKER_UP=0 "$VIGILANT" verify lock >/dev/null 2>>"$T/stderr" \
  && fail "locker-up passed at a greeter's lock rung with no locker running. It
would then be useless; the reason it must be USER scope is that here it should
FAIL, and failing on every greeter edge is exactly why it must not be wired
here" || :
rm -f "$VIGILANCE_MACHINE_HOOKS/lock.verify.d/50-locker-up"

# --- 6. the greeter's own initial depth is not inherited by a real session --
# VIGILANCE_INITIAL_DEPTH only applies when there is NO record. Once a depth
# exists it must win, or a stale environment variable would silently rewrite
# where the machine believes it is.
go open
expect_depth open
VIGILANCE_INITIAL_DEPTH=suspend expect_depth open

pass
