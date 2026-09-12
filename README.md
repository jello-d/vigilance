# vigilance

**Cross an edge, and be vigilant that it took effect.**

vigilance owns what a machine does when you step away and when you come back:
lock, darken the peripherals, mute, restore. Two pillars, and the second is the
reason this exists as a framework rather than a script:

1. make sure all the things go dark when they should, and
2. make sure the mechanism that does it is still **working**.

It hardcodes no mechanism. It knows nothing of logind, swayidle, swaylock or
systemd; each of those is a hook that binds vigilance to one environment. The
point is not to patch the tools into behaving, it is to be smart about working
*around* them, and to notice when one has quietly stopped doing its job.

## The ladder

One dimension: how far the machine has withdrawn. Present tense throughout, so
a state names a condition the machine is **in**, never something that happened
to it.

    open     fully here; unlocked and lit
    lock     session secured; the screen is still lit
    sleep    peripherals down (DDC standby, backlights 0, LEDs off)
    suspend  machine in S3/hibernate

`vigilant go <state>` is declarative: say where you want to be and every edge in
between is crossed. `go suspend` from `lock` therefore fires the `sleep` hooks
as well, which is why suspending actually powers the monitor down instead of
leaving it lit.

**Edges** are the transitions, and hooks are keyed by them. A descent edge
shares its name with the state it enters; only the ascent needs words of its
own:

    open -> lock      lock        lock -> open      unlock
    lock -> sleep     sleep       sleep -> lock     wake
    sleep -> suspend  suspend     suspend -> sleep  resume

Ascent is **not** the descent reversed, and conflating them leaves hardware in
the wrong state. Leaving `sleep`, the saved level is valid, so a hook restores
it. Leaving `suspend`, USB has re-enumerated and a QMK keyboard has forgotten
everything, so the saved state is stale and the hook must re-assert from config.
Same hook, same direction, different correct behaviour, which is why the runner
passes the rung being **left** as `$2`.

## Commands

    vigilant go <state>       traverse to state, crossing every edge between
    vigilant force <state>    assert state, ignoring the recorded depth
    vigilant only <state>     cross exactly one edge into state
    vigilant status           where we are, and where hooks live
    vigilant verify [edge]    ask the hardware whether it agrees
    vigilant hooks [edge]     what would run, in order, resolved
    vigilant report           does reality match what we believe?
    vigilant rescue           one key: record everything, then recover
    vigilant check            wiring audit

The verb set is closed and the **argument is the state**, so a new rung can
never collide with a command name.

Exit codes are a contract, because units branch on them: `0` ok (including a
no-op), `1` crossed but a hook failed, `2` usage, `3` refused (a precondition
was not met and nothing happened).

`rescue` is meant for a single unmodified key, pressable blind when the screen
is gone. It records the full state **before** recovering, because the fault is
intermittent and the button is the only instrument that will be running. It
actuates nothing itself: recovery is `force open`, which crosses every ascent
edge through the hooks, so anything it drives exists once instead of twice.

