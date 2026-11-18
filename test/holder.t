#!/bin/sh
# test/holder.t - who is holding idle off where logind cannot see?
#
# THE GAP THIS CLOSES, measured on two boxes: an idle timer silent for hours,
# a fresh subscription to the compositor equally deaf, no logind inhibitor,
# and nothing able to say who held idle off. Wayfire keeps its own inhibitors
# as one private counter; the idle-audit plugin (wayfire-mods) lists them, and
# a holder.d source turns that into one line the runner can use.
#
# TWO HALVES, each able to fail alone:
#
#   the hook     wayfire-idle-holder against a FAKE wayfire IPC server, so
#                every answer the plugin can give is reachable, and so is
#                every way the conversation can go wrong. Each wrong way must
#                read as n/a (78) and NEVER as "none held" (1): "none" lets
#                the watchdog call a held idle timer WEDGED with certainty.
#   the runner   the answer reaches `timer`, `report` and every watchdog as
#                held|none|unknown, and a pass asks its sources ONCE, because
#                two answers in one pass could disagree.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init holder

HOOK=$HERE/libexec/hooks/wayfire-idle-holder
command -v python3 >/dev/null 2>&1 || skip_now python3 "the hook is python"

# --- the fake compositor ----------------------------------------------------
# Answers every request with the bytes in $T/reply, framed as wayfire frames
# them (native-endian 32-bit length, then the body). `raw:` sends the rest
# unframed and `close` hangs up, which are the two ways a reply can be wrong.
cat > "$T/fakewf" <<'PYEOF'
import json, os, socket, struct, sys
path, reply_file = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(4)
print("ready", flush=True)
while True:
    conn, _ = srv.accept()
    with conn:
        try:
            (n,) = struct.unpack("=I", conn.recv(4))
            method = json.loads(conn.recv(n)).get("method", "")
        except Exception:
            continue
        # A reply file per method where the test wrote one, so view-info and
        # focus-view can answer differently from idle-audit/list.
        alt = "%s.%s" % (reply_file, method.replace("/", "_"))
        reply = open(alt if os.path.exists(alt) else reply_file, "rb").read()
        if reply == b"close":
            continue
        if reply.startswith(b"raw:"):
            conn.sendall(reply[4:])
            continue
        conn.sendall(struct.pack("=I", len(reply)) + reply)
PYEOF
SOCK=$T/wf.sock
python3 -I "$T/fakewf" "$SOCK" "$T/reply" > "$T/fake.out" 2>&1 &
FAKE=$!
_i=0
until [ -S "$SOCK" ] || [ "$_i" -ge 50 ]; do sleep 0.1; _i=$((_i + 1)); done
[ -S "$SOCK" ] || fail "the fake wayfire never listened"
# The harness's trap is kept, literal and all (it removes $T with the path
# baked in at arm time); the fake server's pid is baked in the same way and
# killed first.
# shellcheck disable=SC2064  # expanding NOW is the point
trap "kill $FAKE 2>/dev/null; rm -rf $_T_LITERAL" EXIT INT TERM

_reply() { printf '%s' "$1" > "$T/reply"; }
_ask() {   # -> sets RC, output in $T/said
  RC=0
  env WAYFIRE_SOCKET="$SOCK" VIGILANCE_KIND=holder python3 "$HOOK" \
    > "$T/said" 2>&1 || RC=$?
}
_said() { cat "$T/said" 2>/dev/null || true; }
_now=$(date +%s)

# --- 1. HELD: one window, named by app, pid, comm, and how long -------------
_reply "{\"inhibited\": true, \"consistent\": true, \"inhibitors\": [
  {\"pid\": 42, \"uid\": 1000, \"comm\": \"chrome\", \"since\": $((_now - 600)),
   \"view-id\": 7, \"app-id\": \"google-chrome\", \"title\": \"Meet\",
   \"mapped\": true, \"minimized\": false, \"visible\": true}]}"
_ask
[ "$RC" = 0 ] || fail "a held inhibitor answered rc=$RC: $(_said)"
case "$(_said)" in
  "google-chrome (pid 42 chrome) held 6"[0-9][0-9]"s") ;;
  *) fail "the holder was not named as app, pid, comm and hold: $(_said)" ;;
esac

