#!/bin/sh
# test/intent.t - the rung-darkness table, and the two copies of it.
#
# The runner exports VIGILANCE_INTENT so no hook has to restate the mapping.
# hooklib keeps a local copy as a standalone fallback, and a fallback that can
# drift silently is worse than no fallback: this pins them equal.
#
# WHY THE EXPORT EXISTS: tackup's kbd-rgb hand-rolled the table, read `resume`
# as "coming back up, so light it", and lit a keyboard over a dark screen -- in
# the same pass as ddc-monitor, which read the real mapping and was powering the
# monitor down. Both hooks reported success. An integrator hook needs the
# identical table, and getting it wrong is invisible.
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/scenario.sh"
scenario_init intent

. "$HERE/libexec/vigilance/hooklib.sh"
eval "$(sed -n '/^_intent_of() {/,/^}/p' "$HERE/bin/vigilant")"

# --- the two copies must AGREE on every edge --------------------------------
# Compared against the RUNNER's, which is authoritative. hook_intent layers the
# act policy on top, so compare with VIGILANCE_KIND=verify, where it passes the
# ladder's answer through unchanged.
for _e in lock unlock sleep wake suspend resume; do
  _runner=$(_intent_of "$_e")
  _hook=$(VIGILANCE_KIND=verify hook_intent "$_e")
  [ "$_runner" = "$_hook" ] || fail "intent($_e): runner says '$_runner', the
hooklib fallback says '$_hook' -- the two copies have drifted"
done

# --- the exported value WINS, so the ladder is stated once -------------------
# If the fallback could override the runner, adding a rung would leave every
# hook silently reading a stale table.
_got=$(VIGILANCE_INTENT=dark VIGILANCE_KIND=verify hook_intent wake)
[ "$_got" = dark ] || fail "hook_intent ignored the exported VIGILANCE_INTENT
(got '$_got'); the runner must be authoritative"

# --- act policy survives: lock/unlock must NOT drive brightness -------------
# The one place the two questions differ. Merging them would restore the bug
# where unlocking re-asserted a level the user had set by hand.
for _e in lock unlock; do
  _a=$(VIGILANCE_KIND=act VIGILANCE_INTENT=lit hook_intent "$_e")
  [ "$_a" = none ] || fail "$_e ACTS on brightness ($_a) even with the intent
exported; the act policy was lost"
done

# --- the runner actually EXPORTS it to a hook -------------------------------
# The table agreeing is worth nothing if the value never reaches a hook.
mkdir -p "$VIGILANCE_HOOK_ROOT/sleep.d" "$VIGILANCE_HOOK_ROOT/wake.d"
for _e in sleep wake; do
  cat > "$VIGILANCE_HOOK_ROOT/$_e.d/10-intent" <<EOF
#!/bin/sh
printf '%s=%s\n' "\$VIGILANCE_EDGE" "\${VIGILANCE_INTENT:-UNSET}" >> "$T/seen"
EOF
  chmod +x "$VIGILANCE_HOOK_ROOT/$_e.d/10-intent"
done
: > "$T/seen"
go sleep
go lock
_seen=$(cat "$T/seen")
case "$_seen" in
  *"sleep=dark"*) ;;
  *) printf 'got: %s\n' "$_seen" >&2
     fail "the runner did not export VIGILANCE_INTENT to a sleep hook" ;;
esac
case "$_seen" in
  *"wake=lit"*) ;;
  *) printf 'got: %s\n' "$_seen" >&2
     fail "the runner did not export VIGILANCE_INTENT=lit on wake" ;;
esac

# --- and a hook gets a PATH that includes the user bindir -------------------
# The system manager's PATH has no ~/.local/bin, so a hook calling a
# user-installed command by NAME found nothing and reported success. That is
# how kbd-rgb no-opped on the suspend path while logging a clean crossing.
mkdir -p "$VIGILANCE_HOOK_ROOT/suspend.d"
cat > "$VIGILANCE_HOOK_ROOT/suspend.d/10-path" <<EOF
#!/bin/sh
printf '%s\n' "\$PATH" > "$T/path"
EOF
chmod +x "$VIGILANCE_HOOK_ROOT/suspend.d/10-path"
go suspend
_p=$(cat "$T/path")
case ":$_p:" in
  *":${XDG_BIN_HOME:-$HOME/.local/bin}:"*) ;;
  *) printf 'got: %s\n' "$_p" >&2
     fail "a hook's PATH does not contain the user bindir" ;;
esac
case ":$_p:" in
  *":/usr/bin:"*) ;;
  *) fail "a hook's PATH lost the system directories" ;;
esac

pass
