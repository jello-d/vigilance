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
        atleast.t, and fuzz.t under random sequences
     4  "I could not look" is never "I looked and it is fine" (exit 78)
        not-applicable.t, verify.t, coverage.t
     5  every acting edge has a verifying edge
        tackup modules/tests/lock, with the edge list derived from the tree
     6  no hook can hold an edge open indefinitely
        hook-bounds.t, budget.t
     7  the panic key always works
        rescue.t, cross-lock.t section 4, and fuzz.t after any sequence
     8  one crossing at a time
        cross-lock.t, including section 6: nothing may bypass the lock;
        fuzz.t for the leaked-lock half
     9  save once, assert every time
        level-rules.t (the table, x3 adapters), hook_lib.t, hooks.t
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
        test/mutate (139 records), mutants.t
    20  a check must not read the developer's live box
        hermetic.t
    21  a verdict that may be discarded must not notify before it is accepted
        standing-recheck.t section 9
    22  a power cut cannot leave the ladder unable to act
        test/vm/crash (host-side: the guest is what gets killed)
    23  a security request may deepen the machine, never raise it, and a REAL
        lid switch is the case that proved it matters
        fault-lid (a uinput SW_LID through logind), atleast.t
    24  the machinery is watched whether or not the machine has state to judge
        watchdog.t cases 4 and 4b (no target, and no record at all)
    25  a mechanism that defers can be seen still looking
        cadence.t, including that the ages are read before report's own verify
    26  every exit value the runner names is in the man page AND the README
        claims.t, with the list derived from the constants
    27  the runner's own cost per hook does not grow
        perf.t, which counts forks rather than milliseconds
    28  nothing accumulates per crossing, and one fault is one alert
        soak.t as a slope over a uniform cycle; fuzz.t under a random one
    29  a tier that DEFERS is checked again once its interval elapses
        cadence.t case 6, through the real runner with the stamp backdated
    30  a hook that ACTS survives being run twice in sequence
        level-rules.t for the level keepers, session-repeat.t for the rest
    31  a held idle inhibitor DEFERS an idle deadline rather than missing it,
        and the deferral is bounded, interruptible, and never forces a dark
        rung
        idle-inhibit.t (the reader, both implementations),
        inhibit-bound.t (the bounds, ack, and the dark-rung refusal)
    32  silence is evidence only over time we were WATCHING, and an innocent
        explanation that can be measured is never offered as a guess
        swayidle-watchdog.t cases 2b, 8 and 9
    33  a deadline cannot be LATE before the mechanism judging it has had its
        chance, so idle time is ceilinged by both the last ascent and the idle
        timer's own age
        due.t (both ceilings, and the real `ps` probe behind the second)
    34  every crossing records WHO ASKED, and a label never changes what any
        OTHER mechanism reads out of the same string
        claims.t (the vocabulary, both directions), block.t (the shipped
        sources the debounce must let through), idle-audit.t (the armed
        command resolves past the label), swayidle-due.t case 9 (a label
        cannot invent a deadline)
    35  an edge left OVERDUE with nothing deferring it is REPORTED on every
        pass, naming both causes of the silence rather than one; and where an
        integrator has opted in AND something positively corroborates that
        the edge's own timer saw the quiet stretch, ACTED on after a bound,
        once per episode, the act RE-ARMING the timer rather than forcing a
        dark rung
        overdue-bound.t (the bound, the ambiguous wording, the dark-edge
        refusal, the lit edge and its attribution, the wedge finding, the
        unwatched gap, 0 disabling the act, the act OFF by default, and the
        act HELD without corroboration)
    36  a deadline whose own OWNER saw none of the quiet stretch is DEFERRED
        rather than missed, and takes the idle-inhibit escalation (silent,
        reported, then the session secured, with one veto) instead of a
        per-pass accusation; where the owner DID see it, the overdue finding
        names which half broke; and a tier that cannot answer changes nothing
        concur.t (the hook: agreement, disagreement, a resume that is not
        agreement, the heartbeat precondition, abstention, and the heartbeat
        facts shared with the watchdog), unnamed-bound.t (the framework: the
        dispatch, both bounds, the dark-edge refusal, precedence for a
        nameable hold, the veto, and the view)

### Why the idle reading has two ceilings and not one

Worth stating because the second looks redundant until you see what the first
cannot reach. Both answer the same question: our clock may be older than the
mechanism it is judging, and reporting that as a missed edge is a finding about
us rather than about the machine.

    the last ascent      something raised the ladder, and whatever did also
                         restarted the timer: a lid switch, or swayidle running
                         its pending resume commands on SIGTERM
    the timer's own age   a restart with no timeout outstanding runs no resume,
                         crosses NO edge, and so leaves no ascent to bound
                         against

MEASURED on manifestor, twice, 14 alerts: windows of [restart, restart +
deadline] that close exactly when the primary mechanism fires. The cause is the
compositor's: this Wayfire fires an idle notification only after waiting the
threshold out FROM REGISTRATION, measured when a one-shot idle probe was ruled
out, so it never reports an already-idle seat and a restarted timer re-arms
from zero however long the seat has been quiet.

The integrator restarts that unit whenever the armed argv changes, so every
deploy touching it opened this window.

### Where supervision ACTS, and what makes each case safe

