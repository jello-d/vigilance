# What tackup has to do

vigilance ships MECHANISM; tackup decides POLICY. Nothing in this list can be
done by vigilance without it deciding something that is not its to decide.
Running list, kept current as stages land.

Ordered so the box is never worse off between steps.

## 1. Wire the peripheral hooks (stage 1)

vigilance installs its hooks AVAILABLE but never ENABLED. Symlink the wanted
ones into `~/.config/vigilance/hooks/<edge>.d/`. `panel-power`'s inventory,
translated:

    sleep.d/10-ddc-monitor      -> ~/.local/libexec/vigilance/hooks/ddc-monitor
    sleep.d/20-panel-backlight  -> ...hooks/panel-backlight
    sleep.d/30-kbd-backlight    -> ...hooks/kbd-backlight
    sleep.d/40-mute-leds        -> ...hooks/mute-leds
    sleep.d/60-kbd-rgb          -> tackup's own (qmk-ripple; NOT vigilance's)

    wake.d/, resume.d/, suspend.d/   the same set

The same hook file serves every edge: it branches on `VIGILANCE_EDGE`, and
`resume` deliberately re-asserts DARK rather than restoring (after S3 the
saved state is stale). Numbering is tackup's call: descent runs 10 to 90,
ascent unwinds 90 to 10.

`kbd-rgb` stays tackup's because a QMK keyboard is inventory, not a standard
mechanism. Everything above it is standard, so vigilance ships it.

## 2. Wire the lock provider, trigger and guard

smart-lock and smart-trigger are DELETED. systemd owns the lock's lifetime
(proven against a real swaylock in test/lock-span.t). What tackup wires:

    lock.d/50-swaylock        -> ...providers/swaylock
    lock.block.d/10-phantom   -> ...hooks/phantom-guard

    ~/.config/lock-hooks/     DELETE the whole tree. mute-on-lock moves to
                              vigilance's lock.d / unlock.d, so there is ONE
                              hook tree instead of two.

The `--user` Session.Lock listener is `vigilance-logind.service` (was
`smart-trigger.service`), running `...triggers/logind-lock`.

`~/.config/lock-hooks` going away also means `modules/lock` stops creating a
second hook tree.

## 3. Wire the alert sinks

    alert.d/10-notify-desktop  -> ...hooks/notify-desktop   (vigilance ships)
    alert.d/20-intervention    -> tackup's vigilance-intervention

The intervention flag is the one that matters: these failures happen while you
are away, and a toast nobody sees is not an alert. Clearing stays manual
(`intervention-required clear vigilance`) until vigilant grows a "recovered"
signal.

## 4. Retire the swaylock patch and the shim

- Drop `build/patches/swaylock-blank-toggle.patch` and rebuild swaylock stock.
  See framework-refactor.md 10.1 for why it is deletable: the box's own event
  log shows swayidle handled blank AND restore while locked for months.
- Delete `link/bin/panel-power` (the interim shim) on both machines. It only
  ever existed because the patch hardcoded `$HOME/bin/panel-power`.
- `wayfire.ini`'s `command_display_on` becomes `vigilant go lock` (lit but
  still locked), replacing `panel-power on`.

NOTE the shim is currently RESTORED on manifestor and ABSENT on manifold, on
purpose: manifestor is a desktop that never suspends and has no console
fallback problem, manifold is a laptop on the road. Do not "fix" the asymmetry
without reading that history.

## 5. Session target and probe (stage 2)

- `graphical-session.target` is INACTIVE on this box while a full session
  runs; nothing activates it, and about 20 distro units bind to it. Activating
  it is tackup's call because it means reconciling the wayfire autostart list
  against those units (`mako.service` is Wanted by it while mako already runs
  from autostart, so pulling the target up starts a second mako).
- The wayfire autostart should shrink to ONE entry that starts the target.
  Every current entry is fire-and-forget with no status, which is exactly how
  the idle timer sat dead for two days.

## 6. Units (stage 3)

- Move `swayidle-mgr` off the wayfire autostart and onto a `--user` unit that
  is `PartOf=` the session target.
- Deploy `vigilance-resume.service` (`After=suspend.target`). It ships now;
  there was NO resume path at all before.
- `lock-on-sleep.service` is @UID@-templated as well as @USER@ now (it needs
  XDG_RUNTIME_DIR and the session bus to reach the user manager).
- `lock-watch.service` and `display-watch.timer` are TEMPORARY diagnostics;
  tear both down once the blackout cause is confirmed fixed.

## 7. Things tackup owns that are currently unmanaged

Found while debugging; none of these are reproducible on a rebuild today:

- `~/.config/lock-hooks/{lock,unlock}.d/*` symlinks are hand-placed. tackup
  has ZERO references to `lock-hooks`. `modules/lock` now creates them.
- `lock-watch.service` is hand-placed (`~/.config/systemd/user/`), not
  deployed by anything.
- `link/bin/panel-power` (shim) and `link/bin/screen-rescue` are untracked; a
  `git clean` would drop them.
