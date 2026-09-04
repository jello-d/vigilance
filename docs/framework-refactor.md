# vigilance: from lock suite to edge framework

Plan of record for the refactor agreed 2026-09-02. Supersedes the ad-hoc
`panel-power` / `power-hooks` sketches.

## 1. Charter

vigilance exists because swayidle wedged. Every load-bearing decision in the
repo follows from distrusting the layer beneath it: the transient sibling unit
(systemd reaps cgroups), the committed-lock marker (a running swaylock is not a
committed lock), `Before=sleep.target` (the box must not sleep unlocked), never
SIGKILL mid-lock (ext-session-lock freezes).

So the charter is not "tools for stepping away". It is:

> Be vigilant. Make sure ALL the things go dark when they should, and make
> sure the mechanism that is supposed to do it is actually working.

Two pillars, and the second one is the name. The boundary test is therefore
structural rather than a judgement call each time:

- vigilance owns the LADDER, the ordering, the state discipline, the failure
  reporting, and the verification contract.
- vigilance owns NO specific hardware and NO specific compositor. Those are
  plugins.

Corollary: anything not load-bearing for those two pillars is a guest.
`osd-mgr` is a guest and leaves.

## 2. Model

Two orthogonal concepts. Keeping them separate is the point.

### 2.1 Session is a SCOPE

A session encloses everything else. `suspend` preserves it; logout destroys
it. It is not a rung. It maps onto a systemd target, so session-scoped daemons
are `PartOf=` it and no unit contains a heuristic: swayidle is not running
when the target is down, not because anything checked, but because it cannot
be.

Today there are FOUR disagreeing session heuristics in the tree:

| where | heuristic |
| --- | --- |
| `swayidle-mgr` `need_session()` | `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR` |
| `smart-trigger` `do_lock()` | `WAYLAND_DISPLAY`, else glob `wayland-[0-9]*` |
| tackup `in_session()` | `WAYLAND_DISPLAY` + `pgrep -x wayfire` |
| `panel-power` | `pgrep -x swaylock` (infers session from lock state) |

All four are replaced by one probe (section 5).

### 2.2 The ladder is a DESCENT with graded rungs

Rungs point the same direction. They are not one edge and its inverse.

| rung | meaning | trigger today |
| --- | --- | --- |
| `lock` | session secured; screen may still be lit | idle, lid, Session.Lock |
| `sleep` | peripherals down (DDC, backlights, LEDs) | swaylock blank-after |
| `suspend` | machine to S3/hibernate | logind lid, sleep.target |

Ascent is a SEPARATE ladder, not the descent reversed: `resume`, `wake`,
`unlock` are three distinct edges with three distinct jobs.

Why that matters: ascending from `sleep`, the saved state is valid, so restore
it. Ascending from `suspend`, USB re-enumerated and a QMK keyboard forgot
everything, so the saved state is stale and the hook must re-assert from
config. Same hook, same direction, different correct behaviour. The hook can
only know which if the runner tells it (`from-depth`, section 4).

## 3. The `vigilant` command (settled 2026-09-04)

FIXED VERBS, and the ARGUMENT IS THE STATE. Edge-as-verb was rejected: it puts
every future rung into the verb namespace where it can collide with a command
name. A closed verb set cannot.

Two surfaces with different economics. Conflating them is how panel-power ended
up with `peripherals on|off` bolted onto `on|off`:

    CONTRACT (machine-invoked; wired into units, triggers, keybinds)
      vigilant go <state>          traverse to state, respecting the ladder
      vigilant force <state>       assert state, ignoring the recorded depth
      vigilant session start|end   scope boundary

    CONVENIENCE (human-invoked; free to evolve)
      vigilant status              where we are, and where hooks live
      vigilant hooks [edge]        what would run, in order, resolved
      vigilant verify [edge]       the shared oracle
      vigilant check               wiring audit, [OK]/[FAIL]/[WARN]

STATES ARE PRESENT TENSE, so a state names a condition the machine is IN, never
something that already happened to it: `open`, `lock`, `sleep`, `suspend`.
`open` rather than `unlocked` deliberately: `force unlocked` reads like
bypassing authentication, which is not a phrase that belongs in a security
tool's logs or keybinds.