Invariants 31, 35 and 36 are the only exceptions to "supervision reports, it
does not act", so it is worth stating why none of them is the return of
`enforce`'s forcing.

THE THREE ARE TWO QUESTIONS, not three. Invariant 31 and invariant 36 are the
SAME finding reached by different evidence, which is why they share their
bounds, their action and their veto: a deadline is being deferred, and the only
difference is whether vigilance can NAME what is deferring it. Invariant 35 is
the opposite case, a deadline genuinely missed, and it is the one whose act
ships off.

A held logind idle inhibitor suppresses every idle timeout, because
`swayidle-mgr` arms a logind event so the request is HONOURED: a video call
must not be cut off mid-sentence. That made it possible for the first time for
an idle deadline to pass with nothing wrong, and the overdue detector did not
know the reason existed. MEASURED, on the first full day after that arm landed:
27 alerts in 93 minutes, with the heartbeat silent for 132 minutes and then
healthy again at `NRestarts=0`, so the same process throughout and never a
wedge.

Suppressing the finding alone would have been the wrong fix: a LEAKED inhibitor
then keeps a machine unlocked indefinitely with nothing saying so, which is the
silent false green this whole package exists to prevent.

What makes the forced lock different from the forcing that was retired is that
reaching it takes THREE independent pieces of evidence rather than a
measurement:

    a notification ignored for the whole hour between the two bounds
    a seat genuinely idle past the edge's OWN deadline
    an edge that is `lock`, so a lit rung, never a dark one

A call somebody is attending fails the second. `vigilant timer reset` answers
first. The third is invariant 1. And either bound at 0 disables that half, so
an operator who wants no actuator here keeps none.

The second (invariant 35) is the OTHER half of the same question, and the
asymmetry between them is the whole design. A deferred deadline has a reason;
an overdue one is a fault, and reporting a fault every minute to somebody who
is not at the machine is half a mechanism. MEASURED on manifestor 2026-10-09: a
remote unlock/lock pair left the ladder at `lock` with the idle timer's
timeouts already spent, the detector said so correctly for five passes running,
and a static lock surface sat lit on an OLED for 39 minutes, ended only when a
human walked to the machine: the log shows a real unlock at 22:14:18
(`src=locker-exit`) and a keybind lock two seconds later, which gave the
compositor the seat input swayidle needed, after which the blank fired normally
600s later. What ended it is the one thing a remote operator cannot do.

What keeps it safe is that the act is a RE-ARM rather than a crossing. A forced
`go sleep` would break invariant 1 in precisely the case it exists for: if the
timer really is wedged, the way back is not armed and the screen is stranded
dark. Re-arming the timer fixes the CAUSE and enters no rung at all. Only where
the overdue edge is `lock`, whose rung is a guarantee, is the edge crossed
directly, because there a re-arm alone would push an already-missed lock
deadline out by its whole length again.

ONCE PER EPISODE, and the second pass carries the better finding. A timer that
had merely spent its armed timeouts comes back when restarted, so one still
silent afterwards is WEDGED: positive evidence of the founding failure of this
package, which nothing here could previously tell apart from a timer that was
simply out of timeouts. It is reported and never retried, because a restart
every minute would reset the deadlines every minute, and a box whose lock
deadline is perpetually reset never locks at all.

AND "ONCE PER EPISODE" IS NOT "ONCE PER FAULT", measured in the same incident.
On the lit edge the act SECURES the session, the human unlocks it, the unlock
is seat input, that input drops idle back under the deadline and ENDS the
episode, and a fresh one opens as soon as idle passes the deadline again. So
the act repeats every deadline-plus-bound for as long as the underlying
condition holds. Measured 22 minutes apart against a 480s deadline and a 600s
bound:

    15:28:16  forced lock, and the idle timer re-armed
    15:28:24  cross unlock: the human is back, 8 seconds later
    15:29:22  overdue episode ENDED, because that input cleared it
    15:40:06  a NEW episode opens at 516s of idle
    15:50:56  forced lock again

TWO CONSEQUENCES, and the second is worse than the repetition. The WEDGE
finding above is UNREACHABLE on the lit edge whenever the act succeeds, because
a second miss inside one episode cannot happen if the act's own side effect
ends the episode. And alert dedup makes the repetition SILENT: the first act
notified and the second was suppressed as a repeat inside the 3600s cooldown,
so the human was told once and locked twice. The warning window that makes the
inhibit bound safe does not exist here at all.

AN ACT WHOSE SIDE EFFECT CLEARS ITS OWN PRECONDITION IS SELF-RETRIGGERING, and
counting attempts per episode cannot bound it. Also stronger evidence than the
silence alone: swayidle was restarted by the FIRST act, so it entered the
second window with every timeout freshly armed and still emitted no tick, which
rules out "it had merely spent its timeouts" outright. Not changed, since the
act is off by default and bounding it properly is a design decision rather than
an improvisation; written down so that whoever opts in knows what they get.

AND THE SPAN MAY ONLY COUNT TIME A PASS WAS THERE TO SEE. The supervision timer
does not fire in S3, so a suspend spanning an episode would otherwise be
credited as time overdue and fire the bound the instant the box came back. That
is the same rule the idle clock's MAXGAP enforces, against the same sampler, and
it is the trap the watchdog was caught in on 2026-10-07 with 15941s of S3
inside a 16045s "silence".

