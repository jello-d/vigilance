"""vigilance-indicator: a tray icon for who is keeping the screen awake.

A PRESENTER. It reads `vigilant holders --json` and acts only through
`vigilant` (`holder-go`, `keep-awake`), so it keeps no state of its own and
stopping it changes nothing about what locks. Modelled on usher's indicator:
a near-black rounded tile whose FRAME colour is the state, and a depleting
border for a countdown.

THE FRAME IS THE STATE:

  quiet   muted green   nothing holds the screen up
  held    amber         something else does (a compositor inhibitor, a
                        logind idle inhibitor), named in the tooltip
  awake   blue          the user's own keep-awake, the loudest, so it is never
                        forgotten; its border DRAINS as the time runs down,
                        scaled to the maximum, so 1h fills half the border
                        and 2h all of it
  down    grey          vigilant did not answer

THE GESTURES (no right-click menu: like usher's, it has none):

  left click   go to the holder's window; with several, each click goes to
               the next. With nothing else holding, start or extend
               keep-awake (vigilant keep-awake cycle: off, 1h, 2h, off)
  scroll       keep-awake one hour more (up) or less (down), within 0..2h
  middle click keep-awake off

It looks every POLL seconds (5): a holder appearing or going shows within
that. `render-test <dir>` writes one PNG per state for a visual check.

Deps: dbus-next (pure-Python D-Bus) + Pillow, drawn per size, ARGB32 in
network byte order per the StatusNotifierItem spec.
"""
import asyncio
import json
import math
import os
import subprocess
import sys
import time

from PIL import Image, ImageDraw

VIGILANT = os.environ.get("VIGILANT_BIN", "vigilant")
POLL = 5.0
MAX = float(os.environ.get("VIGILANCE_KEEP_AWAKE_MAX", "7200") or 7200)

_BASE = (0x14, 0x15, 0x19)       # near-black screen
_TINT = 0.14                     # state hue bleed into the screen
FRAME = {
    "quiet": (0x54, 0x86, 0x50),  # muted green: quiet, so louder ones win
    "held":  (0xF2, 0xA6, 0x2C),  # amber: something else holds it up
    "awake": (0x3A, 0x9C, 0xF2),  # blue: the user's own keep-awake
    "down":  (0x84, 0x84, 0x8A),  # grey: vigilant did not answer
}
_DULL = FRAME["down"]             # what a draining border leaves behind


