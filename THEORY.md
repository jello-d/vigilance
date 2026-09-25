# Theory of operation

What this package believes, what it assumes about the world, and which check
enforces each belief. Written because that knowledge was spread across 8,500
lines of test commentary and a private notes file, which made independent
review impossible. A week in which most defects arrived in the fixes for the
previous ones is what a system looks like when nobody can review it, including
its author.

Read `README.md` first for what the tools are. This file is about why they are
correct, and about where they are not.

## 1. The model

One dimension: how far the machine has withdrawn.

    open      here; unlocked and lit
    lock      session secured; screen still lit
    sleep     peripherals down
    suspend   S3 or hibernate

Movement between adjacent rungs is an **edge**. A descent edge shares its name
with the rung it enters (`lock`, `sleep`, `suspend`); ascents need their own
words (`unlock`, `wake`, `resume`).

**Intent belongs to the rung, not the edge.** `resume` is a dark edge purely
because it lands at `sleep`. That one observation is why the vocabulary is a
single table rather than five functions: every special case that used to exist
in `_intent_of` was a restatement of the destination rung's intent.

**The framework owns the ladder and nothing else.** No locker, no compositor,
no monitor and no idle timer appears in the traversal code. Measured rather
than asserted: the nine functions that make up a crossing contain zero
mechanism references. Everything touching hardware is a hook, supplied by the
integrator.

## 2. The invariants, and what enforces each

An invariant with no enforcing check is a wish. Both lists are given so the
wishes are visible.

     1  nothing enters a dark rung unless its way back is armed
        ddc-monitor.t (D6=02 only), dpms.t (never `wlopm --off`)
     2  a block may refuse to take the machine DOWN, never to bring it UP
        block.t, rescue.t
     3  a lock request may deepen the machine, never raise it
        atleast.t
     4  "I could not look" is never "I looked and it is fine" (exit 78)
        not-applicable.t, verify.t, coverage.t
     5  every acting edge has a verifying edge
        tackup modules/tests/lock, with the edge list derived from the tree
     6  no hook can hold an edge open indefinitely
        hook-bounds.t, budget.t
     7  the panic key always works
        rescue.t, cross-lock.t section 4
     8  one crossing at a time
        cross-lock.t, including section 6: nothing may bypass the lock
     9  save once, assert every time
        hooklib.t, hooks.t, panel-backlight.t
    10  a verdict is about a rung, and a rung can move while you measure it
        standing-recheck.t sections 9 and 9b
    11  the record may lead the machine only during a crossing
        standing-recheck.t section 9b
    12  enabled is not working; running is not working; armed is not reachable
        report.t, swayidle-watchdog.t, due.t
    13  a rung at or below `lock` implies the session is locked
        locker-up.t, atleast.t section 4
    14  the framework hardcodes no mechanism
        hermetic.t section 2
    15  a dedup key never contains a measurement
        standing-recheck.t section 10
    16  nothing user-writable is reachable as a root input
        setup.sh check
    17  a command resolves from exactly one PATH entry
        setup.sh check
    18  a test that reaches no verdict is a failure
        test/run
    19  a guard nothing can kill is not a guard
        test/mutate (101 records), mutants.t
    20  a check must not read the developer's live box
        hermetic.t
    21  a verdict that may be discarded must not notify before it is accepted
        standing-recheck.t section 9
    22  a power cut cannot leave the ladder unable to act
        test/vm/crash (host-side: the guest is what gets killed)

### Invariants with no enforcing check

Stated plainly rather than implied:

- **A hook must survive being run twice in sequence.** The crossing lock
  serialises concurrent requests; it does nothing about a second press five
  seconds later. This is discipline only. A generic ratchet was considered and
  rejected: in a sandbox most hooks correctly decline (78), so the check would
  pass vacuously and read as coverage it does not have.
- **No performance guard exists.** A refactor once added an `awk` per hook per
  edge on the security path, about 7%, and nothing would have caught it. It was
  found by going looking.
- **`enforce` has never acted in production.** The forcing half is retired and
  the detection half has produced exactly one true positive so far.
- **The greeter's sleep path has never been observed** on real hardware.

## 3. What is assumed about the world

Each of these was at some point "everyone knows", and each was false here.
`test/environment.t` now asserts the ones the code depends on.

`mkdir` is an atomic claim
: FALSE. uutils coreutils 0.10.0 checks existence and then creates, so it was
  non-exclusive in 14 of 20 concurrent rounds. The crossing lock uses an
  in-shell `set -C` redirect instead, deliberately depending on no external
  program: a lock built on a separate program can be swapped for one with a
  TOCTOU inside it, and here it already was.