BUT THAT ACT IS OFF BY DEFAULT, and the retreat was measured rather than
cautious. It rests on a premise this tier cannot check: that OUR idea of an
idle seat agrees with the deadline owner's. "Overdue" is built from two halves
that come from different places, the DEADLINE from the idle timer and the
IDLENESS from `idle.d`, so where something holds the timer off through a
channel `idle.d` cannot see, a correct deferral is indistinguishable from a
wedged timer.

LIVE on manifold 2026-10-14, which is how this was found. A browser in a video
call took the compositor's own idle inhibitor
(`zwp_idle_inhibit_manager_v1`), so swayidle was told the seat was ACTIVE and
correctly never fired the 480s lock: ZERO `idle-tick` events for 22 minutes
with a 60s heartbeat armed, which is the evidence, and no logind inhibitor and
no owner on `org.freedesktop.ScreenSaver`, so neither channel vigilance CAN see
was in play. The shipped `10-input-counters` reads kernel input counters, which
see no inhibitor of any kind, and read 1166s of idle. The act then locked a
machine somebody was working at, under an alert asserting that the primary
mechanism was not working about one that was declining on purpose.

THE EXACT GAP WAS RECORDED THREE DAYS EARLIER AND CALLED "THE SAFE DIRECTION".
It was, while overdue only REPORTED. Adding an actuator is what made it unsafe,
and the sentence saying so was never revisited. The watchdog one tier over had
the right shape all along: it says an idle inhibitor "produces IDENTICAL
silence and cannot be queried" and offers two causes rather than asserting a
fault. The general rule, now paid for: AN EXCLUSION THAT IS ADEQUATE FOR A
REPORT IS NOT NECESSARILY ADEQUATE FOR AN ACT, so adding an actuator to a
detector means re-deriving every "this errs in the safe direction" the detector
rests on, because the safe direction changed.

Reporting stays on, and names both causes: a report that is wrong costs a
reader a few seconds, and one that names the only cause it can think of sends
them after a healthy mechanism.

AND THE ACT NEEDS POSITIVE CORROBORATION, not merely the absence of a
disagreement, which is the second half of that retreat and the sounder footing.
The commit that defaulted it off said the precondition was "an inhibitor-aware
clock", and strictly the clock is still blind; what invariant 36 supplies is
better than awareness. The act is now only REACHED where a source says the
timer DID observe the stretch, which is exactly when "the timer is alive and
its acting arm is broken" is an established diagnosis rather than one of two
guesses, and a re-arm is the remedy for precisely that. Reaching it on "cannot
tell" was the 2026-10-14 evidence itself.

THE THIRD (invariant 36) IS WHAT MADE THAT RETREAT MORE THAN A RETREAT. The
disagreement the overdue act could not see is itself observable: `concur.d`
asks whether the deadline's OWNER agrees the seat has been quiet for the
stretch `idle.d` measured, and the shipped source answers from the idle
timer's own heartbeat. Where it says no, the edge was never DUE as far as the
thing that owns it was concerned, so this is a deferral and takes invariant
31's escalation rather than an accusation.

IT DELIBERATELY CANNOT SAY WHY, and that does not matter to the action. A
honoured compositor inhibitor and a wedged timer are IDENTICAL from outside,
which is what `swayidle-watchdog` says in as many words and refuses to resolve.
Both want the same response: not to interrupt a call early, and not to leave
the session open for ever either. So the ambiguity costs only the wording of
the message, and the message names both.

AND IT IS NOT A LICENCE TO GO QUIET, which is the half that makes it safe to
add. Leaving an unnameable hold to the overdue tier would mean nothing bounds
it at all now that the act ships off: a LEAKED compositor inhibitor would hold
the session open indefinitely with nothing saying so, which is the silent false
green this package exists to prevent. The deferral is bounded on the same 3h
and 4h as a nameable one, because a leak is exactly as dangerous either way.

THE CONVERSE EARNS ITS KEEP TOO. A CONCURRENCE means the timer observed the
idleness and still did not act, which turns the overdue message from one of two
guesses into a statement that names the half that broke: the tick arm works and
the acting arm does not. That is the 2026-09-12 outage, where a running timer
was armed with a path that had been swept out from under it, and until now
nothing could tell it apart from a timer that saw nothing.

### Why the peripheral cadence is an hour, and what makes that safe

ENFORCED, by invariants 25 and 29; kept here because the REASONING is
what a reader needs before changing the number.

- **A peripheral verifier is checked hourly, not every minute.** Cadence
  follows consequence: `locker-up` answers "is the session secured" and earns a
  minute, while "is the keyboard's RGB still off" does not. What makes that
  safe is the EVENT: the first pass after the rung CHANGES verifies
  everything, because that is when drift is introduced (the keyboard-backlight
  drift appeared 14 seconds after a crossing). The hourly pass is a backstop
  for the case nobody thought of. Measured before it: the recheck ran the whole
  tier every minute at 2.0s a pass, 48 minutes of work a day on an idle
  machine, one second of it a single ddcutil probe, while in the entire log
  history the peripheral verifiers had reported drift exactly NEVER. Crossings
  still do not verify in line, deliberately: a read-back fires before a device
  can settle (the mute LED returns two seconds later) and it would add a verify
  pass to the lock path. **The cadence is now observable**, which it was not
  when it shipped: report's `cadence` section names when each deferring tier
  last genuinely looked and whether the transition has fired for the rung the
  machine is on (invariant 25). **And the interval itself is enforced now**
  (invariant 29): the sentence here used to say only the wall clock could
  measure it, and the wall clock is a FILE. `hook_throttle` compares a stamp
  under the hook's own state dir, so backdating that stamp is an injected clock
  rather than a fixture standing in for one, and cadence.t case 6 drives a real
  hook through the real runner: it checks once, defers on the next pass, and is
  checked AGAIN once the stamp is older than the interval.

