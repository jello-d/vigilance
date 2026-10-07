#!/bin/sh
# test/swayidle-watchdog.t - when is SILENCE evidence?
#
# The hard half of a watchdog is not noticing silence, it is knowing when
# silence means something. A daemon that emits only on idle transitions is
# legitimately quiet whenever nobody is there, so a naive "no events lately"
# check fires on every correct machine and gets deleted within a week, taking
# the one real finding with it.
#
# Three innocent explanations have to be excluded before silence is a fault,
# and each is asserted here:
#
#   the box has not been up long enough to have emitted anything;
#   the machine is at `lock` or below, which PROVES the timer worked: that is
#     how it got there;
#   the subject is not present or not running at all, which is a different
#     tier's finding and must not be reported twice in different words.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init swayidle-watchdog

HOOK=$HERE/libexec/hooks/swayidle-watchdog
mkdir -p "$T/bin" "$T/state/swayidle-mgr"
LOG=$T/state/swayidle-mgr/events.log

# swayidle must look present AND running, or the hook declines before it ever
# reaches the question under test: the precondition, asserted rather than
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
# THE ARMED COMMAND LIST IS PINNED. A daemon pins its argv at start, so the
# heartbeat this hook watches for only exists in an instance launched AFTER it
# was added, and without a fixture every case here would judge whatever the
# developer's own swayidle happens to be armed with.
VIGILANCE_IDLE_CMDLINE=$T/cmdline; export VIGILANCE_IDLE_CMDLINE
printf 'swayidle\0timeout\060\0swayidle-mgr event idle-tick\0' > "$T/cmdline"
# PINNED, never the host's. Every case below depends on how long the machine
# has been up, and reading the real /proc/uptime meant these passed only
# because THIS box had been up for days; the VM tier, booted seconds
# earlier, failed the very first case. A test whose verdict depends on the
# substrate is not testing the code.
VIGILANCE_UPTIME_FILE=$T/uptime; export VIGILANCE_UPTIME_FILE
printf '999999.00 999999.00\n' > "$T/uptime"
VIGILANT=$T/bin/vigilant; export VIGILANT

# OUR OWN STATE DIR, PINNED. The hook keeps the record of when it last LOOKED
# here, and the default is a shared name under /tmp (matching hook_throttle's
# convention): unpinned, these cases would share it with the live box and with
# each other.
WDSTATE=$T/wdstate; mkdir -p "$WDSTATE"
VIGILANCE_STATE_DIR=$WDSTATE; export VIGILANCE_STATE_DIR

# AND THE INHIBITOR, or every case below reads the DEVELOPER'S machine. A held
# idle inhibitor is now a reason for this hook to decline, so an unpinned value
# makes the verdict depend on whether a browser happened to be playing video,
# which is the substrate-reading mistake behind a long line of defects here.
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED

# THROUGH A FILE, and called DIRECTLY rather than in a substitution. `OUT=...`
# inside `$(_run)` is set in a subshell and never reaches the caller, the
# same trap that once defeated a timeout bound here, and it cost a debugging
# round again writing this.
_run() {   # -> sets RC, output in $T/out
  RC=0
  VIGILANCE_KIND=watchdog sh "$HOOK" >"$T/out" 2>>"$T/stderr" || RC=$?
}
_out() { cat "$T/out" 2>/dev/null || true; }
_age() {   # seconds -> backdate the event log, WITH the observer present
  : > "$LOG"
  touch -d "@$(( $(date +%s) - $1 ))" "$LOG"
  # AND IT SAYS THE SAMPLER WAS WATCHING THROUGHOUT, which is now part of the
  # fixture rather than an assumption. Silence only counts while this hook was
  # actually running, so a fixture that ages the event log without saying the
  # sampler was there describes a machine that was ASLEEP, and every case here
  # would correctly report nothing. That is exactly what happened on the first
  # run after the guard landed.
  printf '%s %s\n' "$(date +%s)" "$(( $(date +%s) - $1 - 60 ))" \
    > "$WDSTATE/.lastlook"
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
# ...and it must say the OTHER cause was RULED OUT, not offer it.
#
# THIS ASSERTION USED TO REQUIRE THE OPPOSITE, on the stated grounds that
# "vigilant cannot query one". That was never true: a held idle inhibitor is
# one busctl read away, and offering an alternative that could have been
# resolved is what made this message send a reader hunting a wedge on a box
# whose timer was demonstrably fine. An inhibitor IS checked now, so with none
# held the diagnosis is a statement rather than a pair.
case "$(_out)" in
  *"no idle inhibitor"*) ;;
  *) printf '%s\n' "$(_out)" >&2
     fail "the finding did not say the inhibitor had been ruled out. Naming a