A DESCENT EDGE SHARES ITS NAME WITH THE STATE IT ENTERS (`go sleep` crosses the
`sleep` edge into the `sleep` state, running `sleep.d`). Only the ascent needs
words of its own, because that is where the distinction matters: `wake`
(leaving `sleep`, saved state valid) versus `resume` (leaving `suspend`, saved
state stale). Six hook dirs, four states, one vocabulary.

`go` IS DECLARATIVE and traverses: say where the machine should BE and every
edge in between is crossed, so no caller needs to know the ladder's shape or
sequence its own steps. This DELETED the minimum-rung special case, and fixed a
real defect on the way: `go suspend` from `lock` now fires `sleep.d` before
`suspend.d`, so suspending actually powers the monitor down instead of leaving
it lit.

EDGES TAKE NO ARGUMENTS. Depth is authoritative state, never something a caller
asserts; the moment a caller can claim "I am coming from suspend", the drift the
depth file exists to prevent is back.

NO FLAGS. A `--depth` bare-value flag was considered and dropped: its only
consumer was a test parsing `status` with awk, which is a test artifact, not a
requirement. If a real consumer appears, `resolve <key>` fits the grammar.

HARD CONSTRAINT: `vigilant go suspend` does NOT suspend. It fires the hooks for
that edge, invoked BY the unit ordered `Before=sleep.target`. systemd stays the
actuator; vigilant only crosses edges. The moment vigilant initiates power
transitions it competes with the trust root instead of riding it.

EXIT CODES are a contract, because units and triggers branch on them:

    0  ok, including a no-op
    1  crossed, but one or more hooks FAILED (degraded, but we did move)
    2  usage error
    3  refused: a precondition was not met and NOTHING happened

`3` distinct from `1` is the load-bearing one: a unit receiving `3` knows the
machine is where it was, while `1` means it moved but something is broken.
`verify` returns `0` for ok OR n/a, so a timer firing at the greeter cannot
alarm.

## 4. Hook contract

    <hook> <edge> [from-depth]
      VIGILANCE_EDGE        the edge being crossed
      VIGILANCE_FROM        rung being ascended from (ascent only)
      VIGILANCE_STATE_DIR   per-hook state dir, created and guaranteed

Layout, one root keyed by edge:

    ~/.config/vigilance/hooks/
      lock.d/  sleep.d/  suspend.d/          descent: DO it
      unlock.d/  wake.d/  resume.d/          ascent:  DO it
      <edge>.verify.d/                       did it take effect?
      <edge>.due.d/                          WHEN should it have fired?
      <edge>.block.d/                        is something preventing it?
      alert.d/                               tell the HUMAN (NOT per-edge)

LOG vs ALERT are deliberately different. The LOG is vigilant's own record,
BUILT IN and mechanism-free (a file under `$XDG_STATE_HOME`),
because a supervisor that only records when an integrator wires something up
is not a supervisor, and stderr goes to the journal under a unit but NOWHERE
under a keybind. Telling a HUMAN is policy, so `alert.d` is a hook.

What alerts and what does not is the thing that keeps alerts worth reading: an
ACTUATOR or VERIFY failure alerts (the machine may not be in the state we
believe), a REPORT failure does not (nobody was told, but the machine is
fine). Alerting on the second trains the human to ignore the first. A failing
alert hook is logged and swallowed: the machine's state must never depend on
whether we managed to complain about it.

