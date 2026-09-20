#!/bin/sh
# test/swayidle-watchdog.t - when is SILENCE evidence?
#
# The hard half of a watchdog is not noticing silence, it is knowing when
# silence means something. A daemon that emits only on idle transitions is
# legitimately quiet whenever nobody is there, so a naive "no events lately"
# check fires on every correct machine and gets deleted within a week -- taking
# the one real finding with it.
#
# Three innocent explanations have to be excluded before silence is a fault,
# and each is asserted here:
#
#   the box has not been up long enough to have emitted anything;
#   the machine is at `lock` or below, which PROVES the timer worked -- that is
#     how it got there;
#   the subject is not present or not running at all, which is a different
#     tier's finding and must not be reported twice in different words.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init swayidle-watchdog

HOOK=$HERE/libexec/vigilance/hooks/swayidle-watchdog
mkdir -p "$T/bin" "$T/state/swayidle-mgr"
LOG=$T/state/swayidle-mgr/events.log

# swayidle must look present AND running, or the hook declines before it ever
# reaches the question under test -- the precondition, asserted rather than
# assumed, because every case below would otherwise pass for the wrong reason.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/swayidle"; chmod +x "$T/bin/swayidle"
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/sh
[ -n "${PGREP_FOUND:-}" ] && exit 0
exit 1
EOF
chmod +x "$T/bin/pgrep"
cat > "$T/bin/vigilant" <<'EOF'
#!/bin/sh
printf 'depth: %s\nsince: 1s ago\n' "${FAKE_DEPTH:-open}"
EOF
chmod +x "$T/bin/vigilant"
PATH="$T/bin:$PATH"; export PATH
PGREP_FOUND=1; export PGREP_FOUND
SWAYIDLE_LOG_DIR=$T/state/swayidle-mgr; export SWAYIDLE_LOG_DIR
# PINNED, never the host's. Every case below depends on how long the machine
# has been up, and reading the real /proc/uptime meant these passed only
# because THIS box had been up for days -- the VM tier, booted seconds
# earlier, failed the very first case. A test whose verdict depends on the
# substrate is not testing the code.
VIGILANCE_UPTIME_FILE=$T/uptime; export VIGILANCE_UPTIME_FILE
printf '999999.00 999999.00\n' > "$T/uptime"
VIGILANT=$T/bin/vigilant; export VIGILANT

# THROUGH A FILE, and called DIRECTLY rather than in a substitution. `OUT=...`
# inside `$(_run)` is set in a subshell and never reaches the caller -- the
# same trap that once defeated a timeout bound here, and it cost a debugging
# round again writing this.
_run() {   # -> sets RC, output in $T/out
  RC=0
  VIGILANCE_KIND=watchdog sh "$HOOK" >"$T/out" 2>>"$T/stderr" || RC=$?
}
_out() { cat "$T/out" 2>/dev/null || true; }
_age() {   # seconds -> backdate the event log
  : > "$LOG"
  touch -d "@$(( $(date +%s) - $1 ))" "$LOG"
}

# --- 1. a FRESH heartbeat is healthy ----------------------------------------
_age 60
VIGILANCE_WATCHDOG_QUIET=3600
export VIGILANCE_WATCHDOG_QUIET
_run; [ "$RC" = 0 ] || fail "a heartbeat 60s old was called a fault. A healthy
timer is quiet between pauses, and firing on that is how this tier gets deleted"

# --- 2. LONG SILENCE at `open` IS the finding -------------------------------
# The wedge signature: running, armed, emitting nothing, machine sitting
# unlocked. Every other tier in this suite is green on exactly this input.
_age 20000
FAKE_DEPTH=open; export FAKE_DEPTH
_run; [ "$RC" = 1 ] || fail "20000s of silence at the 'open' rung was not
reported. That is a wedged idle timer: the process is alive and correctly
armed, so report is green, audit has no event to reconcile, and the standing
recheck is satisfied because the machine really IS unlocked"
case "$(_out)" in
  *WEDGED*|*wedged*) ;;
  *) printf '%s\n' "$(_out)" >&2
     fail "the finding did not name the diagnosis" ;;