cause it could have excluded, and did not, is the confidently-ambiguous shape
that cost a whole investigation" ;;
esac

# --- 2b. SILENCE WE DID NOT WATCH IS NOT EVIDENCE --------------------------
# THE LIVE FALSE ALARM. The lid was shut at 09:43:08 and opened at 14:08:49, so
# 15941 of a reported 16045s of "silence" was S3. The real awake silence was
# 104 seconds against a 14400s window, and the box then demonstrably fired both
# idle timeouts (`cross lock src=idle`, then `cross sleep`).
#
# THE UPTIME GUARD CANNOT SEE IT: /proc/uptime INCLUDES suspended time on this
# kernel (measured: 138358 against 138359s of wall clock since btime), so "up
# long enough" stayed true throughout. The sampler's own absence is the witness,
# because the supervision timer does not fire in S3.
_age 20000                   # the event log is genuinely ancient
# ...but our last LOOK was 16000s ago, so we were not here for most of it.
printf '%s %s\n' "$(( $(date +%s) - 16000 ))" "$(( $(date +%s) - 20100 ))" \
  > "$WDSTATE/.lastlook"
_run; [ "$RC" = 0 ] || fail "silence accumulated while this hook was NOT
RUNNING was reported as a wedge. That is the live 7-alert false alarm: the
machine was suspended, so the idle timer could not have spoken, and wall-clock
silence counted time the machine did not exist. Output: $(_out)"

# AND THE PAIR IS THE TEST: the same ancient event log, with the observer
# present, MUST still fire. Otherwise "never report anything" passes the case
# above while switching the tier off, which is the trade every guard in this
# suite has to be checked against.
_age 20000
_run; [ "$RC" = 1 ] || fail "with the sampler present throughout, 20000s of
silence must still be the finding; the gap guard has switched the tier off"

# --- 3. AT `lock` OR BELOW, SILENCE PROVES THE OPPOSITE ---------------------
# The decisive exclusion. If the machine is locked, the idle timer demonstrably
# worked: that is how it got there, and it is then correctly quiet because
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
# Driven by the UPTIME now, which is the variable that actually decides it,
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
verdict. That is report's finding; this tier owns exactly one question:
it is running, but is it WORKING?"
PGREP_FOUND=1

# --- 6. NO SUBJECT AT ALL, and NO HEARTBEAT WIRED ---------------------------
# A MINIMAL PATH, not a renamed stub. Moving $T/bin/swayidle aside proves
# nothing while the REAL /usr/bin/swayidle is still two entries further along:
# the hook found it and the case passed for a reason unrelated to its claim.
# Caught by the case failing; it would have been invisible the other way round.
mkdir -p "$T/min"
# The hook needs date/cut/sed/head, and READLINK since it self-locates to
# source hook_lib; the harness needs sh to invoke it and rm/cat for its own
# cleanup. Omitting sh made the case fail with rc=127, "command not found"
# wearing the costume of a declined hook, and omitting readlink did the same
# thing one layer up: the source line died under `set -e` before the hook
# could decline, so the case failed claiming the DECLINE was broken.
for _c in sh date cut sed head cat rm touch mkdir chmod grep printf \
          readlink dirname; do
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

