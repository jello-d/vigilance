#!/bin/sh
# test/level-rules.t - ONE table of rules, run against EVERY adapter.
#
# WHY THIS FILE EXISTS. The save/restore discipline for any actuator with a
# level worth putting back is four rules, and each was paid for by a live
# defect:
#
#   SAVE ONCE            a second save records the 0 we just set, and restoring
#                        THAT leaves the panel black with the operator convinced
#                        the monitor died.
#   ASSERT EVERY TIME    a save file records that we dimmed, not an observation
#                        that the device is still dim. Trusting it made the
#                        descent a silent no-op that reported success, twice: a
#                        keyboard LED (f08f3a7) and then, three weeks later, the
#                        DDC brightness write (72cd706): the same bug, because
#                        the fix landed in one of two copies.
#   UNREADABLE DROPS     a device that is GONE must lose its stale save, or it
#                        fails every ascent forever and nothing clears it.
#   REFUSED KEEPS        a device that is present and refusing must keep its
#                        save, or the level it has to return to is discarded and
#                        a still-dark panel is stranded.
#
# THE RULES WERE IMPLEMENTED TWICE and that is what this table is for. They now
# live once, in hook_lib's hook_level_dark / hook_level_lit, with the actuator
# supplied by the caller, so the table runs the SAME cases through the generic
# entry point AND through each shipped adapter. A rule that holds for
# brightnessctl and not for DDC is exactly the shape that shipped twice, and it
# cannot be seen by a test that only exercises one.
#
# RUNNING IT THROUGH THE ADAPTERS IS THE POINT, not decoration. Collapsing the
# copies means the adapters are thin, and a thin adapter can still get its half
# wrong: this tool reports an unreadable monitor by printing NOTHING and exiting
# ZERO, while hook_lib's contract is a non-zero level_get. Getting that mapping
# backwards would turn an absent monitor into a hard failure on every edge, and
# no amount of testing the generic implementation would show it.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init level-rules

PLUGINS=$HERE/libexec
HOOKLIB=$HERE/lib/hook_lib
[ -f "$HOOKLIB" ] || fail "no hook_lib at $HOOKLIB"

# --- the table --------------------------------------------------------------
# Each case: a device that can be told to fail on read or on write, a save file
# in a chosen starting state, and the three things that make the rule checkable:
# the exit status, what the save file holds afterwards, and WHETHER THE ACTUATOR
# WAS CALLED. The last one is what catches a silent no-op, and it is the one a
# test asserting only on exit status cannot see.
#
#   name|edge|save-before|get-fails|set-fails|want-rc|want-save|want-writes
#
# `-` means the save file must not exist. want-writes is the value the actuator
# should have been asked for, or `-` for "must not have been called at all".
CASES='
save-once-and-dim|dark|-|0|0|0|42|0
second-descent-re-asserts|dark|42|0|0|0|42|0
absent-device-is-na|dark|-|1|0|0|-|-
refused-write-drops-a-new-save|dark|-|0|1|1|-|0
refused-write-keeps-an-old-save|dark|42|0|1|1|42|0
no-save-means-nobody-dimmed|lit|-|0|0|0|-|-
restore-puts-the-level-back|lit|42|0|0|0|-|42
unreadable-device-drops-the-save|lit|42|1|0|0|-|-
refused-restore-keeps-the-save|lit|42|0|1|1|42|42
'

# --- adapter 1: the generic entry point -------------------------------------
# level_get / level_set supplied directly, which is the contract every other
# adapter is an instance of.
_run_generic() {   # edge save-before get-fails set-fails -> rc, writes in $W
  _sf=$T/save.generic
  rm -f "$_sf"
  [ "$2" = - ] || printf '%s\n' "$2" > "$_sf"
  : > "$W"
  GET_FAILS=$3 SET_FAILS=$4 SF=$_sf SAVE=$_sf sh -c '
    . "'"$HOOKLIB"'"
    level_get() { [ "$GET_FAILS" = 0 ] || return 1; echo 42; }
    level_set() { printf "%s\n" "$1" >> "'"$W"'"
                  [ "$SET_FAILS" = 0 ] || return 1; }
    if [ "'"$1"'" = dark ]; then hook_level_dark "$SF"
    else hook_level_lit "$SF"; fi
  ' 2>>"$T/err"
}
_save_generic() { cat "$T/save.generic" 2>/dev/null || echo -; }

