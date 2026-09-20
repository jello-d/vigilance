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
    vigilant plan [edge]      the same PER CONTEXT: session vs greeter,
                              each in its own direction's order. Exits
                              non-zero if a machine hook is wired to a
                              target the greeter cannot traverse to,
                              which today is invisible: [ -x ] is false
                              for a uid that cannot look.
    vigilant report           does reality match what we believe?
    vigilant rescue           one key: record everything, then recover
    vigilant due [edge]       when SHOULD this edge have fired?
    vigilant enforce          the supervision loop, for a timer
    vigilant audit            did past events produce the edges they should?

The verb set is closed and the **argument is the state**, so a new rung can
never collide with a command name.

There is deliberately **no `vigilant check`**. The wiring audit is `setup.sh
check`, the only thing that knows the prefix, the dependency list and the plugin
tree it installed; a second implementation would be the same fact in two places.
It existed briefly as a stub aliased to `status` while three documents described
it as a wiring audit. That is worse than a missing command, because the missing
one fails loudly. It now does.

Exit codes are a contract, because units branch on them: `0` ok (including a
no-op), `1` crossed but a hook failed, `2` usage, `3` refused (a precondition
was not met and nothing happened).

`rescue` is meant for a single unmodified key, pressable blind when the screen
is gone. It records the full state **before** recovering, because the fault is
intermittent and the button is the only instrument that will be running. It
actuates nothing itself: recovery is `force open`, which crosses every ascent
edge through the hooks, so anything it drives exists once instead of twice.

