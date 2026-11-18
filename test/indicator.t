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
import math
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
want(state == "awake+held", "keep-awake with others read as %s; the ring"
     " and the inside are independent, so both must show" % state)
want(abs(ring - 0.5) < 0.01, "1h of a 2h maximum gave ring %.2f, want 0.5"
     % ring)
want(targets == ["10-wayfire:view:9"], "keep-awake hid the holders' targets")

t = ["a:1", "b:2", "c:3"]
want(next_target(t, None) == "a:1", "first click did not go to the first")
want(next_target(t, "a:1") == "b:2", "the walk did not advance")
want(next_target(t, "c:3") == "a:1", "the walk did not wrap")
want(next_target(t, "gone:9") == "a:1", "a vanished last target stuck")
want(next_target([], "a:1") is None, "no targets still produced one")

# THE RING IS A CLOCK, scaled to the maximum: 12 o'clock is nothing left, the
# arc runs CLOCKWISE, and 1h of 2h reaches 6 o'clock.
def near(p, col, tol=40):
    return p[3] > 0xC0 and all(abs(p[i] - col[i]) <= tol for i in range(3))
def on_ring(deg, s=48):
    # A point mid-band on the ring, `deg` clockwise from 12 o'clock.
    r = s / 2.0 - s / 11.0 / 2.0
    a = math.radians(deg)
    return int(s / 2.0 + r * math.sin(a)), int(s / 2.0 - r * math.cos(a))
def blue(img):
    px = img.load()
    s = img.size[0]
    return sum(1 for x in range(s) for y in range(s)
               if near(px[x, y], COLOUR["awake"]))
full = blue(tile("awake", 1.0, 48))
half = blue(tile("awake", 0.5, 48))
want(full > 0 and 0.4 < half / full < 0.6,
     "half the time left lit %d of %d, want about half" % (half, full))
want(blue(tile("awake", 0.1, 48)) < half, "the clock did not wind back")
want(blue(tile("awake", 0.0, 48)) == 0, "no time left still lit the ring")
q = tile("awake", 0.25, 48).load()
want(near(q[on_ring(45)], COLOUR["awake"])
     and not near(q[on_ring(315)], COLOUR["awake"])
     and not near(q[on_ring(135)], COLOUR["awake"]),
     "a quarter left did not light 12 to 3 o'clock: the arc must start at"
     " the top and run clockwise")
h = tile("awake", 0.5, 48).load()
want(near(h[on_ring(135)], COLOUR["awake"])
     and not near(h[on_ring(225)], COLOUR["awake"]),
     "an hour left did not reach 6 o'clock")
# THE EYE IS THE APP'S HOLD, independent of the ring: a faint closed slit
# when quiet, wide open on a red face with a catchlight when held. Quiet is
# meant to be ignorable, so it must be FAINT, not merely grey.
inner = (24, 9)                                # inside the ring, above the eye
qt = tile("quiet", 0, 48).load()
want(qt[1, 1][3] == 0, "the quiet icon has a corner, so it is not round")
_ra = qt[on_ring(0)][3]
want(0x30 < _ra < 0xA0, "the quiet ring is not faint: alpha %d" % _ra)
want(qt[24, 15][3] == 0, "the quiet eye is open: a closed one draws nothing"
     " above the slit")
want(0 < qt[24, 24][3] < 0xA0, "the quiet slit is missing or not faint")
for st in ("held", "awake+held"):
    hp = tile(st, 0.5, 48).load()
    want(near(hp[inner], COLOUR["held"]),
         "%s did not turn the face red: %r" % (st, hp[inner]))
    want(near(hp[24, 24], (0x16, 0x14, 0x15), 30),
         "%s has no black pupil at the centre: %r" % (st, hp[24, 24]))
    want(near(hp[28, 20], (0xEC, 0xE4, 0xDA), 60),
         "%s has no catchlight up and right of centre: %r" % (st, hp[28, 20]))
ah = tile("awake+held", 0.5, 48).load()
want(near(ah[on_ring(90)], COLOUR["awake"]), "an app's hold hid the clock")
for st in ("quiet", "held", "awake", "awake+held", "down"):
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

# CURRENT WITH ITS SOURCE: the code is copied into the venv at install, so a
# pull changes nothing that runs, and an integrator that reinstalls only when
# the check fails must be told. A stub venv whose python sees a copied package.
mkdir -p "$T/site"
cp -R "$IND/vigilance_indicator" "$T/site/"
rm "$T/venv/bin/python"
printf '#!/bin/sh\nPYTHONPATH=%s exec python3 "$@"\n' "$T/site" \
  > "$T/venv/bin/python"
chmod +x "$T/venv/bin/python"
_out=$(PYTHONDONTWRITEBYTECODE=1 _ind check 2>&1 || true)
printf '%s\n' "$_out" | grep -q 'indicator code current' || fail "an
installed copy identical to the source was not called current: $_out"
printf '# changed\n' >> "$T/site/vigilance_indicator/__main__.py"
_out=$(PYTHONDONTWRITEBYTECODE=1 _ind check 2>&1 || true)
printf '%s\n' "$_out" | grep -q 'indicator code stale ( __main__.py )' \
  || fail "an installed copy that differs from the source was not called
stale, so a pull would never reach the running tray: $_out"

# ...and the CORE's check, which an integrator runs straight after pulling an
# update, must not FAIL on it: the tray is stale by construction until the
# reinstall later in that run, and a FAIL there rolled the update back.
_out=$(PYTHONDONTWRITEBYTECODE=1 VI_STALE=warn _ind check 2>&1 || true)
printf '%s\n' "$_out" | grep -q '\[WARN\] indicator code stale' || fail "with
VI_STALE=warn a stale copy was not a WARN: $_out"
printf '%s\n' "$_out" | grep -q 'FAIL.*stale' && fail "with VI_STALE=warn a
stale copy still FAILed: $_out"
grep -q 'VI_STALE=warn sh "$_root/indicator/setup.sh" check' "$HERE/setup.sh" \
  || fail "the core check asks the tray without VI_STALE=warn, so pulling an
update fails the core check and an integrator rolls it back"

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

pass "the presenter (states, clicks, a ring lit to 6 for 1h, an eye wide\
 open for an app's hold), an optional installer that tells running from stopped\
 and current from stale, and a payload swap that keeps the tray's\
 venv${_vskip:+ (not checked:$_vskip)}"