esac
# ...and it must offer the other explanation rather than assert a fault it
# cannot distinguish. An inhibitor suppresses every timer legitimately.
case "$(_out)" in
  *inhibitor*) ;;
  *) fail "the finding claimed a wedge as certain. An idle inhibitor produces
identical silence, and vigilant cannot query one -- saying so is the honest
shape when the evidence cannot separate two causes" ;;
esac

# --- 3. AT `lock` OR BELOW, SILENCE PROVES THE OPPOSITE ---------------------
# The decisive exclusion. If the machine is locked, the idle timer demonstrably
# worked -- that is how it got there -- and it is then correctly quiet because
# nobody is present. Without this the check fires on every locked machine,
# which is every machine overnight.
for _d in lock sleep suspend; do
  FAKE_DEPTH=$_d
  _run; [ "$RC" = 0 ] || fail "silence at the '$_d' rung was reported as a
wedge. Getting there IS proof the timer fired, so this would go off on every
machine every night and be gone by the end of the week"
done
FAKE_DEPTH=open

# --- 4. TOO EARLY TO JUDGE --------------------------------------------------
# A box up ten minutes has no business being judged on four hours of quiet.
# Driven by the UPTIME now, which is the variable that actually decides it --
# the old version moved the quiet window instead and so never exercised a
# freshly booted machine, the case the VM tier found.
_age 20000
printf '120.00 120.00\n' > "$T/uptime"
_run; [ "$RC" = 78 ] || fail "a box up 120s was judged on a 3600s quiet window.
It cannot have been silent for longer than it has existed, and a watchdog that
fires on every boot is one nobody reads twice"
printf '999999.00 999999.00\n' > "$T/uptime"

# --- 5. NOT RUNNING is a DIFFERENT tier's finding ---------------------------
# `report` already asserts the timer is running and supervised. Two tiers
# reporting one fault in different words teaches a reader to discount both.
PGREP_FOUND=
_run; [ "$RC" = 78 ] || fail "with swayidle not running the hook returned a
verdict. That is report's finding; this tier owns exactly one question --
it is running, but is it WORKING?"
PGREP_FOUND=1

# --- 6. NO SUBJECT AT ALL, and NO HEARTBEAT WIRED ---------------------------
# A MINIMAL PATH, not a renamed stub. Moving $T/bin/swayidle aside proves
# nothing while the REAL /usr/bin/swayidle is still two entries further along:
# the hook found it and the case passed for a reason unrelated to its claim.
# Caught by the case failing; it would have been invisible the other way round.
mkdir -p "$T/min"
# The hook needs date/cut/sed/head; the harness needs sh to invoke it and
# rm/cat for its own cleanup. Omitting sh made the case fail with rc=127 --
# "command not found" wearing the costume of a declined hook.
for _c in sh date cut sed head cat rm touch mkdir chmod grep printf; do
  ln -sf "$(command -v "$_c")" "$T/min/$_c" 2>/dev/null || true
done
cp "$T/bin/pgrep" "$T/bin/vigilant" "$T/min/"
_saved=$PATH
PATH=$T/min; export PATH
command -v swayidle >/dev/null 2>&1 \
  && fail "setup wrong: swayidle is still reachable on the minimal PATH, so
this case cannot test a host that does not have it"
_run; [ "$RC" = 78 ] \
  || fail "on a host with no swayidle the hook did not decline"
PATH=$_saved; export PATH

rm -f "$LOG"
_run; [ "$RC" = 78 ] || fail "with no event log the hook returned a verdict. The
heartbeat is what makes silence mean anything, so without it there is no
expectation to compare against and 0 would be a false all-clear"

pass
