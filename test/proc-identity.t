#!/bin/sh
# test/proc-identity.t - asking whether a process of a given name is running,
# when the name was handed to us by a knob.
#
# TWO DEFECTS, BOTH MEASURED, AND THEY FAIL IN OPPOSITE DIRECTIONS. Five sites
# passed a knob-supplied name to `pgrep -x`, which is wrong twice over:
#
#   comm IS TRUNCATED TO 15 BYTES by the kernel, so an exact match on a longer
#   name can NEVER succeed. The plausible values are ordinary rather than
#   exotic: xfce4-screensaver (17), gnome-screensaver (17),
#   xfce4-power-manager (19), which on an xfce box genuinely IS the idle daemon,
#   and xfce4-session already Recommends the first of them. That direction cries
#   wolf: a correctly locked box reports no locker, a healthy idle timer reports
#   NOT running, and `_rep_idle_armed` finds no pid and so silently stops
#   checking the armed command at all.
#
#   THE pgrep PATTERN IS AN ERE, NOT A LITERAL. `pgrep -x lock.safe` matches a
#   process named `lockXsafe` and `pgrep -x '.*'` matches EVERY process. That
#   direction is a FALSE GREEN on whether the session is secured, and in
#   lock-blank's `pkill` it is not a reporting fault at all: a pattern matching
#   everything SIGNALS THE WHOLE BOX, and the default action for a realtime
#   signal is to terminate.
#
# THE SIXTH SITE IS WHY THE AUDIT HAD TO BE A CLASS AND NOT A GREP. The first
# sweep searched for `pkill -x` and so missed `pkill -"$_sig" -x "$LOCKER"`,
# where a flag sits in between. That site mattered most: the broken guard
# earlier in the same hook was what made it UNREACHABLE, so fixing the guard
# alone would have converted a silent no-op into a hook-failed alert on the
# sleep edge. One hook covering for another's blind spot, inside one file.
#
# ONE CASE TABLE, TWO IMPLEMENTATIONS. The rule lives in hook_lib for hooks and
# in bin/vigilant for the runner, because a hook cannot source the runner and
# the runner must not source the hook author's API. Two implementations of one
# rule is the shape this package paid to delete once (ddc-monitor's hand-written
# save/restore copy), so the table drives BOTH, exactly as level-rules.t drives
# the three level adapters.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init proc-identity
. "$HERE/lib/hook_lib"

LONG=xfce4-screensaver      # 17 bytes; comm holds xfce4-screensav
SHORT=lockXsafe             # 9 bytes, and an ERE dot in its place matches it
FIX=

# A PROCESS WHOSE comm IS THE NAME WE WANT. A plain script keeps comm from its
# own basename; `exec sleep` does not (comm becomes "sleep"), and a copy of
# coreutils dispatches on argv[0] and exits. Both are recorded traps here.
_spawn() {   # <name>
  printf '#!/bin/sh\nsleep 45\n' > "$T/$1"
  chmod +x "$T/$1"
  "$T/$1" &
  FIX="$FIX $!"
}

# AN INDEPENDENT READER FOR THE PRECONDITION, because waiting for the fixture
# with the function under test is circular: a broken helper would report a
# fixture problem and every case below would pass for the wrong reason. -F is a
# fixed string and -x a whole line, so this agrees with nothing by accident.
_comm_exists() {   # <comm-as-stored>
  grep -lxF "$1" /proc/[0-9]*/comm >/dev/null 2>&1
}

_await() {   # <comm-as-stored>
  _i=0
  while [ "$_i" -lt 60 ]; do
    if _comm_exists "$1"; then return 0; fi
    _i=$((_i + 1)); sleep 0.1
  done
  return 1
}

_spawn "$LONG"
_spawn "$SHORT"
_await xfce4-screensav || fail "the fixture process never appeared, so nothing
below would be a statement about this code. Expected a process whose stored
comm is 'xfce4-screensav' (from a script named $LONG)"
_await "$SHORT" || fail "the second fixture process ($SHORT) never appeared"

