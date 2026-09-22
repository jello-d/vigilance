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
  # AN ABSENT DEVICE FAILS WRITES TOO. Modelling BC_FAIL_GET as "reads fail but
  # writes succeed" is a device that does not exist, and the difference is not
  # academic: it made the mutation that deletes hook_lit's absent-device check
  # PASS, because the restore then "succeeded" against nothing.
  if [ -n "${BC_FAIL_GET:-}" ]; then exit 1; fi
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

# --- ...BUT ASSERT EVERY TIME ----------------------------------------------
# Saving once is NOT the same as trusting the save. hook_dark used to `return
# 0` outright when the file existed, reading it as "already saved, therefore
# already dark" -- an inference, not an observation. When it was wrong the
# descent became a SILENT NO-OP THAT REPORTED SUCCESS, and since crossings do
# not run the verify tier, nothing caught it at the edge.
#
# Observed live on manifold: a leftover save file left the keyboard backlight
# lit through every `sleep`, the crossing logged clean, and only the
# once-a-minute standing recheck ever said so. This is that, reproduced: a
# save file present and the device NOT dark, which is the state the old code
# could not tell from a correct one.
_reset 70
hook_dark "$SF" -d x
[ "$(_lvl)" = 0 ] || fail "setup: the first descent did not dim"
echo 55 > "$BC_LEVEL"         # something put the device back, as a stray tool
                              # would; the save file is untouched
hook_dark "$SF" -d x || fail "a re-assert over an existing save failed"
[ "$(_lvl)" = 0 ] || fail "a descent with a save file already present left the
device at $(_lvl). It returned success without looking, which is exactly how a
lit keyboard sat over a dark screen for 39 minutes while every tier was green"
[ "$(cat "$SF")" = 70 ] || fail "the re-assert clobbered the save with
'$(cat "$SF")'; the original level is the one thing that must survive"
hook_lit "$SF" -d x
[ "$(_lvl)" = 70 ] || fail "restore after a re-assert gave $(_lvl), not 70"

# A PRE-EXISTING SAVE SURVIVES A FAILED RE-ASSERT. Dropping it because a later
# write failed would throw away the level the device must return to, stranding
# a panel that may still be dark from the first descent. Only a save this call
# CREATED is dropped on failure.
_reset 70
hook_dark "$SF" -d x
BC_FAIL_SET=1
hook_dark "$SF" -d x 2>>"$T/stderr" \
  && fail "a failed re-assert reported success"
BC_FAIL_SET=
[ -f "$SF" ] || fail "a failed re-assert deleted a PRE-EXISTING save. The
device may still be dark from the first descent, and the level it has to be
restored to is now gone"
[ "$(cat "$SF")" = 70 ] || fail "the pre-existing save was corrupted"

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

# --- a STALE save for a device that is GONE is dropped, not failed forever --
# The mirror of the absent-device case above, on the ascent. hook_dark treats an
# unreadable device as n/a; hook_lit used to treat it as a failed restore, so a
# save file left over from a machine that has since changed failed EVERY ascent
# and alerted each time -- while report cried drift about hardware that is not
# there.
#
# It cannot self-heal either, and that is what makes it permanent: hook_dark
# short-circuits on the save file's existence, so the descent never re-creates
# the condition and never clears it. Measured on a live box: a save written by
# an older hooklib outlived the fix and failed every wake for days.
_reset 45
hook_dark "$SF" -d x || fail "setup: hook_dark failed on a healthy device"
[ -f "$SF" ] || fail "setup: no save file to go stale"
BC_FAIL_GET=1; export BC_FAIL_GET
hook_lit "$SF" -d x 2>>"$T/stderr" \
  || fail "hook_lit reported a FAILED restore for a device that cannot even be
READ. There is nothing to restore to, so this fails every ascent forever and
alerts each time -- and hook_dark short-circuits on the save file, so the
descent never clears it"
[ ! -f "$SF" ] || fail "hook_lit kept a save file for a device that is gone. It
is a leftover from a machine that has changed; keeping it makes report report
drift about hardware that does not exist"
BC_FAIL_GET=

# ...but a device that READS and refuses to be WRITTEN is still a real failure,
# and the save must survive. Without this the fix above would degrade into
# "swallow every restore failure", which is the bug the file was written for.
_reset 35
hook_dark "$SF" -d x
BC_FAIL_SET=1; export BC_FAIL_SET
if hook_lit "$SF" -d x 2>>"$T/stderr"; then
  fail "a readable device that refused the write was reported as a successful
restore; only an UNREADABLE device is n/a"
fi
[ -f "$SF" ] || fail "the save file was dropped for a device that is present
but denied; that level is still wanted and report still needs to see it"
BC_FAIL_SET=

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

# --- THE DISCIPLINE WITHOUT brightnessctl ----------------------------------
# hook_dark/hook_lit took brightnessctl SELECTORS, so the rules they encode --
# save once, assert every time, keep the save when a write is refused, drop it
# when the device cannot be read -- were available only to what brightnessctl
# drives. ddc-monitor needed the same rules for a VCP write and re-implemented
# all of them by hand: two copies of rules that were each learned the hard way.
#
# These cases drive the generic form with a fixture actuator that is not
# brightnessctl at all, which is the only way to show the split is real rather
# than a rename.
FAKE=$T/fake-device
FSAVE=$T/fake-save
rm -f "$FSAVE"
printf '64\n' > "$FAKE"
level_get() { [ -n "${FAKE_GONE:-}" ] && return 1; cat "$FAKE"; }
level_set() { [ -n "${FAKE_GONE:-}" ] && return 1
              [ -n "${FAKE_RO:-}" ] && return 1
              printf '%s\n' "$1" > "$FAKE"; }