`systemctl is-active` means "not down"
: FALSE while a unit is activating. Shipped a lock-edge alert twice.

an unknown key in a config file is ignored
: FALSE. swaylock prints the option and its entire usage, and the lock provider
  returned 1. A dead config key raised an alert on the most security-critical
  edge there is.

`%[fx:mean]` measures luminance
: It averages ALPHA as well, so an opaque all-black frame reads 0.25 and the
  tier measuring a blanked screen called a working mechanism broken.

a screen capture shows what the display emits
: FALSE. `grim` copies the compositor's framebuffer; a backlight is a panel
  property outside it, so a capture reads identically whether the panel is
  blazing or completely off.

`$(...)` respects a `timeout` bound
: Implementation-specific: defeated under uutils, bounded under GNU. The runner
  captures through a file so it depends on neither.

`: > file` is a guarded truncate
: It exits the shell on a redirect error, because `:` is a special builtin.

a log record that was written is a log record that survives
: FALSE across a power cut. `_log` appends without fsync, so records still in
  the page cache are gone, and ext4 leaves the tail of the file as a run of NUL
  bytes: the SIZE is journaled and survives while the data blocks were never
  written. Measured in `test/vm/crash`: of 150 records written, the 50 that had
  been synced survived intact and the rest became one 1232-byte NUL line. The
  artifact is harmless to every shipped reader (`vigilant audit` was run against
  exactly it and reconciled both events correctly), and the only way to prevent
  it is an fsync per record on the security path. So it is a stated limit of the
  forensic tier rather than a defect: the audit tier cannot be trusted about the
  last few seconds before a crash, which is the window it would most like to
  describe.

`[ ... ] && return` is safe under `set -e`
: It kills the shell when the test fails. Has bitten three times.

elapsed time is never negative
: FALSE. A wall clock is not monotonic, and every record here is stamped with
  `date +%s` and compared later against `date +%s`, so an NTP step, an RTC left
  in local time after a dual boot, or a VM restore makes `now - then` NEGATIVE.
  A negative satisfies every `-lt <bound>` and `-le <bound>`, so a bound meant
  to expire something never does. Measured across the twelve such computations:
  three switched a safety mechanism OFF for the length of the skew, silently.
  `phantom-guard` blocked every idle lock, so the screen never locked;
  `_alert_repeat` deduped every alert, so nobody was told; `_crossing_inflight`
  believed a stale marker, suppressing the standing recheck. `_elapsed` now
  detects the anomaly in one place and each caller answers it with whatever does
  not disable itself, because there is no single safe clamp: clamping to 0 still
  satisfies a cooldown.

`awk -v x=...` passes a literal
: It expands backslash escapes. `ENVIRON` does not.

a daemon picks up new code when you deploy it
: It pins its argv at start. Three separate outages came from that gap.

a `--user` unit can see the session it is started from
: It inherits the user MANAGER's environment, not its caller's. The lock
  provider starts swaylock as a transient `--user` unit, so without
  `WAYLAND_DISPLAY` imported into the manager it cannot reach the compositor
  and every lock fails with nothing but "could not start". On a desktop the
  compositor's startup imports it and the dependency is invisible; the session
  tier found it on its first run by not having one.

### Hard dependencies, stated rather than discovered

systemd and logind are a trust root, not a plugin: the units, the transient
locker unit, `systemd-run --user`, and `loginctl` for session state. That is
defensible, since something has to be trusted and an init system is a better
choice than a bespoke supervisor, but it is a real constraint on portability
and should be read as one.

## 4. Defence in depth: what is watching what

Five independent mechanisms, each able to see something the others cannot.
This is the part that has worked: no single failure has evaded all of them.

    crossing-time verify   did this edge take effect, at the moment it ran
    standing recheck       is the machine STILL where it says it is (every 60s)
    report                 is the machinery itself armed, runnable, reachable
    audit                  did a past event produce the edge it should have
    watchdog               is a daemon that is RUNNING actually doing anything

The ordering principle is that each asks a different TENSE: now, still, armed,
past, and alive. A check duplicating another's tense adds noise rather than
depth, which is why the watchdog explicitly declines to report "swayidle is not
running" (that is `report`'s finding) and answers only "it is running and
silent".