# --- 1. THE RUNNER'S TWIN, extracted rather than reimplemented ---------------
# bin/vigilant cannot be sourced: it is a command with a dispatcher and
# top-level work. So the functions come out of it with an awk state machine.
#
# THE EXTRACTION IS ASSERTED BEFORE ANY CASE RUNS. An extraction that silently
# grabbed the wrong lines turns every row below into a statement about nothing,
# and level-rules.t paid for exactly that: five overlapping `sed` ranges printed
# one function twice, all nine cases failed with rc=2, and a table that had
# never run looked like nine broken rules.
RUNNER_FN=$T/runner-fns
awk '
  /^_proc_pids\(\) \{/    { f = 1 }
  /^_proc_running\(\) \{/ { f = 1 }
  f                       { print }
  f && /^\}/              { f = 0 }
' "$HERE/bin/vigilant" > "$RUNNER_FN"

dash -n "$RUNNER_FN" 2>/dev/null || fail "the functions lifted out of
bin/vigilant do not parse, so the extraction is broken rather than the code:
$(cat "$RUNNER_FN")"
for _need in '_proc_pids()' '_proc_running()' '%.15s' '/proc/'; do
  grep -qF "$_need" "$RUNNER_FN" || fail "the extraction from bin/vigilant is
missing '$_need', so it did not lift the functions under test. The truncation
and the /proc read ARE the subject: without them these cases would certify an
implementation that is not the shipped one"
done

# --- 2. ONE TABLE, BOTH IMPLEMENTATIONS -------------------------------------
_drive() {   # <hooklib|runner> <name>
  case $1 in
    hooklib) hook_proc_running "$2" ;;
    runner)  ( . "$RUNNER_FN"; _proc_running "$2" ) ;;
  esac
}

# hit/miss, the name, and why the row is here. A whitespace table cannot carry
# an empty name, so that case is section 3.
CASES="
hit   xfce4-screensaver   17 bytes: comm holds 15, so pgrep -x never matches
hit   xfce4-screensav     the STORED form, and the same process
hit   xfce4-screensaverX  18 bytes sharing the first 15: indistinguishable to
miss  xfce4-screensa      a 14-byte PREFIX: the comparison is EXACT, not a
hit   lockXsafe           an ordinary name, well inside the limit
miss  lock.safe           an ERE dot must NOT match lockXsafe
miss  .*                  an ERE wildcard must NOT match every process
miss  vig-no-such-p       a name no process anywhere can have
"
# THAT LAST ROW SAID `swaylock` AND THAT WAS A VERDICT ABOUT THE DEVELOPER'S
# SCREEN. It passed on the first run and failed on the next, because the box
# locked in between and two real swaylocks appeared: the row's claim is "an
# absent name is a miss", and `swaylock` is only absent when nobody is locked.
# The substrate-reading mistake this suite has paid for four times, arriving in
# the file written to close a class of it. An absent name has to be one that
# cannot exist, not one that usually does not.
_rows=0
while read -r _exp _name _rest; do
  [ -n "${_exp:-}" ] || continue
  _rows=$((_rows + 1))
  for _impl in hooklib runner; do
    if _drive "$_impl" "$_name"; then _got=hit; else _got=miss; fi
    [ "$_got" = "$_exp" ] || fail "the $_impl implementation answered '$_got'
for the name [$_name] where '$_exp' is correct ($_rest). Both implementations
must agree with the table AND with each other: this one is the twin that can
drift"
  done
done <<TABLE
$CASES
TABLE
# A DENOMINATOR, because a table whose rows all got skipped is a green line
# about nothing. The same move test/faults.rec makes for the fault space.
[ "$_rows" -ge 8 ] || fail "only $_rows table rows ran, so most of the cases
were skipped and this file proved almost nothing"

# --- 3. AN EMPTY NAME IS NOT A WILDCARD -------------------------------------
# `pgrep -x ''` happens to return 1 here, so this is not a defect being fixed;
# it is pinned because the new implementation could easily have gone the other
# way. An empty `$_hpn` compared against every comm would match a process whose
# comm is empty, and truncating "" to "" invites it.
for _impl in hooklib runner; do
  if _drive "$_impl" ''; then fail "the $_impl implementation treated an EMPTY
