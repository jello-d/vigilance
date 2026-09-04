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
pass "$(ls "$HERE"/bin | wc -l | tr -d ' ') tools + $(ls \
  "$HERE"/libexec/vigilance/hooks | wc -l | tr -d ' ') hooks + setup.sh parse"
