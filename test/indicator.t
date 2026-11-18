#!/bin/sh
# test/indicator.t - the tray icon for who is keeping the screen awake.
#
# THREE HALVES, each able to fail alone:
#
#   the presenter  pure functions from `vigilant holders --json` to a state,
#                  a ring, a tooltip and the click targets, and the tiles
#                  they draw; no D-Bus, which is imported only by the service
#   the installer  an OPTIONAL install that the core's `check` mentions only
#                  where it exists, and whose own check tells RUNNING from
#                  installed-but-not-running
#   the payload    a core install must carry the tray's venv across its swap,
#                  or every install deletes the tray's environment
set -eu
. "$(dirname "$0")/harness_lib"
harness_init indicator

IND=$HERE/indicator
command -v python3 >/dev/null 2>&1 || skip_now python3 "the tray is python"
# PILLOW GATES THE PRESENTER ONLY. The installer and the payload carry need
# none of it, so a box without it still checks those, and the pass line says
# what was not checked rather than reading as a full pass.
_vskip=
if python3 -c 'import PIL' 2>/dev/null; then :; else _vskip=" pillow"; fi

# --- 1. THE PRESENTER ---------------------------------------------------------
if [ -z "$_vskip" ]; then
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=$IND \
  python3 - "$T" <<'PYEOF' > "$T/py.out" 2>&1 || true
import sys
from vigilance_indicator.__main__ import (COLOUR, next_target, parse_rows,
                                          summarise, tile, icon_pixmap)

fails = []
def want(cond, msg):
    if not cond:
        fails.append(msg)

rows = parse_rows('junk\n{"source": "keep-awake", "who": "keep-awake",'
                  ' "left": 3600, "set": 3600, "go": null}\n[1]\n'
                  '{"source": "10-wayfire", "who": "google-chrome",'
                  ' "go": "view:9", "text": "google-chrome (titan, hidden)"}\n'
                  '{"source": "logind", "who": "Zoom", "go": null,'
                  ' "text": "Zoom (uid 997, pid 5)"}\n')
want(len(rows) == 3, "parse_rows kept %d rows, want 3 (junk skipped)"
     % len(rows))

state, ring, tip, targets = summarise(None)
want(state == "down", "vigilant not answering read as %s" % state)
state, ring, tip, targets = summarise([])
want(state == "quiet" and not targets, "nothing held read as %s" % state)
state, ring, tip, targets = summarise(rows[1:])
want(state == "held", "another holder read as %s" % state)
want(targets == ["10-wayfire:view:9"], "targets %r" % targets)
want("titan" in tip and "Zoom" in tip, "the tooltip did not name every"
     " holder: %r" % tip)
state, ring, tip, targets = summarise(rows)
want(state == "awake", "keep-awake with others read as %s; the user's own"
     " hold must be the loud one" % state)
want(abs(ring - 0.5) < 0.01, "1h of a 2h maximum gave ring %.2f, want 0.5"
     % ring)
want(targets == ["10-wayfire:view:9"], "keep-awake hid the holders' targets")

t = ["a:1", "b:2", "c:3"]
want(next_target(t, None) == "a:1", "first click did not go to the first")
want(next_target(t, "a:1") == "b:2", "the walk did not advance")
want(next_target(t, "c:3") == "a:1", "the walk did not wrap")
want(next_target(t, "gone:9") == "a:1", "a vanished last target stuck")
want(next_target([], "a:1") is None, "no targets still produced one")

# THE FACE IS A CLOCK, scaled to the maximum: 12 o'clock is nothing left, the
# sector runs CLOCKWISE, and 1h of 2h reaches 6 o'clock.
def blue(img):
    px = img.load()
    s = img.size[0]
    return sum(1 for x in range(s) for y in range(s)
               if px[x, y] == COLOUR["awake"] + (0xFF,))
full = blue(tile("awake", 1.0, 48))
half = blue(tile("awake", 0.5, 48))
want(full > 0 and 0.4 < half / full < 0.6,
     "half the time left lit %d of %d, want about half" % (half, full))
want(blue(tile("awake", 0.1, 48)) < half, "the clock did not wind back")
want(blue(tile("awake", 0.0, 48)) == 0, "no time left still lit the face")
q = tile("awake", 0.25, 48).load()
isblue = lambda p: p == COLOUR["awake"] + (0xFF,)
want(isblue(q[34, 14]) and not isblue(q[14, 14]) and not isblue(q[34, 34]),
     "a quarter left did not light 12 to 3 o'clock: the sector must start at"
     " the top and run clockwise")
h = tile("awake", 0.5, 48).load()
want(isblue(h[34, 34]) and not isblue(h[14, 34]),
     "an hour left did not reach 6 o'clock")
# QUIET IS FAINT and round: a corner is empty, the centre barely there.
qt = tile("quiet", 0, 48).load()
want(qt[1, 1][3] == 0, "the quiet icon has a corner, so it is not a circle")
want(0 < qt[24, 24][3] < 0x80, "the quiet face is not faint: alpha %d"
     % qt[24, 24][3])
