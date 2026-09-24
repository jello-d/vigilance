#!/bin/sh
# test/faults.t - the fault space must stay well-formed, and stay honest.
#
# test/faults is a DENOMINATOR. Its value is entirely in being complete and
# current: a declared fault whose scenario was renamed away reads as covered
# and is not, which is worse than an empty cell because it removes the prompt
# to go and write one.
#
# WHAT THIS CANNOT CHECK, said plainly: whether a named scenario actually
# injects the fault it is claimed against. No grep can know that. So this
# asserts the cheap, mechanical things -- the shape of every record, that every
# named test exists, that the space has not quietly shrunk -- and REPORTS the
# coverage rather than asserting a number, because a coverage ratchet would
# reward adding tests over adding faults, and the faults nobody has thought of
# are the ones worth knowing about.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init faults

F=$HERE/test/faults
[ -r "$F" ] || fail "no fault declaration at $F"

_n=0; _cov=0; _bad=; _gone=
_id=; _m=; _f=; _e=; _t=

_check() {
  [ -n "$_id" ] || return 0
  for _k in m f e t; do
    eval "_v=\$_$_k"
    [ -n "$_v" ] || _bad="$_bad $_id(no-$_k)"
  done
  _n=$((_n + 1))
  case "$_t" in
    -) ;;
    *) _cov=$((_cov + 1))
       [ -f "$HERE/test/$_t.t" ] || _gone="$_gone $_id(->$_t)" ;;
  esac
  # THE RESPONSE MUST COME FROM THE VOCABULARY. "it survived" is not a
  # response, and free text here is how a cell stops making a claim.
  case "$_e" in
    ACT:*|ALERT:*|DEGRADE:*|RECOVER:*|REFUSE:*) ;;
    *) _bad="$_bad $_id(response-not-in-vocabulary)" ;;
  esac
  _m=; _f=; _e=; _t=
}

while IFS= read -r _line; do
  case "$_line" in
    '= '*) _check; _id=${_line#??} ;;
    'm '*) _m=${_line#??} ;;
    'f '*) _f=${_line#??} ;;
    'e '*) _e=${_line#??} ;;
    't '*) _t=${_line#??} ;;
  esac
done < "$F"
_check

[ -z "$_bad" ] || fail "malformed fault record(s):$_bad

Every record needs a mechanism, a fault, an expected response drawn from
ACT/ALERT/DEGRADE/RECOVER/REFUSE, and a test or an explicit '-'."

[ -z "$_gone" ] || fail "fault(s) naming a scenario that no longer exists:$_gone

A declared fault pointing at a missing test reads as covered and is not, which
is worse than an empty cell: it removes the prompt to write one."

# A SPACE THAT EMPTIED WOULD VALIDATE PERFECTLY, the same hole test/mutants
# guards against. It held 20 faults when written.
[ "$_n" -ge 15 ] || fail "the fault space holds only $_n records; it covered 20
when written, so this has lost ground rather than gained it"

pass "$_cov of $_n faults exercised"
