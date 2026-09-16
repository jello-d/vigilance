#!/bin/sh
# test/runtime-dir.t - WHERE the authoritative state lives, which decides
# whether every other answer is about this machine or about nothing.
#
# The depth file IS the state. Resolve its directory wrongly and vigilant does
# not fail -- it answers confidently about a record nobody writes.
#
# WHAT THIS FOUND. RUN_DIR was
#
#   ${VIGILANCE_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/vigilance}
#
# and XDG_RUNTIME_DIR is UNSET in a non-interactive ssh, in cron, and under
# `su`. Measured: `vigilant status` there read an empty /tmp/vigilance and
# reported `depth: open, since: unknown` -- the same answer whether the machine
# was open, locked or dark. The tell was `since: unknown`, because the real
# record has a timestamp and this one had no record at all.
#
# That is the project's own subject turned on itself: a tool about truthful
# state, confidently wrong about it, with nothing saying the record it read was
# not the session's.
#
# Two things were wrong and they need separate fixes:
#   1. it gave up too early -- logind creates /run/user/<uid> for ANY session of
#      that uid, the ssh one included, so the real record is still findable; and
#   2. the last resort was a SHARED NAME in a sticky world-writable directory.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init runtime-dir

VIG=$HERE/bin/vigilant
UID_=$(id -u)

# Everything below must resolve RUN_DIR for itself, so the sandbox's own
# VIGILANCE_RUN_DIR has to be out of the way -- it deliberately outranks every
# other source. The fallbacks are then redirected INTO the sandbox with
# VIGILANCE_RUNTIME_BASE and TMPDIR, so no case reaches a real path.
_run() {   # <runtime-base> <tmpdir> <args...>
  _rb=$1; _td=$2; shift 2
  env -u XDG_RUNTIME_DIR -u VIGILANCE_RUN_DIR \
    VIGILANCE_RUNTIME_BASE="$_rb" TMPDIR="$_td" \
    VIGILANCE_LOG="$T/rt.log" \
    VIGILANCE_HOOK_ROOT="$T/nohooks" \
    VIGILANCE_MACHINE_HOOKS="$T/nomachine" \
    "$VIG" "$@" 2>>"$T/stderr"
}

mkdir -p "$T/base/$UID_/vigilance" "$T/empty" "$T/tmp1" "$T/tmp2"

# --- 1. THE ssh CASE: no XDG_RUNTIME_DIR, but /run/user/<uid> exists ---------
# The real record must be FOUND, not replaced with an empty one. Seeded with a
# rung that is not the default, because `open` is what a missing record reports
# and the two would be indistinguishable.
printf 'sleep %s\n' "$(date +%s)" > "$T/base/$UID_/vigilance/depth"
_out=$(_run "$T/base" "$T/tmp1" status)
case "$_out" in
  *"depth: sleep"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "with XDG_RUNTIME_DIR unset, status did not read the record in the
runtime dir that logind maintains for this uid. Over ssh or from cron it
reports 'open' whatever the machine is actually doing -- and 'open' is the one
answer that means nothing needs attention" ;;
esac

# ...and the "since" line proves a RECORD was read, not a default. A missing
# record also yields `depth: open`, so matching the rung alone could pass
# against a fallback that found nothing.
case "$_out" in
  *"since: unknown"*)
     printf '%s\n' "$_out" >&2
     fail "the rung was right but no record was read ('since: unknown'), so the
answer came from the empty-state default rather than from the session's file" ;;
esac

# --- 2. XDG_RUNTIME_DIR still WINS when it is set ---------------------------
# The probe is a fallback, not an override: a session that states its runtime
# dir must be believed over a guess assembled from a uid.
printf 'lock %s\n' "$(date +%s)" > "$T/tmp2/depth-holder" 2>/dev/null || true
mkdir -p "$T/xdg/vigilance"
printf 'lock %s\n' "$(date +%s)" > "$T/xdg/vigilance/depth"
# -u BEFORE any assignment: env stops parsing options at the first NAME=VALUE,
# so a flag after one is taken as the command to run (rc=127).
_out=$(env -u VIGILANCE_RUN_DIR XDG_RUNTIME_DIR="$T/xdg" \
  VIGILANCE_RUNTIME_BASE="$T/base" TMPDIR="$T/tmp2" \
  VIGILANCE_LOG="$T/rt.log" VIGILANCE_HOOK_ROOT="$T/nohooks" \
  VIGILANCE_MACHINE_HOOKS="$T/nomachine" "$VIG" status 2>>"$T/stderr")
case "$_out" in
  *"depth: lock"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "XDG_RUNTIME_DIR was set and ignored in favour of the /run/user
guess; a session's stated runtime dir must outrank one assembled from a uid" ;;
esac

# --- 3. NEITHER available: per-uid, under TMPDIR, and SAID OUT LOUD ---------
# The shared name was the problem. /tmp/vigilance is one path for every user of
# the box in a sticky world-writable directory: whoever creates it first owns
# it, and a pre-planted symlink there redirects the depth writes of everyone who
# comes after. That is the authoritative state of a lock supervisor.
_out=$(_run "$T/empty" "$T/tmp2" report) || true
[ -d "$T/tmp2/vigilance-$UID_" ] || fail "with no runtime dir anywhere, the
fallback did not land at a PER-UID path under TMPDIR. A shared name in a sticky
world-writable directory is where another local user gets to choose what this
machine believes its own state to be"

# And it must not be silent. A fallback nobody is told about is a machine
# reporting 'open' forever with a perfectly clean bill of health.
case "$_out" in
  *"no runtime dir found"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "the state fell back to a private directory the session does not
share, and report said nothing. Every rung reads as 'open' there, which is
exactly the answer that means nothing is wrong" ;;
esac

# It is a WARN and not a FAIL: the state is in a SAFE place, just not a shared
# one, and the machine itself may be perfectly healthy.
_no_fail_in "$_out" wiring "a fallback runtime dir was raised as a FAIL; it is
degraded reporting, not a broken machine"

# --- 4. and the explicit override still outranks everything -----------------
# The whole sandbox depends on this, so it is asserted rather than assumed: if
# VIGILANCE_RUN_DIR ever stopped winning, every scenario in this suite would
# quietly start reading the developer's own live state.
mkdir -p "$T/explicit"
printf 'suspend %s\n' "$(date +%s)" > "$T/explicit/depth"
_out=$(env XDG_RUNTIME_DIR="$T/xdg" VIGILANCE_RUN_DIR="$T/explicit" \
  VIGILANCE_RUNTIME_BASE="$T/base" TMPDIR="$T/tmp2" \
  VIGILANCE_LOG="$T/rt.log" VIGILANCE_HOOK_ROOT="$T/nohooks" \
  VIGILANCE_MACHINE_HOOKS="$T/nomachine" "$VIG" status 2>>"$T/stderr")
case "$_out" in
  *"depth: suspend"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "VIGILANCE_RUN_DIR did not outrank XDG_RUNTIME_DIR. Every scenario in
this suite sandboxes state through that variable, so if it stops winning the
tests silently start reading and writing the developer's own live record" ;;
esac

pass
