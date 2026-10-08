#!/bin/sh
# test/claims.t - documentation is a CLAIM, and a claim nothing checks rots.
#
# This project's second-largest bug class, after probes reading the live box, is
# prose that describes behaviour the code does not have. Every one of these was
# real, and every one survived because nothing compared the two:
#
#   "vigilant check: wiring audit"   three documents said it; the code was a
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
. "$(dirname "$0")/harness_lib"
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
# not at one that starts with it: the closing quote is at the end of the last
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
_plug="$HERE/libexec"
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
  grep -qE "^#  +$_c  " "$V" \
    || fail "exit code $_c is not documented in vigilant's own header"
  awk '/^\.SH EXIT STATUS/,/^\.SH FILES/' "$M" | grep -q "^\.B $_c\$" \
    || fail "exit code $_c is documented in the code but not in the man page"
done

# --- AND EVERY HOOK EXIT VALUE REACHES THE README ---------------------------
# The general form of a gap that shipped. The README taught 78 carefully, in
# the very section a third-party hook author reads before writing one, and said
# nothing at all about 75. A hook that wants to defer then gets written to
# `exit 0`, which claims work it did not do: the exact conflation the contract
# exists to break, arriving in the docs rather than the code.
#
# THE MAN PAGE WAS ALREADY FORCED and the README never was. Every KNOB had to
# appear in one or the other (below), and the exit codes in the man page and the
# header, so the front door of a public repo was the one surface nothing
# checked. Both are required here because they answer different readers: the man
# page is the reference, the README is what someone reads before writing a hook.
#
# DERIVED FROM THE CONSTANTS rather than listed. A check with a hardcoded
# subject cannot see the value nobody thought to add, which is the only kind of
# gap worth having a check for, and this one was found by a list of four.
#
# What it cannot judge is whether the explanation is any good; the BOLD is the
# convention both entries use, so it distinguishes a value presented as a code
# from a number that happens to appear in a measurement.
for _hc in $(sed -n 's/^HOOK_[A-Z]*=\([0-9]*\)$/\1/p' "$V"); do
  awk '/^\.SH EXIT STATUS/,/^\.SH FILES/' "$M" | grep -q "^\.B $_hc\$" \
    || fail "$_hc is a named exit value in the runner and is missing from the
man page's EXIT STATUS section. A hook author reading the reference for the
contract they are implementing has to find every value in it."
  grep -q "\*\*$_hc\*\*" "$R" \
    || fail "$_hc is a named exit value in the runner and the README never
mentions it as one. That is the surface an outside integrator reads before
writing a hook, and a contract taught by halves is one they will implement by
halves: the value they were never told about becomes exit 0, which claims work
that did not happen."
done