**The known blind spot:** every mechanism above is inside vigilance. Nothing
watches vigilance from outside except systemd, which is why the supervision
timer is a systemd unit rather than a daemon of ours.

## 5. Test strategy, and its limits

Two substrates run the SAME scenarios:

    test/run      stub:    fast, no root. Actuators are recorder hooks.
    test/vm/run   VM:      real systemd, logind, suspend, user bus, sway.
                  session: the REAL hooks, wired, driven by the REAL daemons.

THE SESSION TIER IS THE ANSWER TO THE FOURTH SHORTFALL BELOW. Both other tiers
replace the shipped hooks with recorders, so nothing ever ran the real hook set
through a real ladder cycle. It uses the guest's real paths on purpose -- the
real log, the real hook tree, the real units -- because sandboxing them would
put the recorders back one layer down. A VM marker gates it, so a capability
granted by mistake cannot aim it at a desk.

The rule that keeps it honest: **the stub tier stubs actuators, never the trust
root.** A stubbed `systemctl` lies, and a lying stub is exactly how a green test
coexists with a broken box. A scenario needing what the stub cannot provide
declares `require` and skips visibly.

On top of that:

- `test/mutate` breaks each guard on purpose and asserts that a test notices.
  90 records. A guard nothing kills is decorative.
- `mutants.t` re-checks that every record still describes the code, so a
  reworded line fails in seconds rather than silently disarming a mutation.
- `hermetic.t` ratchets that no check reads the developer's live box.
- `claims.t` ratchets that every knob is documented.
- `environment.t` ratchets the platform assumptions in section 3.

### Where this still falls short

1. **Fixtures encode the author's model.** The clearest case: the lock unit's
   state was modelled as a boolean, so the fixture could not express
   `activating`, which is exactly the state the code also failed to consider.
   Both agreed, the test passed, the live box failed. A fixture derived from a
   mental model can only test that mental model. The mitigation is to prefer a
   real substrate wherever one can be built, which is what the VM user bus is
   for.
2. **Fail-open mechanisms are opaque to outcome assertions.** Where every path
   ends in the same outcome by design, only the RECORD discriminates. Four
   mutations survived `cross-lock.t` before its assertions moved onto the log.
3. **Most defects now arrive in fixes.** The change repairing a defect is
   written under the same misunderstanding that caused it, and ships within
   hours. `test/lock-race-real.t` exists because the fix for a race contained
   the same race.
3a. **A reader racing a writer cannot be fixed by exclusion here.** The crossing
   lock eliminates writer-against-writer (invariant 8). The standing recheck is
   a READER, and it must not hold that lock across its verify: a verify is
   seconds of ddcutil round trips and screen captures, and making a lock request
   wait on one would trade a reporting fault for a security one. So the recheck
   uses optimistic concurrency instead -- measure, then check whether the state
   moved, and discard if it did. **That is only valid if the discarded work had
   no externally visible effect**, which is invariant 21 and which took three
   attempts to get right: the verdict was discarded correctly all along while
   the alert inside it had already reached a human. The general form: a
   transaction that can be rolled back must not emit before it commits.
3b. **Fidelity beats diversity, measured.** Classifying the last ten defects by
   what would have caught them: six are real-component integration, one is a
   platform primitive, and NONE is environment diversity. A second stack (X11)
   would have caught nothing; running the real components did.
4. **Nothing gates deployment.** The package pin tracks `head`, so a push
   reaches the machines on the next integrator run. The operator is the canary.

## 6. Rules of thumb that earned their place

Each of these cost at least one live failure.

- **Test the capability, not the implementation.** A grep for an idiom cannot
  tell "does not do X" from "does X another way", and it sent two repos chasing
  work that did not exist.
- **Assert the precondition, not just the outcome.** A timing assertion on a
  path that was never taken is green for ever.
- **Check the deployment before the mechanism.** Twice, a "broken feature" was
  a checkout one commit behind.
- **A negative result from a coarse instrument is not a negative result.** A
  race eight trials could not reproduce showed up 9 times in 12 once the window
  was widened by 200ms.
- **When a measurement falls outside its defined range, suspect the
  instrument** before the thing being measured.
- **Confirm a mutation actually landed.** A pattern matching nothing leaves the
  file untouched, and that reads as "the guard does not bite".
- **A record format that defeats a reader of the log is a defect in the log.**
- **Silence means opposite things at the two ends of the ladder.** At a dark
  rung a silent monitor is complying; at a lit rung the same silence is a panel
  that was told to come on and did not.
