#!/bin/sh
# test/service.t - the `service` verb, which places six units and was untested.
#
# setup.t deliberately covers install -> check -> uninstall and stops there,
# because `service` touches systemd. So the verb that places EVERY unit in the
# package -- the Session.Lock listener, the supervision timer, the forensic
# timer, the idle supervisor -- had no coverage at all.
#
# systemctl is STUBBED, and the distinction from the suite's no-stubbing rule
# matters. That rule exists because a stubbed systemctl LIES about system state
# and a lying stub is how a green test coexists with a broken box. Here nothing
# asks about system state: the stub RECORDS what the verb tried to enable,
# which is the only way to assert "this one must NOT be enabled", and it keeps
# the test from enabling real units in the developer's own session.
#
# WHAT THIS CAUGHT. `do_service` ran `systemctl --user enable ... || true` and
# then printed "rendered + enabled" unconditionally. On any box without a user
# systemd instance -- a provisioner, a container, an ssh session before the user
# bus exists -- it claimed to have armed the listener that crosses the `lock`
# edge on logind's signal, while arming nothing. Believing that listener is up
# when it is not is exactly the gap that leaves a machine unlocked.
set -eu
. "$(dirname "$0")/lib.sh"
harness_init service

PREFIX=$T/prefix
XDG_CONFIG_HOME=$T/cfg
export PREFIX XDG_CONFIG_HOME
USR=$XDG_CONFIG_HOME/systemd/user
mkdir -p "$T/bin"

_stub_systemctl() {   # <exit-code>
  cat > "$T/bin/systemctl" <<EOF
#!/bin/sh
if [ "\$2" = enable ]; then printf '%s\n' "\$3" >> "$T/enabled"; fi
exit $1
EOF
  chmod +x "$T/bin/systemctl"
}
_run() { PATH="$T/bin:$PATH" sh "$HERE/setup.sh" "$@" 2>&1; }

: > "$T/enabled"
_stub_systemctl 0
_out=$(_run service)

# --- every unit is PLACED ---------------------------------------------------
for _u in vigilance-logind.service vigilance-enforce.service \
          vigilance-enforce.timer vigilance-audit.service \
          vigilance-audit.timer vigilance-idle.service; do
  [ -f "$USR/$_u" ] || fail "'service' did not place $_u. A unit that is not
there cannot be enabled, started or noticed as missing"
done

# --- and RENDERED, with no placeholder left behind --------------------------
# The units carry @VIGILANT@ and @PLUGINS@ so they name no home. A unit deployed
# with a literal @NAME@ as its ExecStart cannot exec, which is the 203/EXEC that
# made the suspend-lock guarantee fiction once already.
for _u in "$USR"/*; do
  _left=$(grep -oE '@[A-Z_]+@' "$_u" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -z "$_left" ] || fail "$(basename "$_u") kept unrendered placeholders:
$_left"
done
grep -q "ExecStart=$PREFIX/bin/vigilant " "$USR/vigilance-enforce.service" \
  || fail "@VIGILANT@ did not render to the prefix this install actually used"
grep -q "ExecStart=$PREFIX/libexec/vigilance/triggers/logind-lock" \
  "$USR/vigilance-logind.service" \
  || fail "@PLUGINS@ did not render to this install's plugin tree"

# --- a RENDERED unit is a real file, not a symlink --------------------------
# It cannot be a link: a link cannot be substituted. This is the property that
# made the placeholders possible at all, so it is asserted rather than assumed.
[ ! -L "$USR/vigilance-logind.service" ] \
  || fail "the unit is a SYMLINK; a symlinked unit cannot carry a substituted
placeholder, so it would deploy with a literal @VIGILANT@"

# --- the idle unit is PLACED but deliberately NOT enabled -------------------
# Only the COMPOSITOR knows when WAYLAND_DISPLAY has been imported and a display
# exists to connect to. Enabling it against a target starts swayidle into a void
# and it spins against the restart limit.
grep -qx vigilance-idle.service "$T/enabled" \
  && fail "'service' ENABLED vigilance-idle.service. Only the compositor can
know when a display exists; enabled against a target it starts swayidle into a
void" || :
for _e in vigilance-logind.service vigilance-enforce.timer \
          vigilance-audit.timer; do
  grep -qx "$_e" "$T/enabled" || fail "'service' did not enable $_e"
done

# --- the success message is only claimed when it is TRUE --------------------
case "$_out" in
  *"rendered + enabled the --user Session.Lock listener"*) ;;
  *) printf '%s\n' "$_out" >&2; fail "no success message on a clean enable" ;;
esac

# --- AND THE BUG: a FAILED enable must not be reported as enabled -----------
rm -rf "$XDG_CONFIG_HOME"; : > "$T/enabled"
_stub_systemctl 1
_out=$(_run service)
case "$_out" in
  *"rendered + enabled"*)
    printf '%s\n' "$_out" >&2
    fail "'service' claimed it ENABLED the units while every systemctl call
failed. On a box with no user systemd this says the Session.Lock listener is
armed when nothing is armed, and that listener is what locks the screen" ;;
esac
case "$_out" in
  *"could NOT enable"*) ;;
  *) printf '%s\n' "$_out" >&2
     fail "'service' swallowed the enable failure without saying so" ;;
esac
# ...and it still PLACED them, because that part is correct with no user bus.
[ -f "$USR/vigilance-logind.service" ] \
  || fail "a failed enable also skipped placing the unit; placing is correct
even where enabling is impossible"

# --- uninstall removes what service placed ---------------------------------
# Rendered units are plain files, so readlink cannot identify them as ours; they
# are removed by name. That is only safe if the names come from this clone.
_stub_systemctl 0
_run uninstall >/dev/null
for _u in vigilance-logind.service vigilance-enforce.timer \
          vigilance-idle.service; do
  [ ! -e "$USR/$_u" ] || fail "uninstall left $_u behind; a stale unit keeps
running against a package that is gone"
done

pass
