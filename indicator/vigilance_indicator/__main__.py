"""vigilance-indicator: a tray icon for who is keeping the screen awake.

A PRESENTER. It reads `vigilant holders --json` and acts only through
`vigilant` (`holder-go`, `keep-awake`), so it keeps no state of its own and
stopping it changes nothing about what locks. A CIRCLE, so it does not run
together with the square icons beside it in a tray.

THE FACE IS THE STATE:

  quiet   faint grey disc   nothing holds the screen up
  held    amber disc        something else does (a compositor inhibitor, a
                            logind idle inhibitor), named in the tooltip
  awake   a blue clock      the user's own keep-awake: lit clockwise from
                            12 o'clock for the time left, scaled to the
                            maximum, so 1h reaches 6 o'clock and 2h is the
                            whole face; it winds back toward 12 as it runs
  down    an empty slashed  vigilant did not answer
          grey ring

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
import os
import subprocess
import sys
import time

from PIL import Image, ImageDraw

VIGILANT = os.environ.get("VIGILANT_BIN", "vigilant")
POLL = 5.0
MAX = float(os.environ.get("VIGILANCE_KEEP_AWAKE_MAX", "7200") or 7200)

COLOUR = {
    "held":  (0xF2, 0xA6, 0x2C),  # amber: something else holds it up
    "awake": (0x3A, 0x9C, 0xF2),  # blue: the user's own keep-awake
    "down":  (0x84, 0x84, 0x8A),  # grey: the quiet face, and vigilant silent
}


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
# A CIRCLE, NOT A TILE: a tray full of rounded squares runs together, and a
# round face also reads as the clock the keep-awake is. Drawn OVERSAMPLE times
# larger and scaled down, which is the antialiasing Pillow's shapes lack.
OVERSAMPLE = 4
_FAINT = 0x50                     # the quiet face: there, and easy to ignore


def _rgba(col, alpha=0xFF):
    return tuple(col) + (alpha,)


def tile(state, ring, size):
    big = size * OVERSAMPLE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    lw = max(OVERSAMPLE, big // 12)
    box = [lw // 2, lw // 2, big - 1 - lw // 2, big - 1 - lw // 2]
    grey = COLOUR["down"]
    if state == "down":
        # An empty face with a slash: nothing answered, so nothing is shown.
        d.ellipse(box, outline=_rgba(grey, 0x90), width=lw)
        d.line([box[0] + big * 0.18, box[3] - big * 0.18,
                box[2] - big * 0.18, box[1] + big * 0.18],
               fill=_rgba(grey, 0x90), width=lw)
    elif state == "held":
        d.ellipse(box, fill=_rgba(COLOUR["held"]))
    else:
        d.ellipse(box, fill=_rgba(grey, _FAINT),
                  outline=_rgba(grey, 0x90), width=lw)
        a = max(0.0, min(1.0, ring)) if state == "awake" else 0.0
        if a >= 1.0:
            d.ellipse(box, fill=_rgba(COLOUR["awake"]))
        elif a > 0:
            # THE CLOCK: 12 o'clock is nothing left, the lit sector runs
            # CLOCKWISE, so an hour of a two-hour maximum reaches 6 o'clock.
            # Pillow measures from 3 o'clock, clockwise, hence the -90.
            d.pieslice(box, -90, -90 + 360 * a, fill=_rgba(COLOUR["awake"]))
    return img.resize((size, size), Image.LANCZOS)


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