hook_level_dark "$FSAVE" || fail "the generic dark path failed on a healthy
non-brightnessctl device"
[ "$(cat "$FAKE")" = 0 ] || fail "generic dark did not drive the device to 0"
[ "$(cat "$FSAVE")" = 64 ] || fail "generic dark saved '$(cat "$FSAVE")'"

# SAVE ONCE, ASSERT EVERY TIME -- the same pair the brightnessctl path gets.
printf '40\n' > "$FAKE"
hook_level_dark "$FSAVE" || fail "a re-assert failed"
[ "$(cat "$FAKE")" = 0 ] || fail "the generic path trusted its save file and
left the device at $(cat "$FAKE"); that is the silent no-op, one layer down"
[ "$(cat "$FSAVE")" = 64 ] || fail "the re-assert clobbered the save"

hook_level_lit "$FSAVE" || fail "the generic restore failed"
[ "$(cat "$FAKE")" = 64 ] || fail "restore gave $(cat "$FAKE"), not 64"
[ -f "$FSAVE" ] && fail "a completed restore left its save file behind"

# REFUSED WRITE KEEPS THE SAVE; UNREADABLE DEVICE DROPS IT. Collapsing those
# is what left a stale save failing every ascent for four days.
printf '64\n' > "$FAKE"
hook_level_dark "$FSAVE" || fail "setup"
FAKE_RO=1
hook_level_lit "$FSAVE" 2>>"$T/stderr" && fail "a refused restore reported ok"
FAKE_RO=
[ -f "$FSAVE" ] || fail "a REFUSED restore dropped the save; the level the
device must return to is now gone, on a device that is present and answering"

FAKE_GONE=1
hook_level_lit "$FSAVE" 2>>"$T/stderr" || fail "an absent device made the
restore FAIL; it is n/a, and failing every ascent forever is the other half"
FAKE_GONE=
[ -f "$FSAVE" ] && fail "an unreadable device kept its stale save, which is
what fails every later ascent about hardware that is simply not there"

unset -f level_get level_set 2>/dev/null || true

# --- A DEVICE THAT WILL NOT STAY DARK IS NOT OURS TO DARKEN ----------------
# Measured on a live box: `mute-on-lock` mutes at the lock edge, the driver
# lights the ThinkPad mute LED because the LED IS the mute state, and at the
# sleep rung these two hooks want opposite things. The driver settles it,
# putting the LED back about two seconds after every write.
#
# 278 drift alerts across ONE twelve-hour sleep, about a fight that cannot be
# won. A tier that cries about the unwinnable gets ignored for the winnable.
#
# DETECTED IN VERIFY, not at the crossing: the reassertion takes seconds, so a
# read-back in the act tier fires before the device can bounce and costs a call
# to learn nothing. That was the first attempt and it detected zero.
_reset 70
rm -f "$SF.notours"
hook_dark "$SF" -d x || fail "setup: the descent failed"
echo 70 > "$BC_LEVEL"          # something else puts it straight back
_vr=0
hook_verify_level "$SF" dark -d x 2>>"$T/stderr" || _vr=$?
[ "$_vr" = 78 ] || fail "a device that returned to EXACTLY the level we saved
was reported as drift (rc=$_vr), not declined. It was set to 0 and something
put it back; that is a fight we lose, and reporting it once a minute forever
is a complaint rather than a finding"
[ -f "$SF.notours" ] || fail "no marker was left, so the next pass re-litigates
the same unwinnable device"

# ...and it stays quiet afterwards, which is the whole point.
_vr=0
hook_verify_level "$SF" dark -d x 2>>"$T/stderr" || _vr=$?
[ "$_vr" = 78 ] || fail "the second pass reported rc=$_vr instead of declining"

# A LIT EDGE RE-OPENS THE QUESTION. Whatever drove the device may have stopped
# -- the mute LED goes out when audio is unmuted -- so tomorrow's dark edge
# must test it again rather than inherit today's verdict.
hook_lit "$SF" -d x 2>>"$T/stderr" || true
[ -f "$SF.notours" ] && fail "a lit edge left the not-ours marker in place; a
device excused once would be excused forever, including after the condition
that was driving it went away"

# --- ...BUT A GENUINELY LIT DEVICE IS STILL DRIFT --------------------------
# The exclusion is narrow on purpose: EXACTLY the level we saved. A device at
# some OTHER bright value was not reasserted, it just never went dark, and
# that is the finding this tier exists for.
_reset 70
rm -f "$SF.notours"
hook_dark "$SF" -d x || fail "setup"
echo 90 > "$BC_LEVEL"          # bright, but NOT the level we saved
_vr=0
hook_verify_level "$SF" dark -d x 2>>"$T/stderr" || _vr=$?
[ "$_vr" = 1 ] || fail "a device sitting at 90 when it should be dark returned
rc=$_vr. Only a return to the EXACT saved level means something else drives it;
anything else is a device that simply did not go dark"

pass
