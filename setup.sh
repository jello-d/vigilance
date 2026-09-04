#!/bin/sh
# setup.sh - install / uninstall / check / test the vigilance lock / screen-
# power / idle suite: `vigilant` (the edge runner) plus the tools in bin/, and
# the plugins in libexec/vigilance/ (hooks, providers, triggers). The SINGLE
# entry point a consumer or provisioning layer uses.
#
# vigilant runs hooks in ~/.config/vigilance/hooks/<edge>.d on every edge; that
# hook system is the extension point, and WHICH hooks run is the integrator's
# to decide. smart-lock and smart-trigger are gone: systemd owns the lock's
# lifetime now (see docs/framework-refactor.md 10.1).
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
# The SYSTEM units (systemd/lock-on-sleep.service, vigilance-resume.service)
# need root; place them under /etc/systemd/system yourself (or let a host do
# it). They are @USER@/@UID@-templated.
set -eu

PKG=vigilance
VERSION=0.1.0
_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# HOME is not guaranteed in every context this runs from (a provisioner, a
# service, cloud-init's runcmd), and under `set -eu` an unset HOME aborts
# before the first message. Derive it rather than assume it.
if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)
  if [ -z "$HOME" ]; then
    echo "$PKG: HOME unset and not derivable from passwd" >&2; exit 1
  fi
  export HOME
fi

PREFIX=${PREFIX:-$HOME/.local}
_bin=${XDG_BIN_HOME:-$PREFIX/bin}
_lib=$PREFIX/libexec
_shr=${XDG_DATA_HOME:-$PREFIX/share}
_man=$_shr/man
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
_usr=$_cfg/systemd/user
_unit=$_root/systemd/vigilance-logind.service
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
  # libexec carries the shipped PLUGINS: hooks/ (peripheral actuators, alert
  # sinks, block guards), providers/ (how to bring a locker up) and triggers/
  # (what crosses an edge). All installed AVAILABLE but never WIRED: which
  # plugin runs where is policy, and policy is the integrator's. One that
  # shipped pre-enabled would be vigilance deciding policy, which is the
  # mistake mute-on-lock was moved out to avoid.
  if [ -d "$_root/libexec/$PKG" ]; then
    mkdir -p "$_lib"
    ln -sfn "$_root/libexec/$PKG" "$_lib/$PKG"
  fi
  echo "$PKG: linked the tools (+ man, hooks) into $PREFIX"
}

do_service() {
  mkdir -p "$_usr"
  ln -sfn "$_unit" "$_usr/vigilance-logind.service"
  systemctl --user enable vigilance-logind.service 2>/dev/null || true
  echo "$PKG: linked + enabled the --user Session.Lock listener"
  echo "$PKG: the SYSTEM units need root -- place lock-on-sleep.service and"
  echo "  vigilance-resume.service from $_root/systemd under /etc/systemd/"
  echo "  system (both are @USER@/@UID@-templated)."
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _l=$_bin/$(basename "$_t")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_t" ] && rm -f "$_l" || :; done
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    [ "$(readlink "$_l" 2>/dev/null)" = "$_m" ] && rm -f "$_l" || :; done
  [ "$(readlink "$_usr/vigilance-logind.service" 2>/dev/null)" = "$_unit" ] \
    && rm -f "$_usr/vigilance-logind.service" || :
  [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ] \
    && rm -f "$_lib/$PKG" || :
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
  for _k in hooks providers triggers; do
    for _h in "$_root"/libexec/"$PKG"/"$_k"/*; do
      [ -x "$_h" ] || continue
      _n=$(basename "$_h")
      if [ -x "$_lib/$PKG/$_k/$_n" ]; then ok "${_k%s} $_n available"
      else bad "${_k%s} $_n not installed ($_lib/$PKG/$_k/$_n)"; fi
    done
  done
  if [ -d "$_cfg/shapes" ]; then
    ok "shape config present (~/.config/shapes)"
  else warn "no ~/.config/shapes; the lock provider uses a plain lock"; fi
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
