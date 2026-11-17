#!/bin/sh
# test/power-key.t - a press of the power key lights a dark display.
#
# THREE THINGS, each able to fail on its own:
#
#   the trigger    wakes the ACTIVE seat user's ladder with `go lock atmost`,
#                  labelled, debounced, and does nothing when there is no one
#                  to wake. logind, runuser and vigilant are stubbed: the first
#                  two are the system, and the suite never asks root of a test.
#   the rule       matches the power key and nothing else acpid reports.
#   the check      tells ARMED from merely placed, and fails a second rule on
#                  the same key, since acpid runs every match.
set -eu
. "$(dirname "$0")/harness_lib"
harness_init power-key

TRIG=$HERE/libexec/triggers/power-key
RULE=$HERE/acpi/vigilance-power-key
mkdir -p "$T/stub" "$T/run/1000" "$T/run/971" "$T/state"

# --- stubs ------------------------------------------------------------------
# loginctl answers from PK_* so each case states the seat it models. One
# property per call, which is how the trigger asks.
cat > "$T/stub/loginctl" <<'EOF'
#!/bin/sh
case "$*" in
  "show-seat seat0 -p ActiveSession --value") printf '%s\n' "${PK_SID:-}" ;;
  *" -p Class --value") printf '%s\n' "${PK_CLASS:-}" ;;
  *" -p User --value")  printf '%s\n' "${PK_UID:-}" ;;
  *" -p Name --value")  printf '%s\n' "${PK_NAME:-}" ;;
  *) exit 1 ;;
esac
EOF
cat > "$T/stub/getent" <<EOF
#!/bin/sh
printf '%s:x:1:1::%s:/bin/sh\n' "\$2" "$T/home/\$2"
EOF
# runuser records WHO it was asked to run as, then runs the rest unchanged.
cat > "$T/stub/runuser" <<EOF
#!/bin/sh
[ "\$1" = -u ] || exit 9
printf '%s\n' "\$2" >> "$T/runuser"
shift 2; [ "\$1" = -- ] && shift
exec "\$@"
EOF
cat > "$T/stub/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF
# vigilant records its argv and the environment it was handed.
cat > "$T/vigilant" <<EOF
#!/bin/sh
printf 'args=%s src=%s run=%s user=%s home=%s\n' "\$*" \
  "\${VIGILANCE_SOURCE:-}" "\${XDG_RUNTIME_DIR:-}" "\${USER:-}" "\${HOME:-}" \
  >> "$T/calls"
EOF
chmod +x "$T/stub/"* "$T/vigilant"

_press() {   # run the trigger once; prints its exit status
  _r=0
  env PATH="$T/stub:$PATH" VIGILANT="$T/vigilant" \
    VIGILANCE_POWER_KEY_STATE="$T/state" \
    VIGILANCE_POWER_KEY_RUN_ROOT="$T/run" \
    sh "$TRIG" "$@" > "$T/said" 2>&1 || _r=$?
  printf '%s' "$_r"
}
_calls() { if [ -f "$T/calls" ]; then wc -l < "$T/calls"; else echo 0; fi; }
# The wake is DETACHED, so its record lands a moment after the trigger exits.
_await_calls() {   # <n>
  _i=0
  while [ "$(_calls)" -lt "$1" ] && [ "$_i" -lt 50 ]; do
    sleep 0.1; _i=$((_i + 1))
  done
}
_reset() { rm -f "$T/calls" "$T/runuser" "$T/state/last"; }

# --- 1. THE WAKE: the seat's user, the right verb, labelled -----------------
_reset
export PK_SID=10 PK_CLASS=user PK_UID=1000 PK_NAME=jello
[ "$(_press)" = 0 ] || fail "a press with an active user session failed:
$(cat "$T/said")"
_await_calls 1
[ "$(_calls)" = 1 ] || fail "a press woke the ladder $(_calls) time(s), want 1"
_c=$(cat "$T/calls")
case "$_c" in "args=go lock atmost "*) ;; *)
  fail "the press ran '$_c'. It must be exactly 'go lock atmost': plain 'go
lock' would LOCK a machine in use from open, and 'atleast' would never light a
dark one" ;;
esac
case "$_c" in *" src=power-key "*) ;; *)
  fail "the press was not labelled power-key, so the log cannot say why the
screen came back: $_c" ;;
esac
case "$_c" in *" run=$T/run/1000 "*) ;; *)
  fail "the wake did not run in the seat user's runtime dir, so it would raise
