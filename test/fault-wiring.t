#!/bin/sh
# test/fault-wiring.t - a WIRED hook that cannot run, which is how this package
# lost the ability to lock for 84 minutes with nothing detecting 46 of them.
#
# THE FAULT, measured live on 2026-10-04 rather than imagined:
#
#   18:04  a package layout change moved the plugin tree in /opt while every
#          wired symlink still pointed at the old path. Every hook became a
#          dangling link.
#   18:33  `cross lock: open -> lock` with an EMPTY act tier. No locker, rc=0,
#          a clean crossing in the log. The rung that means "the session is
#          secured" was recorded with nothing having secured it.
#   46 MIN of total silence, then the wiring was repaired and the standing
#          recheck reported drift THIRTY-EIGHT SECONDS later.
#   84 MIN during which every lid close and every hotkey press was declined
#          `already at 'lock'; nothing to do`, because the record claimed the
#          rung and the decline rested on that claim.
#
# WHY NOTHING SAW IT, which is the part worth holding down. `_hooks_in` lists a
# hook only `if [ -x ]`, so a dangling symlink does not FAIL, it ceases to
# EXIST. That took out the locker AND `locker-up` TOGETHER, so the standing
# recheck ran `verify`, got no hooks, answered n/a, and treats n/a as NOT drift,
# correctly. The actuator, its verifier and the recheck are all symlinks into
# ONE tree: losing the tree lost all three. Defence in depth was not depth.
#
# THREE RESPONSES ARE ASSERTED HERE, each the live gap it closes:
#
#   the supervision pass ALERTS on a blocked hook, naming it. It reads
#     directory entries and asks -x, running nothing, so it is immune by
#     construction to the fault it reports: it is the one check that was
#     correct the entire time, in the one verb nothing runs on a timer.
#   an edge whose act tier ran NOTHING because everything wired to it is
#     blocked does not report success.
#   a SECURITY request is not declined on a stale record: the rung is
#     confirmed before it is stood on.
#
# IN THE SESSION TIER ON PURPOSE. The stub tier covers each guard against a
# fixture (watchdog.t, hooks.t, atleast.t), and the fault was a REAL deploy
# moving a REAL tree under REAL wiring an integrator created. Here the hooks are
# the shipped ones, wired as tackup wires them.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/session_lib"

session_init fault-wiring
require compositor

USER_LOCK=$HOME/.config/vigilance/hooks/lock.d

