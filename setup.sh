#!/bin/sh
# setup.sh - install / uninstall / check / test the vigilance lock / screen-
# power / idle suite: the standalone Wayland tools in bin/ (smart-lock,
# smart-trigger, swayidle-mgr, panel-power, osd-mgr, idle-capture, lock-watch).
# The SINGLE entry point a consumer or provisioning layer uses. smart-lock runs
# the hooks in ~/.config/lock-hooks/ on lock/unlock; that hook system is the
# extension point, and the specific hooks are the integrator's to drop in.
#
#   ./setup.sh install     symlink the tools (+ man) into ~/.local
#   ./setup.sh service     install + enable the --user Session.Lock listener
#   ./setup.sh all         install + service
#   ./setup.sh uninstall   remove the symlinks (+ the --user listener)
#   ./setup.sh check       every tool + dependency present; [OK]/[FAIL] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# POSIX sh, non-privileged. `install` is bin + man ONLY (the contract a
# provisioner delegates to); the --user listener is a separate `service` verb,
# so a host that wires systemd itself gets no duplicate unit. The
# suspend-lock SYSTEM unit (systemd/lock-on-sleep.service, Before=sleep.target)
# needs root; place it under /etc/systemd/system yourself (or let a host do it).
set -eu

PKG=vigilance
VERSION=0.1.0
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
_usr=$_cfg/systemd/user
_unit=$_root/systemd/smart-trigger.service
DEPS="swaylock swayidle wlopm ddcutil"   # external runtime deps (spanning/DDC)
RC=0

# marker contract: plain [OK]/[FAIL]/[WARN] an integrator styles in its palette;
# self-coloured at a terminal, plain when piped or under NO_COLOR.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _G=$(printf '\033[32m'); _R=$(printf '\033[31m')
  _Y=$(printf '\033[33m'); _O=$(printf '\033[0m')
else _G=; _R=; _Y=; _O=; fi
ok()   { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$1"; }
bad()  { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$1"; RC=1; }
warn() { printf '  %s[WARN]%s %s\n' "$_Y" "$_O" "$1"; }

_man_pages() { for _m in "$_root"/man/man*/*.[0-9]; do
  [ -e "$_m" ] && printf '%s\n' "$_m"; done; }

do_install() {
  mkdir -p "$_bin"
  for _t in "$_root"/bin/*; do ln -sfn "$_t" "$_bin/$(basename "$_t")"; done
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; ln -sfn "$_m" "$_d/$(basename "$_m")"; done
  echo "$PKG: linked the tools (+ man) into $PREFIX"
}

do_service() {
  mkdir -p "$_usr"
  ln -sfn "$_unit" "$_usr/smart-trigger.service"
  systemctl --user enable smart-trigger.service 2>/dev/null || true
  echo "$PKG: linked + enabled the --user Session.Lock listener"
  echo "$PKG: the suspend-lock SYSTEM unit needs root -- place"
  echo "  $_root/systemd/lock-on-sleep.service under /etc/systemd/system."
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _l=$_bin/$(basename "$_t")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_t" ] && rm -f "$_l" || :; done
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_m" ] && rm -f "$_l" || :; done
  [ "$(readlink "$_usr/smart-trigger.service" 2>/dev/null)" = "$_unit" ] \
    && rm -f "$_usr/smart-trigger.service" || :
  echo "$PKG: removed the ~/.local symlinks (+ the --user listener)"
}

do_check() {
  echo "== $PKG (lock / screen-power / idle) =="
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    if command -v "$_n" >/dev/null 2>&1; then ok "$_n present"
    else bad "$_n not on PATH"; fi; done
  for _d in $DEPS; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent ($_d powers spanning/DDC, degrades)"; done
  if [ -d "$_cfg/shapes" ]; then
    ok "shape config present (~/.config/shapes)"
  else warn "no ~/.config/shapes; smart-lock uses a single-output lock"; fi
}

_U="usage: setup.sh [install|service|all|uninstall|check|test|version]"
case "${1:-install}" in
  install)   do_install ;;
  service)   do_service ;;
  all)       do_install; do_service ;;
  uninstall) do_uninstall ;;
  check)     do_check; exit "$RC" ;;
  test)      exec sh "$_root/test/run" ;;
  version)   echo "$PKG $VERSION" ;;
  -h|--help|help) echo "$_U" ;;
  *) echo "setup.sh: unknown command '${1:-}'" >&2; echo "$_U" >&2; exit 2 ;;
esac