a ladder that is not theirs: $_c" ;;
esac
[ "$(cat "$T/runuser")" = jello ] || fail "the wake ran as
'$(cat "$T/runuser")', not as the active session's user"
grep -q 'waking the display for jello' "$T/said" || fail "the press logged
nothing, and acpid's syslog line is the only trace a press leaves:
$(cat "$T/said")"

# --- 2. DEBOUNCE: one press, possibly reported twice -----------------------
[ "$(_press)" = 0 ] || fail "a debounced repeat failed"
sleep 0.3
[ "$(_calls)" = 1 ] || fail "a second event inside the debounce window woke
the ladder again. One press can arrive through both the input layer and
netlink"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$T/state/last"
[ "$(_press)" = 0 ] || fail "a press after the window failed"
_await_calls 2
[ "$(_calls)" = 2 ] || fail "a press AFTER the debounce window was swallowed"
# A clock that stepped back must not suppress every press until it catches up.
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$T/state/last"
[ "$(_press)" = 0 ] || fail "a press after a backward clock step failed"
_await_calls 3
[ "$(_calls)" = 3 ] || fail "a stamp from the FUTURE suppressed the press: a
backward clock step would silence the power key for as long as the skew"

# --- 3. A GREETER is a user like any other ----------------------------------
_reset
export PK_SID=3 PK_CLASS=greeter PK_UID=971 PK_NAME=_greetd
[ "$(_press)" = 0 ] || fail "a press on the greeter failed"
_await_calls 1
[ "$(cat "$T/runuser" 2>/dev/null)" = _greetd ] || fail "a press at the
greeter did not wake the greeter's own ladder"

# --- 4. NOTHING TO WAKE is a quiet no-op, never an error and never a wake ----
_nowake() {   # <why>
  _reset
  _rc=$(_press)
  sleep 0.3
  [ "$(_calls)" = 0 ] || fail "$1, and the trigger woke something anyway:
$(cat "$T/calls")"
  printf '%s' "$_rc"
}
export PK_SID= PK_CLASS= PK_UID= PK_NAME=
[ "$(_nowake 'no active session on seat0')" = 0 ] || fail "no session on the
seat must be a quiet exit 0: $(cat "$T/said")"
export PK_SID=2 PK_CLASS=manager PK_UID=1000 PK_NAME=jello
[ "$(_nowake 'the active session is a manager')" = 0 ] \
  || fail "a non-user session class must be a quiet exit 0"
export PK_SID=10 PK_CLASS=user PK_UID=1001 PK_NAME=jello
[ "$(_nowake 'the user has no runtime dir')" = 0 ] \
  || fail "a missing runtime dir must be a quiet exit 0"
# These two reach runuser and a path from a root shell, so a value that is not
# plainly a uid or a user name stops it.
export PK_UID='1000;x' PK_NAME=jello
[ "$(_nowake 'the uid is not a number')" = 1 ] \
  || fail "a non-numeric uid was not refused"
export PK_UID=1000 PK_NAME='-x'
[ "$(_nowake 'the name starts with a dash')" = 1 ] \
  || fail "a user name runuser would read as an option was not refused"

# --- 5. THE EVENT TEXT IS NEVER USED -----------------------------------------
# acpid can hand an action the event text; the rule does not, and the trigger
# takes no arguments. Anything passed is ignored rather than interpreted.
_reset
export PK_SID=10 PK_CLASS=user PK_UID=1000 PK_NAME=jello
[ "$(_press 'button/power PBTN; touch '"$T"'/pwned')" = 0 ] \
  || fail "a press carrying event text failed"
_await_calls 1
[ ! -e "$T/pwned" ] || fail "event text reached a shell"
case "$(cat "$T/calls")" in "args=go lock atmost "*) ;; *)
  fail "event text changed what the trigger ran" ;;
esac

# --- 6. THE RULE: the power key, and only the power key ---------------------
_re=$(sed -n 's/^event=//p' "$RULE")
for _ev in 'button/power PBTN 00000080 00000000' \
           'button/power PWRF 00000080 00000001'; do
  printf '%s\n' "$_ev" | grep -Eq -- "$_re" \
    || fail "the rule's event '$_re' does not match '$_ev'"
done
for _ev in 'button/sleep SBTN 00000080 00000000' \
           'button/lid LID close' 'ac_adapter ACPI0003:00 00000080 00000000' \
           'button/powerx PBTN 00000080 00000000'; do
  printf '%s\n' "$_ev" | grep -Eq -- "$_re" \
    && fail "the rule's event '$_re' also matches '$_ev'"
