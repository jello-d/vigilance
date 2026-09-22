#!/bin/sh
# test/tools.t - every shipped script parses under its own shell (the shebang
# picks sh vs bash; smart-lock uses bash arrays). Catches a syntax
# regression before it ships.
. "$(dirname "$0")/lib.sh"
harness_init tools

# The shipped HOOKS and their shared lib are swept too: they are as shipped as
# anything in bin/, and a hook with a syntax error fails at an edge crossing,
# which is the worst possible moment to find out.
_bad=0
for _f in "$HERE"/bin/* "$HERE"/setup.sh \
          "$HERE"/libexec/vigilance/hooklib.sh \
          "$HERE"/libexec/vigilance/hooks/*; do
  [ -f "$_f" ] || continue
  case "$(head -1 "$_f")" in
    *bash)
      if command -v bash >/dev/null 2>&1; then
        bash -n "$_f" 2>/dev/null || { echo "  syntax: $_f" >&2; _bad=1; }
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
# behaved the same -- which is exactly why nothing noticed, and why a later fix
# to the adapter did nothing at all on a live box.
#
# `dash -n` cannot see this: two definitions are perfectly valid shell.
_dupes=
for _f in "$HERE"/bin/* "$HERE"/libexec/vigilance/hooklib.sh \
          "$HERE"/libexec/vigilance/hooks/* \
          "$HERE"/libexec/vigilance/providers/*; do
  [ -f "$_f" ] || continue
  _d=$(grep -oE '^[_a-zA-Z][_a-zA-Z0-9]*\(\)' "$_f" | sort | uniq -d)
  [ -n "$_d" ] && _dupes="$_dupes $(basename "$_f"):$(echo $_d | tr ' ' ',')"
done
[ -z "$_dupes" ] || fail "function(s) defined twice in one file:$_dupes

The later definition wins and the earlier is dead code. A refactor that leaves
the old body behind passes every test -- the shadowing copy behaves the same --
right up until someone fixes the copy that is never called."

pass "$(ls "$HERE"/bin | wc -l | tr -d ' ') tools + $(ls \
  "$HERE"/libexec/vigilance/hooks | wc -l | tr -d ' ') hooks + setup.sh parse"
