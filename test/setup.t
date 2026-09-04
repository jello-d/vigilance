#!/bin/sh
# setup.t - setup.sh install -> assert bin + man links (and NOT the --user unit,
# which is the separate `service` verb) -> check -> uninstall -> assert gone. A
# scratch HOME; nothing outside it is touched. `service` is not exercised: its
# `systemctl --user enable` would reach the real session manager.
. "$(dirname "$0")/lib.sh"
harness_init setup

BIN=$T/bin; SHR=$T/share; CFG=$T/config
run() {
  env PREFIX="$T" XDG_BIN_HOME="$BIN" XDG_DATA_HOME="$SHR" \
    XDG_CONFIG_HOME="$CFG" NO_COLOR=1 sh "$HERE/setup.sh" "$@"
}

# install: every bin/ tool + the man page linked; the --user unit is NOT (that
# is `service`, kept out so a host wiring systemd itself gets no duplicate).
run install >/dev/null 2>&1 || fail "install errored"
for _t in "$HERE"/bin/*; do _n=$(basename "$_t")
  [ "$(readlink "$BIN/$_n")" = "$_t" ] || fail "$_n not symlinked"; done
[ -e "$SHR/man/man1/vigilance.1" ] || fail "man page not linked"
[ -e "$CFG/systemd/user/vigilance-logind.service" ] \
  && fail "install linked the --user unit (should be service-only)"

# libexec: the shipped hooks are installed AVAILABLE...
[ "$(readlink "$T/libexec/vigilance")" = "$HERE/libexec/vigilance" ] \
  || fail "libexec hooks not linked"
[ -x "$T/libexec/vigilance/providers/swaylock" ] \
  || fail "a shipped provider is not reachable through the install"
# ...and never WIRED. A hook that shipped pre-enabled would be vigilance
# deciding policy, which is exactly what mute-on-lock was moved out to avoid.
for _e in lock sleep suspend unlock wake resume; do
  [ -e "$CFG/vigilance/hooks/$_e.d" ] \
    && fail "install wired $_e.d; which hooks run is the integrator's call"
done

# check runs (tools are on the sandbox PATH via BIN)
PATH="$BIN:$PATH" run check >/dev/null 2>&1 || fail "check failed post-install"

# uninstall: the bin + man symlinks are removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
for _t in "$HERE"/bin/*; do _n=$(basename "$_t")
  [ -e "$BIN/$_n" ] && fail "$_n symlink not removed"; done
[ -e "$SHR/man/man1/vigilance.1" ] && fail "man page not removed"
[ -e "$T/libexec/vigilance" ] && fail "libexec hooks link not removed"

pass "install + check + uninstall"