name as a match. At a locked rung that is the false green this whole file is
about: a locker reported up because nobody said what to look for"; fi
done

# --- 4. THE SIGNAL PATH, where a wide match is DESTRUCTIVE -------------------
# lock-blank broadcasts a signal to the locker, and the broadcast is meant to
# reach swaylock's password-backend child too. So "signal everything of that
# name" is correct and "signal everything" is not: the default action for a
# realtime signal is to terminate, which makes an over-wide pattern here a
# box-wide kill rather than a wrong answer.
HITS=$T/hits
cat > "$T/$LONG-sig" <<EOF
#!/bin/sh
trap 'echo hit >> $HITS' USR2
echo ready > $T/sig-ready
_i=0
while [ "\$_i" -lt 300 ]; do _i=\$((_i + 1)); sleep 0.1; done
EOF
chmod +x "$T/$LONG-sig"
# Run it under the LONG name by copying, so comm is the name and not the suffix.
cp "$T/$LONG-sig" "$T/sigdir-$LONG" 2>/dev/null || true
mkdir -p "$T/sigdir"
cp "$T/$LONG-sig" "$T/sigdir/$LONG"
chmod +x "$T/sigdir/$LONG"
"$T/sigdir/$LONG" &
FIX="$FIX $!"
_i=0
while [ ! -f "$T/sig-ready" ] && [ "$_i" -lt 60 ]; do _i=$((_i + 1)); sleep 0.1
done
[ -f "$T/sig-ready" ] || fail "the signal fixture never became ready, so the
cases below would be about a process that is not listening"

hook_proc_signal USR2 "$LONG" || fail "hook_proc_signal could not signal a
process named $LONG that IS running. This is the live defect: pkill -x with a
17-byte name matches nothing, returns non-zero, and lock-blank then exits 1
with a hook-failed alert on the sleep edge, about a locker that is right there"
_i=0
while [ ! -s "$HITS" ] && [ "$_i" -lt 60 ]; do _i=$((_i + 1)); sleep 0.1; done
[ -s "$HITS" ] || fail "hook_proc_signal reported success but the process never
received the signal, so the success was about the enumeration rather than the
delivery"

if hook_proc_signal USR2 '.*'; then fail "an ERE wildcard signalled something.
With pkill this pattern reached EVERY process on the box, and with -RTMIN the
default action is to terminate, so this is the one case in this file where the
wrong answer is destructive rather than merely wrong"; fi

# --- 5. END TO END: the call site, not just the helper ----------------------
# A perfect helper proves nothing if a call site still reaches for pgrep. This
# drives the real `report` against a real process under a long locker name.
#
# VIGILANCE_LOCKER_UP MUST BE UNSET, because scenario_init sets it and the knob
# SHORT-CIRCUITS the probe under test. A knob that replaces the thing being
# measured is how the triggers section nearly shipped untested.
unset VIGILANCE_LOCKER_UP
VIGILANCE_LOCKER=$LONG; export VIGILANCE_LOCKER
hook lock 10-prov           # `lock` needs a provider wired or it declines

_sec() {   # <section>
  "$VIGILANT" report 2>/dev/null \
    | awk -v s="-- $1 --" '$0 == s { f = 1; next } /^-- / { f = 0 } f' || true
}

# A DISCRIMINATING PAIR, which is the whole point of doing it at two rungs. The
# same long name and the same live process must produce OPPOSITE verdicts: a
# probe stuck at "not running" passes the second half, one stuck at "running"
# passes the first, and only a correct one passes both.
_o=$(_sec coherence)
case "$_o" in
  *'locker is UP'*) ;;
  *) fail "at rung 'open' with a locker named $LONG running, coherence must say
a locker is UP and an edge was missed. Reading it as absent is the truncation
defect, and it is the half that cries wolf:
$_o" ;;
esac

go lock
_o=$(_sec coherence)
case "$_o" in
  *'matches a live locker'*) ;;
  *) fail "at rung 'lock' with a locker named $LONG running, coherence must
agree the rung matches. Anything else means report FAILS about a correctly
locked box, once a minute, on the security question:
$_o" ;;
esac