# --- EVERY KNOB IS DOCUMENTED ----------------------------------------------
# An audit counted 41 VIGILANCE_* knobs and found 29 of them documented
# nowhere. The extension points existed and were not discoverable, which for a
# package claiming "ship the 80 percent, dial in the rest" is the gap that
# matters most: a dial nobody can find is not a dial.
#
# A ratchet rather than a one-time sweep, because the doc was never wrong on
# purpose: knobs arrive one at a time with the feature that needs them, and
# nothing asked. This is what asks.
_undoc=
for _k in $(grep -ohE 'VIGILANCE_[A-Z_]+' "$HERE"/bin/* \
              "$HERE"/lib/hook_lib \
              "$HERE"/libexec/hooks/* \
              "$HERE"/libexec/providers/* 2>/dev/null | sort -u); do
  grep -qE "\b$_k\b" "$M" "$HERE/README.md" 2>/dev/null || _undoc="$_undoc $_k"
done
[ -z "$_undoc" ] || fail "knob(s) referenced in code and documented nowhere:
$_undoc

Every VIGILANCE_* name has to appear in the man page or the README. A knob is a
promise that something is adjustable, and one nobody can find is a promise to
whoever reads the source and nobody else."

# AND THE OTHER DIRECTION, which nothing asked until now. The check above is
# code -> docs; this is docs -> code, and a knob that was renamed or removed
# leaves behind a documented name nothing reads. That is worse than an
# undocumented one: it is a promise that something is adjustable when turning
# it has no effect at all, and the reader has no way to tell from the page.
#
# ZERO TODAY, measured before writing this, so it is a ratchet rather than a
# sweep. The precedent is directly below: THEORY.md naming a test that no
# longer exists is the same shape, a dead reference that reads as substance.
_orphan=
for _k in $(grep -ohE 'VIGILANCE_[A-Z0-9_]+' "$M" "$HERE/README.md" \
            2>/dev/null | sort -u); do
  grep -rqE "\b$_k\b" "$HERE"/bin "$HERE"/lib "$HERE"/libexec \
    "$HERE"/setup.sh "$HERE"/systemd 2>/dev/null || _orphan="$_orphan $_k"
done
[ -z "$_orphan" ] || fail "knob(s) DOCUMENTED but absent from the code:$_orphan

A documented name nothing reads is a promise that setting it does something.
Either the knob was removed and the page did not follow, or it was renamed and
only one side moved. Both leave a reader turning a dial wired to nothing."

# --- EVERY SHIPPED VIGILANCE_SOURCE VALUE IS DOCUMENTED, BOTH WAYS ---------
# The vocabulary is OPEN by design: vigilant never branches on the value, so an
# integrator names their own gestures and nothing in the framework learns them.
# What CAN be checked, and is the half that rotted, is the list of what the
# SHIPPED callers set.
#
# MEASURED WHEN THIS WAS WRITTEN, against a list in prose that had been carried
# for weeks: it named `lid`, which nothing has ever emitted (a lid close
# arrives as a logind Session.Lock and cannot be told apart), while omitting
# SIX values the tree really sets. Wrong in both directions at once, which is
# why both directions are asserted. A reader grepping the log for `src=lid`
# finds nothing and cannot tell a missing feature from a wrong page.
#
# Extracted through the .TP structure rather than by matching `.B` lines: that
# section's prose legitimately bolds `open`, `sleep`, `idle`, `unset` and a
# character class, and a looser pattern would quietly take those as vocabulary.
_wa=$(awk '/^\.SS WHO ASKED/ { s = 1; next } s && /^\.SS/ { exit }
           s && p { print; p = 0 } s && /^\.TP$/ { p = 1 }' "$M" \
      | sed -n 's/^\.B  *//p' | sed 's/\\-/-/g' | sort -u)
[ -n "$_wa" ] || fail "the man page has no WHO ASKED vocabulary section, so
nothing documents what src= in a crossing record can say"

_srcbad=
for _s in $(grep -rhoE 'VIGILANCE_SOURCE=[a-z0-9-]+' "$HERE"/bin "$HERE"/lib \
              "$HERE"/libexec "$HERE"/systemd 2>/dev/null \
            | sed 's/.*=//' | sort -u); do
  printf '%s\n' "$_wa" | grep -qxF "$_s" || _srcbad="$_srcbad $_s"
done
[ -z "$_srcbad" ] || fail "source(s) SET by shipped code and documented
nowhere:$_srcbad

Every value the shipped tree puts in VIGILANCE_SOURCE has to appear in the man
page's WHO ASKED list. That list is what a human reads to interpret a src=
field in the log, and the questions it exists to answer (why did my screen go
dark, why did it come back) cannot be answered from a value nothing explains."

# AND THE REVERSE, which needs the three ORIGINS of a value told apart, and
# this check found that out by firing on a correct page:
#
#   the RUNNER synthesises   unset, invalid. No caller sets them, and they are
#                            the two answers the page most needs to explain.
#   this PACKAGE sets        everything the loop above derives from the tree.
#   an INTEGRATOR sets       manual. There is no keybind in this package: a
#                            human asking is a gesture only a host can wire,
#                            and phantom-guard's whole reason for existing is
#                            to allow that one while debouncing idle. So it is
#                            vocabulary, documented here, emitted elsewhere.
#
# The exemption is a LIST rather than a loose pattern so adding to it is a
# deliberate act: an integrator value is exactly where a typo would otherwise
# never be caught, since nothing in this tree can confirm the spelling.
_srcorphan=
for _s in $(printf '%s\n' "$_wa"); do
  case "$_s" in unset|invalid|manual) continue ;; esac
  grep -rqF "VIGILANCE_SOURCE=$_s" "$HERE"/bin "$HERE"/lib "$HERE"/libexec \
    "$HERE"/systemd 2>/dev/null || _srcorphan="$_srcorphan $_s"
done
[ -z "$_srcorphan" ] || fail "source(s) DOCUMENTED but emitted by
nothing:$_srcorphan

This is how 'lid' survived for weeks: a gesture we expected to be able to
distinguish, written down as though we could. A documented source nothing sets
sends a reader looking through the log for a record that cannot exist.
If an INTEGRATOR rather than this package emits it, add it to the exemption
list above with the reason, as 'manual' is."

# --- THEORY.md NAMES THE CHECK THAT ENFORCES EACH INVARIANT ----------------
# The whole value of that map is that it lets a reader go and READ the check,
# and separates the invariants that are enforced from the ones that are only
# hoped for. A renamed or deleted test turns an entry into a dead reference,
# and a dead reference is worse than a blank: it reads as coverage.
#
# Only the existence of the file is asserted. Whether it still checks what the
# table says is a judgement no grep can make, and claiming otherwise here would
# be the same false confidence the document is about.
_gone=
for _t in $(grep -ohE '\b[a-z][a-z0-9-]+\.t\b' "$HERE/THEORY.md" | sort -u); do
  [ -f "$HERE/test/$_t" ] || _gone="$_gone $_t"
done
[ -z "$_gone" ] || fail "THEORY.md names test(s) that no longer exist:$_gone

The invariant map is the only place that says which check enforces which
promise. An entry pointing at nothing reads as enforcement and is not."

pass
