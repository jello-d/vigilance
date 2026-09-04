#!/bin/sh
# test/depth-survives-suspend.t - depth state must survive a REAL suspend.
#
# The claim being tested: depth lives in $XDG_RUNTIME_DIR, which survives
# suspend and hibernate but not a reboot. That is load-bearing, not incidental.
# If depth were lost across a suspend, the ascent would not know which rung it
# came up from, and a hook could not tell a restore-from-saved-state (leaving
# `sleep`) from a re-assert (leaving `suspend`, where USB re-enumerated and a
# QMK board forgot everything). The wrong branch leaves hardware dark.
#
# This cannot be faked. A stubbed suspend proves nothing about whether tmpfs
# survived, so the stub substrate SKIPS rather than pretending, and says so.
# That visible skip is the point: a green stub run must never read as full
# coverage.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init depth-survives-suspend

require systemd suspend

hook lock 10-a
hook suspend 10-a
hook resume 10-a

go suspend
expect_depth suspend

# A real S3 cycle, driven by the substrate (the VM runner supplies rtcwake).
scenario_suspend

expect_depth suspend
: > "$RECORD"
go sleep
expect_rc 0
expect_depth sleep
# FROM must still read `suspend`, which is the whole point: only that tells a
# hook its saved state is stale and it must re-assert instead of restore.
expect_record "resume suspend 10-a"

pass
