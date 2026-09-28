# test/probe - experiments a machine has to answer, not a test suite

Nothing here runs under `test/run` or `test/vm/run`, and that is deliberate: a
probe needs real hardware, root, or a human's absence, so it cannot be a
scenario. `test/run` globs `test/*.t`, so a subdirectory is invisible to it.

**They live in the repo because /tmp lost the last two.** Every earlier probe in
this project was written to `/tmp/bin-<name>` and a reboot took it: the parked
lid scenario went that way once, and its replacement had to be written from
scratch. A probe that took two hours of somebody's cooperation to run is worth
versioning, and the reasoning in its header is worth more than the script.

## What is here

- **`evdev-idle-proof`** asks whether evdev can tell "input happened" from
  "nothing happened" without reading an event. It needs root and your absence,
  not your hands: every phase actuates itself with uinput.
- **`evdev-sample`** is the sampler it drives: `open -> wait -> poll(0) ->
  close` per device, never reading. Standalone, and `--self-test`able with no
  root and no device.

## Writing another one

The rules are the ones the rest of this suite already pays for, and every one of
them was learned by getting it wrong here:

- **Use `~/lib/handoff.sh`.** It logs to a known `/tmp` path so the agent reads
  the result directly instead of asking anyone to paste output back, and it
  authenticates sudo once with a visible result.
- **Install the script at a path that is not `$HANDOFF_BASE/$NAME`.** A probe
  once landed on the very directory its own log wanted, so the run produced no
  log at all.
- **Assert the precondition, not just the outcome.** A fault or a stimulus that
  did not take makes everything after it pass for the wrong reason. If the
  precondition cannot be measured, say which claim rests on it rather than
  quietly presenting an assumption as a result.
- **Give the margin.** One probe here used a 5s threshold with a 4s wait, so
  "it did not fire" was consistent with every conclusion.
- **Dry-run against a stub before asking a human for their time**, and do not
  let the stub model something impossible. `--self-test` covers the poll
  mechanics and says out loud what it cannot cover.
- **Restore before you summarise.** A summary that states a state the script is
  about to change is worse than none.
- **Fail loudly when the thing under test did not run.** A harness that narrates
  an error and then reports a pass is the exact class this project exists to
  catch.