# --- AN UNARMED TIMER CANNOT BE JUDGED -------------------------------------
# A DAEMON PINS ITS ARGV AT START. The heartbeat is a timeout armed when the
# idle timer launches, so an instance predating it emits nothing however
# healthy it is, and this hook would read the stale log as a wedge and say so
# once an hour about a timer working perfectly.
#
# It fired within a day of shipping: swayidle had been up four days, had no
# `idle-tick` in its argv, and had fired an idle-lock six hours earlier. Alive,
# reported wedged. The expectation silence is measured against DOES NOT EXIST
# until the unit is restarted, so the only honest answer is "I cannot tell".
_age 20000
printf 'swayidle\0timeout\0480\0swayidle-mgr event idle-lock\0' > "$T/cmdline"
_run; [ "$RC" = 78 ] || fail "a timer with no heartbeat in its argv was judged
(rc=$RC). It emits nothing to watch, so silence proves nothing, and calling
that a wedge accuses a daemon that is working of the one fault it does not have"
case "$(_out)" in
  *restart*) ;;
  *) printf '%s\n' "$(_out)" >&2
     fail "the finding did not say how to make it answerable. 'Restart the
unit' is the whole remedy and leaving it out sends a reader hunting a wedge" ;;
esac

# ...and an ARMED timer is judged normally, or the guard would switch the whole
# hook off on every box.
printf 'swayidle\0timeout\060\0swayidle-mgr event idle-tick\0' > "$T/cmdline"
_run; [ "$RC" = 1 ] || fail "an ARMED timer silent for 20000s at the open rung
returned $RC instead of reporting. The precondition guard must gate the
question, not replace it"

# --- 8. A HELD IDLE INHIBITOR IS NOT THIS HOOK'S FINDING -------------------
# It suppresses every timeout including the heartbeat, so silence is the
# inhibitor being HONOURED. The inhibit bound owns a hold that goes on too
# long, and two tiers accusing in different words is how a reader learns to
# discount both: the same division of labour this hook already keeps with
# `report` over whether swayidle is running at all.
_age 20000
VIGILANCE_BLOCK_INHIBITED=idle
_run; [ "$RC" = 78 ] || fail "with idle INHIBITED, 20000s of silence was
reported as a wedge (rc=$RC). That is the measured false alarm: the timer is
doing exactly what it was asked to do, and the message used to offer this as
one of two causes it claimed it could not check. Output: $(_out)"
case "$(_out)" in
  *inhibit*) ;;
  *) printf '%s\n' "$(_out)" >&2
     fail "the decline did not say WHY, so a reader sees a silent 78 and
cannot tell it from a hook that could not look" ;;
esac

# --- 9. CANNOT TELL KEEPS BOTH CAUSES --------------------------------------
# The n/a contract at the one place where collapsing it is worst in BOTH
# directions. Reading an unanswerable bus as "inhibited" switches this tier
# off; reading it as "not inhibited" asserts a wedge the evidence cannot
# support. So with no answer the message names both, which is the honest shape
# and the one the hook used to use unconditionally.
mkdir -p "$T/stub"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/busctl"
chmod +x "$T/stub/busctl"
RC=0
VIGILANCE_KIND=watchdog PATH=$T/stub:$PATH \
  env -u VIGILANCE_BLOCK_INHIBITED sh "$HOOK" >"$T/out" 2>>"$T/stderr" || RC=$?
[ "$RC" = 1 ] || fail "with busctl FAILING the hook must still report the
silence (rc=$RC): an unanswerable bus is not evidence that nothing is
inhibited, but it is not a reason to stop watching either"
case "$(_out)" in
  *"could not be asked"*) ;;
  *) printf '%s\n' "$(_out)" >&2
     fail "with no answer from logind the finding must SAY the inhibitor could
not be ruled out. Asserting a bare wedge there is the confidently-wrong
diagnosis this project keeps paying for" ;;
esac
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED

pass "silence counts only while watched, a held inhibitor defers to the\
 bound, and an unanswerable bus keeps both causes"