# --- adapter 2: brightnessctl (hook_dark / hook_lit) ------------------------
# The shipped adapter three hooks use. A STUB TOOL, because brightnessctl is an
# ACTUATOR and stubbing one is how you assert what was NOT called; the rules
# under test are not the tool.
#
# AND THE STUB MUST NOT MODEL AN IMPOSSIBLE DEVICE: `set` succeeding while `get`
# fails is something no real device does, and a stub that allowed it once made
# an absent-device check look tested when it was not.
mkdir -p "$T/bin"
cat > "$T/bin/brightnessctl" <<'EOF'
#!/bin/sh
for _a in "$@"; do
  case $_a in
    get) [ "${GET_FAILS:-0}" = 0 ] || exit 1; echo 42; exit 0 ;;
    max) echo 100; exit 0 ;;
    set) shift; ;;
  esac
done
# the last argument of `set N` is the level
eval "_lvl=\${$#}"
printf '%s\n' "$_lvl" >> "$WRITES"
[ "${SET_FAILS:-0}" = 0 ] || exit 1
EOF
chmod +x "$T/bin/brightnessctl"

_run_bctl() {
  _sf=$T/save.bctl
  rm -f "$_sf"
  [ "$2" = - ] || printf '%s\n' "$2" > "$_sf"
  : > "$W"
  PATH="$T/bin:$PATH" WRITES=$W GET_FAILS=$3 SET_FAILS=$4 SF=$_sf sh -c '
    . "'"$HOOKLIB"'"
    if [ "'"$1"'" = dark ]; then hook_dark "$SF"
    else hook_lit "$SF"; fi
  ' 2>>"$T/err"
}
_save_bctl() { cat "$T/save.bctl" 2>/dev/null || echo -; }

# --- adapter 3: ddc-monitor's brightness path ------------------------------
# The copy that drifted. Its functions are pulled out of the SHIPPED FILE rather
# than re-typed, so this cannot test a paraphrase of the hook.
#
# EXTRACTED BY A STATE MACHINE, and the first attempt was wrong in the way this
# repo has been bitten before. Five `sed -n '/^_name()/,/^}/p'` ranges OVERLAP,
# because _bright_save is a ONE-LINER: its range has no `^}` of its own, so it
# ran on to the next function's closing brace and the following range then
# printed that function a second time. The result was a duplicated definition,
# which is not valid shell, so all nine cases failed with rc=2 and a table
# that had not run at all looked like nine broken rules.
cat > "$T/bin/ddcutil" <<'EOF'
#!/bin/sh
case " $* " in
  *" getvcp 10 "*)
    [ "${GET_FAILS:-0}" = 0 ] || exit 0          # prints NOTHING, exits 0
    echo "VCP code 0x10 (Brightness): current value = 42, max value = 100"
    exit 0 ;;
  *" setvcp 10 "*)
    eval "_lvl=\${$#}"
    printf '%s\n' "$_lvl" >> "$WRITES"
    [ "${SET_FAILS:-0}" = 0 ] || exit 1
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/ddcutil"

_run_ddc() {
  _sf=$T/state/bright-9
  mkdir -p "$T/state"
  rm -f "$_sf"
  [ "$2" = - ] || printf '%s\n' "$2" > "$_sf"
  : > "$W"
  PATH="$T/bin:$PATH" WRITES=$W GET_FAILS=$3 SET_FAILS=$4 \
  VIGILANCE_STATE_DIR="$T/state" sh -c '
    . "'"$HOOKLIB"'"
    '"$(_ddc_funcs)"'
    if [ "'"$1"'" = dark ]; then _bright_dark 9; else _bright_lit 9; fi
  ' 2>>"$T/err"
}
_save_ddc() { cat "$T/state/bright-9" 2>/dev/null || echo -; }

# THE EXTRACTION IS A PRECONDITION, ASSERTED TWICE. An extraction that matched
# nothing leaves an empty program and every case "passes" against no code at
# all; one that matched badly is not valid shell and every case fails for a
# reason that has nothing to do with the rules. Both happened. So: it must
# PARSE, and it must contain the delegation this table is here to check.
_ddc_funcs() {
  awk '
    /^_bright_(save|get|adapt|dark|lit)\(\)/ {
      inf = 1; print
      if ($0 ~ /}[ \t]*$/) inf = 0          # a one-liner opens and closes here
      next
    }
    inf { print; if ($0 ~ /^}/) inf = 0 }
  ' "$PLUGINS/hooks/ddc-monitor"
}
_ddc_funcs > "$T/ddc-funcs.sh"
dash -n "$T/ddc-funcs.sh" 2>"$T/ddcerr" || fail "the extracted ddc functions are
not valid shell, so every case below would fail for a reason that is not about
the rules: $(cat "$T/ddcerr")"
for _f in _bright_save _bright_get _bright_adapt _bright_dark _bright_lit; do
  grep -q "^$_f()" "$T/ddc-funcs.sh" \
    || fail "the extraction missed $_f, so its cases would run against nothing"