# --- the state, from vigilant's own view: PURE --------------------------------
def parse_rows(text):
    """`vigilant holders --json` output as a list of dicts. A line that is
    not an object is skipped rather than allowed to break the view."""
    rows = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _dur(secs):
    secs = int(secs)
    if secs >= 3600:
        return "%dh%02dm" % (secs // 3600, (secs % 3600) // 60)
    return "%dm" % max(1, (secs + 59) // 60)


def summarise(rows):
    """(state, ring, tooltip, targets) from the rows, or the `down` picture
    when rows is None (vigilant did not answer). `ring` is the fraction of
    the keep-awake maximum still left; `targets` the holder-go ids in
    order."""
    if rows is None:
        return "down", 0.0, "vigilant is not answering", []
    awake = [r for r in rows if r.get("source") == "keep-awake"]
    others = [r for r in rows if r.get("source") != "keep-awake"]
    lines = []
    ring = 0.0
    if awake:
        left = awake[0].get("left") or 0
        ring = max(0.0, min(1.0, float(left) / MAX))
        lines.append("Keep-awake: %s left (then the lock, if idle)"
                     % _dur(left))
    for r in others:
        lines.append(r.get("text") or r.get("who") or "a holder")
    targets = ["%s:%s" % (r["source"], r["go"]) for r in others
               if r.get("go") and r.get("source")]
    if awake:
        state = "awake"
    elif others:
        state = "held"
    else:
        state = "quiet"
        lines.append("Nothing is keeping the screen awake")
    hint = []
    if targets:
        hint.append("click: go to it")
    elif not others:
        hint.append("click: keep awake")
    hint.append("scroll: keep-awake +/-1h")
    if awake:
        hint.append("middle-click: keep-awake off")
    lines.append("(" + "; ".join(hint) + ")")
    return state, ring, "\n".join(lines), targets


def next_target(targets, last):
    """The holder after `last` in order, wrapping; the first if `last` is
    gone. PURE, so a click walks the holders whatever the poll did."""
    if not targets:
        return None
    if last in targets:
        return targets[(targets.index(last) + 1) % len(targets)]
    return targets[0]


# --- drawing: PURE -----------------------------------------------------------
def _lift(base, f):
    return tuple(int(base[i] * (1 - f) + 0xFF * f) for i in range(3)) + (0xFF,)


def _screen(state):
    col = FRAME.get(state, FRAME["down"])
    return tuple(int(_BASE[i] * (1 - _TINT) + col[i] * _TINT)
                 for i in range(3)) + (0xFF,)


def _eye(d, s, state):
    # The identity mark: an eye, lifted off the screen. Its pupil takes the
    # frame colour while something holds the screen up, so the glyph and the
    # frame say the same thing at a glance.
    cx, cy = s / 2.0, s / 2.0
    w, h = s * 0.27, s * 0.15
    d.ellipse([cx - w, cy - h, cx + w, cy + h], fill=_lift(_BASE, 0.62))
    r = s * 0.10
    pupil = (FRAME[state] + (0xFF,)) if state in ("held", "awake") \
        else _lift(_BASE, 0.12)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=pupil)


def _perimeter(m, side, r):
    # The rounded-square border centreline from the UPPER-LEFT corner,
    # counter-clockwise, sampled along the edges too, so a leading fraction
    # can end mid-edge.
    L, T, R, B = m, m, m + side, m + side
    pts = []

    def arc(cx, cy, a0, a1):
        n = max(2, int(abs(a1 - a0) / 12))
        for i in range(n + 1):
            a = math.radians(a0 + (a1 - a0) * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))

    def edge(p0, p1):
        n = max(1, int(math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / 3))
        for i in range(1, n + 1):
            pts.append((p0[0] + (p1[0] - p0[0]) * i / n,
                        p0[1] + (p1[1] - p0[1]) * i / n))

    arc(L + r, T + r, 225, 180)
    edge((L, T + r), (L, B - r))
    arc(L + r, B - r, 180, 90)
    edge((L + r, B), (R - r, B))
    arc(R - r, B - r, 90, 0)
    edge((R, B - r), (R, T + r))
    arc(R - r, T + r, 360, 270)
    edge((R - r, T), (L + r, T))
    arc(L + r, T + r, 270, 225)
    return pts