Shipped sinks demonstrate the boundary. vigilance ships `notify-desktop`
(notify-send is a freedesktop standard); tackup ships `vigilance-intervention`
(`intervention-required` is this estate's own tool). A desktop toast is missed
if nobody is looking, and these failures happen while you are away, so the
persistent flag is the one that matters: an alert raised at 3am is still in
front of you at 9am.

The due/block pair is what turns vigilance from a dispatcher into a
supervisor; see 10.1.1. `due` and `block` are mechanism-SPECIFIC (they read
swayidle's timer, swaylock.conf's `blank-after`, `systemd-inhibit`), which is
exactly why they are hooks: vigilant itself stays mechanism-agnostic.

Ordering: descent ascending (`10` to `90`), ascent descending (`90` to `10`).

Three things the runner provides that hooks currently re-implement or get
wrong:

1. STATE DIR per hook. Deletes the copy-pasted save-file logic in
   `backlight()`, `kbd_backlight()` and `mute_leds()`, which are three
   near-identical implementations of one discipline.
2. DEPTH AS INVARIANT. The runner knows the current rung, so "never dim a live
   desktop" becomes "refuse `sleep` unless depth >= `lock`". One declarative
   rule replaces every hook's `pgrep -x swaylock` guess.
3. FAILURE REPORTING. Today the swaylock patch does `_exit(127)` silently by
   design, which is how a dead hook hid on two machines for days. The runner
   names the hook that failed.

Depth state lives in `$XDG_RUNTIME_DIR/vigilance/`, which survives suspend and
hibernate but not reboot. That is correct: a boot means we are at the top.

### Hook inventory and ownership

Shipped by vigilance, AVAILABLE but not enabled (a hook that ships enabled is
vigilance making a policy decision):

    libexec/vigilance/hooks/ddc-monitor       DDC/MCCS, any external panel
    libexec/vigilance/hooks/panel-backlight   brightnessctl, any laptop
    libexec/vigilance/hooks/kbd-backlight     discovered LED, not hardcoded
    libexec/vigilance/hooks/mute-leds         brightnessctl; see 10.3

Shipped by the integrator (tackup), because it is inventory:

    kbd-rgb       qmk-ripple, one specific keyboard

The rule: vigilance ships any hook whose MECHANISM is standard; the integrator
decides which ones RUN. Ownership follows the mechanism, not whether this
particular desk has the hardware.

The integrator symlinks the ones it wants into `<edge>.d/`, exactly as
`modules/lock` now does for the lock hooks. One pattern, used twice.

## 5. Session probe

The probe answers WHICH SESSION, not yes/no. `smart-trigger` globs for a
wayland socket specifically so it can pass `--setenv=WAYLAND_DISPLAY`; a
boolean would not have helped it.

Evidence for why this must be careful: manifestor has seven logind sessions,
six of them the same user. Two are agent ssh sessions, two are `closing`
strays, one is a manager. Only

    Type=wayland (or x11) AND Class=user AND State=active AND Seat non-empty

selects the real one. An ssh session registers with logind, so "is there an
active session for this user" is TRUE at the greeter.

Plugins, in order of trustworthiness:

    logind              loginctl show-session; seat-aware, X11 and Wayland
    wayland-socket      the existing fallback
    x11                 DISPLAY plus a round trip
    compositor-process  pgrep; last resort, labelled as such

### Two paths

ANNOUNCE (start): the compositor autostart holds exactly ONE line,
`vigilant session-start`, which imports the environment and activates the
target. systemd owns everything after. This also closes the autostart trust
hole: one fire-and-forget entry instead of five, and if it does not run, EVERY
session daemon is visibly down rather than one silently missing.

PROBE (query): for callers with no session env, namely the system sleep unit,
the verifier, and `tackup check`. They ask; they never assume.

### State of the standard mechanism on this box (measured 2026-09-02)

- Environment IS imported: wayfire's `0_environment` runs
  `dbus-update-activation-environment --systemd`, and the user manager has
  `WAYLAND_DISPLAY`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`.
- `graphical-session.target` is INACTIVE on both manifold and manifestor while
  a full session runs. Nothing activates it; `startwayfire` does not.
- About 20 distro units reference it (`mako`, `xdg-desktop-portal*`,
  `gnome-keyring-daemon`, `gvfs-*`, `at-spi`). `mako.service` is inactive while
  mako runs from wayfire autostart, so the unit path is dead and bypassed.

Half the mechanism is in place. We supply the missing half, and use the
standard name so future units interoperate.

LIKELY BONUS, to be confirmed, NOT part of this work: the `0_portals`
workaround in wayfire.ini exists because the portal's GTK backend activates
before `WAYLAND_DISPLAY` lands and falls back to X, stalling waybar about 30s
at login. That is the classic symptom of the target never activating. Proper
activation may let that hack be deleted.

## 6. Verify tier

For every hook that acts, an optional paired hook that asserts it took effect.
`sleep.verify.d/10-ddc-monitor` runs `getvcp d6` and confirms `02`, which is
literally what we did by hand to prove manifestor was broken. That diagnostic
session should have been a hook that already existed.

The pattern already exists three times, hand-rolled and inconsistent:
`smart-lock`'s MARKER plus `smart-trigger`'s `_wait_marker` (a genuine reverse
hook: it asserts the lock COMMITTED and gates suspend on it); `lock-watch` and
`idle-capture` (reverse hooks demoted to "temporary diagnostics"); and
`modules/lock check` plus `setup.sh check` (the same assertions at
provisioning time).

### Verdict vocabulary, shared

    ok        asserted state matches actual
    fail      it does not
    n/a       out of scope; the probe says there is no session

The third verdict is load-bearing. Without it `vigilant verify` reports
"swayidle not running" at the greeter, which is wrong and corrosive: a check
that cries wolf gets ignored, and then a real failure hides in the noise.

This is the same shape as `ignore` in tackup's `install_check` (a platform gap
is not drift) and `unverified` for an unreachable head pin. Three places now
where "I cannot currently know" is a distinct answer from "it is broken".
Make the vocabulary explicit and shared rather than reinventing it a fourth
time.

## 7. systemd

Three failure modes, only one currently covered.

    dying        Restart=always. Covered today.
    wedging      Restart never fires; the process never exits. This is the
                 founding trauma. WatchdogSec + systemd-notify WATCHDOG=1.
    not starting wayfire [autostart] is fire-and-forget with no status. This
                 is exactly how the idle timer was dead for two days.

Units:

    vigilance-session.target      the scope. BindsTo graphical-session.target,
                                  off by default; see 10.2
    vigilance-idle.service        idle trigger; PartOf the target. Replaces
                                  the wayfire autostart entry.
    smart-trigger.service         logind listener; exists
    lock-on-sleep.service         Before=sleep.target; exists
    vigilance-resume.service      After=suspend.target; NEW. There is no
                                  resume path at all today.
    vigilance-verify.timer        periodic reconcile

RECONCILIATION RISK: `PartOf=` means daemons stop when the target stops, which
is correct. But if the compositor dies without stopping the target, asserted
(target active) and actual (probe says no session) drift apart. That is the
same failure class as everything else in this cycle, so it gets the same
treatment: `vigilance-verify.timer` reconciles the two and fails loud. The
probe is what makes that reconciliation possible at all, which is the real
argument for it being pluggable state rather than a boolean helper.

## 8. Disposition of every current tool

| today | becomes |
| --- | --- |
| `panel-power` | dissolves; DDC ships as a hook, rest as hooks |
| `swayidle-mgr` | idle trigger source, under a unit |
| `smart-lock` | DELETED; systemd owns the span (10.1.4) |
| `smart-trigger` | DELETED; a 5-line trigger plugin replaces `listen` |
| `lock-watch`, `idle-capture` | promoted into the verify tier |
| `osd-mgr` | leaves vigilance; not on the charter |
| swaylock patch | DELETED; stock swaylock, supervised (10.1) |

### 10.1.4 smart-lock and smart-trigger are DELETED

A lock is a SPAN, not an edge, and something must own it. That was the whole
argument for keeping smart-lock. It was wrong in one specific: SYSTEMD tracks
spans, and systemd is the trust root already chosen. Verified against a real
swaylock under a real compositor in `test/lock-span.t`:

| smart-lock hand-rolled | systemd does |
| --- | --- |
| `flock` + `pgrep` idempotence | the unit name is the singleton |
| marker file for "committed" | `systemctl start` BLOCKS until commit |
| `while pgrep; sleep 0.25` | cgroup liveness |
| unlock detection | `ExecStopPost`, which also fires on a CRASH |
| foreground process holding the cgroup | the unit IS the span |

`GuessMainPID=no` is load-bearing and was found the hard way: swaylock forks a
password-backend child, so the cgroup holds two processes and systemd cannot
guess which is main (`MainPID=0`). The first draft asserted MainPID and FAILED
in the VM. Cgroup emptiness is the honest signal for a process that forks
helpers.

The provider RETURNS AT COMMIT, not at unlock. That is the suspend gate's
semantics for free, and it releases the caller: smart-lock blocked until
unlock, which pinned swayidle for hours (18:31 to 20:37 on one lock) and
stopped it firing any other timer.

smart-trigger decomposes into: the suspend gate (`lock-on-sleep.service` runs
`vigilant go lock` directly) and a five-line `Session.Lock` subscriber
(`triggers/logind-lock`). The phantom guard becomes `lock.block.d`, reading
vigilant's timestamped depth instead of a private stamp file.

PROVENANCE travels in `VIGILANCE_SOURCE`, never in argv, so edges keep taking
no arguments. That is safety-critical: the guard must suppress ONLY the idle
path, because gating suspend or a lid close would leave the box asleep
UNLOCKED. Blocking FAILS OPEN (only an explicit exit 10 blocks) for the same
reason.

## 9. Staging

Each stage lands independently and leaves the box working.

1. LADDER, RUNNER, HOOKS. Deletes panel-power's inventory, kills the silent
   `execl`, removes the `link/bin/panel-power` shim.
   BUILT so far: `bin/vigilant` (ladder, depth invariant, loud hook failure,
   `verify` as the shared oracle); `libexec/vigilance/hooks/{ddc-monitor,
   panel-backlight,kbd-backlight,mute-leds}` plus `hooklib.sh`; `setup.sh`
   installs libexec AVAILABLE-but-unwired; the shared scenario vocabulary and
   four scenarios. NOT yet done: retire `panel-power` itself, and point
   swayidle at `vigilant go sleep` / `vigilant go lock` for the blank edges
   (it demonstrably handled both while locked for months; see 10.1). NO
   REBUILD is needed now that the patch is deleted rather than amended, which
   also removes the sudo handoff this stage used to require.
2. SESSION PROBE, TARGET, ANNOUNCE. Must precede the unit work, which depends
   on the target existing.
3. UNITS. swayidle off the wayfire autostart; add the resume unit; `PartOf=`
   the target.
4. VERIFY TIER, with the three-verdict vocabulary. Promote smart-lock's marker
   to the first reverse hook.
5. WATCHDOG. `WatchdogSec` plus `systemd-notify` on long-running units.
6. SUPERVISION: `due.d` + `block.d` hooks and the enforcement loop (10.1.2).
   Ships AFTER the rescue key, never before: forcing a descent without a
   proven ascent is how a user gets stranded.
7. PLUGIN-IZE swaylock and swayidle. Last: no current failure drives it.

## 10. Decisions (settled 2026-09-02)

### 10.1 DELETE the swaylock patch; supervise instead of trusting

REVISED 2026-09-04, reversing the earlier "shrink the patch" decision. The
box's own logs refuted the premise it rested on.

The patch existed because the pre-patch swayidle design supposedly "could only
blank and never restored on presence" (`swayidle-mgr` header). The event log
says otherwise, repeatedly, over months, WHILE LOCKED:

    08-02 00:25:31  idle-lock
    08-02 00:27:31  blank      <- 120s after the lock
    08-02 14:51:03  unblank    <- 14.5 hours later, on return

    08-03 10:28:18  idle-lock
    08-03 10:30:18  blank
    08-03 21:58:23  unblank    <- 11.5 hours later

So swayidle DOES see idle and resume while the session is locked on this
compositor. The presence-awareness the patch was built for is available from
outside it, and a load-bearing claim in our own docs was not supported by the
machine's own history.

What the patch uniquely provided, after that: only INHIBITOR-PROOF blanking.
`session-lock.cpp` never touches idle inhibitors (it calls
`output->set_inhibited()`, which is plugin activation, a different mechanism),
so a client holding a Wayland idle inhibitor suppresses `wlr_idle_notifier`
and swayidle will not fire even with the screen locked.

That single gap does not justify carrying C across upstream versions,
especially since the patch's hardcoded `%s/bin/panel-power` is what broke on
two machines and cost a day. STOCK SWAYLOCK, NO PATCH.

### 10.1.1 The inversion: vigilance SUPERVISES, it does not trust

Deleting the patch does not mean hoping the stock tools work. It means
vigilance stops assuming they do and starts CHECKING. This is the charter's
second pillar finally made concrete, and it is what the name has always
promised.

The enabling fact: `vigilant` is invoked for EVERY edge, so it sees both the
STATE and the INTENT. Nothing else in the stack knows both. Once it records
"we entered `lock` at T, and policy says `sleep` is due N seconds later", a
watchdog can check at T+N and act when the primary mechanism did not.

That needs two hook kinds beyond the actuators and verifiers:

    <edge>.due.d     WHEN should this edge have fired? Emits a deadline in
                     seconds after the previous rung was entered. The TIMEOUT
                     LIVES OUTSIDE VIGILANT (swaylock.conf `blank-after`, a
                     swayidle timer), so a mechanism-specific hook reads it
                     and reports it. vigilant stays mechanism-agnostic.

    <edge>.block.d   Is something LEGITIMATELY preventing it? An idle
                     inhibitor, a fullscreen video, a policy. Lets
                     enforcement be conditional rather than blind, so we do
                     not fight a mechanism that is behaving correctly.

The depth file gains the TIME the rung was entered; without it there is no
deadline to compute.

### 10.1.2 The enforcement loop (the "not so nice" half)

On a timer:

    due = max(<edge>.due.d)          # what the environment's own config says
    if now > entered_at + due + GRACE and depth is still shallower:
        if <edge>.block.d reports a block:
            LOG it; hold off (or force anyway, per policy)
        else:
            FORCE the edge, and LOG that the primary mechanism failed

GRACE exists so the primary mechanism wins the race in the normal case;
vigilant only acts when the edge is demonstrably overdue. The point is not to
take the timer over. It is that a mechanism which silently stops working
becomes a RECORDED, CORRECTED event instead of weeks of dead peripherals.

SAFETY CONSTRAINT, learned the hard way: never force a descent without a
reliable ASCENT. vigilant cannot see input while locked once the patch is
gone, so a forced blank could land while someone is typing a password. The
`always_binding_` rescue key is the floor under this (proven to fire while
locked), and enforcement must not ship before it is in place. Aggressive
enforcement without a recovery path is how a user gets stranded.

### 10.1.3 Playing nice with the stock mechanisms

Supervision is not only correction. Where a standard interface exists,
vigilant should FEED it rather than invent a private one:

- logind's `LockedHint` is `no` on this box even while genuinely locked, and
  `IdleHint` is never set. Nothing feeds them. `vigilant go lock` should call
  `SetLockedHint(true)`, so anything else asking logind gets the truth. That
  is asserted-vs-actual drift in the standard interface, fixed at the source.
- `systemd-inhibit --list` is readable unprivileged and is the first
  `block.d` hook. Coverage is PARTIAL: it reports logind inhibitors only, and
  Wayland `idle-inhibit` is a separate channel it cannot see. Say so in the
  hook rather than implying full coverage.

### 10.2 Two targets, because the mechanism forces it

`graphical-session.target` is owned by the `systemd` package itself (verified
with `dpkg -S`; LGPL, "part of systemd"). It is NOT an Ubuntu construct, so
using it binds us to systemd, which is already the chosen trust root.

But it declares:

    RefuseManualStart=yes
    StopWhenUnneeded=yes

so it CANNOT be started directly; it must be pulled in by another unit's
dependency. The two-layer design is therefore forced, not merely preferred:

    vigilance-session.target        ours, manually startable
      BindsTo=graphical-session.target        one line
      Before=graphical-session.target
    vigilance-*.service   PartOf=vigilance-session.target

Our units bind to OUR target, which is the seam: point it at a different
session signal, or drop the binding, without touching N units.
`StopWhenUnneeded=yes` means the standard target tears down when ours does.

THE BINDING IS OFF BY DEFAULT AND TACKUP OPTS IN. `mako.service` is Wanted by
`graphical-session.target` while mako already runs from wayfire's autostart;
pulling the target up starts a second mako or fails the unit, and the same
question applies to the other ~20 distro units. Reconciling the autostart list
against those units is inventory work, belongs to tackup, and must NOT be a
precondition for landing vigilance's stages.

### 10.3 `mute-leds` ships with vigilance

Corrected from the earlier draft. The `root:input` `g+w` on
`/sys/class/leds/platform::mute/brightness` comes from BRIGHTNESSCTL's own
udev rule, not a tackup-specific one (see `modules/mute-led`'s header);
tackup's only job is putting the login user in `input`, which is
brightnessctl's standard requirement everywhere. `brightnessctl --list
--class=leds` already lists `platform::mute` and `platform::micmute`.

So it ships in vigilance, available and unwired, exactly like `ddc-monitor`,
with one change: drive it through `brightnessctl --class=leds --device=...`
instead of the raw sysfs writes `mute_leds()` does today. That sheds the last
box-specific assumption and makes it identical in shape to `kbd-backlight`.

THE GENERAL RULE this settles: vigilance ships any hook whose MECHANISM is
standard; the integrator decides which ones RUN. Ownership follows the
mechanism, not whether this particular desk has the hardware.

## 11. Test tiers and how they integrate

The integration between tiers matters more than either tier. This cycle proved
why: `modules/tests/lock` was GREEN the whole time `~/bin/panel-power` did not
exist. The tests tested the CODE; every bug was in the WIRING. Two tiers that
do not share a definition of correctness just give two ways to be confidently
wrong.

So the SHARED LAYER is built first and both tiers are thin adapters on it.

    test/
      lib.sh          existing harness (harness_init, pass, fail)
      scenario.sh     the shared vocabulary; both substrates use it
      scenarios/      substrate-agnostic scenario files
      run             STUB substrate: fast, no root
      vm/run          VM substrate: root, real systemd + logind

Three rules make them cohere.

### 11.1 One scenario suite, two substrates

Scenarios are written once against `scenario.sh` and executed by both drivers.
Same assertions, different ground truth.

### 11.2 `vigilant verify` is the shared oracle

Assertions go THROUGH the product's own verifier, not by poking at files. The
suite and the production watchdog then cannot disagree about what "correct"
means, because they call the same predicate. Every verify hook written
improves the suite AND live monitoring.

### 11.3 The stub tier stubs ACTUATORS, never the TRUST ROOT

Hardware actuators (ddcutil, brightnessctl, qmk) are stubbed by recorder
hooks. systemd, logind and suspend are NEVER stubbed: a stubbed `systemctl`
lies, and a lying stub is exactly how a green test coexisted with a broken
box. Scenarios needing them are VM-ONLY and SKIP WITH A VISIBLE MARKER.

`test/run` must print a coverage summary (`N passed, M skipped (need VM)`) so
a green stub run can never read as full coverage. A silently skipped test is
the same false confidence that let `lock-watch` sit dead for 74k restarts.

### 11.4 Division of labour

| tier | the question it answers |
| --- | --- |
| stub | does the logic do what we mean? |
| VM | does a FROM-SCRATCH INSTALL produce a working system? |
| oracle | used by both tiers AND running in production |

The VM tier installs from scratch (clone, `setup.sh install`, wire the hooks,
boot, `vigilant check`) so it tests WIRING rather than code. That is the
category every bug in this cycle fell into.

### 11.5 Scenarios owed, drawn from real failures

Each reproduces a failure this cycle that was silent at the time:

    didn't start      assert the UNIT is active, not that a process exists
    wedged            SIGSTOP the daemon; assert WatchdogSec restarts it
    wrong session     ssh + tty + wayland sessions; assert the probe picks
                      the wayland one (manifestor had seven)
    broken hook path  point a hook at nothing; assert it fails LOUD
    target drift      kill the compositor without stopping the target;
                      assert verify reports the mismatch

## 12. Interim state (remove when stage 1 lands)

`link/bin/panel-power -> ../../../../.local/bin/panel-power` is a deliberate
temporary shim on manifold and manifestor, restoring the peripherals hook that
the vigilance extraction broke when `panel-power` moved from `~/bin` to
`~/.local/bin`. Untracked as of this writing. Stage 1 deletes it.