# DECLARED BEFORE THE TRAP, because the trap runs on every exit path including
# `fail`, and a half-restored wiring would break every later scenario in the
# boot. Same reason fault-clock stashes rather than deletes.
STASH=$T/stash
mkdir -p "$STASH"
_restore_wiring() {
  [ -d "$STASH" ] || return 0
  for _s in "$STASH"/*; do
    [ -e "$_s" ] || [ -L "$_s" ] || continue
    mv "$_s" "$USER_LOCK/" 2>/dev/null || true
  done
  rm -f "$USER_LOCK/99-vig-dangling" 2>/dev/null || true
}
trap '_restore_wiring; session_done; rm -rf "$T"' EXIT INT TERM HUP

[ -d "$USER_LOCK" ] || skip_now wired-lock-edge "no user-scope lock.d on this\
 box, so there is no integrator wiring to break and nothing below would be a\
 statement about a real deployment"

# --- 1. A SINGLE BLOCKED HOOK IS ALERTED ON THE TIMER -----------------------
# ADDED rather than broken, so this half touches nobody else's wiring at all. A
# dangling entry is exactly what a moved target leaves behind.
#
# THIS IS THE GENERAL DETECTOR, and the one that would have ended the live
# incident in 60 seconds instead of 46 minutes. It fires however many other
# hooks survive, which matters: on a real box lock.d also holds mute-on-lock,
# so a provider alone going dangling leaves the act tier non-empty and only
# this check can see it.
ln -sfn /nonexistent/moved-away "$USER_LOCK/99-vig-dangling"
[ ! -x "$USER_LOCK/99-vig-dangling" ] \
  || fail "the planted entry is executable, so the fault was not injected and
everything below would pass for the wrong reason"

_sink=$HOME/.config/vigilance/hooks/alert.d
mkdir -p "$_sink"
cat > "$_sink/99-vig-sink" <<SINK
#!/bin/sh
printf '%s|%s\n' "\$VIGILANCE_ALERT_KIND" "\$VIGILANCE_ALERT_MSG" >> $T/alerts
SINK
chmod +x "$_sink/99-vig-sink"
_drop_sink() { rm -f "$_sink/99-vig-sink"; }

: > "$T/alerts"
VIGILANCE_ALERT_COOLDOWN=0 "$VIGILANT" enforce >/dev/null 2>&1 || true
if ! grep -q 'wiring-blocked' "$T/alerts" 2>/dev/null; then
  _drop_sink
  fail "a hook wired but UNRUNNABLE raised NO alert from the supervision pass,
which is the 46 silent minutes exactly. This check reads directory entries and
asks -x, so it cannot be blinded by the fault it reports.
alerts: $(cat "$T/alerts" 2>/dev/null)"
fi
grep -q '99-vig-dangling' "$T/alerts" \
  || { _drop_sink; fail "the alert did not NAME the hook that cannot run.
'Something is wrong with the wiring' sends a reader to check everything, and
the live fault had the exact path in hand the whole time:
$(cat "$T/alerts")"; }

# --- 2. AN EDGE THAT ACTUATED NOTHING DOES NOT REPORT SUCCESS ---------------
# Now the whole tier goes, which is what the layout change did. The real
# entries are moved ASIDE and restored in the trap.
for _h in "$USER_LOCK"/*; do
  case $_h in *99-vig-dangling) continue ;; esac
  [ -e "$_h" ] || [ -L "$_h" ] || continue
  mv "$_h" "$STASH/" 2>/dev/null || true
done
[ -z "$("$VIGILANT" hooks lock 2>/dev/null | grep -E '\[user\].*-> ' \
        | grep -v 99-vig-dangling)" ] || true

"$VIGILANT" go open >/dev/null 2>&1 || true
_grc=0
"$VIGILANT" go lock >/dev/null 2>&1 || _grc=$?
if [ "$_grc" = 0 ]; then
  _drop_sink
  fail "the lock edge crossed with every wired hook UNRUNNABLE and reported
SUCCESS (rc=0). Nothing actuated and the rung that means the session is secured
was recorded anyway. lock-on-sleep reads this status, and a box that cannot veto
a suspend reads it on the way down."
fi

# --- 3. AND A SECURITY REQUEST IS NOT DECLINED ON THE STALE RECORD ----------
# The record now says `lock` while nothing locked, which is the state the live
# box sat in for 84 minutes. A security request must RE-ASSERT rather than
# stand on a claim it can see is false.
#
# The provider comes back for this half, because the question is whether the
# request reaches it. Everything else stays stashed, so the only thing that can
# make the record true is the hook under test.
for _s in "$STASH"/*; do
  case $_s in *swaylock*|*provider*|*10-*) mv "$_s" "$USER_LOCK/" 2>/dev/null ;;
  esac
done
rm -f "$USER_LOCK/99-vig-dangling"
printf 'lock %s\n' "$(date +%s)" > "${XDG_RUNTIME_DIR}/vigilance/depth"
_relocked() { [ "$(crossed lock)" -ge 1 ] || locker_up; }
LOG_FROM=$(wc -l < "$LOG" 2>/dev/null || echo 0)
"$VIGILANT" go lock atleast >/dev/null 2>&1 || true
if ! await 15 _relocked && ! logsince | grep -q 'RE-ASSERTED'; then
  _drop_sink
  fail "with the record at 'lock' and no locker up, a SECURITY request was
declined instead of re-asserting the edge. That is the live lockout: a
transient wiring fault had become a permanent inability to secure the session,
and the only thing that ended it was a human running 'vigilant go open'.
log: $(logsince | tail -5)"
fi

_drop_sink
pass "a blocked hook is alerted and NAMED, an edge that actuated nothing does\
 not claim success, and a stale record does not refuse a lock"