### Why "run every hook twice" is a real check here and not a vacuous one

A GENERIC RATCHET WAS REJECTED FOR A GOOD REASON and the reason had to be
answered rather than ignored: in a sandbox most hooks correctly decline with 78,
so "run them all twice" passes over an empty set and reads as coverage it does
not have.

Two things answer it. The SESSION TIER has real devices, so a decline there
means something is genuinely absent rather than stubbed out. And
session-repeat.t carries a DENOMINATOR: it counts the rows that actually acted
and FAILS if that count is zero, so a run which proved nothing says so instead
of printing a green line. Same move as test/faults.rec for the fault space.

THE DISTURBANCE IS THE HOOK'S OWN VOCABULARY, which is what makes it generic
without needing per-hook knowledge of how to break a device:

    act dark -> act lit -> act dark AGAIN -> is the device really dark?

The ascent puts the device in the wrong state for the second descent, so a hook
that short-circuits on its own state no-ops that descent, returns 0, and is
caught by a readback taken INDEPENDENTLY of the hook. That is exactly the shape
that shipped twice: hook_dark returned 0 outright when its save file existed,
and ddc-monitor's hand-written copy did it again three weeks later.

PROVEN TO BITE BY HAND, which is what the corpus limit prescribes for a VM-only
guard: reintroducing that short-circuit in sway-dpms turned the scenario red on
precisely the second-descent readback, while the other row still passed, so the
failure was attributable. The stub tier's own sway-dpms.t stayed green in the
same run, which is the argument for the scenario existing.

### What the fuzzer buys, and what it does not

`test/fuzz.t` builds a random sequence from the ladder's LEGAL operations, with
FAULTS in the alphabet, and checks the invariants after every step. It exists
because of one measured pattern: every defect the box found and the tests did
not had the same shape, a MODEL incomplete exactly where an external actor
touched the state. A scenario can only contain sequences somebody thought of;
this needs no model.

TWO PROPERTIES MAKE IT USABLE rather than alarming. The sequence is derived from
a SEED by an LCG in shell arithmetic, not from $RANDOM or awk's srand, so it is
identical on any box for ever; and a violation BISECTS to the shortest failing
prefix and prints the two numbers that reproduce it. A fuzzer that cannot
reproduce its own failure reports something unactionable and gets switched off.
Default seed and length are FIXED, so the suite has a regression test rather
than a slot machine.

FIRST RESULTS, stated honestly: about 6200 operations across seven seeds, no
product defect. It did find one real bug, in ITSELF: the liveness check read `go
lock`'s exit code as "did the lock happen", and with a failing hook wired the
runner correctly returns 1 while the depth reaches `lock`. That is the same
conflation this suite has paid for before, committed in the file written to
catch such things, and caught by running it.

AND ONE VACUOUS CHECK, found the way they should be. The first oracle asked
`status` whether the depth was a rung, which `_depth` GUARANTEES: it validates
the record and falls back with a note. Planting a corrupt record changed
nothing, so the check could never fire. It reads the RECORD ON DISK now, which
is the falsifiable claim (the runner must never WRITE a bad one), and planting
that same corruption is what finally exercised the bisect.

### Invariants with no enforcing check

Stated plainly rather than implied:

- **A LOCK CAN OUTLIVE EVERY LOCKER, and then `open` is a false rung.** The
  model above defines `open` as "here; unlocked and lit", and vigilance infers
  that from the locker's PRESENCE. Lock state belongs to the COMPOSITOR, and
  ext-session-lock makes the two come apart in a MANDATED way:

        If the client dies while the session is locked the session remains
        locked, possibly permanently depending on compositor policy.
        If the client dies while the session is locked, the compositor must
        not unlock the session in response.

  So a locker that is SIGKILLed, crashes, or takes a SIGTERM (which it does
  not handle) sends no `unlock_and_destroy`, and the screen stays covered with
  NO process anywhere. The provider's ExecStopPost fires regardless (its own
  header says it "also fires on a CRASH"), so the ladder crosses `unlock` and
  records `open` exactly as it does for a real release.

  THIS IS NOT THE BOUND TAKEN 2026-10-03, which was about a locker vigilance
  cannot SEE. Here there is no locker to see: "no locker of ours is up" is
  true, and the screen is still locked. A reader following that wording goes
  looking for a rival process that does not exist.

  NOTHING CAN CATCH IT TODAY, and the reasons are each independently sound:
  there is no process to find; the transient unit is gone and `--collect`ed;
  systemd recorded no outcome for it (Type=forking with GuessMainPID=no leaves
  MainPID=0, and seven days of journal hold no stop record); `_cross_one` runs
  the act and report tiers only, never verify; and `screen-dark` is
  dark-rung-only on purpose, because a lit-rung emission check would fire on
  every waking moment and be switched off.

  THE DIRECTION IS THE SAFE ONE FOR SECURITY and the unsafe one for use: the
  screen is MORE locked than claimed, so nothing is exposed. Two real costs,
  though. `rescue`, whose entire purpose is "the screen is dark and nothing
  will bring it back", crosses to `open`, finds no locker to clear, and reports
  success: it cannot clear the one state it exists for. And the box recovers
  only BY ACCIDENT, when the idle timer raises a fresh locker at its next
  deadline and the compositor grants it because the dead client's lock object
  went with it.

  Whether `rescue` should raise a locker to clear it is a DECISION and is not
  improvised here; raising one is the protocol's own recovery and is the
  opposite of a bypass, since the user then authenticates normally.