for st in ("quiet", "held", "awake", "down"):
    pm = icon_pixmap(st, 0.5)
    want([p[0] for p in pm] == [22, 32, 48]
         and all(len(p[2]) == p[0] * p[0] * 4 for p in pm),
         "the %s pixmap is not ARGB32 at 22/32/48" % st)

print("FAIL " + "; ".join(fails) if fails else "OK")
PYEOF
[ "$(tail -1 "$T/py.out")" = OK ] || fail "the presenter: $(cat "$T/py.out")"
fi

# --- 2. THE INSTALLER, with systemctl stubbed --------------------------------
mkdir -p "$T/stub" "$T/venv/bin" "$T/bin" "$T/cfg"
printf '#!/bin/sh\nexit 0\n' > "$T/venv/bin/vigilance-indicator"
ln -sf "$(command -v python3)" "$T/venv/bin/python"
chmod +x "$T/venv/bin/vigilance-indicator"
cat > "$T/stub/systemctl" <<EOF
#!/bin/sh
case "\$*" in
  *is-active*) cat "$T/active" 2>/dev/null || echo inactive ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/stub/systemctl"
_ind() {
  env PATH="$T/stub:$PATH" VI_VENV="$T/venv" VI_BIN="$T/bin" \
    XDG_CONFIG_HOME="$T/cfg" VI_SKIP_BUILD=1 NO_COLOR=1 \
    sh "$IND/setup.sh" "$@"
}
_ind installed && fail "installed reported true before any install"
_ind install > /dev/null 2>&1 || fail "indicator install failed"
_ind installed || fail "installed reported false after an install"
[ -L "$T/bin/vigilance-indicator" ] || fail "no link in the bin dir"
echo inactive > "$T/active"
_out=$(_ind check 2>&1 || true)
printf '%s\n' "$_out" | grep -q 'installed but not running' || fail "an
installed, stopped tray was not reported as such: $_out"
echo active > "$T/active"
_out=$(_ind check 2>&1 || true)
printf '%s\n' "$_out" | grep -q 'vigilance-indicator.service running' \
  || fail "a running tray was not reported running: $_out"

# The core's check mentions the tray ONLY where it is installed.
_core() {
  env PATH="$T/stub:$PATH" PREFIX="$T/pfx" XDG_BIN_HOME="$T/pfx/bin" \
    XDG_DATA_HOME="$T/pfx/share" XDG_CONFIG_HOME="$1" \
    VI_VENV="$T/venv" VI_BIN="$T/bin" NO_COLOR=1 \
    VIGILANCE_ACPI_EVENTS="$T/acpi" sh "$HERE/setup.sh" check 2>&1 || true
}
mkdir -p "$T/acpi" "$T/nocfg"
_out=$(env PATH="$T/stub:$PATH" PREFIX="$T/pfx" XDG_BIN_HOME="$T/pfx/bin" \
  XDG_DATA_HOME="$T/pfx/share" XDG_CONFIG_HOME="$T/nocfg" \
  VI_VENV="$T/venv" VI_BIN="$T/nobin" NO_COLOR=1 \
  VIGILANCE_ACPI_EVENTS="$T/acpi" sh "$HERE/setup.sh" check 2>&1 || true)
printf '%s\n' "$_out" | grep -qi 'indicator' && fail "the core check talked
about a tray this box never installed: $(printf '%s\n' "$_out" \
  | grep -i indicator)"
_out=$(_core "$T/cfg")
printf '%s\n' "$_out" | grep -q 'vigilance-indicator.service running' \
  || fail "the core check did not include an installed tray's state"

# --- 3. THE PAYLOAD CARRIES THE TRAY'S VENV ----------------------------------
# An explicit `install` and a fully sandboxed prefix: setup.sh with no verb
# IS install, which has written into a live home once already.
_inst() {
  env PREFIX="$T/p2" XDG_BIN_HOME="$T/p2/bin" XDG_DATA_HOME="$T/p2/share" \
    XDG_CONFIG_HOME="$T/p2/cfg" NO_COLOR=1 sh "$HERE/setup.sh" install \
    > /dev/null 2>&1
}
_inst || fail "a sandboxed core install failed"
mkdir -p "$T/p2/share/vigilance/venv-indicator/bin"
printf 'marker\n' > "$T/p2/share/vigilance/venv-indicator/bin/marker"
_inst || fail "a second sandboxed core install failed"
[ -f "$T/p2/share/vigilance/venv-indicator/bin/marker" ] || fail "a core
install deleted the tray's venv from the payload, so every install would
leave the tray link pointing at nothing"
[ -x "$T/p2/share/vigilance/bin/vigilant" ] || fail "the carried venv cost
the payload its own contents"

pass "the presenter (states, clicks, a round clock face lit to 6 for 1h), an\
 optional installer that tells running from stopped, and a payload swap\
 that keeps the tray's venv${_vskip:+ (not checked:$_vskip)}"
