#!/bin/sh
# test/plan.t - "what runs, as whom" is a question nothing could answer.
#
# `hooks` lists what is wired. It does so for THIS session, implicitly, and in
# one fixed order, and each of those silences has cost a real outage:
#
#   SCOPE. The greeter's sleep edge darkened the keyboard and left the screen
#   lit, because the only blanking hook was user-scope. A merged listing made
#   that look identical to a session that had one.
#
#   ORDER. It reverses on an ascent, so one listed order is wrong for half the
#   edges -- and a restore that runs in descent order addresses devices that
#   are still powered off.
#
#   REACHABILITY. _hooks_in lists a hook only `if [ -x ]`, and that test is
#   FALSE for a uid that cannot traverse to the target. A machine-scope hook
#   pointing into a 0750 home does not FAIL for the greeter, it does not
#   EXIST: no log, no alert, no missing-hook warning. That is the one fault in
#   this suite that is silent BY CONSTRUCTION, and it is why this verb exits
#   non-zero rather than merely printing.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init plan

# EVERY COMPONENT of the path is walked, and mktemp gives 0700 -- so without
# this the entire fixture is unreachable and every case below passes or fails
# for a reason that has nothing to do with the code under test.
chmod 755 "$T"

# `nobody` stands in for the greeter: it exists on every Linux, it owns none of
# the fixture and shares no group with it, which is exactly the relationship
# _greetd has to a user's home.
GREETER=nobody
id -u "$GREETER" >/dev/null 2>&1 || GREETER=daemon
# A hard fail, not a skip: every Linux has one of these, and test/run now
# counts a verdictless test as a failure precisely so a quiet opt-out cannot
# make a suite look green while the assertion stopped running.
id -u "$GREETER" >/dev/null 2>&1 || fail "no unprivileged account (tried
nobody, daemon) to stand in for the greeter; the reachability assertions below
cannot run without one"
VIGILANCE_GREETER_USER=$GREETER; export VIGILANCE_GREETER_USER

MACH=$T/machine-hooks
_hook() {   # root edge-dir name
  mkdir -p "$1/$2"
  printf '#!/bin/sh\nexit 0\n' > "$1/$2/$3"
  chmod +x "$1/$2/$3"
}
# --- 1. a USER hook is named as ABSENT for the greeter ----------------------
# The listing that merges both scopes is the one that hid a greeter with no way
# to blank its screen. Saying "absent" out loud is the whole point of the verb.
_hook "$VIGILANCE_HOOK_ROOT" sleep.d 10-user-only
_hook "$MACH" sleep.d 20-machine-too
_out=$("$VIGILANT" plan sleep 2>/dev/null || true)
case "$_out" in
  *"absent : 10-user-only"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "a user-scope hook was not reported as ABSENT for the greeter. That
is the exact shape of the outage this verb exists for: the greeter's only
blanking hook was user-scope, so its sleep edge ran nothing that could darken a
screen, and every listing showed the merged set as though it would" ;;
esac
case "$_out" in
  *"greeter: 20-machine-too"*) ;;
  *) fail "a machine-scope hook was not listed for the greeter" ;;
esac
# ...and it must NOT appear in the greeter's own list.
_g=$(printf '%s\n' "$_out" | grep 'greeter:')
case "$_g" in
  *10-user-only*) fail "a user-scope hook was listed as something the GREETER
runs. It has no user scope at all, so this is not a mis-sort, it is a claim
that something will happen which cannot" ;;
esac

# --- 2. ORDER FLIPS on an ascent -------------------------------------------
# Descending, the user layer is torn down first; coming up, the machine layer
# is restored first so a user hook never addresses a device still powered off.
# A single static listing is therefore wrong for half the edges.
_hook "$VIGILANCE_HOOK_ROOT" wake.d 10-user-only
_hook "$MACH" wake.d 20-machine-too
_d=$("$VIGILANT" plan sleep 2>/dev/null | grep 'act.*session:' || true)
_a=$("$VIGILANT" plan wake  2>/dev/null | grep 'act.*session:' || true)
case "$_d" in
  *"10-user-only 20-machine-too"*) ;;
  *) fail "descent did not list the USER scope first (got: $_d)" ;;
esac
case "$_a" in
  *"20-machine-too 10-user-only"*) ;;
  *) fail "ascent listed the same order as descent (got: $_a). The traversal
reverses, so a plan that does not is telling the reader the restore happens in
an order it never happens in" ;;
esac

