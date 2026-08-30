#!/bin/sh
# test/install.t - install into a sandbox HOME, assert the symlinks land, that
# `check` is self-consistent, then uninstall and assert they are gone. Nothing
# outside the scratch dir is touched.
. "$(dirname "$0")/lib.sh"
harness_init install

BIN=$T/bin
CFG=$T/config
run() {
  env HOME="$T" XDG_BIN_HOME="$BIN" XDG_CONFIG_HOME="$CFG" NO_COLOR=1 \
    "$HERE/install" "$@"
}

# --- install: every bin/ tool + the --user unit symlinked into the sandbox ----
run install >/dev/null 2>&1 || fail "install errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ "$(readlink "$BIN/$_n")" = "$_t" ] || fail "$_n not symlinked"
done
[ "$(readlink "$CFG/systemd/user/smart-trigger.service")" \
  = "$HERE/systemd/smart-trigger.service" ] || fail "--user unit not linked"

# --- check runs (tools are on the sandbox PATH via BIN) -----------------------
PATH="$BIN:$PATH" run check >/dev/null 2>&1 || fail "check failed post-install"

# --- uninstall: the symlinks are removed -------------------------------------
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
for _t in "$HERE"/bin/*; do
  _n=$(basename "$_t")
  [ -e "$BIN/$_n" ] && fail "$_n symlink not removed"
done
[ -e "$CFG/systemd/user/smart-trigger.service" ] && fail "unit not removed"

pass "install + check + uninstall"