def _border(img, s, frac):
    # The border IS the countdown: blue for the fraction of the maximum still
    # held, dull grey for the rest, so an hour reads as half a frame.
    fw = max(1, s // 11)
    inset = fw / 2.0
    pts = _perimeter(inset, s - 1 - fw, max(1.0, s // 7 - inset))
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + math.hypot(pts[i][0] - pts[i - 1][0],
                                        pts[i][1] - pts[i - 1][1]))
    total = cum[-1] or 1.0
    d = ImageDraw.Draw(img)
    d.line(pts, fill=_DULL + (0xFF,), width=fw, joint="curve")
    a = max(0.0, min(1.0, frac))
    if a <= 0:
        return
    held = [p for p, c in zip(pts, cum) if c >= (1.0 - a) * total]
    if len(held) >= 2:
        d.line(held, fill=FRAME["awake"] + (0xFF,), width=fw, joint="curve")


def tile(state, ring, size):
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = max(2, s // 7)
    fw = max(1, s // 11)
    if state == "awake":
        d.rounded_rectangle([0, 0, s - 1, s - 1], r, fill=_screen(state))
        _border(img, s, ring)
    else:
        d.rounded_rectangle([0, 0, s - 1, s - 1], r, fill=_screen(state),
                            outline=FRAME.get(state, FRAME["down"]) + (0xFF,),
                            width=fw)
    _eye(d, s, state)
    return img


def _to_argb(img):
    rgba = img.tobytes("raw", "RGBA")
    out = bytearray(len(rgba))
    for i in range(0, len(rgba), 4):
        out[i] = rgba[i + 3]
        out[i + 1] = rgba[i]
        out[i + 2] = rgba[i + 1]
        out[i + 3] = rgba[i + 2]
    return bytes(out)


def icon_pixmap(state, ring, sizes=(22, 32, 48)):
    out = []
    for s in sizes:
        t = tile(state, ring, s)
        # Level with the sibling gadgets in the tray, as usher's does: one
        # invisible pixel at the top-right corner.
        t.putpixel((s - 1, 0), (0, 0, 0, 1))
        out.append([s, s, _to_argb(t)])
    return out


# --- talking to vigilant -----------------------------------------------------
def read_rows():
    """The holders, or None when vigilant could not be asked."""
    try:
        p = subprocess.run([VIGILANT, "holders", "--json"],
                           capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    return parse_rows(p.stdout)


def render_test(outdir):
    os.makedirs(outdir, exist_ok=True)
    for state, ring in (("quiet", 0), ("held", 0), ("awake", 1.0),
                        ("awake", 0.5), ("awake", 0.1), ("down", 0)):
        name = "%s-%03d.png" % (state, int(ring * 100))
        tile(state, ring, 48).save(os.path.join(outdir, name))
        print(os.path.join(outdir, name))


def main():
    a = sys.argv[1:]
    if a[:1] == ["render-test"]:
        render_test(a[1] if len(a) > 1 else ".")
        return
    if a[:1] == ["summary"]:
        state, ring, tip, targets = summarise(read_rows())
        print("state %s ring %.2f targets %s\n%s" % (state, ring, targets,
                                                    tip))
        return
    asyncio.run(_run())


# --- SNI service (scaffolding as usher's indicator) --------------------------
def _run():
    from dbus_next import BusType, PropertyAccess
    from dbus_next.aio import MessageBus
    from dbus_next.service import (ServiceInterface, dbus_property, method,
                                   signal)

    WATCHER = "org.kde.StatusNotifierWatcher"
    WATCHER_PATH = "/StatusNotifierWatcher"
    ITEM_PATH = "/StatusNotifierItem"
    SCROLL_GAP = 0.4     # a touchpad sends a burst; one step per burst

    def _sig(state, ring):
        # Redraw only when the picture changes: the state, and the ring in
        # 48 steps, so a two-hour drain redraws every 2.5 minutes at most.
        return (state, round(ring * 48))

    class Indicator(ServiceInterface):
        def __init__(self):
            super().__init__("org.kde.StatusNotifierItem")
            self._last = None
            self._scrolled = 0.0
            self._apply(read_rows(), force=True)

        def _apply(self, rows, force=False):
            state, ring, tip, targets = summarise(rows)
            changed_tip = tip != getattr(self, "_tip", None)
            self._tip, self._targets, self._state = tip, targets, state
            key = _sig(state, ring)
            if force or key != getattr(self, "_key", None):
                self._key = key
                self._pixmap = icon_pixmap(state, ring)
                if not force:
                    self.NewIcon()
            if changed_tip and not force:
                self.NewToolTip()

        def refresh(self):
            self._apply(read_rows())

        @dbus_property(access=PropertyAccess.READ)
        def Category(self) -> "s":
            return "ApplicationStatus"

        @dbus_property(access=PropertyAccess.READ)
        def Id(self) -> "s":
            return "vigilance-indicator"

        @dbus_property(access=PropertyAccess.READ)
        def Title(self) -> "s":
            return "screen awake"

        @dbus_property(access=PropertyAccess.READ)
        def Status(self) -> "s":
            return "Active"

        @dbus_property(access=PropertyAccess.READ)
        def IconName(self) -> "s":
            return ""

        @dbus_property(access=PropertyAccess.READ)
        def IconPixmap(self) -> "a(iiay)":
            return self._pixmap

        @dbus_property(access=PropertyAccess.READ)
        def OverlayIconName(self) -> "s":
            return ""

        @dbus_property(access=PropertyAccess.READ)
        def AttentionIconName(self) -> "s":
            return ""

        @dbus_property(access=PropertyAccess.READ)
        def AttentionIconPixmap(self) -> "a(iiay)":
            return self._pixmap

        @dbus_property(access=PropertyAccess.READ)
        def ToolTip(self) -> "(sa(iiay)ss)":
            return ["", [], "screen awake", self._tip]

        @dbus_property(access=PropertyAccess.READ)
        def ItemIsMenu(self) -> "b":
            return False

        @method()
        def Activate(self, x: "i", y: "i"):
            target = next_target(self._targets, self._last)
            if target:
                self._last = target
                self._spawn("holder-go", target)
            elif self._state != "held":
                self._spawn("keep-awake", "cycle")

        @method()
        def SecondaryActivate(self, x: "i", y: "i"):
            self._spawn("keep-awake", "off")

        @method()
        def Scroll(self, delta: "i", orientation: "s"):
            now = time.monotonic()
            if orientation != "vertical" or now - self._scrolled < SCROLL_GAP:
                return
            self._scrolled = now
            # A tray reports scrolling UP as a negative delta.
            self._spawn("keep-awake", "more" if delta < 0 else "less")

        def _spawn(self, *args):
            asyncio.get_event_loop().create_task(self._act(*args))

        async def _act(self, *args):
            try:
                p = await asyncio.create_subprocess_exec(
                    VIGILANT, *args, stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE)
                _, err = await p.communicate()
                if p.returncode:
                    print("vigilance-indicator: %s refused: %s"
                          % (" ".join(args), err.decode().strip()),
                          flush=True)
            except OSError as e:
                print("vigilance-indicator: %s failed: %s"
                      % (" ".join(args), e), flush=True)
            self.refresh()

        @signal()
        def NewIcon(self):
            pass

        @signal()
        def NewToolTip(self):
            pass

    async def watch(item):
        while True:
            await asyncio.sleep(POLL)
            item.refresh()

    async def go():
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
        item = Indicator()
        bus.export(ITEM_PATH, item)
        name = "org.kde.StatusNotifierItem-%d-1" % os.getpid()
        await bus.request_name(name)

        async def register():
            try:
                intro = await bus.introspect(WATCHER, WATCHER_PATH)
                obj = bus.get_proxy_object(WATCHER, WATCHER_PATH, intro)
                w = obj.get_interface(WATCHER)
                await w.call_register_status_notifier_item(name)
                print("vigilance-indicator: registered %s" % name,
                      flush=True)
            except Exception as e:  # pylint: disable=broad-except
                print("vigilance-indicator: register failed: %s" % e,
                      flush=True)

        # (Re)register whenever the tray watcher appears, so a restarted bar
        # never leaves this invisible.
        di = await bus.introspect("org.freedesktop.DBus",
                                  "/org/freedesktop/DBus")
        dobj = bus.get_proxy_object("org.freedesktop.DBus",
                                    "/org/freedesktop/DBus", di)
        dbus = dobj.get_interface("org.freedesktop.DBus")

        def on_owner(n, old, new):
            if n == WATCHER and new:
                asyncio.get_event_loop().create_task(register())
        dbus.on_name_owner_changed(on_owner)
        try:
            owner = await dbus.call_get_name_owner(WATCHER)
        except Exception:  # pylint: disable=broad-except
            owner = ""
        if owner:
            await register()
        else:
            print("vigilance-indicator: waiting for the tray watcher",
                  flush=True)
        asyncio.create_task(watch(item))
        await asyncio.get_event_loop().create_future()

    return go()


if __name__ == "__main__":
    main()