# --- 3. A HOOK THE GREETER CANNOT REACH: marked, explained, and non-zero ----
# THE SILENT-BY-CONSTRUCTION FAULT. The symlink is root-owned and resolves
# fine for us; what fails is traversal to the TARGET, three levels up, for a
# uid that is not us.
mkdir -p "$T/private"
printf '#!/bin/sh\nexit 0\n' > "$T/private/real-hook"
chmod +x "$T/private/real-hook"
chmod 700 "$T/private"
mkdir -p "$MACH/sleep.d"
ln -sf "$T/private/real-hook" "$MACH/sleep.d/30-unreachable"
_out=$("$VIGILANT" plan sleep 2>/dev/null) && PLAN_RC=0 || PLAN_RC=$?

[ "$PLAN_RC" != 0 ] || fail "a machine-scope hook the greeter cannot reach was
reported with a clean exit. This is the one fault in the suite that is silent
by construction -- [ -x ] is false for a uid that cannot traverse, so the hook
does not fail, it does not exist -- and a verb that prints it without failing
leaves an integrator exactly as unwarned as before"

case "$_out" in
  *"30-unreachable!"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the unreachable hook was not marked in the listing, so it reads as
something the greeter runs" ;;
esac
case "$_out" in
  *"UNREACHABLE BY THE GREETER"*) ;;
  *) fail "no explanation section for the unreachable hook" ;;
esac
# THE PRECONDITION, asserted: it must be blocked at $T/private, not at some
# ancestor. If the fixture were unreachable higher up, this case would pass
# while proving nothing about per-component walking -- and case 4 would fail.
case "$_out" in
  *"blocked at $T/private"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the report did not name $T/private as the blocking component. It
must name the DIRECTORY that denies traversal, because that is what has to be
changed -- naming only the hook sends the reader to fix a symlink that is
already correct" ;;
esac

# --- 4. a REACHABLE machine hook is NOT flagged -----------------------------
# Without this, a check that flagged everything would pass case 3 and be
# useless. It is also why $T had to be opened up above.
mkdir -p "$T/open"
printf '#!/bin/sh\nexit 0\n' > "$T/open/real-hook"
chmod +x "$T/open/real-hook"
chmod 755 "$T/open"
ln -sf "$T/open/real-hook" "$MACH/sleep.d/40-reachable"
_out=$("$VIGILANT" plan sleep 2>/dev/null || true)
case "$_out" in
  *"40-reachable!"*) fail "a hook the greeter CAN reach was flagged
unreachable. A check that flags everything reports nothing, and this one would
be switched off within a day of shipping" ;;
esac
rm -f "$MACH/sleep.d/30-unreachable"
_out=$("$VIGILANT" plan sleep 2>/dev/null) && PLAN_RC=0 || PLAN_RC=$?
[ "$PLAN_RC" = 0 ] || fail "with the unreachable hook removed, plan still
exited $PLAN_RC. The non-zero must track the actual finding, or it is noise"
case "$_out" in
  *"UNREACHABLE"*) fail "the explanation section was printed with nothing to
explain" ;;
esac

# --- 5. an ACL grants traversal, and must be believed -----------------------
# Mode bits are not the whole answer. Granting the greeter a named ACL entry is
# exactly how an integrator would deliberately open a path, and a check that
# read only the mode would report that correct setup as broken.
if command -v setfacl >/dev/null 2>&1 \
   && setfacl -m "u:$GREETER:x" "$T/private" 2>/dev/null; then
  ln -sf "$T/private/real-hook" "$MACH/sleep.d/30-unreachable"
  # The FILE needs to be readable/executable too, not just the directory.
  setfacl -m "u:$GREETER:rx" "$T/private/real-hook" 2>/dev/null || true
  _out=$("$VIGILANT" plan sleep 2>/dev/null || true)
  case "$_out" in
    *"30-unreachable!"*) fail "a path opened to the greeter by ACL was still
reported unreachable. Reading the mode bits alone calls a correct, deliberate
grant a fault -- and the fix it implies (loosen the mode) is worse than what
the operator already did" ;;
  esac
  setfacl -b "$T/private" 2>/dev/null || true
  rm -f "$MACH/sleep.d/30-unreachable"
fi

# --- 6. NO GREETER ACCOUNT: say so, do not guess ----------------------------
# On a box with no greeter there is nothing to be unreachable by, and inventing
# either verdict would be worse than declining.
_out=$(VIGILANCE_GREETER_USER=no-such-greeter-acct "$VIGILANT" plan sleep \
       2>/dev/null) && PLAN_RC=0 || PLAN_RC=$?
[ "$PLAN_RC" = 0 ] || fail "plan failed on a box with no greeter account"
case "$_out" in
  *"no no-such-greeter-acct account here"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with no greeter account, plan did not say that reachability was NOT
checked. Silence there reads as 'checked and clean', which is the conflation
this entire verb exists to break" ;;
esac

# --- 7. cross-cutting tiers are not listed under an edge --------------------
# `.audit` was once in KINDS, so a hook in <edge>.audit.d read as WIRED while
# cmd_audit reads plain audit.d and would never have run it. Listing audit
# under an edge here would re-teach exactly that wrong model.
_hook "$VIGILANCE_HOOK_ROOT" audit.d 10-source
_out=$("$VIGILANT" plan sleep 2>/dev/null || true)
case "$_out" in
  *"cross-cutting (not per-edge)"*) ;;
  *) fail "the cross-cutting tiers were not listed apart from the edges" ;;
esac
_s=$(printf '%s\n' "$_out" | sed -n '/^sleep /,/^cross-cutting/p')
case "$_s" in
  *10-source*) fail "an audit.d hook was listed under the sleep edge. audit is
cross-cutting -- the hook names its own edge in its output, which is why it is
not keyed by one -- and showing it under an edge teaches the model that put a
hook in <edge>.audit.d where nothing would ever run it" ;;
esac

# --- 8. IT ACTUATES NOTHING -------------------------------------------------
# A planning verb that moved the machine would be the worst possible bug in a
# tool whose job is to be safe to run while wondering what is wired.
go lock
# The DEPTH and the LOG, not the whole of `status`: that carries a "since Ns
# ago" field which ticks on its own, so comparing it whole fails for a reason
# that has nothing to do with the claim -- and a test that fails on a clock is
# one that gets deleted rather than read.
_before=$("$VIGILANT" status 2>/dev/null | grep '^depth:' || true)
_lbefore=$(wc -l < "$VIGILANCE_LOG" 2>/dev/null | tr -d ' ')
"$VIGILANT" plan >/dev/null 2>&1 || true
_after=$("$VIGILANT" status 2>/dev/null | grep '^depth:' || true)
_lafter=$(wc -l < "$VIGILANCE_LOG" 2>/dev/null | tr -d ' ')
[ "$_before" = "$_after" ] || fail "plan moved the machine
(before: $_before / after: $_after). It is offline by contract"
[ "$_lbefore" = "$_lafter" ] || fail "plan wrote $(( _lafter - _lbefore ))
log records. It runs no hook and crosses no edge, so it must leave the forensic
record untouched -- an offline verb that logs pollutes the audit tier that
reads it"

# --- 9. THE WIRING FINGERPRINT ---------------------------------------------
# Two boxes diverging silently is documented history here, not a worry: the
# shared rules file ran at 124 lines on one machine and 145 on the other,
# undetected, and the missing block contained a hard rule. Nothing has ever
# compared the wiring, which is assembled per box by an integrator.
_fp() { "$VIGILANT" plan 2>/dev/null | sed -n 's/^wiring fingerprint: //p'; }

_a=$(_fp)
[ -n "$_a" ] || fail "plan emitted no wiring fingerprint"
[ "$_a" = "$(_fp)" ] || fail "the fingerprint changed between two runs of the
SAME wiring. An unstable one compares unequal for boxes that agree, which is
worse than none: it trains you to ignore the difference"

# A NEW HOOK MUST MOVE IT, or it certifies agreement it never checked.
_hook "$MACH" sleep.d 90-extra
_b=$(_fp)
[ "$_a" != "$_b" ] || fail "adding a wired hook did not change the
fingerprint. It would report two differently-wired boxes as identical"

# THE SHARPEST CASE: same hook NAME, different TARGET. Two boxes agreeing on
# the name of a hook that points at different code is exactly the drift worth
# catching, and it is the shape the shadowed /usr/local binaries took -- the
# name was right on both and one resolved to a stale copy.
ln -sf "$T/open/real-hook" "$MACH/sleep.d/90-extra"
_c=$(_fp)
[ "$_b" != "$_c" ] || fail "repointing a hook at different code left the
fingerprint unchanged. Name-only comparison is what let a stale system copy
shadow the live one while every check agreed the wiring was correct"
rm -f "$MACH/sleep.d/90-extra"
[ "$(_fp)" = "$_a" ] || fail "removing the extra hook did not restore the
original fingerprint; it is order- or history-dependent rather than canonical"

# NOT emitted for a single edge: a fingerprint over the edges you happened to
# ask about would compare unequal for two boxes that agree entirely.
case "$("$VIGILANT" plan sleep 2>/dev/null || true)" in
  *"wiring fingerprint"*) fail "a single-edge plan emitted a fingerprint. It
covers only what was asked for, so comparing two of them says nothing about
whether the boxes agree" ;;
esac

pass
