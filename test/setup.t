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
[ -e "$CFG/systemd/user/smart-trigger.service" ] \
  && fail "install linked the --user unit (should be service-only)"
# the mute lock-hooks are wired to the installed mute-on-lock (both entries)
[ "$(readlink "$CFG/lock-hooks/lock.d/10-mute-on-lock")" = "$BIN/mute-on-lock" ] \
  || fail "mute lock-hook not wired"
[ "$(readlink "$CFG/lock-hooks/unlock.d/10-unmute-on-unlock")" \
  = "$BIN/mute-on-lock" ] || fail "unmute lock-hook not wired"

# check runs (tools are on the sandbox PATH via BIN)
PATH="$BIN:$PATH" run check >/dev/null 2>&1 || fail "check failed post-install"

# uninstall: the bin + man symlinks are removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
for _t in "$HERE"/bin/*; do _n=$(basename "$_t")
  [ -e "$BIN/$_n" ] && fail "$_n symlink not removed"; done
[ -e "$SHR/man/man1/vigilance.1" ] && fail "man page not removed"
[ -e "$CFG/lock-hooks/lock.d/10-mute-on-lock" ] && fail "mute lock-hook not removed"

pass "install + check + uninstall"