# --- 2. HIDDEN, NO WINDOW, and two holders at once ---------------------------
_reply "{\"inhibited\": true, \"consistent\": true, \"inhibitors\": [
  {\"pid\": 42, \"comm\": \"chrome\", \"since\": null, \"view-id\": 7,
   \"app-id\": \"google-chrome\", \"visible\": false},
  {\"pid\": 9, \"comm\": \"player\", \"since\": null, \"view-id\": null,
   \"app-id\": \"\", \"visible\": false}]}"
_ask
[ "$RC" = 0 ] || fail "two holders answered rc=$RC"
[ "$(_said)" = 'google-chrome (pid 42 chrome, hidden); player (pid 9 player,'\
' no window)' ] || fail "two holders, hidden and windowless, read: $(_said).
A hidden window's inhibitor still holds idle off, and saying it is hidden is
what tells a reader it may be a tab nobody is looking at"

# --- 3. INHIBITED WITH NOBODY HOLDING: wayfire's counter has drifted ---------
_reply '{"inhibited": true, "consistent": false, "inhibitors": []}'
_ask
[ "$RC" = 0 ] || fail "a drifted counter must still read as held (idle IS
off), got rc=$RC"
case "$(_said)" in *drifted*) ;;
  *) fail "a drifted counter was not named as one: $(_said)" ;;
esac

# --- 4. NONE: the compositor holds idle off for nobody ------------------------
_reply '{"inhibited": false, "consistent": true, "inhibitors": []}'
_ask
[ "$RC" = 1 ] || fail "nothing held must answer 1, got rc=$RC: $(_said)"

# --- 5. EVERY WRONG CONVERSATION IS n/a, NEVER "NONE" -------------------------
for _bad in '{"error": "No such method found!"}' 'raw:not json' 'close' \
            '[1, 2, 3]' '{"inhibitors": "nonsense"}'; do
  _reply "$_bad"
  _ask
  [ "$RC" = 78 ] || fail "a reply of '$_bad' answered rc=$RC: $(_said). Only
78 is safe here: 1 would tell the watchdog the compositor holds nothing"
done
RC=0
env -u WAYFIRE_SOCKET XDG_RUNTIME_DIR="$T/nothing" VIGILANCE_KIND=holder \
  python3 "$HOOK" > "$T/said" 2>&1 || RC=$?
[ "$RC" = 78 ] || fail "with no wayfire socket at all the hook answered $RC"

# --- 6. THE RUNNER: timer, report, and the watchdog's three answers ----------
holderhook() {   # <rc> <sentence>  (also counts how often it is asked)
  mkdir -p "$VIGILANCE_HOOK_ROOT/holder.d"
  printf '#!/bin/sh\necho x >> "%s"\nprintf "%%s\\n" "%s"\nexit %s\n' \
    "$T/asked" "$2" "$1" > "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
  chmod +x "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
}
# A watchdog that records what it was handed, and declines.
mkdir -p "$VIGILANCE_HOOK_ROOT/watchdog.d"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$VIGILANCE_IDLE_HELD"'\
' "$VIGILANCE_IDLE_HOLDER" > "%s"\nexit 78\n' "$T/handed" \
  > "$VIGILANCE_HOOK_ROOT/watchdog.d/10-rec"
chmod +x "$VIGILANCE_HOOK_ROOT/watchdog.d/10-rec"

"$VIGILANT" timer > "$T/view" 2>&1 || true
grep -q '^holder:' "$T/view" && fail "with no holder.d source wired the timer
view printed a holder line anyway, which is noise on every box without one"

holderhook 0 'google-chrome (pid 42 chrome, hidden) held 900s'
"$VIGILANT" timer > "$T/view" 2>&1 || true
grep -q '^holder:   google-chrome (pid 42 chrome, hidden)' "$T/view" \
  || fail "the timer view did not show the holder: $(cat "$T/view")"
_rep=$("$VIGILANT" report 2>&1 || true)
printf '%s\n' "$_rep" | grep -q 'idle held off in the compositor by:'\
' google-chrome' || fail "report did not show the holder beside the idle
clock: $(printf '%s\n' "$_rep" | sed -n '/-- deadlines --/,/^--/p')"

# ASKED ONCE, with BOTH callers in the pass: a deadline being deferred (the
# unnamed escalation asks to name its holder) AND a watchdog. With only one
# caller this assertion could not fail, whatever the cache did.
mkdir -p "$VIGILANCE_HOOK_ROOT/lock.due.d" "$VIGILANCE_HOOK_ROOT/idle.d" \
  "$VIGILANCE_HOOK_ROOT/concur.d"
