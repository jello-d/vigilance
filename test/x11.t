#!/bin/sh
# test/x11.t - the X11 plugins, and the assumptions a second platform reads
# back.
#
# WHY X11 AT ALL, when nothing in this fleet runs it. Not portability for its
# own sake: a second platform is the only thing that can TEST the claim this
# package makes about itself: that the framework owns the ladder and nothing
# else. The framework audit measured zero mechanism references across the nine
# crossing functions, which says the code contains no Wayland; it cannot say the
# CONTRACTS are free of it. Adding a platform is how you find out, and it found
# two things before a line of X11 code existed: `VIGILANCE_LOCKER` was a half
# promise (the name was a knob while `-f` and Type=forking were not), and the
# integrator's argv helper was handing a swaylock config file to whatever locker
# it was given.
#
# xset AND xprintidle ARE ACTUATORS AND PROBES, which the suite's rule permits
# stubbing: they stand in for hardware, not for system state. What is NOT
# stubbed is the exit-code contract, the intent table or the throttle.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init x11

DPMS=$HERE/libexec/vigilance/hooks/x11-dpms
IDLE=$HERE/libexec/vigilance/hooks/x11-idle
mkdir -p "$T/bin" "$T/state"
PATH=$T/bin:$PATH; export PATH

# The server's answer, as a file the fixture can rewrite mid-run. `xset q`
# prints a block; only two lines of it matter here.
XSET_Q=$T/xset-q
XSET_LOG=$T/xset-calls
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"
cat > "$T/bin/xset" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> $XSET_LOG
case "\$1" in
  q) [ -z "\${XSET_RC:-}" ] || exit "\$XSET_RC"
     cat $XSET_Q; exit 0 ;;
esac
exit \${XSET_RC:-0}
EOF
chmod +x "$T/bin/xset"

_dpms() {   # <edge> [kind] -> rc, with the state dir fresh
  rm -rf "$T/state"; mkdir -p "$T/state"
  _rc=0
  env DISPLAY=:0 VIGILANCE_STATE_DIR="$T/state" \
    VIGILANCE_KIND="${2:-act}" PATH="$PATH" \
    sh "$DPMS" "$1" >>"$T/out" 2>>"$T/err" || _rc=$?
  printf '%s' "$_rc"
}

# --- 1. THE INTENT TABLE IS THE RUNNER'S, not restated here -----------------
# A hook that re-derives dark/lit is the defect that once lit a keyboard over a
# dark screen. `unlock` is lit, `sleep` is dark, and an edge with no intent is
# not this hook's business.
: > "$XSET_LOG"
[ "$(_dpms sleep)" = 0 ] || fail "a dark edge failed against a healthy server"
grep -q 'dpms force off' "$XSET_LOG" || fail "the dark edge did not power the
screen off: $(cat "$XSET_LOG")"
: > "$XSET_LOG"
[ "$(_dpms wake)" = 0 ] || fail "a lit edge failed"
grep -q 'dpms force on' "$XSET_LOG" || fail "the lit edge did not power the
screen on: $(cat "$XSET_LOG")"
: > "$XSET_LOG"
[ "$(_dpms nonsense)" = 0 ] || fail "an edge with no intent must be a no-op"
[ ! -s "$XSET_LOG" ] || fail "an edge with no intent touched the server:
$(cat "$XSET_LOG")"

# --- 2. NOT APPLICABLE, three ways, and never exit 0 ------------------------
# "I could not look" is never "I looked and it is fine". Each of these is a real
# deployment: a Wayland box with no xset, a SYSTEM unit with no DISPLAY (the
# same environment gap that makes the locker provider need WAYLAND_DISPLAY told
# to it), and an X server that is not accepting connections.
_rc=0
env DISPLAY= VIGILANCE_STATE_DIR="$T/state" sh "$DPMS" sleep \
  >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "with no DISPLAY the hook returned $_rc, not 78. A unit
or a timer has no session environment, and a hook that claims success there is
one that blanked nothing"
_rc=0
env DISPLAY=:0 XSET_RC=1 VIGILANCE_STATE_DIR="$T/state" sh "$DPMS" sleep \
  >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "with the X server unreachable the hook returned $_rc,
