#!/bin/sh
# test/hooklib.t - the save/restore discipline every peripheral hook depends on.
#
# hooklib is the smallest and most load-bearing file in the package: five hooks
# source it, and it owns the rule that decides whether a screen comes back on.
# It had no direct test.
#
# WHAT THIS FOUND. hook_lit ended with:
#
#   _bc "$@" set "$(cat "$_sf")" || true
#   rm -f "$_sf"
#
# so a FAILED restore returned 0 and deleted the save file. Both of the things
# that could have noticed are defeated by that one line:
#
#   the hook's exit status   swallowed by `|| true`, so the runner logs a clean
#                            crossing and raises no alert
#   report's "saved levels   can never fire, because the evidence it looks for
#   outstanding at a lit      was just deleted by the thing that failed
#   rung"
#
# The result is the screen staying dark with the record of what it should have
# been thrown away, and nothing anywhere saying so. That is the exact failure
# this project exists to prevent, living in the library all the peripheral hooks
# are built on.
#
# It is not hypothetical either: brightnessctl is DENIED on a box whose user is
# not in the `vigilant` group, which is the state manifold was in for weeks.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init hooklib

. "$HERE/libexec/vigilance/hooklib.sh"

# A brightnessctl that can be made to fail on demand, so the denial path is
# exercised rather than assumed. It is an ACTUATOR, which the suite's rule
# permits stubbing; nothing here stands in for system state.
mkdir -p "$T/bin"
cat > "$T/bin/brightnessctl" <<'EOF'
#!/bin/sh
eval _last=\${$#}
_prev=
if [ "$#" -ge 2 ]; then eval _prev=\${$(($# - 1))}; fi
case "$_last" in
  get) if [ -n "${BC_FAIL_GET:-}" ]; then exit 1; fi
       cat "$BC_LEVEL" 2>/dev/null || exit 1
       exit 0 ;;
  max) echo "${BC_MAX:-100}"; exit 0 ;;
esac
if [ "$_prev" = set ]; then
  if [ -n "${BC_FAIL_SET:-}" ]; then exit 1; fi
  printf '%s\n' "$_last" > "$BC_LEVEL"
  exit 0
fi
exit 1
EOF
chmod +x "$T/bin/brightnessctl"
PATH="$T/bin:$PATH"; export PATH
BC_LEVEL=$T/level; export BC_LEVEL
SF=$T/save

_lvl() { cat "$BC_LEVEL" 2>/dev/null || echo MISSING; }
# EXPORTED, because the stub is a separate process. Without the export the
# switches were invisible to it and every "failure" case silently exercised the
# HAPPY path -- the test would have passed against the broken hooklib.
export BC_FAIL_GET= BC_FAIL_SET=
_reset() {
  echo "${1:-80}" > "$BC_LEVEL"; rm -f "$SF"
  BC_FAIL_GET=; BC_FAIL_SET=
}

# --- the happy path: dim, then restore exactly what was there ---------------
_reset 80
hook_dark "$SF" -d x || fail "hook_dark failed on a healthy device"
[ "$(cat "$SF")" = 80 ] || fail "hook_dark saved '$(cat "$SF")', not the level
that was actually set (80)"
[ "$(_lvl)" = 0 ] || fail "hook_dark did not dim the device (level $(_lvl))"
hook_lit "$SF" -d x || fail "hook_lit failed restoring a saved level"
[ "$(_lvl)" = 80 ] || fail "hook_lit restored $(_lvl), not the saved 80"
[ ! -f "$SF" ] || fail "hook_lit left the save file behind after a SUCCESSFUL
restore; the next descent would then refuse to save and the real level is lost"

# --- SAVE ONCE, because a hook is wired on several edges --------------------
# A hook in both sleep.d and suspend.d runs twice on lock -> sleep -> suspend,
# and `resume` re-asserts dark a third time. Without the guard the second save
# records 0 over the real level and the restore brings the screen back BLACK.
_reset 70
hook_dark "$SF" -d x
hook_dark "$SF" -d x          # second descent, device already at 0
[ "$(cat "$SF")" = 70 ] || fail "a second hook_dark overwrote the save with
'$(cat "$SF")'; restoring that returns the screen to black"
hook_lit "$SF" -d x
[ "$(_lvl)" = 70 ] || fail "after a double-dim the restore gave $(_lvl)"

# --- THE BUG: a FAILED restore must not report success ---------------------
# stderr is captured, not shown: these failures are EXPECTED here, and a passing
# run whose output contains error text trains you not to read it.
_reset 60
hook_dark "$SF" -d x
BC_FAIL_SET=1; export BC_FAIL_SET
if hook_lit "$SF" -d x 2>>"$T/stderr"; then
  fail "hook_lit returned SUCCESS while the restore failed. The screen is still
dark, the runner logs a clean crossing, and no alert is raised -- which is how a
denied brightnessctl left two machines dark for weeks with a green record"
fi

# --- ...and must not destroy the evidence ----------------------------------
# report's only signal for 'a descent dimmed something the ascent never put
# back' is the save file surviving to a lit rung. Deleting it on failure blinds
# that check permanently.
[ -f "$SF" ] || fail "hook_lit deleted the save file after a FAILED restore.
That erases the level it could not put back AND blinds report's 'saved levels
outstanding at a lit rung' check, which exists for precisely this case"
[ "$(cat "$SF")" = 60 ] || fail "the surviving save file no longer holds the
level that was saved"

# --- and a later retry still works, because the file survived --------------
BC_FAIL_SET=
hook_lit "$SF" -d x || fail "a retry after a failed restore did not succeed"
[ "$(_lvl)" = 60 ] || fail "the retry restored $(_lvl), not 60"
[ ! -f "$SF" ] || fail "the save file outlived a successful retry"

# --- a FAILED dim must not leave a save file behind ------------------------
# The mirror case. If the dim failed the device was never darkened, so a save
# file would make report cry 'outstanding save at a lit rung' about a screen
# nobody touched.
_reset 55
BC_FAIL_SET=1; export BC_FAIL_SET
if hook_dark "$SF" -d x 2>>"$T/stderr"; then
  fail "hook_dark returned SUCCESS while the dim failed; the rung says dark and
the hardware is lit, with nothing saying so"
fi
[ ! -f "$SF" ] || fail "hook_dark kept a save file after failing to dim. Nothing
was dimmed, so that file is a false 'outstanding save' and report would report
drift about a device in its correct state"
BC_FAIL_SET=

# --- NO DEVICE is n/a, not failure -----------------------------------------
# A desktop has no panel backlight. Every shipped hook degrades to a no-op.
_reset 50
BC_FAIL_GET=1; export BC_FAIL_GET
hook_dark "$SF" -d x || fail "hook_dark treated an ABSENT device as a failure;
a box without that device is not a broken box"
[ ! -f "$SF" ] || fail "hook_dark left a save file for a device that does not
exist"
BC_FAIL_GET=

# --- a CORRUPT save file is refused, not handed to brightnessctl -----------
# `set ""` or `set garbage` is not a restore, and silently rm-ing afterwards
# would lose the level for good.
_reset 40
: > "$SF"                       # empty: a truncated write, a full disk
if hook_lit "$SF" -d x 2>>"$T/stderr"; then
  fail "hook_lit accepted an EMPTY save file as a level to restore"
fi
printf 'not-a-number\n' > "$SF"
if hook_lit "$SF" -d x 2>>"$T/stderr"; then
  fail "hook_lit accepted a non-numeric save file as a level to restore"
fi

# --- hook_verify_level: the two directions ---------------------------------
_reset 0; rm -f "$SF"
hook_verify_level "$SF" dark -d x 2>/dev/null \
  || fail "verify said a device at 0 was not dark"
_reset 90
hook_verify_level "$SF" dark -d x 2>/dev/null \
  && fail "verify passed a device at 90/100 as DARK" || :
# `lit` is only assertable when something recorded what to restore to: with no
# save file nobody dimmed it, so there is nothing to compare against.
_reset 90; rm -f "$SF"
hook_verify_level "$SF" lit -d x 2>/dev/null \
  || fail "verify failed a lit device with no save file; that is n/a, not drift"
echo 90 > "$SF"; _reset 0; echo 90 > "$SF"
hook_verify_level "$SF" lit -d x 2>/dev/null \
  && fail "verify passed a device at 0 as LIT, with a save file saying so" \
  || :

# --- hook_intent: the runner wins, and lock/unlock differ by KIND ----------
# The runner exports the ladder's darkness table; this is the ACT policy on top.
# They differ ONLY at lock/unlock, and merging them put back the bug where
# unlocking re-asserted a brightness the user had set by hand.
[ "$(VIGILANCE_INTENT=dark hook_intent sleep)" = dark ] \
  || fail "hook_intent ignored the runner's exported intent"
[ "$(VIGILANCE_KIND=act hook_intent lock)" = none ] \
  || fail "hook_intent let an ACT hook drive brightness at the lock edge"
[ "$(VIGILANCE_KIND=verify VIGILANCE_INTENT=lit hook_intent lock)" = lit ] \
  || fail "hook_intent refused to let VERIFY assert the lit rung at lock"

pass