## Six hook kinds

    <edge>.d          DO it      actuators; drive the hardware
    <edge>.verify.d   CHECK it   did the edge actually take effect?
    <edge>.report.d   TELL       announce it outward (logind's SetLockedHint)
    <edge>.due.d      WHEN       when SHOULD this edge have fired?
    <edge>.block.d    WHY NOT    is something legitimately preventing it?
    alert.d           SHOUT      tell the HUMAN; not per-edge, it is
                                 cross-cutting and raised by vigilant itself

`due` and `block` are read **inward** from the environment; `report` is written
**outward** to it. Both directions are hooks, so playing nice with a stock
mechanism never means hardcoding an assumption about which mechanism it is.

The verify tier is the one that earns the name. Without it an edge can log a
clean crossing over hardware that never moved, which is exactly how a monitor
once sat dark for two days behind a green light.

`block` hooks **fail open** by design: only an explicit exit 10 blocks an edge.
A broken block hook must never be able to suppress a lock, because suppressing
a lock is a security failure while allowing a redundant one is merely noise.

The log is built in and mechanism-free, because a supervisor that only records
when an integrator wires something up is not a supervisor. Alerting a human is
policy (a toast, a bar, an intervention flag), so that is a hook.

## Two scopes, and why the greeter comes free

    /etc/vigilance/hooks        machine, root-owned, EVERY session
    ~/.config/vigilance/hooks   user-owned, no sudo ever

Peripherals belong to the **machine**: a monitor and a keyboard backlight should
behave the same whether or not anyone is logged in. Locking, audio and
notifications belong to a **user**.

That split is what lets a **greeter** session work with no configuration of its
own. It simply has no user scope, so it gets the machine hooks and nothing else,
and the peripherals dim at the login screen exactly as they do in a session
while nothing user-shaped (audio, notifications, the lock provider) even exists
to run. No duplicated config, no second code path, and no per-session filtering
pushed down into the mechanism. The greeter begins at the `lock` rung rather
than traversing to it, since there is no user session to protect.

The alternative designs are worse in instructive ways. One shared tree needs
per-session filtering, which makes the mechanism session-aware. Copying the
config for the greeter means two things to keep in step, and the copy is what
goes stale. A greeter cannot read an encrypted user home anyway.

**Ordering** follows the layering, in both directions. Machine is the lower
layer, so it comes up first and goes down last, exactly as systemd orders
units:

    descent   user 10->90, then machine 10->90
    ascent    machine 90->10, then user 90->10

Dependencies point user -> machine and never the reverse: a USB DAC powered
down by a machine hook must be back before a user hook tries to unmute it.

## What ships

`bin/` has the commands. `vigilant` is the edge runner; `swayidle-mgr` is a thin
single-instance idle timer; `idle-capture` and `lock-watch` are opt-in
diagnostics.

`libexec/vigilance/` holds plugins that are **available and wired by nobody**.
An integrator chooses which run on which edge, because that is policy:

    hooks/ddc-monitor      real screen-off over DDC/CI (VCP D6), modeset-safe
    hooks/dpms             re-assert outputs ON; never turns one off
    hooks/panel-backlight  the built-in panel backlight
    hooks/kbd-backlight    the keyboard backlight (vendor LED, discovered)
    hooks/mute-leds        the mute / mic-mute indicator LEDs
    hooks/logind-hint      SetLockedHint, so the rest of the desktop knows
    hooks/phantom-guard    debounce a spurious re-lock (a block hook)
    hooks/journal          an alert sink that works in any session
    providers/swaylock     bring a locker up as a transient systemd unit
    triggers/logind-lock   cross `lock` on logind's Session.Lock

`dpms` is deliberately asymmetric: it issues `wlopm --on` and **never** turns an
output off, because on wlroots that is a connector change which re-modesets and
can destroy views. The asymmetry is the safety rule.

## systemd owns the lock's lifetime

The lock is a transient `--user` unit, not a child process. The unit name is the
singleton, `systemctl start` blocks until the lock commits, and `ExecStopPost`
fires on unlock **and** on a crash. `Type=forking` with `GuessMainPID=no` is
load-bearing: swaylock forks a password backend, so cgroup emptiness is the
honest liveness signal for a process that forks helpers.

The suspend guarantee is a **system** unit ordered `Before=sleep.target`, so the
box cannot sleep unlocked. `go suspend` does not suspend: it fires that edge's
hooks, invoked by the unit. systemd stays the actuator and vigilant only crosses
edges, because the moment it initiates a power transition it competes with the
trust root instead of riding it.

## Install

    ./setup.sh install     symlink the tools (+ man) into ~/.local
    ./setup.sh service     + enable the --user Session.Lock listener
    ./setup.sh all         both
    ./setup.sh check       every tool + dependency present ([OK]/[FAIL])
    ./setup.sh test        the in-repo suite
    ./setup.sh uninstall   remove what install placed

`install` is the tools alone, which is what a provisioning layer delegates to.
`VIGILANCE_INSTALL_COPY=1` copies instead of symlinking, for a system prefix a
greeter must be able to read (a clone under a 0750 home cannot be followed by
another user).

Three things need **root**, so a host places them:

    systemd/lock-on-sleep.service      Before=sleep.target (@USER@-templated)
    systemd/vigilance-resume.service   After=suspend.target
    udev/99-vigilance.rules            device access; see below

## Device access: the `vigilant` group

The peripheral hooks write LED and backlight brightness through `brightnessctl`,
whose own udev rule grants the `input` group. Do **not** use that group.
`input` is overloaded, guarding two unrelated capabilities under one name:

    /dev/input/event*             root:input crw-rw----   raw event READ
    /sys/class/leds/*/brightness  root:input -rw-rw-r--   LED write

Joining it to dim a keyboard backlight also grants the ability to read every
keystroke on the machine. `udev/99-vigilance.rules` grants a dedicated
`vigilant` group instead, **narrowed by node rather than by class**: only the
specific LEDs these hooks touch are re-grouped, so `input3::capslock` and
friends keep `input` and nobody gains input-event access.

It also group-grants the DDC i2c devices, which `uaccess` cannot cover. The
system sleep units run as the desktop user, but before a graphical login the
seat belongs to the greeter, so a `uaccess` ACL reads `user:_greetd:rw-` with no
entry for that user and a suspend from the greeter could not sleep the monitor.
A group grant is seat-independent, and additive: `uaccess` still applies for the
logged-in case.

Every user that runs vigilance must be in the group, including the greeter user
if greeter coverage is on. Without it the hooks are denied and **silently
no-op**, because `brightnessctl` failure is swallowed by design; `vigilant
report` probes the nodes for writability, since a requirement nothing verifies
is only a comment.

## Dependencies

`swaylock`, `swayidle`, `wlopm`, `ddcutil`, `brightnessctl`. All degrade
gracefully: a hook that finds no device exits 0 rather than failing an edge.
Multi-output spanned locks additionally use the integrator's display-shape and
wallpaper tooling when present.

POSIX shell throughout; no daemon of its own.

## Tests

Two substrates run the **same** scenarios, because the integration between them
matters more than either one:

    sh test/run       stub substrate: fast, no root, no systemd
    sh test/vm/run    VM substrate: real systemd, logind and suspend

The rule that keeps it honest: the stub substrate stubs **actuators**, never the
**trust root**. Hardware is replaced by recorder hooks; systemd, logind and
suspend are never stubbed, because a stubbed `systemctl` lies, and a lying stub
is how a green test coexists with a broken box. A scenario needing them declares
`require systemd` and is skipped **visibly**, so a green stub run can never be
mistaken for full coverage.

This is not theoretical. Every bug in this suite's history was a wiring error,
not a logic error, and each one survived a green stub run.

## License

Apache-2.0.

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once per
clone:

    git config core.hooksPath .githooks
