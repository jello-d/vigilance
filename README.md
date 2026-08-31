# vigilance

**Keep watch over an idle or absent machine: lock, blank, and run your hooks.**

vigilance is a suite of Wayland tools for what a machine should do when you
step away, and when you return. It is built swayidle-INDEPENDENT for every
security-critical path, because a single wedge-prone idle daemon must not *be*
the lock guarantee.

- **smart-lock**: the lock executor. Per-display "shape" config, multi-output
  spanned lock screens, and lock/unlock hooks.
- **smart-trigger**: the robust launcher/listener. Runs the lock on suspend (a
  `Before=sleep.target` system oneshot, so the box cannot sleep unlocked) and on
  the logind `Session.Lock` signal (lid-close, `loginctl lock-session`),
  launching swaylock as a sibling systemd unit that survives the trigger.
- **swayidle-mgr**: a thin single-instance idle-lock timer.
- **panel-power**: real screen-off over DDC/CI (modeset-safe, NVIDIA-safe), not
  a destructive connector toggle.
- **osd-mgr**: supervises the OSD server so volume/brightness keys self-heal.
- the **idle-capture** / **lock-watch** diagnostics.

`smart-lock` runs every executable in `~/.config/lock-hooks/{lock,unlock}.d/` on
lock/unlock (the event is passed as `$1`). That hook system is the extension
point; vigilance ships no hooks of its own. An integrator drops in its own, for
example muting audio while you are away.

## Install

    ./setup.sh install     # symlink the tools (+ man) into ~/.local
    ./setup.sh service     # + enable the --user Session.Lock listener
    ./setup.sh all         # both of the above

`install` is the tools alone (what a provisioning layer delegates to); `service`
adds the `--user` listener separately, so a host that wires systemd itself gets
no duplicate unit. The suspend-lock **system** unit (`Before=sleep.target`)
needs root; place `systemd/lock-on-sleep.service` under `/etc/systemd/system`
(or let a host manager do it).

## Audit

    ./setup.sh check       # every tool + dependency present

## Dependencies

`swaylock`, `swayidle`, `wlopm`, `ddcutil` (spanning/DDC degrade gracefully if
absent). Multi-output spanned locks also use `kanshi-autoscale` (the display
"shape") and `wallpaper-slicer` when present.

POSIX shell (a couple of tools use bash arrays); no daemon of its own.

## License

Apache-2.0.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks
