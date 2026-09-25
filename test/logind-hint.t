#!/bin/sh
# test/logind-hint.t - the hook that keeps logind's LockedHint honest.
#
# IT HAD NO TEST AT ALL, which is how the bug below survived: of the seventeen
# shipped hooks it was the only one not referenced by any test file, and the
# defect was live on both boxes the whole time.
#
# WHAT IT IS FOR. `LockedHint` is the standard answer to "is this session
# locked?", and on this fleet nothing set it, so the standard interface lied.
# vigilant knows the truth because it crosses the edge, so it feeds the stock
# mechanism instead of inventing a private one.
#
# THE BUG, measured live rather than reasoned about:
#
#   21:43:12 cross unlock: lock -> open
#   21:43:12 logind-hint: SetLockedHint false failed for session 2
#
# `loginctl list-sessions --no-legend` PRINTS `-` FOR AN EMPTY SEAT, not an
# empty field, so the old `$4 != ""` excluded nothing and the fallback took the
# first row for the user: logind's seatless `manager` session. The `lock` edge
# comes from the compositor and HAS XDG_SESSION_ID, so it set the hint right;
# the `unlock` edge comes from the locker unit's teardown and does NOT, so it
# fell back to the wrong session and failed. LockedHint went true and was never
# cleared, and logind read `yes` while the depth record, swaylock and
# screen-lock.service all said unlocked.
#
# THE FIXTURE MUST PRINT `-`, or it cannot express the bug -- the same reason a
# boolean lock-unit fixture could not express `activating` and shipped a defect
# to a live box twice. Stubbing loginctl and busctl is legitimate here for the
# opposite reason to usual: they are the trust root, so the test must not create
# real sessions or mutate a real one's hint, and what is under test is the
# hook's CHOICE of session rather than logind's behaviour.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init logind-hint

HOOK=$HERE/libexec/vigilance/hooks/logind-hint
mkdir -p "$T/bin"
PATH="$T/bin:$PATH"; export PATH

# A REAL FLEET LAYOUT, taken from `loginctl list-sessions` on a live box: two
# seatless `manager` bookkeeping sessions first, then the real wayland one. The
# ORDER matters -- the bug was taking the first match, so a fixture listing the
# real session first would pass with the defect present.
cat > "$T/bin/loginctl" <<EOF
#!/bin/sh
case "\$1" in
  list-sessions)
    printf '1 1001 other           -     2093 manager -    no -\n'
    printf '2 1000 %s           -     2088 manager -    no -\n' "\$(id -un)"
    printf '9 1000 %s           seat0 5471 user    tty7 no -\n' "\$(id -un)"
    ;;
  show-session)
    # -p Seat --value
    case "\$2" in
      9) printf 'seat0\n' ;;
      *) printf '\n' ;;
    esac
    ;;
esac
EOF
# busctl RECORDS what it was asked to do, and which session path. That is the
# whole assertion: "it did not fail" would pass with the hint set on the wrong
# session, which is precisely the shipped behaviour.
cat > "$T/bin/busctl" <<EOF
#!/bin/sh
for _a in "\$@"; do printf '%s ' "\$_a"; done >> $T/busctl.log
printf '\n' >> $T/busctl.log
case " \$* " in
  *GetSession*)
    for _a in "\$@"; do _last=\$_a; done
    printf 's "/org/freedesktop/login1/session/_3%s"\n' "\$_last" ;;
  *SetLockedHint*)
    # The real thing REFUSES on a session with no seat, which is what produced
    # "SetLockedHint false failed for session 2" on the live box.
    case " \$* " in *_32*) exit 1 ;; esac ;;
esac
EOF
chmod +x "$T/bin/loginctl" "$T/bin/busctl"