# --- 6. THE RATCHET: no shipped site may hand a name to pgrep/pkill ---------
# A CHECK WITH A HARDCODED SUBJECT CANNOT SEE THE SITE NOBODY THOUGHT TO LIST,
# which is the only kind worth having a check for, and this very audit missed
# lock-blank's `pkill -"$_sig" -x` by grepping for one spelling. So the rule is
# over the TREE and derived from the code rather than from a list.
#
# THE SURVIVING LITERAL CALLS ARE CHECKED, NOT EXEMPTED. Five sites still call
# pgrep/pkill with a hardcoded `swaylock` or `swayidle`, and they are correct
# because those names are 8 bytes and carry no ERE metacharacter. That is a
# property worth asserting rather than a judgement worth trusting: it is exactly
# what stops being true the day somebody renames one.
_viol=$(find "$HERE/bin" "$HERE/libexec" "$HERE/systemd" -type f 2>/dev/null \
  | while read -r _f; do
      awk -v F="${_f#$HERE/}" '
        { line = $0; sub(/^[[:space:]]+/, "", line)
          if (line ~ /^#/) next
          if (line !~ /p(grep|kill)/) next
          rest = line; sub(/.*p(grep|kill)/, "", rest)
          sub(/^[[:space:]]+/, "", rest)
          while (rest ~ /^-[a-zA-Z0-9]+([[:space:]]|$)/) {
            sub(/^-[a-zA-Z0-9]+[[:space:]]*/, "", rest) }
          name = rest; sub(/[[:space:]].*$/, "", name); gsub(/^"|"$/, "", name)
          if (name ~ /\$/) {
            printf "%s:%s a name from a variable: %s\n", F, FNR, name; next }
          if (length(name) > 15) {
            printf "%s:%s literal over 15 bytes: %s\n", F, FNR, name; next }
          # A LITERAL SCAN RATHER THAN A BRACKET EXPRESSION, because gawk 5.3.2
          # REJECTS a leading `]` in one: /[][.]/ is "Unmatched [" there,
          # contrary to POSIX, and a detector that errors out is a detector that
          # reports nothing. index() needs no regex at all.
          meta = "[]().*+?{}|^$\\"
          for (i = 1; i <= length(meta); i++) {
            if (index(name, substr(meta, i, 1)) > 0) {
              printf "%s:%s literal with an ERE metachar: %s\n", F, FNR, name
              break } } }
      ' "$_f"
    done)
[ -z "$_viol" ] || fail "shipped code reaches for pgrep/pkill in a way this
file exists to prevent. A name from a VARIABLE must go through
hook_proc_running / hook_proc_signal (or the runner's _proc_running), and a
literal must be at most 15 bytes with no ERE metacharacter:
$_viol"

# AND THE RATCHET MUST BITE, or it is a green line over an empty scan. Planting
# the defect back is the only thing that proves the detector runs at all: this
# project has shipped two detectors that silently matched nothing.
_probe=$T/ratchet-probe
printf '#!/bin/sh\npgrep -x "$SOME_KNOB" >/dev/null\n' > "$_probe"
_caught=$(awk '
  { line = $0; sub(/^[[:space:]]+/, "", line)
    if (line ~ /^#/) next
    if (line !~ /p(grep|kill)/) next
    rest = line; sub(/.*p(grep|kill)/, "", rest); sub(/^[[:space:]]+/, "", rest)
    while (rest ~ /^-[a-zA-Z0-9]+([[:space:]]|$)/) {
      sub(/^-[a-zA-Z0-9]+[[:space:]]*/, "", rest) }
    name = rest; sub(/[[:space:]].*$/, "", name); gsub(/^"|"$/, "", name)
    if (name ~ /\$/) print "caught" }' "$_probe")
[ "$_caught" = caught ] || fail "the ratchet's own detector did not fire on a
planted \`pgrep -x \"\$SOME_KNOB\"\`, so section 6 passing says nothing about
the tree. A detector that degrades to silence is what the conventions check
exists to catch, and it has happened here twice"

kill $FIX 2>/dev/null || true
pass "truncation and ERE closed in both twins, signal path safe, report agrees"