not 78"
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"

# ...AND WITH xset GENUINELY ABSENT. A MINIMAL PATH, because moving the stub
# aside does not remove a real binary two entries later: the fourth instance
# of that shape in this suite. `sh` stays on it deliberately: omitting it once
# made rc=127 wear the costume of a declined hook.
mv "$T/bin/xset" "$T/bin/xset.off"
_minpath=$T/minbin
mkdir -p "$_minpath"
for _need in sh dash readlink dirname basename cat awk tr grep sed cut \
             mkdir rm ls date id env head; do
  _w=$(command -v "$_need" 2>/dev/null) || continue
  ln -sf "$_w" "$_minpath/$_need" 2>/dev/null || true
done
_rc=0
env -i PATH="$_minpath" DISPLAY=:0 HOME="$T" VIGILANCE_STATE_DIR="$T/state" \
  sh "$DPMS" sleep >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "with xset absent the hook returned $_rc, not 78"
[ -z "$(PATH=$_minpath command -v xset 2>/dev/null)" ] \
  || fail "the minimal PATH still reaches a real xset, so that case was about a
renamed stub rather than an absent tool"
mv "$T/bin/xset.off" "$T/bin/xset"

# --- 3. DPMS DISABLED AT THE SERVER IS A REFUSAL, not a no-op ---------------
# `xset dpms force off` with DPMS disabled returns 0 and the screen stays lit.
# That is asserted-versus-actual drift living in the actuator, which is how a
# monitor sat dark for two days behind a green light, so a dark rung must not
# be entered on the strength of it.
printf 'DPMS is Disabled\n  Monitor is On\n' > "$XSET_Q"
: > "$XSET_LOG"
[ "$(_dpms sleep)" = 1 ] || fail "with DPMS disabled at the server, a dark edge
did not FAIL. xset returns 0 for a force that does nothing, so silence here is a
lie about a dark screen"
# ...but a LIT rung is not blocked by it: the screen is already on, which is
# what the ascent wants, and failing here would break every wake on a box that
# simply does not use DPMS.
[ "$(_dpms wake)" = 78 ] || fail "with DPMS disabled, a LIT edge must decline
rather than fail: the screen is already in the state the ascent wants"
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"

# --- 3b. AND A SERVER WITH NO DPMS AT ALL IS 78, NOT A REFUSAL --------------
# ABSENT IS NOT DISABLED. Found by running the hook against a real X server on
# its first day: Xvfb reports no DPMS block whatever, even started with
# `+extension DPMS`, and the first version of this hook read that as "disabled"
# and FAILED every dark edge. A cry-wolf on every sleep, on a server where there
# is nothing to fix and no remedy to name, which is the one thing a check must
# never do, because it teaches a reader to discount the tier.
#
# The two answers differ because only "Disabled" has a remedy (`xset +dpms`) and
# only "Disabled" is a claim about a screen that COULD have gone dark.
printf 'Keyboard Control:\n  auto repeat:  on\nPointer Control:\n' > "$XSET_Q"
[ "$(_dpms sleep)" = 78 ] || fail "on a server with no DPMS extension at all the
hook returned $(_dpms sleep), not 78. Absent is not disabled: nothing to
enable, so a failure here is a permanent false alarm on a substrate that
simply cannot do this (Xvfb, measured)"
[ "$(_dpms wake)" = 78 ] || fail "a lit edge on a server with no DPMS must also
decline"
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"

# --- 4. VERIFY READS THE SERVER BACK, in the server's own vocabulary --------
# It says On / Standby / Suspend / Off, and the three non-On states all mean
# "not scanning out". A check demanding exactly "Off" would call a screen in
# Standby drift, which is the same mistake as expecting one DDC power code from
# every panel.
for _s in Off Standby Suspend; do
  printf 'DPMS is Enabled\n  Monitor is %s\n' "$_s" > "$XSET_Q"
  [ "$(_dpms sleep verify)" = 0 ] || fail "verify called a monitor in $_s state
