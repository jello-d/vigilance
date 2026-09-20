#!/bin/sh
# test/mutants.t - the corpus must still describe THIS code.
#
# `test/mutate` is the real check and it takes ~30s, so it is a separate
# command. This is the cheap half that runs with the suite, and it exists
# because of one specific rot: A MUTATION WHOSE TARGET LINE NO LONGER EXISTS
# LEAVES THE FILE UNTOUCHED. The tests then pass, and "the guard does not bite"
# is what that looks like from outside. That exact mistake has been made three
# times here -- a pattern that never matched, a sed delimiter that clashed with
# `||`, and a search string that had been reworded since.
#
# So the moment someone edits a guarded line, this fails and names the record
# to update. It runs no mutation and executes nothing: it just asserts the
# corpus and the code still agree.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init mutants

CORPUS=$HERE/test/mutants
[ -f "$CORPUS" ] || fail "no mutation corpus at test/mutants"

_n=0
M_N=; M_F=; M_T=; M_O=
_check() {
  [ -n "$M_N" ] || return 0
  _n=$((_n + 1))
  [ -n "$M_F" ] || fail "record '$M_N' names no file"
  [ -n "$M_T" ] || fail "record '$M_N' names no test. A mutation with nothing
to kill it cannot report anything: the corpus would grow while proving less"
  [ -n "$M_O" ] || fail "record '$M_N' has no line to remove"
  [ -f "$HERE/$M_F" ] || fail "record '$M_N' targets $M_F, which does not exist"
  for _t in $M_T; do
    [ -f "$HERE/test/$_t.t" ] \
      || fail "record '$M_N' names test '$_t', which does not exist. A record
naming a deleted test can never kill anything and will report SURVIVED forever"
  done
  # THE LOAD-BEARING ONE. -F is a fixed string and -x is whole-line, so this
  # matches exactly what the driver's awk will match -- no regex, nothing to
  # clash with the `||`, `*` and `$` these lines are full of.
  grep -Fxq -- "$M_O" "$HERE/$M_F" || fail "record '$M_N' wants to remove a
line that is no longer in $M_F:

  [$M_O]

The mutation would leave the file untouched, every named test would pass, and
the driver would report the guard as covered when nothing was changed at all.
Update the record to the line as it reads now."
  M_N=; M_F=; M_T=; M_O=
}

# MALFORMED PREFIXES FIRST, because they fail SILENTLY in the worst direction.
# The format is a two-character prefix, and a code line starting at column 0
# invites writing "-if [ ... ]" instead of "- if [ ... ]". The driver then sees
# no old line at all -- or worse, no NEW line, which turns an intended replace
# into a DELETE: a different mutation than the one written down, possibly still
# valid shell, possibly still killing a test, and wrong about what it proved.
# Four records in this file were written that way.
_bad=$(grep -n '^[-+][^ ]' "$CORPUS" | grep -v '^[0-9]*:--' || true)
[ -z "$_bad" ] || fail "record line(s) missing the space after the prefix:

$_bad

'- x' is a target line; '-x' is not parsed as one at all. A '+' written that
way is worse than a '-': it silently becomes a DELETE instead of a replace."

while IFS= read -r _line; do
  case "$_line" in
    '= '*) _check; M_N=${_line#??} ;;
    'f '*) M_F=${_line#??} ;;
    't '*) M_T=${_line#??} ;;
    '- '*) M_O=${_line#??} ;;
  esac
done < "$CORPUS"
_check

# A corpus that silently emptied would validate perfectly. The suite already
# treats a test that reached no verdict as a failure; same rule here.
[ "$_n" -ge 15 ] || fail "the corpus holds only $_n records. It covered 19
guards when written, so this has lost coverage rather than gained it"

# EVERY GUARDED FILE SHOULD BE ONE THE SUITE ACTUALLY SHIPS. A record pointing
# at a scratch path would validate and never protect anything real.
while IFS= read -r _line; do
  case "$_line" in
    'f '*) case "${_line#??}" in
             bin/*|libexec/*|install|setup.sh) ;;
             *) fail "a record targets '${_line#??}', which is not shipped
code. The corpus must guard what the package installs, not a fixture" ;;
           esac ;;
  esac
done < "$CORPUS"

pass