done
grep -q 'hook_level_dark' "$T/ddc-funcs.sh" \
  || fail "the extracted _bright_dark does not delegate to hook_level_dark, so
the copy is back and this table is no longer checking one implementation"

# --- run the table ----------------------------------------------------------
W=$T/writes
: > "$T/err"
_fails=0
for _adapter in generic bctl ddc; do
  printf '%s\n' "$CASES" | while IFS='|' read -r _n _edge _pre _gf _sf_f \
      _wrc _wsave _wwrites; do
    [ -n "${_n:-}" ] || continue
    _rc=0
    "_run_$_adapter" "$_edge" "$_pre" "$_gf" "$_sf_f" >/dev/null || _rc=$?
    _got_save=$("_save_$_adapter")
    _got_w=$(tr '\n' ' ' < "$W" | sed 's/ *$//')
    [ -n "$_got_w" ] || _got_w=-
    _bad=
    [ "$_rc" = "$_wrc" ] || _bad="$_bad rc=$_rc(want $_wrc)"
    [ "$_got_save" = "$_wsave" ] || _bad="$_bad save=$_got_save(want $_wsave)"
    # The writes are compared as a SET of one: a rule that wrote twice where it
    # should write once is a different defect and would read as a pass if the
    # comparison only looked for the value somewhere in the list.
    [ "$_got_w" = "$_wwrites" ] || _bad="$_bad writes=$_got_w(want $_wwrites)"
    if [ -n "$_bad" ]; then
      printf 'RULE BROKEN  %-34s %s:%s\n' "$_n" "$_adapter" "$_bad"
      echo x >> "$T/failed"
    fi
  done
done

if [ -f "$T/failed" ]; then
  _c=$(awk 'END { print NR }' "$T/failed")
  fail "$_c rule/adapter combination(s) disagree, listed above. These four rules
were each learned from a live defect, and the last time two implementations of
them drifted it shipped the identical silent no-op twice, three weeks apart. The
table is what makes that visible before a box does."
fi

# --- the tenth rule, which needed a case of its own ------------------------
# THE SAVE FILE CANNOT BE WRITTEN. Not expressible in the table above (it is a
# property of the filesystem, not of the device), and it is the defect this
# round found: `level_get > "$_sf"` is ONE compound that is also false when the
# REDIRECT fails, and that branch returned 0 saying "no such device here; fine"
# about a device that was present and readable. Measured before the fix: rc=0,
# the actuator never called, the only trace a shell redirect error on a stderr
# that goes nowhere under a keybind.
#
# REACHABLE, not theoretical: the save lives under STATE_ROOT=$RUN_DIR/state,
# which is exactly what the runtime-dir-read-only fault cell mounts a read-only
# tmpfs over, and a filesystem remounted read-only is how it reaches a real box.
#
# NOT DIMMING IS THE RIGHT ANSWER, which is why the assertion is rc=1 AND no
# write: the ladder's own invariant is that nothing enters a dark state unless
# its way back is armed, and a level nobody recorded is no way back.
_NOTCHECKED=
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$T/ro"
  chmod 500 "$T/ro"
  : > "$W"
  _rc=0
  GET_FAILS=0 SET_FAILS=0 sh -c '
    . "'"$HOOKLIB"'"
    level_get() { echo 42; }
    level_set() { printf "%s\n" "$1" >> "'"$W"'"; }
    hook_level_dark "'"$T/ro/save"'"
  ' 2>>"$T/err" || _rc=$?
  [ "$_rc" = 1 ] || fail "with a save file that cannot be WRITTEN and a device
that is present and readable, the descent exited $_rc. Returning 0 there is a
silent no-op reporting success: the edge logs clean and the screen stays lit."
  [ ! -s "$W" ] || fail "the device was dimmed ($(cat "$W")) with no recorded
level to restore it to. Nothing may enter a dark state unless its way back is
armed, and an unrecorded level is no way back."
  grep -q 'cannot record' "$T/err" || fail "the failure was not explained. 'no
such device here' was the old message and it was the wrong diagnosis: the device
was present, and the filesystem was the problem."
else
  # ROOT IGNORES PERMISSION BITS, so the fault cannot be injected here at all,
  # the same reason test/actuators declares `require unprivileged`. Said out
  # loud, because a skip nobody sees is how coverage gets overstated.
  _NOTCHECKED=' not checked: unwritable-save(root ignores modes)'
fi

pass "9 rules x 3 adapters + the unwritable save$_NOTCHECKED"