drift at a dark rung. Standby and Suspend are not scanning out either"
  [ "$(_dpms wake verify)" = 1 ] || fail "verify passed a monitor in $_s
state at
a LIT rung, which is a dark screen the machine believes is on"
done
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"
[ "$(_dpms wake verify)" = 0 ] || fail "verify called a monitor that is On drift
at a lit rung"
[ "$(_dpms sleep verify)" = 1 ] || fail "verify passed a monitor still On
at a dark rung"
# AND AN ANSWER IT CANNOT PARSE IS A FAILURE, not a pass. A server whose output
# changes shape must not read as agreement.
printf 'DPMS is Enabled\n  Monitor is Sideways\n' > "$XSET_Q"
[ "$(_dpms sleep verify)" = 1 ] || fail "an unrecognised monitor state passed
verify. Silence about an answer we cannot read is the conflation exit 78 exists
to break, and here it would certify a dark rung"
printf 'DPMS is Enabled\n  Monitor is On\n' > "$XSET_Q"

# --- 5. THE VERIFY TIER MUST NOT WRITE --------------------------------------
# kbd-rgb shipped that defect: it drove the device and then read it back, so the
# verify healed the drift it was meant to report and sleep.verify.d was
# STRUCTURALLY INCAPABLE of finding anything.
: > "$XSET_LOG"
_dpms sleep verify >/dev/null
grep -q 'force' "$XSET_LOG" && fail "the verify tier issued a force: it repairs
the state it is asked to judge, so it can never report drift:
$(cat "$XSET_LOG")" || :

# --- 6. AND IT THROTTLES, but only for the standing recheck -----------------
# THE STATE MUST MATCH THE RUNG HERE, or this measures the verdict
# rather than the cadence: with the monitor On at a dark rung the verify
# legitimately fails, and "rc=1" would read as "the throttle is broken".
printf 'DPMS is Enabled\n  Monitor is Off\n' > "$XSET_Q"
rm -rf "$T/state"; mkdir -p "$T/state"
_rc=0
env DISPLAY=:0 VIGILANCE_STATE_DIR="$T/state" VIGILANCE_KIND=verify \
  VIGILANCE_RECHECK=1 sh "$DPMS" sleep >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 0 ] || fail "the first recheck verify should run, not skip (rc=$_rc)"
_rc=0
env DISPLAY=:0 VIGILANCE_STATE_DIR="$T/state" VIGILANCE_KIND=verify \
  VIGILANCE_RECHECK=1 sh "$DPMS" sleep >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 75 ] || fail "a second recheck verify inside the window returned
$_rc, not 75 (not due)"
_rc=0
env DISPLAY=:0 VIGILANCE_STATE_DIR="$T/state" VIGILANCE_KIND=verify \
  sh "$DPMS" sleep >>"$T/out" 2>>"$T/err" || _rc=$?
[ "$_rc" = 0 ] || fail "an EXPLICIT verify was throttled (rc=$_rc). 'I looked an
hour ago' is not an answer to 'is the screen dark right now', and lock-on-sleep
runs exactly that before a suspend"

# --- 7. x11-idle: MILLISECONDS IN, SECONDS OUT ------------------------------
# The unit mismatch is the whole risk in that file. Reporting ms as s makes the
# seat look idle a thousand times longer than it is, which INVENTS a finding: a
# false overdue on a machine somebody is sitting at, and false overdue alerts
# are the documented reason a live box had its supervision timer stopped by
# hand.
cat > "$T/bin/xprintidle" <<EOF
#!/bin/sh
[ -z "\${XPI_RC:-}" ] || exit \$XPI_RC
printf '%s\n' "\${XPI_MS:-0}"
EOF
chmod +x "$T/bin/xprintidle"
_idle() {   # -> the answer, or "rc=N"
  _o=$(env DISPLAY=:0 XPI_MS="${1:-}" XPI_RC="${2:-}" PATH="$PATH" \
       sh "$IDLE" 2>>"$T/err") || { printf 'rc=%s' "$?"; return 0; }
  printf '%s' "$_o"
}
[ "$(_idle 480000)" = 480 ] || fail "480000ms read as $(_idle 480000)s, so the
unit conversion is wrong. A thousand-fold overstatement of idle time is a false
overdue on a machine in use"
[ "$(_idle 0)" = 0 ] || fail "zero idle must be reported as 0, not declined: it
is the most important reading there is (input one second ago)"
[ "$(_idle 1999)" = 1 ] || fail "1999ms should floor to 1s, got $(_idle 1999)"