printf '#!/bin/sh\necho "480 idle"\n' > "$VIGILANCE_HOOK_ROOT/lock.due.d/10-d"
printf '#!/bin/sh\necho 900\n' > "$VIGILANCE_HOOK_ROOT/idle.d/10-i"
printf '#!/bin/sh\necho "saw none of it"\nexit 1\n' \
  > "$VIGILANCE_HOOK_ROOT/concur.d/10-c"
chmod +x "$VIGILANCE_HOOK_ROOT/lock.due.d/10-d" \
  "$VIGILANCE_HOOK_ROOT/idle.d/10-i" "$VIGILANCE_HOOK_ROOT/concur.d/10-c"
printf 'open %s\n' "$(( $(date +%s) - 9999 ))" > "$VIGILANCE_RUN_DIR/depth"
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$VIGILANCE_RUN_DIR/last-ascent"
: > "$T/asked"
"$VIGILANT" enforce > /dev/null 2>&1 || true
grep -q 'deferred by an idle inhibitor: google-chrome' "$VIGILANCE_LOG" \
  || fail "precondition: the deferral never asked for its holder, so the
asked-once check below would be about one caller: $(cat "$VIGILANCE_LOG")"
[ "$(cat "$T/handed" 2>/dev/null)" = 'held|google-chrome (pid 42 chrome,'\
' hidden) held 900s' ] || fail "a watchdog was not handed the holder: $(cat \
  "$T/handed" 2>/dev/null)"
[ "$(wc -l < "$T/asked")" -le 1 ] || fail "one pass asked the holder sources
$(wc -l < "$T/asked") times; two answers in one pass could disagree"

holderhook 1 'nothing holds idle off in wayfire'
"$VIGILANT" enforce > /dev/null 2>&1 || true
case "$(cat "$T/handed" 2>/dev/null)" in none\|*) ;;
  *) fail "a source answering NONE reached the watchdog as: $(cat \
    "$T/handed" 2>/dev/null)" ;;
esac
holderhook 78 'no wayfire answered'
"$VIGILANT" enforce > /dev/null 2>&1 || true
case "$(cat "$T/handed" 2>/dev/null)" in unknown\|*) ;;
  *) fail "a source that could not ask reached the watchdog as: $(cat \
    "$T/handed" 2>/dev/null)" ;;
esac

# --- 7. WHOSE, THE JSON FORM, AND GOING THERE --------------------------------
# An enclave window carries a security context; its holder is that enclave's,
# not the pid of the proxy that relays its traffic.
_reply "{\"inhibited\": true, \"consistent\": true, \"inhibitors\": [
  {\"pid\": 7, \"comm\": \"severance-disp\", \"since\": null, \"view-id\": 32,
   \"app-id\": \"google-chrome\", \"visible\": false}]}"
printf '%s' '{"result": "ok", "info": {"id": 32, "security-context":
  {"sandbox-engine": "severance", "app-id": "", "instance-id": "titan"}}}' \
  > "$T/reply.window-rules_view-info"
_ask
case "$(_said)" in "google-chrome (titan, pid 7 severance-disp, hidden)") ;;
  *) fail "an enclave holder was not attributed to its enclave: $(_said)" ;;
esac
RC=0
env WAYFIRE_SOCKET="$SOCK" VIGILANCE_KIND=holder VIGILANCE_HOLDER_FORMAT=json \
  python3 "$HOOK" > "$T/said" 2>&1 || RC=$?