- **An idle source whose counter is reset by READING it goes undetected, and
  reads as a false green.** MEASURED on the VM guest's X server, whose display
  has no input devices:

        spaced: 3008 2975 2980     reads three seconds apart
        rapid:  1 0 0 1            reads back to back

  It reports the interval since the previous READER rather than since input. A
  supervision pass reads three times (judge, settle, and the one that decides),
  so the deciding read can never see more than the gap since the second, and an
  idle-anchored deadline is permanently not due: the overdue detector and the
  inhibit escalation both go silently inert. Worse, `x11-idle` reports the
  server's 600s screensaver timeout as its `ceiling=`, so `report` calls a 480s
  deadline MEASURABLE while the readable value is always about zero. That is
  this project's signature false green, arriving through a door the ceiling
  machinery does not watch.

  LATENT on this fleet (both boxes are Wayland and use input-counters) and real
  for any X11 integrator who wires the source.

  A TWO-READ DISCRIMINATOR WAS TRIED AND REVERTED. Two immediate reads tell a
  stable counter from a read-reset one only when the FIRST read is large, and
  inside a supervision pass it never is: the previous read of the same pass
  just reset it. So it fired for hand-runs and not for the case that matters.

  BUILT 2026-10-15, and the CEILING half is closed: `x11-idle` reports what it
  has been SEEN to reach, with the age over which it watched, exactly as
  input-counters does, and reads no `xset` at all. Measured end to end against
  the real report: a counter capped at 5s now reads "longest quiet seen is 5s
  ... NOT YET SHOWN" where it used to read "measurable (clock has observed 600s
  quiet)", and the message becomes true the moment the counter genuinely
  reaches 600.

  TWO DEFECTS WERE VISIBLE WITHOUT THE DISPUTED MECHANISM AT ALL, which is why
  this could be fixed while the mechanism stays open. `ceiling=600` came out of
  `xset q`, and its consumer renders that field as "clock has observed": a
  config value laundered into evidence, in the field invented to prevent
  exactly that. And a timeout BELOW the deadline, which is a hard impossibility
  known at the first call, landed in report's too-young exemption and read "NOT
  YET SHOWN"; the hook's own comment claimed `age=cap` prevented that, and
  asserted the opposite of what the code produced.

  THE GAP QUESTION RESOLVED ONCE THE TWO FIELDS WERE TOLD APART. `age` is how
  long WE watched, which a suspend interrupts, so a gap re-anchors it. The
  ceiling is the SERVER'S own count of time since input, so a large value read
  after a gap really was reported and really does demonstrate the counter's
  reach, and it is KEPT. That is where this differs from input-counters, whose
  ceiling is a wall-time inference between samples and was measured inflated to
  241310s on a counter moving every 25s.

  STILL OPEN, and deliberately not guessed at: WHETHER A READER RESETS THE
  COUNTER. The two measurements on record disagree (this entry's, against the
  306s-then-2s screensaver reset the hook's own header records), and the
  development box cannot settle it because its Xwayland does not advertise
  MIT-SCREEN-SAVER at all, so `xprintidle` there would fail and the hook
  correctly declines. **The fix above does not depend on the answer**, which is
  the property that made it safe to build: whatever caps the counter is what
  shows up in a high-water mark. Settling it needs the guest, or an X11 box.

  ALSO STILL OPEN: a STRUCTURAL cap has no field to carry it, so a deadline
  longer than the screensaver timeout is now learned by watching rather than
  stated at the first call. Slower and true. Giving it its own field is a
  change to the `idle.d` contract and wants its own increment.

- **The greeter's sleep path is observed only in the guest.** session-greeter.t
  drives the real machine hook set at the `lock` rung against a real sway and
  reads output dpms back with swaymsg independently of the hook, so the edge is
  known to darken the screen and to be verified rather than merely acted on. It
  has still never run on real hardware, and it says nothing about the greeter's
  UID: a machine-scope hook target must be root-visible or _greetd cannot even
  see it, which is a separate finding with no check of its own.

### A LABEL MUST NOT CHANGE WHAT ANYTHING ELSE READS

Attributing the crossings (invariant 34) meant putting `env VIGILANCE_SOURCE=
<who>` in front of several commands, and two mechanisms were already reading
those same strings for something else. Both broke, and both broke SILENTLY in
the reassuring direction, which is what makes this a rule rather than two
fixes.

`_rep_idle_armed` asserts each command in the running idle daemon's argv is
executable, which is the check written for the 2026-09-12 outage: a swayidle
pinned to a path that had been swept, firing into nothing, with nothing else
able to see it. It took the command's first WORD, which with a prefix is `env`,
and `env` resolves on every box ever built. So the attribution would have
blinded the one check standing between that outage and a repeat of it. The
resolution walks past a leading `env` and its assignments now.

`swayidle-due` reports the deadline the argv DECLARES, and matches the edge as
a word with `=` counting as a boundary, which it must: `idle-lock` and
`suspend-if-battery` are both legitimate places for an edge name to sit. So a
source value that merely SPELLS an edge name is indistinguishable from the
edge. MEASURED with `VIGILANCE_SOURCE=resume` on the 480s lock arm, the hook
answered `480 idle` for edge `resume`: a deadline no integrator declared, on an
edge swayidle arms nothing for, handed straight to the overdue detector. An
environment assignment is not part of the command, so the leading run is
skipped; only the leading run, because a `FOO=bar` after the program is that
program's argument.

THE SHIPPED LABELS WERE CHOSEN AROUND THIS, not merely checked against it. The
idle timer's second threshold is `blank` and not `idle` because `phantom-guard`
gates exactly `idle` and that traversal crosses the lock edge from `open`, so
the obvious name would have newly subjected the blank to a debounce and could
leave the box neither asleep nor locked. Its resume arm is `input` rather than
`resume` for the reason above.

AND THE VOCABULARY LIST IS IN ONE PLACE, because the one it replaced was in two
and both rotted: a prose list in `bin/vigilant` and one in the man page, each
naming `lid`, which nothing has ever emitted (a lid close arrives as a logind
`Session.Lock` and cannot be told apart), while omitting six values the tree
really set. Wrong in both directions at once, for weeks. claims.t derives it
from the tree now and fails either way.

### A verifier reads what the HARDWARE reports, not what was asked for

`screen-dark` read `brightness` until 2026-10-05, and that is the REQUESTED
value: a verifier standing on it says "we asked for 0" rather than "it IS 0".
`actual_brightness` is what the panel reports, and the kernel exposes both
precisely because they can differ (a write can be clamped, ignored, or
overridden by firmware or another driver).

THE TWO TIERS COULD DISAGREE ABOUT ONE PANEL. `_rep_coherence` and the hardware
section already read `actual_brightness`, so the hook's choice meant the runner
and its own verifier could answer the backlight question differently, while the
comment immediately below the read carefully guarded the THRESHOLD against
exactly that kind of drift. The larger disagreement was underneath it.

A/B'd against the old hook with the real tree layout reproduced: asked for 0
with the panel reporting 300 of 400, the old one returned 0 and the new one
returns 1. LATENT rather than live, because the two agree 80/80 on manifold.

THE FALLBACK IS NAMED. `actual_brightness` is standard in the sysfs backlight
ABI and present on every device in this fleet, but a driver omitting it must not
make the branch vanish: it drops to the requested value and SAYS so, because a
silent fallback is how the original choice went unexamined. Held down in
screen-dark.t by a fixture that can express DIVERGENCE, which is the thing the
old cases could not do: they wrote only `brightness`, so every one of them
passed with the defect present.

### Ruled out, with the measurement

Kept because a closed avenue reopens every time somebody re-derives the idea.

An **evdev idle source** cannot exist under the no-daemon rule, and the probe
that seemed to authorise one was answering a different question.
`test/probe/evdev-idle-proof` established, on real hardware, that `open -> wait
-> poll(0) -> close` sees input AND sees the absence of input without reading
an event, and `test/evdev-sample.t` holds that down in the guest. Both are
about a WINDOW.

A clock needs more than that. A hook observes only while it runs, about 8s of
every 60 under its bound, and **sampled observation cannot prove absence
between samples**, so it would report idle time it never watched. That is the
one unsafe direction for a clock gating an alert: it manufactures a finding
rather than suppressing one. Continuous coverage means a persistent process
next to the security path, which is what this package exists to avoid. A
COUNTER is sampling-safe for the opposite reason: it accumulates between
samples, so any interval sees everything that happened in it.

So the remedy for a contaminated counter is not a second clock. It is to NAME
the device that chatters, which the counters can already do and which needs no
privilege, no evdev and nothing to opt into. What remains outside vigilance is
the device's own firmware.

**THE PASS'S OWN BLIND WINDOW IS THE SAME DECISION, not a shortfall.** The
supervision pass reads the clock before any hook runs and tells its sources to
re-baseline afterwards, so traffic our own hooks generate on an input device is
not counted as seat input, which it was, once a minute, for ever. What stays
unattributed is the pass itself, about three seconds in sixty. Stated with the
arithmetic rather than waved at: falsely reaching a 480s deadline needs EIGHT
consecutive keystrokes each landing in that 5% window, about 4e-11, against the
alternative of counting our own traffic, which was not a risk but a certainty.
Closing it would take continuous observation, i.e. the daemon ruled out above,
and production must not carry one for this. A continuous observer would only
ever be a SCENARIO instrument, so if it is ever built it belongs in the guest
and never in the shipped set.

**HIDING A CURSOR IS NOT A HOOK'S TO DO, and that is structural rather than a
gap in tooling.** OPEN ITEM, 2026-10-01: on a panel with no real power-saving
option the black-painted lock surface is the only darkening mechanism, and a
white pointer on it is a static bright region on an OLED, which is the burn-in
that mechanism exists to prevent. Observed on manifestor's glass: the cursor IS
hidden when the locker takes over, and a notification brings it back.

The obvious remedy, a hook that enumerates ways to hide it, has nothing to
enumerate. Every pointer protocol this compositor advertises is for a client to
set ITS OWN cursor (`wp_cursor_shape_manager_v1`, `zwp_pointer_constraints_v1`)
or to synthesise input (`zwlr_virtual_pointer_manager_v1`); none lets one client
hide another's. So the only actors are the locker and the compositor, and
swaylock is already one of them: `wl_pointer_set_cursor` appears in its binary,
which is why it was hidden in the first place. X11 is why the idea feels like it
should exist, since `unclutter` and `xbanish` are real there.

THE ONE TECHNICALLY AVAILABLE TRICK IS ACTIVELY HARMFUL. Warping the pointer
with the virtual-pointer protocol is INPUT, so it would reset the idle clock,
which is the mechanism that darkens the box in the first place. It would fight
the ladder to hide a cursor.

**DETECTION IS DONE AND NEEDS NO NEW POLLING**, which is the part worth knowing
before anyone proposes a timer for it. `grim -c` composites the live cursor
(measured: 1747 differing pixels against a plain capture) and the peak statistic
reads it, and `screen-dark` carries no `hook_throttle`, so it already runs on
every supervision pass where six peripheral hooks defer for an hour.

WHAT IS STILL UNKNOWN is the one fact that decides whether a fix can exist. If
the notification causes a pointer leave/enter cycle then swaylock can re-hide on
enter, and patching it is a mechanism this fleet already has. If instead the
compositor draws a default cursor because focus moved to a surface that sets
none, swaylock cannot reach it and it is Wayfire's. The guest can settle that
without touching anyone's glass: lock, measure with and without `-c`, map a
surface, measure again.

AND DETECTION ALONE IS NOT A STABLE END STATE. If the cursor is visible for most
of a dark rung on such a box, this becomes a permanently-on warning, which is
the cry-wolf shape banned throughout this file and the documented reason a live
box once had its enforce timer stopped by hand. So the mechanism has to be
established rather than lived with.

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

`systemd-run` returning success means the thing is running
: FALSE under `Type=simple`, which returns the instant the unit is started.
  Measured in the guest: `go lock` returned 0 with no locker anywhere, because
  the locker refused on startup and exited in milliseconds. `Type=forking` is
  the only one that establishes anything, because it blocks until the fork, and
  it is the one setting a foreground locker cannot use. So the provider confirms
  survival, and only for the non-forking case, because waiting on every lock
  would put seconds on the shipped path to catch a hypothetical.

a locker is any program that covers the screen
: NOT ENOUGH HERE, and this is a limit of the provider rather than of lockers.
  The design is that the UNIT IS THE SPAN of the lock and `ExecStopPost` is how
  an unlock is detected, so the locker must hold the lock for its own LIFETIME.
  A locker that asks a running daemon to lock and then exits (the
  `xfce4-screensaver-command --lock` shape, which is what an integrator on a
  desktop environment reaches for first) leaves the screen covered and its unit
  dead, so the ladder records `open` while the display is locked: the record
  BEHIND the world, which every tier that trusts the record then agrees with.
  Such a locker is refused rather than accepted, because a loud wrong is better
  than a silent one, and the message names the requirement instead of guessing
  at the screen's state. The provider CANNOT tell that case from a locker that
  failed on startup, and says so rather than picking one.

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

### "Is the session locked" has no universal probe, so the claim is bounded

Vigilance verifies ITS OWN locker and nothing wider. Both probes that answer the
question recognise exactly two things, the transient unit the provider started
and ONE process name from `VIGILANCE_LOCKER`, so a locker vigilance neither
started nor was told about is invisible to `locker-up` and to report's
`coherence` section.

MEASURED rather than reasoned, 2026-10-03, against real components: a real
i3lock holding the screen with the depth record at `open` left `verify unlock`
reporting `ok (1 checked)` and coherence reporting `[OK]`. Held down by
`test/fault-rival-locker.t`, which is also where the measurement lives.

THE CLAIM IS NOW BOUNDED TO THE EVIDENCE: coherence says it found no locker of
OURS and names what it cannot see, rather than certifying the session. That is
the same correction the dark-hardware branch of the same section took, and the
reason is identical: a pass must mean "I looked and it is fine", never "I could
not look".

THE TWO OBVIOUS WIDENINGS REMAIN WRONG. Enumerating every locker is not a
capability anyone has. Returning `HOOK_NA` at `unlock` would make the edge read
NOTHING CHECKED on every box, which is noise that retires the tier and loses the
missed-unlock case the hook exists for.

### RETRACTED 2026-10-04: the `LockedHint` plan rested on a false premise

This file said the candidate was logind's `LockedHint`, "which a well-behaved
rival sets and which would genuinely catch the light-locker and GNOME class",
pending a stale-hint exclusion. **The premise does not hold.** Measured against
the real package payloads, with `apt-get download` plus `dpkg-deb -x` so nothing
had to be installed to find out:

    light-locker        Lock, Unlock, SetIdleHint      NO SetLockedHint
    xfce4-screensaver   Lock, Unlock, Inhibit          NO SetLockedHint
    xscreensaver        (no login1 session members)    NO SetLockedHint

None of the three canonical rivals sets the hint. They CONSUME `Lock`/`Unlock`,
which is what makes them the thing that locks when logind says lock. So that
route would have accepted a real stale-value false-alarm risk in exchange for
almost no yield, against exactly the population it was chosen for.

It is recorded rather than quietly replaced because the note asserted the
premise as fact for a day, and because this is the failure mode the file already
names twice: reasoning about a mechanism and then writing the check from the
reasoning. The measurement was cheap and it reversed the design.

### What replaced it: a LIVE query, on the interface they do implement

The same strings show light-locker and xfce4-screensaver both implementing
`GetActive`/`SetActive`/`ActiveChanged`, so `report` now asks
`org.freedesktop.ScreenSaver` at rung `open`, in `_screensaver_active`. Three
properties, each measured rather than argued:

- **No stale case at all**, which is what made the exclusion the hint needed
  unnecessary instead of merely cheaper. A live query asks whoever owns the name
  at that instant, so a rival that died leaves nothing behind to misread.
- **ACQUIRED, never merely activatable.** On a live box `org.gnome.ScreenSaver`
  is listed activatable and unowned, so calling the name blind has D-Bus START a
  screensaver daemon. Vigilance must not spawn a rival locker in the act of
  asking whether one exists. This is a safety rule, not an optimisation.
- **Nothing owning the name reports "cannot tell", never "no".** The failure
  direction is an absent claim, which is the same contract exit 78 carries.

WARN AND NOT FAIL, deliberately. A desktop that owns its own locking raises its
screensaver with this ladder correctly at `open`, so a FAIL there would set
`RRC=1` permanently on every such box, and a report that is always non-zero is
one nobody reads. The disagreement is real and the remedy is the integrator's:
route that locker through `go lock atleast`, or expect the line.

STILL NOT SEEN: a locker that answers nothing at all. i3lock is exactly that,
which is why `test/fault-rival-locker.t` keeps its bounded assertions and the
third outcome above is the one its rival produces.

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
through a real ladder cycle. It uses the guest's real paths on purpose: the
real log, the real hook tree, the real units, because sandboxing them would
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
   uses optimistic concurrency instead: measure, then check whether the state
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
5. **The mutation corpus cannot reach a VM-only guard.** `test/mutate` runs on
   the host, and a record whose named test SKIPS there is refused rather than
   scored, which is correct. But it means every guard covered only by a session
   or fault scenario is outside the corpus: "N records all killed" is a claim
   about the stub tier, not about the suite. RE-MEASURED at 142 records: they
   name 36 distinct tests and exactly one of those gates on a capability
   (`actuators`, on `unprivileged`), which the HOST has and the root guest does
   not, so nothing the corpus names is VM-only and the claim still holds. Such
   guards have to be proven to bite by hand, by running the scenario against the
   unfixed code once, and saying so: invariant 30 and the sway-dpms drift path
   were both closed that way.
6. **The idle clock cannot see every inhibitor its idle timer honours.** This
   is the premise behind invariant 35's act, and it is why that act ships off.
   An idle deadline has two halves from two places: the DEADLINE is the idle
   timer's and the IDLENESS is `idle.d`'s. There are at least three channels
   through which something can hold a timer off, and the shipped source sees
   none of them:

       logind Inhibit what=idle          vigilant reads it (_idle_inhibited)
       org.freedesktop.ScreenSaver       vigilant can query an owner of it
       zwp_idle_inhibit_manager_v1       NOTHING here can see it

   The third is the Wayland protocol a browser takes during a video call, and
   it is the one the compositor honours, which is also why it cannot be
   queried: it is a client-side protocol with no introspection and no "is one
   held" request. `10-input-counters` reads kernel input counters, which see no
   inhibitor of ANY kind, so on a Wayland box the clock and the timer routinely
   disagree about whether the seat is idle, and the clock is the one that is
   wrong. Measured live 2026-10-14: 1166s of counted idle against a timer that
   had not seen one second of it.

   The direction is safe for REPORTING (a false overdue costs a reader a few
   seconds, and the message names both causes) and unsafe for ACTING, which is
   why the two are configured separately.

   DETECTED NOW, AND STILL NOT SEEN, which is the distinction worth keeping.
   `concur.d` (invariant 36) asks whether the deadline's owner agrees the seat
   was quiet, so the DISAGREEMENT is observable even though the inhibitor
   itself never will be: the Wayland protocol has no introspection and no "is
   one held" request, so there is nothing to query, ever. What vigilance can
   say is "something is holding this timer off, or it has wedged, and these are
   indistinguishable from outside", which is enough to bound it.

   AND THE FIRST FIX WAS WRONG, recorded because it is the obvious one and
   somebody will re-derive it. This paragraph used to propose an `idle.d`
   source relaying the TIMER'S OWN view, on the grounds that its heartbeat is a
   durable record and therefore sampling-safe, with minimum-wins doing the
   rest. It would have worked on the false positive and opened a worse hole:
   the aggregate would read ~0 during a call, the deadline would never come
   due, and a LEAKED compositor inhibitor would then hold the session open
   indefinitely with nothing saying so. A false positive traded for a silent
   false green. The question is also different in kind, which is the deeper
   reason: `idle.d` MEASURES THE SEAT and `concur.d` OBSERVES A MECHANISM, and
   putting the second into the first is what made the aggregator the wrong
   place.

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