## Seven hook kinds

    <edge>.d          DO it      actuators; drive the hardware
    <edge>.verify.d   CHECK it   did the edge actually take effect?
    <edge>.report.d   TELL       announce it outward (logind's SetLockedHint)
    <edge>.due.d      WHEN       when SHOULD this edge have fired?
    <edge>.block.d    WHY NOT    is something legitimately preventing it?
    audit.d           DID IT     did a PAST event produce its edge?
    alert.d           SHOUT      tell the HUMAN; raised by vigilant itself

The last two are **cross-cutting**: they sit at the top of a scope rather than
under an edge. An audit hook names the edge in its own output, because one event
source (a journal) reports events for several edges, and an alert is not about a
single edge at all.

### The three questions

`verify`, `due` and `audit` differ in **tense**, and no one of them can answer
another. That is why they are three kinds and not one cleverer one:

    verify   NOW    does the hardware match the rung we believe we are at?
    due      SOON   is an edge pending and past its deadline?
    audit    PAST   did an event that already happened produce its edge?

Only the third can see an event that produced **no** edge. That is not a
hypothetical: a system unit ordered `Before=sleep.target` died 203/EXEC on every
single sleep for a whole refactor, and the box slept unlocked. Nothing was in a
wrong state afterwards and nothing was pending, so `verify` and `due` were both
blind to it, while the unit reported `enabled` and `canonical`. Both of those
hold for a unit naming a binary that does not exist. A failed `Before=` oneshot
does not stop the sleep.

`due` and `block` are read **inward** from the environment; `report` is written
**outward** to it. Both directions are hooks, so playing nice with a stock
mechanism never means hardcoding an assumption about which mechanism it is.

The verify tier is the one that earns the name. Without it an edge can log a
clean crossing over hardware that never moved, which is exactly how a monitor
once sat dark for two days behind a green light.

A hook may exit **78** to say **not applicable** -- "there is nothing here for
me to do". That is deliberately distinct from 0, because exit 0 means both "I
did the work" and "not applicable", and nothing downstream can then tell a tier
where every hook *confirmed* from one where every hook *declined*. On a desktop
whose monitor has no DPMS standby and which has no panel backlight, both screen
verifiers declined and `verify sleep` said OK: the screen was checked by
nothing, and the tier that exists to catch exactly that reported green.

`vigilant verify` itself exits **78** when an edge has **no** verify hooks at
all, which closes the same hole one level up. `lock-on-sleep.service` runs
`vigilant verify lock` as `ExecStartPost` and systemd reads only the *status*,
so with 0 there an emptied `lock.verify.d` let the box suspend with its lock
verified by nothing. `report` gains a **coverage** section naming every edge
that acts with no verify tier, asked statically so it can see an edge the
machine is not currently on.

So `verify` now names them -- `ok (3 checked, 1 n/a: panel-backlight)` -- and an
edge where *every* hook declined is reported as `NOTHING CHECKED`, a FAIL: the
state is unknown rather than good. Using 78 is optional; a hook that exits 0 is
counted as having checked, so nothing existing changes behaviour.

`block` hooks **fail open** by design: only an explicit exit 10 blocks an edge.
A broken block hook must never be able to suppress a lock, because suppressing
a lock is a security failure while allowing a redundant one is merely noise.

Hooks are **time-bounded**. They run in lexical order and the lock provider is
not first, so a hook that hangs blocks every later hook on its edge -- including
the one that locks the screen. Under `lock-on-sleep.service` that removes the
guarantee outright: systemd kills the unit at its 25s timeout and nothing can
veto a suspend, so the box sleeps unlocked. Each hook therefore runs under
`timeout(1)` with a SIGKILL backstop, defaulting to 10s and set by
`VIGILANCE_HOOK_TIMEOUT` (`0` disables). The same bound covers `alert.d`, which
is reached from a hook failure: a notifier that hangs would otherwise block the
very edge whose failure raised it. If `timeout(1)` is missing the bound is
silently gone, so `vigilant report` warns. The `audit.d` tier has its own larger
budget (`VIGILANCE_AUDIT_TIMEOUT`, 60s): it reads an external event log and is
legitimately slower than anything on the lock path, and sharing the edge bound
would retire the forensic tier by crying wolf.

`report` also compares the **edge budget** against `lock-on-sleep.service`'s
`TimeoutStartSec` -- two numbers in two files that must relate, with nothing
else relating them. The number that matters is not the total but the time before
the screen is *locked*: hooks run in lexical order and `block.d` runs before all
of them, so anything ordered ahead of the provider delays the lock itself, while
`report.d` and `verify.d` run after it and risk only the unit being killed.

They also only apply in one direction. **A block may refuse to take the machine
down; it may never refuse to bring it back up.** Refusing a descent is the
tier's purpose and is safe: the machine stays awake and usable. Refusing an
ascent leaves it in a dark rung with the one path out vetoed, which would make
"the screen is dark and nothing will bring it back" a supported configuration
-- and it disabled `vigilant rescue`, the panic key, until this was fixed.
Nothing is lost: the `unlock` edge performs no authentication (the locker does),
so blocking it never kept anyone out. A block hook wired on `unlock`, `wake` or
`resume` is ignored and reported by `vigilant report` as a wiring error.

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
    hooks/lock-blank       paint the LOCK SURFACE black, and restore it
    hooks/sway-dpms        power outputs off/on -- SWAY sessions only
    hooks/screen-dark      VERIFY the screen is actually dark, mechanism-blind
    hooks/kbd-backlight    the keyboard backlight (vendor LED, discovered)
    hooks/mute-leds        the mute / mic-mute indicator LEDs
    hooks/logind-hint      SetLockedHint, so the rest of the desktop knows
    hooks/phantom-guard    debounce a spurious re-lock (a block hook)
    hooks/journal          an alert sink that works in any session
    hooks/swayidle-due     read swayidle's own timers as a `due` deadline
    hooks/locker-up        VERIFY the session is locked (or is not)
    hooks/logind-sleep-audit  did each real sleep produce its `lock` edge?
    hooks/swayidle-idle-audit did each idle timer firing produce its `lock`?
    providers/swaylock     bring a locker up as a transient systemd unit
    triggers/logind-lock   cross `lock` on logind's Session.Lock

`dpms` is deliberately asymmetric: it issues `wlopm --on` and **never** turns an
output off, because on wlroots that is a connector change which re-modesets and
can destroy views. The asymmetry is the safety rule.

`locker-up` is the `lock` edge's missing partner. The framework's rule is that
for every hook which acts, a paired hook asserts it took effect, and the most
important actuator in the suite had none: on a real box the `lock` edge was
verified by three hooks that all check a **peripheral**. They assert the screen
is lit; not one asked whether the session was secured. Wire it in the **user**
scope only, never the machine scope, because a greeter *is* the locked state and
has no locker at all.

Two hooks guard the idle path, and neither substitutes for the other:
`swayidle-idle-audit` asks whether a timer that **fired** produced its edge, and
`vigilant report` asks whether the timers can fire **at all** by reading the
running swayidle's argv. The second exists because the first cannot see an exec
failure: when the command does not run, the log entry it would have written is
never written either. That is not hypothetical, and it is why both are here.

### What cannot be guaranteed

**Nothing can veto a suspend.** A unit ordered `Before=sleep.target` delays the
transition while it runs, and a delay inhibitor delays it too, but when either
fails or times out, logind proceeds. There is no supported way to refuse a
suspend outright, and a suite that could refuse one could strand a laptop on a
critical battery. So the suspend lock's goal is not prevention: it is that
sleeping unlocked becomes **loud and recorded** rather than a green light.
`lock-on-sleep.service` therefore runs `vigilant verify lock` after crossing, so
that "the unit succeeded" is a claim about the session and not merely about the
hooks.

## Platforms: what is generic, and what you should not wire

Most of this is platform-neutral. Seven of the shipped hooks are sysfs, I2C or
logind, with no Wayland in them at all. They work unchanged under X11, any
Wayland compositor, or none:

    ddc-monitor  panel-backlight  kbd-backlight  mute-leds
    logind-hint  journal  logind-sleep-audit  phantom-guard

Only `dpms` is compositor-bound (`wlopm`, so wlroots), alongside the swaylock
provider and the swayidle `due` hook. Those are plugins precisely so another
environment can swap them.

**The rule that decides whether a screen hook helps or hurts:**

> Input restores a blanked screen for free exactly when the component that owns
> **input** also owns the **blanking**.

On X11 the server owns both, so `xset dpms` wakes on a keypress. A full desktop
(GNOME, KDE) blanks internally, same result. On bare wlroots the blanking is
delegated to an external client over IPC, which is why swayidle's canonical
config has to PAIR `output * power off` with `resume 'output * power on'`.

vigilance is by definition external. So anything it blanks, something must
explicitly unblank. Hence:

- **`panel-backlight` is a trade, not a free win.** A backlight written through
  sysfs is invisible to the input stack. Where the platform can safely blank
  the panel itself, this hook is both REDUNDANT and INFERIOR -- same darkness,
  by a route a keypress cannot undo. Prefer the platform's mechanism and leave
  it unwired. It exists for the case where the platform cannot.
- **`lock-blank` exists because nothing else can repaint a locked screen.**
  Under `ext-session-lock` the lock surface renders above every layer-shell
  layer, so no overlay can cover it, and on a panel with no DPMS standby the
  hardware can only DIM -- measured on a QD-OLED, `VCP 10 = 0` is dim, not
  black. So the locker has to do it, and swaylock is patched with a two-signal
  interface (`SIGUSR2` blank, `SIGRTMIN` restore) carrying no timer and no
  policy: WHEN to blank is this hook's business, driven by the ladder. On an
  OLED a black pixel is an off pixel, so this is a real power-down of the
  emitting surface without a power state the panel may not return from. It
  changes what is drawn, never whether the session is locked.

- **`screen-dark` is the only check that asks the RUNG'S question.** Every other
  verifier asks about its own mechanism, and each can be satisfied or n/a on its
  own terms while the thing the rung MEANS goes unexamined. That is not
  theoretical: a lit screen survived four separate green verdicts -- an
  unimplemented `D6` code, a monitor that vanished from its own map, a user
  session with no darkening mechanism, and a greeter with none either -- and
  every hook was individually correct each time. The failure lived in the gap
  *between* per-device checks, which is exactly where a per-device check cannot
  look. This one measures what the display emits and compares it to what the
  rung claims. Keep both: the device checks say WHICH mechanism failed, this
  says THAT the machine is lying.

- **`sway-dpms` is how a GREETER goes dark, and it is safe in machine scope
  because it cannot act outside sway.** A greeter has no locker, so `lock-blank`
  has nothing to signal; on a panel advertising no DPMS standby `ddc-monitor`
  can only dim. So a greeter's sleep edge killed the keyboard and left the
  screen lit, on the session nobody is present to notice. The gate is the tool:
  `swaymsg` only talks to sway, so in a Wayfire session -- which gets the same
  machine hooks, and where powering an output off destroys views -- it simply
  cannot act and declines. `dpms` stays ON-only and untouched.

- **`ddc-monitor` is not redundant with anything, and cannot be undone by
  input.** It speaks I2C to the monitor's own scaler, which no compositor and
  no X server can do: DPMS drops the video signal and leaves the panel to
  decide what that means. The corollary is that a keypress never reaches the
  monitor, so wiring it means the ascent must be armed by something.
- **`dpms` is ON-only and must stay that way.** Do not complete it into an
  off-switch; see its header for the crash that asymmetry avoids.

Which is one invariant, enforced in `bin/vigilant` and worth stating plainly:

> **Nothing may put the machine into a dark rung unless it arms its own way
> back.**

Every dark descent that actually runs comes from a swayidle pairing its
`timeout` with a `resume`, so activity brings the screen back. `vigilant
enforce` refuses to FORCE a descent into a dark rung for the same reason. The
blackouts in this suite's history were all one bug in different clothes:
something went dark by a route with nothing armed to undo it.

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

`systemd/` ships eight units. The two that need root are `@USER@`/`@UID@`/
`@HOME@`-templated, because **`%h` in a system unit resolves to root's home**
regardless of `User=`. That is precisely how the suspend lock was fiction for a
whole refactor:

    lock-on-sleep.service     SYSTEM, Before=sleep.target: the suspend lock
    vigilance-resume.service  SYSTEM, After=suspend.target: come back to `lock`
    vigilance-logind.service  --user, the Session.Lock listener
    vigilance-enforce.timer   --user, the supervision loop, every minute
    vigilance-audit.timer     --user, the forensic pass, daily + Persistent
    vigilance-idle.service    --user, keeps the idle timer alive

`vigilance-idle.service` is **placed but never enabled** against a target: only
the compositor knows when a display exists to connect to, so it starts the unit
from its own autostart. Enabling it against a target would start swayidle into a
void.

Supervision is **report-only** by default, so enabling the timers cannot cross
an edge on its own. `VIGILANCE_ENFORCE=force` lets `enforce` act, and even then
it will never force a descent into a **dark** rung, because such a descent has
nothing armed to bring the machine back. Not caution in the abstract: it
is exactly how the resume unit once blanked an active user's screen for 32
seconds.

## Install

    ./setup.sh install     symlink the tools (+ man) into ~/.local
    ./setup.sh service     + enable the --user Session.Lock listener
    ./setup.sh all         both
    ./setup.sh check       tools, deps, plugins, units, man, device access
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
