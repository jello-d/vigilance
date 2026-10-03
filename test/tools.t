#!/bin/sh
# test/tools.t - every shipped script parses under its own shell (the shebang
# picks sh vs bash; smart-lock uses bash arrays). Catches a syntax
# regression before it ships.
. "$(dirname "$0")/harness_lib"
harness_init tools

# The shipped HOOKS and their shared lib are swept too: they are as shipped as
# anything in bin/, and a hook with a syntax error fails at an edge crossing,
# which is the worst possible moment to find out.
_bad=0
# What could not be checked, named in the verdict rather than left silent.
_vskip=
# test/probe/ IS IN THE LIST, and for a reason already paid for once: the VM
# guest script was shipped code with no syntax check at all, and two
# three-minute boots ended in "guest never reported" over a quoting slip that
# `dash -n` finds in 0.05s. A probe is worse placed to absorb that, because the
# cost of a broken one is somebody's cooperation rather than a rerun.
for _f in "$HERE"/bin/* "$HERE"/setup.sh \
          "$HERE"/libexec/vigilance/hook_lib \
          "$HERE"/libexec/vigilance/hooks/* "$HERE"/test/probe/*; do
  [ -f "$_f" ] || continue
  # DOCUMENTATION IS NOT A SCRIPT. Skipped by extension rather than by dropping
  # non-executable files, because "skip what is not executable" would silently
  # stop checking a hook that lost its mode bit in a copy.
  case "$_f" in *.md) continue ;; esac
  case "$(head -1 "$_f")" in
    *python*)
      # THE FALLBACK BELOW IS `dash -n`, which on a python file reports a syntax
      # error about perfectly good code. Caught the moment test/probe joined the
      # list, by this check failing on its own new subject.
      python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$_f" \
        2>/dev/null || { echo "  syntax: $_f" >&2; _bad=1; } ;;
    *bash)
      # NO SUBJECT TODAY, and the skip is recorded anyway. Nothing shipped
      # carries a bash shebang now (smart-lock and mute-on-lock did, and both
      # were retired), so this arm checks nothing and costs nothing. But it is
      # the one place in this file that could silently STOP checking: add a
      # bash script on a box without bash and its syntax goes unverified while
      # the verdict still reads as a full pass. Naming the skip removes that.
      if command -v bash >/dev/null 2>&1; then
        bash -n "$_f" 2>/dev/null || { echo "  syntax: $_f" >&2; _bad=1; }
      else
        _vskip=" bash (needed by $_f)"
      fi ;;
    *)
      { dash -n "$_f" 2>/dev/null || sh -n "$_f" 2>/dev/null; } \
        || { echo "  syntax: $_f" >&2; _bad=1; } ;;
  esac
done
[ "$_bad" = 0 ] || fail "a shipped script failed its syntax check"
# --- NO SHIPPED SCRIPT DEFINES A FUNCTION TWICE ----------------------------
# A second definition silently WINS and the first becomes dead code. Not
# hypothetical: a refactor split hook_lit into an adapter over a shared
# implementation and left the old body further down the file, so for two days
# the adapter was never called. Every test passed, because the shadowing copy
# behaved the same, which is exactly why nothing noticed, and why a later fix
# to the adapter did nothing at all on a live box.
#
# `dash -n` cannot see this: two definitions are perfectly valid shell.
_dupes=
for _f in "$HERE"/bin/* "$HERE"/libexec/vigilance/hook_lib \
          "$HERE"/libexec/vigilance/hooks/* \
          "$HERE"/libexec/vigilance/providers/*; do
  [ -f "$_f" ] || continue
  _d=$(grep -oE '^[_a-zA-Z][_a-zA-Z0-9]*\(\)' "$_f" | sort | uniq -d)
  [ -n "$_d" ] && _dupes="$_dupes $(basename "$_f"):$(echo $_d | tr ' ' ',')"
done
[ -z "$_dupes" ] || fail "function(s) defined twice in one file:$_dupes

The later definition wins and the earlier is dead code. A refactor that leaves
the old body behind passes every test (the shadowing copy behaves the same)
right up until someone fixes the copy that is never called."

pass "$(ls "$HERE"/bin | wc -l | tr -d ' ') tools + $(ls \
  "$HERE"/libexec/vigilance/hooks | wc -l | tr -d ' ') hooks + setup.sh\
 parse${_vskip:+ (not checked:$_vskip)}"
