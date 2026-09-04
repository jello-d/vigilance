#!/bin/sh
# test/hook-failure.t - a failing hook must be LOUD, must NAME itself, and must
# NOT abort its siblings.
#
# This is the regression for the bug that hid on two machines for days: the
# patched swaylock forked $HOME/bin/panel-power, the path went stale when
# vigilance extracted panel-power to ~/.local/bin, the execl failed, and
# _exit(127) swallowed it BY DESIGN ("best-effort: any failure is silently
# ignored"). Nothing anywhere reported it. A monitor burned its backlight for
# days and the only symptom was a screen that did not turn off.
#
# Three properties, all absent before:
#   1. the runner's exit status is non-zero, so a caller can react
#   2. the failing hook is NAMED on stderr, so the log says which one
#   3. siblings still run: one dark monitor must not leave the keyboard lit
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init hook-failure

hook lock 10-ok
hook lock 20-broken 3       # exits 3, as a stale path or dead tool would
hook lock 30-ok

go lock
expect_rc 1                                  # 1. loud, not silent
expect_stderr "HOOK FAILED (rc=3): lock 20-broken"   # 2. names the hook
expect_record "lock open 10-ok
lock open 20-broken
lock open 30-ok"                             # 3. siblings still ran

# The edge still CROSSED. A hook that could not act does not mean the session
# is unlocked; depth must reflect reality so the ascent unwinds correctly.
expect_depth lock

# --- verify is the shared oracle, and it reports the same failure -----------
# A verify hook that cannot confirm its edge took effect fails the same way,
# which is what lets the test suite and the production watchdog agree.
: > "$RECORD"
hook lock.verify 10-confirm
expect_verify lock ok

hook lock.verify 20-cannot-confirm 4
expect_verify lock fail

pass