done
grep -v '^#' "$RULE" | grep -q '%e' && fail "the rule passes %e, putting event
text in a root shell"
[ "$(sed -n 's/^action=//p' "$RULE")" = '@PLUGINS@/triggers/power-key' ] \
  || fail "the rule's action is not the templated trigger path"

# --- 7. THE CHECK: armed, not merely placed ---------------------------------
# A sandboxed events dir and stubbed acpid/systemctl/journalctl, so the verdict
# is about the fixture and never the host's acpid.
EV=$T/acpi-events
mkdir -p "$EV" "$T/cstub"
cat > "$T/cstub/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  "is-active acpid.service") printf '%s\n' "${ACPID_STATE:-active}" ;;
  *"show acpid.service -p ActiveEnterTimestamp --value"*)
    printf '%s\n' "${ACPID_SINCE:-}" ;;
  *) exit 0 ;;
esac
EOF
cat > "$T/cstub/journalctl" <<'EOF'
#!/bin/sh
if [ -n "${ACPID_RELOAD:-}" ]; then
  printf '%s.000000 box acpid[1]: 2 rules loaded\n' "$ACPID_RELOAD"
fi
exit 0
EOF
printf '#!/bin/sh\n' > "$T/cstub/acpid"
chmod +x "$T/cstub/"*
_render() {
  sed "s|@PLUGINS@|$HERE/libexec|" "$RULE" \
    > "$EV/vigilance-power-key"
}
_check() {   # -> the power-key lines of `setup.sh check`
  env PATH="$T/cstub:$PATH" PREFIX="$T/pfx" XDG_BIN_HOME="$T/pfx/bin" \
    XDG_DATA_HOME="$T/pfx/share" XDG_CONFIG_HOME="$T/pfx/cfg" NO_COLOR=1 \
    VIGILANCE_ACPI_EVENTS="$EV" VIGILANCE_ACPID_LOCK="$T/acpid.lock" \
    sh "$HERE/setup.sh" check 2>&1 | grep 'power key' || true
}
_has() {   # <marker> <text> <why>
  _out=$(_check)
  printf '%s\n' "$_out" | grep -F "[$1]" | grep -qF "$2" \
    || fail "$3. The check said:
$_out"
}
_now=$(date +%s)
export ACPID_STATE=active ACPID_SINCE= ACPID_RELOAD=

_has WARN 'not placed' "with no rule placed the power key is an integrator
task, and the check must say it is not placed"

_render
touch -d "@$((_now - 100))" "$EV/vigilance-power-key"
ACPID_RELOAD=$((_now - 50))
_has OK 'armed' "a placed rule, a running acpid and a reload after the rule
was placed is ARMED"

ACPID_RELOAD=$((_now - 200))
_has FAIL 'not reloaded' "acpid's last load predates the rule, so the rule
is not in force, and the check called it armed"
ACPID_SINCE="@$((_now - 10))"
ACPID_RELOAD=
_has OK 'armed' "acpid STARTED after the rule was placed, which loads it"

ACPID_STATE=inactive
_has FAIL "acpid.service is 'inactive'" "a placed rule with acpid stopped is
nothing listening"
ACPID_STATE=active

: > "$T/acpid.lock"
_has FAIL 'PAUSED' "acpid's lock file pauses every event, and a paused acpid
was not reported"
rm -f "$T/acpid.lock"

rm -f "$T/cstub/acpid"
_has FAIL 'not installed' "a placed rule with no acpid installed is nothing
reading it"
printf '#!/bin/sh\n' > "$T/cstub/acpid"; chmod +x "$T/cstub/acpid"

printf 'event=button/power.*\naction=/sbin/shutdown -h now\n' > "$EV/powerbtn"
_has FAIL 'match the same press' "a second rule on the power key runs on the
same press, and the stock one shuts the machine down"
# One acpid would not load, by its own naming rule, is not a second handler.
mv "$EV/powerbtn" "$EV/.powerbtn"
_out=$(_check)
printf '%s\n' "$_out" | grep -q 'match the same press' && fail "a rule acpid
skips (a leading dot) was counted as a second handler:
$_out"
rm -f "$EV/.powerbtn"
printf 'event=button/lid.*\naction=/bin/true\n' > "$EV/lid"
_out=$(_check)
printf '%s\n' "$_out" | grep -q 'match the same press' && fail "a rule for a
DIFFERENT event was reported as handling the power key:
$_out"
rm -f "$EV/lid"

sed -i "s|^action=.*|action=$T/nowhere/power-key|" "$EV/vigilance-power-key"
_has FAIL 'not an executable' "the rule's action resolves to nothing, so every
press runs nothing"

pass "the wake, debounce, nothing-to-wake, the rule, and the check's states"
