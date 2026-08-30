# vigilance

**Keep watch over an idle or absent machine: lock, blank, mute, and restore.**

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
- **mute-on-lock**, and the **idle-capture** / **lock-watch** diagnostics.

## Install

    vigilance install     # symlink tools + the --user listener into ~/.local

The suspend-lock **system** unit (`Before=sleep.target`) needs root; place
`share/vigilance/systemd/lock-on-sleep.service` under `/etc/systemd/system`
(or let a host manager do it).

## Audit

    vigilance check       # every tool + dependency present

## Dependencies

`swaylock`, `swayidle`, `wlopm`, `ddcutil` (spanning/DDC degrade gracefully if
absent). Multi-output spanned locks also use `kanshi-autoscale` (the display
"shape") and `wallpaper-slicer` when present.

POSIX shell (a couple of tools use bash arrays); no daemon of its own.

## License

Apache-2.0.
