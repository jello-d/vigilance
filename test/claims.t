#!/bin/sh
# test/claims.t - documentation is a CLAIM, and a claim nothing checks rots.
#
# This project's second-largest bug class, after probes reading the live box, is
# prose that describes behaviour the code does not have. Every one of these was
# real, and every one survived because nothing compared the two:
#
#   "vigilant check -- wiring audit"   three documents said it; the code was a
#                                      stub aliased to `status`
#   "SIX HOOK KINDS"                   stayed six for a whole refactor after
#                                      audit.d made it seven
#   "audit covers it"                  due and enforce told the reader the
#                                      forensic tier watched idle-anchored
#                                      edges; no source for them existed
#   "@HOME@, NOT %h"                   a comment describing the fix sat above
#                                      an ExecStart that still used %h
#   the `vigilant` group               declared REQUIRED in setup.sh's header,
#                                      verified by nothing, so on a real box
#                                      every peripheral write was denied while
#                                      the log showed clean crossings
#
# A comment cannot be executed, so the honest move is to assert the small set of
# claims that ARE mechanical: counts, inventories and name parity. Those are
# exactly the ones that drifted.
#
# This does not police prose. It polices claims with a checkable referent.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init claims

R=$HERE/README.md
M=$HERE/man/man1/vigilance.1
V=$HERE/bin/vigilant

# --- the HOOK KIND COUNT, which drifted for an entire refactor --------------
# Five per-edge kinds in KINDS, plus the two CROSS-CUTTING tiers (audit.d and
# alert.d) that are deliberately not in it. Derived, not restated, so adding a
# kind fails this until the prose is updated.
_per_edge=$(grep -m1 '^KINDS=' "$V" | cut -d= -f2- | tr -d '"' | wc -w)
_total=$((_per_edge + 2))
case "$_total" in
  5) _word=Five ;; 6) _word=Six ;; 7) _word=Seven ;; 8) _word=Eight ;;
  *) fail "unexpected hook-kind total $_total; teach this test the word" ;;
esac
grep -q "^## $_word hook kinds" "$R" \
  || fail "README says '$(grep -oE '^## [A-Z][a-z]+ hook kinds' "$R")' but the
code has $_per_edge per-edge kinds plus audit.d and alert.d = $_total. That
exact drift sat in the README for a whole refactor after audit.d landed"
grep -q "^$_word kinds" "$M" \
  || fail "the man page disagrees with the code on the kind count ($_total)"

# --- the LADDER: every rung in the code is documented -----------------------
# The rungs ARE the vocabulary. A rung the docs do not mention is one a reader
# cannot ask for.
# FROM THE TABLE, which is where the rungs are declared now. `LADDER` is
# derived from it at runtime, so grepping that line reads an awk expression
# rather than a list of rungs.
# FROM THE TABLE, which is where the rungs are declared now. `LADDER` is
# derived from it at runtime, so grepping that line reads an awk expression
# instead of a list of rungs. The range ends at the line that CLOSES the quote,
# not at one that starts with it -- the closing quote is at the end of the last
# row, so anchoring at the start swept up every comment that followed.
_rungs=$(sed -n "/^LADDER_TABLE=/,/'\$/p" "$V" \
         | sed "s/^LADDER_TABLE='//; s/'\$//" | awk 'NF { print $1 }')
for _r in $_rungs; do
  grep -q "^    $_r " "$R" || grep -q "^\.B $_r\$" "$M" \
    || fail "rung '$_r' is in LADDER but neither the README ladder table nor
the man page documents it"
done

# --- every VERB in the dispatch is documented -------------------------------
# `check` is the exception and is asserted the other way round: it must NOT be
# presented as a working verb, because three documents once said it was.
_verbs=$(awk '/^_sub=/,/^esac$/' "$V" \
         | grep -oE '^  [a-z][a-z|-]*\)' | tr -d ' )' | tr '|' '\n' \
         | grep -vE '^(-h|--help|help|check)$')
for _v in $_verbs; do
  grep -q "\b$_v\b" "$M" \
    || fail "dispatch has the verb '$_v' and the man page never mentions it"
  grep -q "vigilant $_v\b" "$R" \
    || fail "dispatch has the verb '$_v' and the README's command list omits it"
done
grep -q 'vigilant check' "$M" \
  && fail "the man page presents 'check' as a verb; it is deliberately NOT one
(the wiring audit is setup.sh check) and saying otherwise is the original sin
this whole file exists to prevent" || :

# --- every SHIPPED PLUGIN is in the README inventory ------------------------
# A plugin nobody documents is one an integrator never wires. swayidle-due
# shipped undocumented and was invisible until a sweep found it.
_plug="$HERE/libexec/vigilance"
for _p in "$_plug"/hooks/* "$_plug"/providers/* "$_plug"/triggers/*; do
  [ -f "$_p" ] || continue
  _n=$(basename "$_p")
  grep -q "$_n" "$R" || fail "plugin '$_n' ships but the README inventory does
not name it, so nobody wiring this package would know it exists"
done

# --- every UNIT is documented ------------------------------------------------
# With one principled exception: the .service half of a documented .timer is an
# implementation detail of that timer, not a separate thing to wire.
for _u in "$HERE"/systemd/*; do
  _n=$(basename "$_u")
  if grep -q "$_n" "$M" || grep -q "$_n" "$R"; then continue; fi
  case "$_n" in
    *.service)
      _t=${_n%.service}.timer
      if [ -f "$HERE/systemd/$_t" ] \
         && { grep -q "$_t" "$M" || grep -q "$_t" "$R"; }; then
        continue
      fi ;;
  esac
  fail "unit '$_n' ships and neither the man page nor the README mentions it.
Six units were undocumented at once before this check existed"
done

# --- the EXIT CODE contract appears in both the code header and the man -----
# Units branch on these. The header calls them a contract; a contract documented
# in only one place is one a caller can read the wrong version of.
for _c in 0 1 2 3; do
  grep -qE "^#   $_c  " "$V" \
    || fail "exit code $_c is not documented in vigilant's own header"
  awk '/^\.SH EXIT STATUS/,/^\.SH FILES/' "$M" | grep -q "^\.B $_c\$" \
    || fail "exit code $_c is documented in the code but not in the man page"
done

# --- EVERY KNOB IS DOCUMENTED ----------------------------------------------
# An audit counted 41 VIGILANCE_* knobs and found 29 of them documented
# nowhere. The extension points existed and were not discoverable, which for a
# package claiming "ship the 80 percent, dial in the rest" is the gap that
# matters most -- a dial nobody can find is not a dial.
#
# A ratchet rather than a one-time sweep, because the doc was never wrong on
# purpose: knobs arrive one at a time with the feature that needs them, and
# nothing asked. This is what asks.
_undoc=
for _k in $(grep -ohE 'VIGILANCE_[A-Z_]+' "$HERE"/bin/* \
              "$HERE"/libexec/vigilance/hooklib.sh \
              "$HERE"/libexec/vigilance/hooks/* \
              "$HERE"/libexec/vigilance/providers/* 2>/dev/null | sort -u); do
  grep -qE "\b$_k\b" "$M" "$HERE/README.md" 2>/dev/null || _undoc="$_undoc $_k"
done
[ -z "$_undoc" ] || fail "knob(s) referenced in code and documented nowhere:
$_undoc

Every VIGILANCE_* name has to appear in the man page or the README. A knob is a
promise that something is adjustable, and one nobody can find is a promise to
whoever reads the source and nobody else."

pass
