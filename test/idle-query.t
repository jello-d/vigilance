#!/bin/sh
# test/idle-query.t - `vigilant idle`: facts for an integrator's battery sleep.
#
# THE CONTRACT (tackup section 11): seconds idle from the ladder's own clock,
# whether something ELSE holds idle off, and the user's keep-awake; 78 for
# "cannot tell"; and callable as ROOT, answering for seat0's active graphical
# session. Each half fails differently:
#
#   app_holder must be null, never false, when the compositor could not be
#     asked: false would let a battery sleep fire mid-video
#   root must never answer for a greeter, a tty or nobody: those are 78, so a
#     caller cannot read an unknown as idle
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init idle-query

_idle() {   # <seconds>
  mkdir -p "$VIGILANCE_HOOK_ROOT/idle.d"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
  chmod +x "$VIGILANCE_HOOK_ROOT/idle.d/10-src"
}
holderhook() {   # <rc> <sentence>
  mkdir -p "$VIGILANCE_HOOK_ROOT/holder.d"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\nexit %s\n' "$2" "$1" \
    > "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
  chmod +x "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
}
_q() {   # -> sets RC, the JSON fields in $T/q as "idle app keep left holder"
  RC=0
  "$VIGILANT" idle --json > "$T/raw" 2>>"$T/stderr" || RC=$?
  python3 -I -c 'import json,sys
o = json.load(open(sys.argv[1]))
print(o["idle_seconds"], o["app_holder"], o["keep_awake"],
      o["keep_awake_left"] is not None, o["holder"])' "$T/raw" \
    > "$T/q" 2>&1 || true
}
_got() { cat "$T/q" 2>/dev/null; }
command -v python3 >/dev/null 2>&1 || skip_now python3 "the test parses JSON"

# --- 1. THE FACTS ------------------------------------------------------------
_idle 1234
holderhook 1 'nothing holds idle off in wayfire'
VIGILANCE_BLOCK_INHIBITED=''; export VIGILANCE_BLOCK_INHIBITED
_q
[ "$RC" = 0 ] || fail "a box with a clock answered rc=$RC"
[ "$(_got)" = "1234 False False False None" ] || fail "nothing held, no
keep-awake: '$(_got)' from $(cat "$T/raw")"

holderhook 0 'google-chrome (titan, pid 7 severance-disp, hidden)'
_q
[ "$(_got)" = "1234 True False False google-chrome (titan, pid 7"\
" severance-disp, hidden)" ] || fail "a compositor holder: '$(_got)'"

holderhook 1 'nothing holds idle off in wayfire'
VIGILANCE_BLOCK_INHIBITED=idle
_q
case "$(_got)" in "1234 True "*) ;;
  *) fail "a logind idle inhibitor (which the ScreenSaver bridge takes) did
not make app_holder true: '$(_got)'" ;; esac
VIGILANCE_BLOCK_INHIBITED=''

# THE ONE THAT MATTERS: the compositor could not be asked.
holderhook 78 'no wayfire answered'
_q
case "$(_got)" in "1234 None "*) ;;
  *) fail "with the compositor unaskable app_holder read '$(_got)'. It must
be null: false would let a battery sleep fire in the middle of a video" ;;
esac

"$VIGILANT" keep-awake 1h > /dev/null
holderhook 1 'nothing holds idle off in wayfire'
_q
case "$(_got)" in "1234 False True True"*) ;;
  *) fail "keep-awake was not reported: '$(_got)'" ;; esac
"$VIGILANT" keep-awake off > /dev/null

# A typo from a root service must not come back as an answer in the text form.
_rc=0; "$VIGILANT" idle --jsno > /dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown argument was answered (rc=$_rc)"

# No idle clock is "cannot tell", never a number.
rm -rf "$VIGILANCE_HOOK_ROOT/idle.d"
_q
[ "$RC" = 78 ] || fail "with no idle clock the query answered rc=$RC"
_idle 1234

# --- 2. AS ROOT: seat0's active graphical session, or 78 ----------------------
mkdir -p "$T/stub"
printf '#!/bin/sh\necho 0\n' > "$T/stub/id"
cat > "$T/stub/loginctl" <<'EOF'
#!/bin/sh
case "$*" in
  "show-seat seat0 -p ActiveSession --value") printf '%s\n' "${Q_SID:-}" ;;
  *" -p Class --value") printf '%s\n' "${Q_CLASS:-}" ;;
  *" -p Type --value")  printf '%s\n' "${Q_TYPE:-}" ;;
  *" -p User --value")  printf '%s\n' "${Q_UID:-}" ;;
  *" -p Name --value")  printf '%s\n' "${Q_NAME:-}" ;;
  *) exit 1 ;;
esac
EOF
# runuser records WHO it ran as, then runs the command WITHOUT production's
# `env -i`: that clean environment is right on a real box and would throw away
# every sandbox variable here, so the child would read this box's real clock.
# So it skips `env -i` and the assignments after it, keeping only the marker
# that stops the child recursing into the root path.
cat > "$T/stub/runuser" <<'EOF'
#!/bin/sh
printf '%s\n' "$2" > "$RANAS"
shift 2; [ "$1" = -- ] && shift
[ "$1" = env ] && shift; [ "$1" = -i ] && shift
while [ "$#" -gt 0 ]; do
  case "$1" in *=*) shift ;; *) break ;; esac
done
exec env VIGILANCE_IDLE_AS_USER=1 "$@"
EOF
RANAS=$T/ranas; export RANAS
chmod +x "$T/stub/id" "$T/stub/loginctl" "$T/stub/runuser"
_root() {   # -> RC; output in $T/raw
  RC=0
  PATH="$T/stub:$PATH" "$VIGILANT" idle --json > "$T/raw" 2>>"$T/stderr" \
    || RC=$?
}
for _c in 'no session:::::' 'greeter:3:greeter:wayland:971:_greetd' \
          'tty:4:user:tty:1000:jello' 'manager:2:manager::1000:jello'; do
  _why=${_c%%:*}; _r=${_c#*:}
  Q_SID=${_r%%:*}; _r=${_r#*:}; Q_CLASS=${_r%%:*}; _r=${_r#*:}
  Q_TYPE=${_r%%:*}; _r=${_r#*:}; Q_UID=${_r%%:*}; Q_NAME=${_r#*:}
  export Q_SID Q_CLASS Q_TYPE Q_UID Q_NAME
  rm -f "$T/ranas"
  _root
  [ "$RC" = 78 ] || fail "as root with $_why on seat0 the query answered
rc=$RC: an unknown must never read as idle"
  [ ! -e "$T/ranas" ] || fail "as root with $_why it ran as $(cat \
    "$T/ranas") anyway"
done
Q_SID=10 Q_CLASS=user Q_TYPE=wayland Q_UID=1000 Q_NAME=jello
export Q_SID Q_CLASS Q_TYPE Q_UID Q_NAME
_root
[ "$RC" = 0 ] || fail "as root with a graphical session the query failed
($RC): $(cat "$T/raw")"
[ "$(cat "$T/ranas" 2>/dev/null)" = jello ] || fail "as root it did not
answer as the active session's user"
case "$(cat "$T/raw")" in '{"idle_seconds": 1234,'*) ;;
  *) fail "as root the facts did not come back: $(cat "$T/raw")" ;; esac

pass "facts with app_holder null when the compositor cannot be asked, 78 with\
 no clock, and as root only for seat0's active graphical session"