_run() {   # <edge> [XDG_SESSION_ID]
  : > "$T/busctl.log"
  _rc=0
  if [ -n "${2:-}" ]; then
    _out=$(XDG_SESSION_ID=$2 sh "$HOOK" "$1" 2>&1) || _rc=$?
  else
    _out=$(env -u XDG_SESSION_ID sh "$HOOK" "$1" 2>&1) || _rc=$?
  fi
}
_hinted() { grep -c 'SetLockedHint' "$T/busctl.log" 2>/dev/null || true; }
_path_used() {
  sed -n 's/.*session\/_3\([0-9]*\).*/\1/p' "$T/busctl.log" | tail -1
}

# --- 1. THE BUG: no XDG_SESSION_ID must still find the SEATED session -------
# This is the unlock edge as the locker unit's teardown runs it. Before the fix
# the fallback picked session 2 and SetLockedHint failed.
_run unlock
[ "$_rc" = 0 ] || fail "with no XDG_SESSION_ID the hook exited $_rc: $_out
The unlock edge runs from the locker unit's teardown, which has no session id,
so this is the path that runs on every real unlock -- and it picked logind's
seatless 'manager' session because `loginctl` prints '-' for an empty seat and
the old guard tested only for an empty field"
[ "$(_path_used)" = 9 ] || fail "the hint was reported against session
'$(_path_used)', not the seated session 9. Setting it on the wrong session
leaves the real one stale while reporting success, which is the standard
interface lying -- exactly what this hook exists to prevent"

# --- 2. ...and the value must follow the EDGE -------------------------------
grep -q 'SetLockedHint b false' "$T/busctl.log" \
  || fail "the unlock edge did not report false: $(cat "$T/busctl.log")"
_run lock
grep -q 'SetLockedHint b true' "$T/busctl.log" \
  || fail "the lock edge did not report true: $(cat "$T/busctl.log")"

# --- 3. AN UNSEATED XDG_SESSION_ID IS NOT TRUSTED --------------------------
# In a non-interactive ssh that variable names the SSH session (measured:
# Id=2095 Seat= Type=tty Remote=yes). Trusting it sets the hint on a remote tty
# and leaves the graphical session stale, while exiting 0.
_run lock 2
[ "$(_path_used)" = 9 ] || fail "XDG_SESSION_ID named the seatless session 2 and
the hook believed it, reporting against session '$(_path_used)'. An ssh-driven
crossing then updates the wrong session and calls it success"

# --- 4. a seated XDG_SESSION_ID IS trusted, without a lookup ---------------
# The common case. The assertion guards against "always ignore the variable",
# which would pass every case above while adding a loginctl call to every edge.
_run lock 9
[ "$(_path_used)" = 9 ] || fail "a seated XDG_SESSION_ID was not honoured"

# --- 5. NO SEATED SESSION IS n/a, NOT A FAILURE ----------------------------
# A headless server or an ssh-only context has nothing to report against. Exit 1
# would raise hook-failed on every unlock of a machine where nothing is wrong,
# and this path became reachable the moment the seat check started excluding the
# manager session the old code settled for.
cat > "$T/bin/loginctl" <<'EOF'
#!/bin/sh
case "$1" in
  list-sessions) printf '2 1000 someone - 2088 manager - no -\n' ;;
  show-session)  printf '\n' ;;
esac
EOF
chmod +x "$T/bin/loginctl"
_run unlock
[ "$_rc" = 78 ] || fail "with no seated session the hook exited $_rc, not 78.
'I could not look' is not 'I looked and it is fine', and it is not a failure
either: 1 here cries wolf on every headless box"
[ "$(_hinted)" = 0 ] || fail "it set a hint despite having no session to set it
against"

# --- 6. an edge that does not change locked-ness does nothing ---------------
for _e in sleep suspend wake resume; do
  _run "$_e"
  [ "$_rc" = 0 ] || fail "edge '$_e' exited $_rc; it should be a clean no-op"
  [ "$(_hinted)" = 0 ] || fail "edge '$_e' reported a locked-hint, and it does
not change locked-ness"
done

pass