# --- 8. ...AND "I CANNOT TELL" IS 78, NEVER 0 ------------------------------
# 0 means "input one second ago", so a missing answer read as zero would reset
# every deadline for ever and report a healthy machine. This is the sharpest
# instance of the n/a contract in the package.
[ "$(_idle '' 1)" = "rc=78" ] || fail "a failing xprintidle gave
$(_idle '' 1), not 78. Zero would be the single most dangerous wrong answer"
[ "$(_idle banana)" = "rc=78" ] || fail "a non-numeric answer gave
$(_idle banana), not 78. The runner validates too, but a source that knows it
cannot answer must say so rather than lean on the runner"
_rc=0
env DISPLAY= PATH="$PATH" sh "$IDLE" >/dev/null 2>>"$T/err" || _rc=$?
[ "$_rc" = 78 ] || fail "with no DISPLAY x11-idle returned $_rc, not 78"
[ "$(_idle 99999999999999)" = "rc=78" ] || fail "a 14-digit reading was taken;
it overflows the shell's arithmetic, which is how an idle source once leaked
'[: Illegal number:' into a comparison"

# --- 9. THE CEILING IS THE SERVER'S SCREENSAVER TIMEOUT --------------------
# MEASURED AGAINST A REAL SERVER, and the first version of this hook was wrong
# about it: XScreenSaverQueryInfo reports idle time WITHIN the current
# screensaver state, so when the saver activates the counter starts again.
#
#     x11-idle -> 306s     ... 3 seconds later ...     x11-idle -> 2s
#
# So a deadline longer than that timeout can never be witnessed here, which is
# precisely the question `ceiling=` answers, and why the counter clock has
# carried one since a chattering keyboard capped it at 74s. `age` is reported
# equal to the ceiling because the cap is STRUCTURAL and known at the first
# call: report's "too young to have seen that yet" exemption must not excuse a
# hard limit.
printf 'Screen Saver:\n  timeout:  600    cycle:  600\n' > "$XSET_Q"
_a=$(env DISPLAY=:0 XPI_MS=5000 PATH="$PATH" sh "$IDLE")
[ "$_a" = "5 ceiling=600 age=600" ] || fail "with the server's screensaver at
600s the source answered '$_a'. It must report that cap, or report calls a 480s
deadline measurable on a clock that resets before it: the exact false
green the ceiling field was invented for"

# ...AND NO CEILING WHEN THE SCREENSAVER IS OFF, because then the answer really
# does stand on its own. Silence is "no opinion", which the runner passes
# through and report reads as measurable.
printf 'Screen Saver:\n  timeout:  0    cycle:  0\n' > "$XSET_Q"
_a=$(env DISPLAY=:0 XPI_MS=5000 PATH="$PATH" sh "$IDLE")
[ "$_a" = 5 ] || fail "with the screensaver disabled the source still qualified
its answer ('$_a'). A cap that does not exist must not be reported, or every
long deadline reads as unmeasurable on a correctly configured box"

# ...and an xset it cannot run leaves the cap UNKNOWN, which is no opinion
# rather than unbounded: the same direction every other doubt here takes.
mv "$T/bin/xset" "$T/bin/xset.off"
_a=$(env -i PATH="$_minpath:$T/bin" DISPLAY=:0 HOME="$T" XPI_MS=5000 \
     sh "$IDLE" 2>/dev/null || echo "rc=$?")
mv "$T/bin/xset.off" "$T/bin/xset"
[ "$_a" = 5 ] || fail "with xset unavailable the source answered '$_a';
it should still report the idle time it DOES know, unqualified"

pass "x11-dpms and x11-idle, against a stubbed server"