_j=$(python3 -I -c 'import json,sys
o = json.loads(open(sys.argv[1]).read())
print(o["who"], o["owner"], o["window"], o["visible"], o["go"])' "$T/said" \
  2>&1)
[ "$_j" = "google-chrome titan 32 False view:32" ] || fail "the JSON form read
'$_j' from: $(_said)"
printf '%s' '{"result": "ok"}' > "$T/reply.window-rules_focus-view"
RC=0
env WAYFIRE_SOCKET="$SOCK" VIGILANCE_KIND=holder python3 "$HOOK" go view:32 \
  > "$T/said" 2>&1 || RC=$?
[ "$RC" = 0 ] || fail "go view:32 with wayfire agreeing answered $RC: $(_said)"
printf '%s' '{"error": "no such view"}' > "$T/reply.window-rules_focus-view"
RC=0
env WAYFIRE_SOCKET="$SOCK" VIGILANCE_KIND=holder python3 "$HOOK" go view:32 \
  > "$T/said" 2>&1 || RC=$?
[ "$RC" = 1 ] || fail "a refused focus answered $RC"
RC=0
env WAYFIRE_SOCKET="$SOCK" VIGILANCE_KIND=holder python3 "$HOOK" go 'x;rm' \
  > "$T/said" 2>&1 || RC=$?
[ "$RC" = 1 ] || fail "a token the hook never issued was acted on ($RC)"
rm -f "$T/reply.window-rules_view-info" "$T/reply.window-rules_focus-view"

# --- 8. vigilant holders: every source, as text and as one object per line --
mkdir -p "$T/stub"
cat > "$T/stub/systemd-inhibit" <<'EOF'
#!/bin/sh
cat <<'ROWS'
WHO                UID  USER   PID  COMM    WHAT          WHY       MODE
Zoom Meeting       997  titan  555  zoom    idle          in a call block
swayidle           1000 jello  66   swayidl sleep         preventing delay
ROWS
EOF
chmod +x "$T/stub/systemd-inhibit"
holderhook 0 'google-chrome (pid 42 chrome, hidden) held 900s'
printf '%s\n' '#!/bin/sh' \
  'if [ "${VIGILANCE_HOLDER_FORMAT:-}" = json ]; then' \
  '  echo "{\"who\": \"google-chrome\", \"go\": \"view:9\", \"text\": \"g\"}"' \
  'else echo "google-chrome (pid 42 chrome, hidden)"; fi' \
  'if [ "$1" = go ]; then echo "$2" > '"'$T/went'"'; exit 0; fi' \
  'exit 0' > "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
chmod +x "$VIGILANCE_HOOK_ROOT/holder.d/10-h"
"$VIGILANT" keep-awake 1h > /dev/null
PATH="$T/stub:$PATH" "$VIGILANT" holders > "$T/h.txt" 2>&1 || true
for _want in 'keep-awake: 3' \
             'logind: Zoom Meeting (uid 997, pid 555): in a call' \
             '10-h: google-chrome (pid 42 chrome, hidden)'; do
  grep -q "^$_want" "$T/h.txt" || fail "holders did not list '$_want':
$(cat "$T/h.txt")"
done
grep -q swayidle "$T/h.txt" && fail "a sleep-only inhibitor was listed as
holding the screen up: $(cat "$T/h.txt")"
PATH="$T/stub:$PATH" "$VIGILANT" holders --json > "$T/h.json" 2>&1 || true
_j=$(python3 -I -c 'import json,sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(" ".join("%s/%s/%s" % (r["source"], r["who"], r.get("go")) for r in rows))
print([r.get("why") for r in rows if r["source"] == "logind"])
' "$T/h.json" 2>&1)
# THE WHY IS CARRIED: for a relay such as the ScreenSaver bridge it is the only
# place the real app is named, so a tray showing WHO alone names the relay.
[ "$_j" = "keep-awake/keep-awake/None logind/Zoom Meeting/None"\
" 10-h/google-chrome/view:9
['in a call']" ] || fail "holders --json read '$_j' from:
$(cat "$T/h.json")"
"$VIGILANT" keep-awake off > /dev/null

# --- 9. holder-go routes the token back to the source that issued it --------
rm -f "$T/went"
"$VIGILANT" holder-go 10-h:view:9 > /dev/null 2>&1 || fail "holder-go to a
wired source failed"
[ "$(cat "$T/went" 2>/dev/null)" = view:9 ] || fail "the source was handed
'$(cat "$T/went" 2>/dev/null)', not its own token view:9"
for _bad in 'nope:view:9' 'view9' '../x:view:9'; do
  _rc=0; "$VIGILANT" holder-go "$_bad" > /dev/null 2>&1 || _rc=$?
  [ "$_rc" = 2 ] || fail "holder-go '$_bad' answered $_rc, want 2"
done

pass "the hook names (whose included), says none, flags drift, reads every\
 bad reply as n/a, emits JSON and goes there; holders merges every source,\
 holder-go routes home; the runner hands watchdogs held|none|unknown, once"
