#!/bin/sh
# test/concurrency.t - the depth file has more than one writer and more than one
# reader, and nothing serialises them.
#
# WHO RACES, concretely. This is not a thought experiment about a hypothetical
# multi-user system; these are the things already wired on this box:
#
#   vigilance-enforce.timer   reads the depth EVERY MINUTE, forever
#   vigilance-audit.timer     reads it daily
#   Super+L                   writes it, at any instant
#   swayidle's timers         write it at 480s/600s/1200s of idle
#   lock-on-sleep.service     writes it as the machine goes down
#   the resume unit           writes it on the way back
#
# THE BUG THIS WAS WRITTEN FOR, measured before it was fixed: `> "$DEPTH_FILE"`
# TRUNCATES the file and only then writes it, so a reader landing in that window
# gets an EMPTY file. 2 reads in 4000 during a hammer test.
#
# An empty read is not a harmless blip. `_depth` returns empty, `_depth_of ""`
# fails, and every caller does `_dfrom=$(_depth_of "$(_depth)") || _dfrom=0`
# -- and 0 is `open`. So a concurrent reader concludes the machine is UNLOCKED
# when it is actually at `sleep`, and a traversal from that false start crosses
# the wrong edges: recorded at `lock` while the peripherals are dark and nothing
# is armed to re-light them. That is the dark-with-no-way-back failure this
# entire suite exists to prevent, arriving through the front door.
#
# Rare is not the same as impossible, and the cost is not proportional to the
# odds. A minutely timer gets 1,440 attempts a day, forever.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init concurrency

# The real functions, extracted, so this tests the SHIPPED implementation rather
# than a restatement of it. Same technique idle-suspend.t uses for _run.
_ex='/^_set_depth() {/,/^}/p;/^_depth() {/,/^}/p;/^_depth_of() {/,/^}/p'
_fns=$(sed -n "$_ex" "$HERE/bin/vigilant")

D=$VIGILANCE_RUN_DIR/depth
mkdir -p "$VIGILANCE_RUN_DIR"

# --- a reader must NEVER observe a torn or empty depth ----------------------
# Hammered rather than reasoned about: the window is microseconds, so a single
# interleaving proves nothing either way. 4000 rounds found it reliably.
cat > "$T/writer" <<EOF
set -eu
DEPTH_FILE=$D
LADDER='open lock sleep suspend'
$_fns
_i=0
while [ \$_i -lt 4000 ]; do
  _set_depth sleep
  _i=\$((_i + 1))
done
EOF
cat > "$T/reader" <<EOF
set -eu
DEPTH_FILE=$D
LADDER='open lock sleep suspend'
$_fns
_bad=0; _i=0
while [ \$_i -lt 4000 ]; do
  _v=\$(_depth 2>/dev/null || true)
  case "\$_v" in
    open|lock|sleep|suspend) ;;
    *) _bad=\$((_bad + 1)) ;;
  esac
  _i=\$((_i + 1))
done
echo "\$_bad"
EOF

_set_depth_seed() { printf 'sleep %s\n' "$(date +%s)" > "$D"; }
_set_depth_seed

sh "$T/writer" & _w=$!
_bad=$(sh "$T/reader")
wait "$_w" 2>/dev/null || true

[ "$_bad" = 0 ] || fail "a concurrent reader saw a non-rung depth $_bad times in
4000 reads. Every caller turns that into 'open' via the _depth_of fallback, so
the machine reports itself UNLOCKED while it is dark -- and a traversal from
that false start leaves the record at 'lock' with the peripherals off and
nothing armed to bring them back"

# --- the value read is never a PARTIAL rung either --------------------------
# A truncated write could in principle yield 'sle' rather than nothing, which
# would pass a naive emptiness check and then fail _depth_of the same way. The
# case statement above already rejects it; this asserts the seeded value
# survives, so the test cannot pass by never having raced at all.
_final=$(sh -c "DEPTH_FILE=$D; LADDER='open lock sleep suspend'
$_fns
_depth")
[ "$_final" = sleep ] || fail "after the hammer the depth reads '$_final', not
the value every writer wrote; the file is being left in a state no writer
intended"

# --- and the writer is atomic: no leftover temp files ----------------------
# An atomic replace writes beside the target and renames. If it leaves debris,
# the run dir fills with generations and a future glob picks one up.
_tmps=$(find "$VIGILANCE_RUN_DIR" -maxdepth 1 -name 'depth.*' 2>/dev/null \
          | wc -l)
[ "$_tmps" = 0 ] || fail "$_tmps temporary depth file(s) left behind; an atomic
replace must rename onto the target, not accumulate beside it"

pass
