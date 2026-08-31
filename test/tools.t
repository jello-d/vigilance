#!/bin/sh
# test/tools.t - every shipped script parses under its own shell (the shebang
# picks sh vs bash; smart-lock uses bash arrays). Catches a syntax
# regression before it ships.
. "$(dirname "$0")/lib.sh"
harness_init tools

_bad=0
for _f in "$HERE"/bin/* "$HERE"/setup.sh; do
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
pass "$(ls "$HERE"/bin | wc -l | tr -d ' ') tools + setup.sh parse"
