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

# --- COPY MODE: what a shared/system prefix needs ---------------------------
# The default install SYMLINKS into the clone. That is unreadable from a system
# prefix, because the clone lives under a home that is 0750 (and ~/.cache 0700),
# so a greeter following /usr/local/bin/vigilant would get nothing. Copy mode
# is what makes a system install real.
CBIN=$T/cbin; CLIB=$T/clib
crun() {
  env PREFIX="$T/copy" XDG_BIN_HOME="$CBIN" XDG_DATA_HOME="$T/cshare" \
    XDG_CONFIG_HOME="$CFG" NO_COLOR=1 VIGILANCE_INSTALL_COPY=1 \
    sh "$HERE/setup.sh" "$@"
}
crun install >/dev/null 2>&1 || fail "copy install errored"

[ -f "$CBIN/vigilant" ] || fail "copy mode did not place vigilant"
[ -L "$CBIN/vigilant" ] \
  && fail "copy mode left a SYMLINK; it must be a real file"
[ -f "$T/copy/libexec/vigilance/hooks/ddc-monitor" ] \
  || fail "copy mode did not copy the plugin tree"
[ -L "$T/copy/libexec/vigilance" ] \
  && fail "copy mode symlinked libexec; a system prefix cannot follow it"
[ -x "$CBIN/vigilant" ] || fail "the copied vigilant is not executable"

# Nothing under the copy may point back into the clone: that is the whole
# point, since the clone sits in an unreadable home.
_leak=$(find "$T/copy" -type l 2>/dev/null | while read -r _l; do
          case "$(readlink -f "$_l" 2>/dev/null)" in
            "$HERE"/*) echo "$_l" ;;
          esac
        done)
[ -z "$_leak" ] || fail "copy install leaks a link back into the clone: $_leak"

# Re-copying is idempotent (apply re-runs every time to avoid staleness), and
# a nested tree would mean cp -a landed a directory INSIDE the old one.
crun install >/dev/null 2>&1 || fail "second copy install errored"
[ -e "$T/copy/libexec/vigilance/vigilance" ] \
  && fail "re-copy nested the plugin tree inside itself"

crun uninstall >/dev/null 2>&1 || fail "copy uninstall errored"
[ -e "$CBIN/vigilant" ] && fail "copy uninstall left vigilant behind"
[ -d "$T/copy/libexec/vigilance" ] && fail "copy uninstall left the tree behind"

pass "install + check + uninstall + copy mode"
