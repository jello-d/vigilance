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
#   ./setup.sh check       tools, deps, plugins, units, man pages and device
#                          access; emits [OK]/[FAIL]/[WARN] markers
#   ./setup.sh test        run the in-repo test suite (test/run)
#   ./setup.sh version     the packaged version
#
# INSTALL MODE. By default `install` SYMLINKS into the clone, so an edit to the
# checkout is live. Set VIGILANCE_INSTALL_COPY=1 to COPY instead, which is what
# a shared/system prefix needs: the clone lives under a user's home (0750, and
# ~/.cache is 0700), so symlinks from /usr/local into it are unreadable by any
# other user -- a greeter following one gets nothing. More generally a system
# binary must not depend on a user's home being present, mounted or unlocked.
#
# A copy can drift from the clone, so a copying install RE-COPIES every run.
# It is idempotent and cheap; staleness is the failure mode to avoid, not
# wasted bytes.
#
# POSIX sh, non-privileged. `install` is bin + man ONLY (the contract a
# provisioner delegates to); the --user listener is a separate `service` verb,
# so a host that wires systemd itself gets no duplicate unit.
# The SYSTEM units (systemd/lock-on-sleep.service, vigilance-resume.service)
# need root; place them under /etc/systemd/system yourself (or let a host do
# it). They are @USER@/@UID@/@HOME@-templated -- and @HOME@ is NOT %h: in a
# SYSTEM unit %h resolves to ROOT's home regardless of User=, which is exactly
# how the suspend lock 203/EXEC'd on every sleep for a whole refactor.
#
# udev/99-vigilance.rules is the same shape: root-only, so a host places it,
# and it grants the `vigilant` group write on exactly the nodes the peripheral
# hooks drive. WITHOUT IT those hooks silently no-op, because brightnessctl is
# denied and hook_dark/hook_lit swallow the failure by design. The group must
# exist and the users that run vigilance must be in it -- including the greeter
# user, if greeter coverage is on. Deliberately NOT `input`: that group also
# grants raw read on /dev/input/event*, i.e. every keystroke.
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
# External runtime deps. brightnessctl was MISSING from this list while three
# shipped hooks (kbd-backlight, panel-backlight, mute-leds) called it by name,
# so the one dependency whose absence is SILENT -- hook_dark/hook_lit swallow
# its failure by design -- was the one `check` did not look for.
DEPS="swaylock swayidle wlopm ddcutil brightnessctl"

# NAME THE CONSUMER, not just the package. "dep ddcutil absent" says nothing
# about what stops working; the marker contract is meant to be actionable, and
# one shared message ("powers spanning/DDC") was wrong for most of them.
_dep_why() {   # dep -> what stops working without it
  case "$1" in
    swaylock)      echo "the swaylock lock provider" ;;
    swayidle)      echo "the idle timer (nothing will lock on idle)" ;;
    wlopm)         echo "the dpms hook (wlroots output power)" ;;
    ddcutil)       echo "the ddc-monitor hook (external-monitor standby)" ;;
    brightnessctl) echo "the backlight + keyboard/mute LED hooks" ;;
    *)             echo "a plugin" ;;
  esac
}
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

# _place <src> <dst>: symlink, or copy when VIGILANCE_INSTALL_COPY=1.
# --remove-destination on the copy so replacing a RUNNING binary cannot fail
# with ETXTBSY: the old inode is unlinked and any live process keeps it.
#
# THE CHOWN IS NOT OPTIONAL. `cp -a` implies --preserve=all, which carries the
# SOURCE's ownership across even when the copy runs as root. The clone this
# installs from lives in a user's home, so a root install of copy mode produced
# /usr/local/bin/vigilant owned by the LOGIN USER: a binary the greeter session
# executes that the unprivileged account can rewrite at will. Found on a real
# box, where /usr/local/bin itself had also drifted to user ownership.
#
# So when root is installing, root owns the result. Root is the only identity
# that could be placing files in a system prefix, and preserving a user's
# ownership there is never what was meant.
_place() {
  if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
    cp -a --remove-destination "$1" "$2"
    if [ "$(id -u)" = 0 ]; then chown -R root:root "$2"; fi
  else
    ln -sfn "$1" "$2"
  fi
}

# Tools that belong at a SHARED/SYSTEM prefix, and why the rest do not.
#
# Greeter coverage installs this package to /usr/local so _greetd can reach it.
# Only the EDGE RUNNER belongs there: the greeter's launcher runs `swayidle`
# DIRECTLY and never calls swayidle-mgr, and idle-capture/lock-watch are
# diagnostics a human runs inside a session.
#
# Installing the rest is not untidy, it is ACTIVELY HARMFUL. /usr/local/bin
# precedes ~/.local/bin on a default PATH, so a copy there SHADOWS the live pkg
# symlink and then rots behind it. Observed on a real box: a system swayidle-mgr
# dated a day earlier was winning `command -v`, so an idle-suspend seam added to
# the package that morning was inert -- the tool that ran had never heard of it.
#
# Keyed on COPY MODE, which is already defined as "what a shared/system prefix
# needs" (see the header). A symlinking install to a user prefix is unaffected.
SYSTEM_TOOLS="vigilant"

_wanted_at_prefix() {   # <tool-name>
  [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ] || return 0   # user prefix: all
  for _w in $SYSTEM_TOOLS; do [ "$1" = "$_w" ] && return 0; done
  return 1
}

do_install() {
  mkdir -p "$_bin"
  for _t in "$_root"/bin/*; do
    _n=$(basename "$_t")
    if _wanted_at_prefix "$_n"; then
      _place "$_t" "$_bin/$_n"
    else
      # SWEEP what an earlier over-install left. Leaving it would keep
      # shadowing the live copy, and a stale shadow is worse than a missing
      # tool: the missing one fails loudly, the shadow does the old thing.
      if [ -e "$_bin/$_n" ] || [ -L "$_bin/$_n" ]; then
        rm -f "$_bin/$_n"
        echo "$PKG: removed $_bin/$_n (session tool; it shadowed the live copy)"
      fi
    fi
  done
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"; _place "$_m" "$_d/$(basename "$_m")"; done
  # libexec carries the shipped PLUGINS: hooks/ (peripheral actuators, alert
  # sinks, block guards), providers/ (how to bring a locker up) and triggers/
  # (what crosses an edge). All installed AVAILABLE but never WIRED: which
  # plugin runs where is policy, and policy is the integrator's. One that
  # shipped pre-enabled would be vigilance deciding policy, which is the
  # mistake mute-on-lock was moved out to avoid.
  if [ -d "$_root/libexec/$PKG" ]; then
    mkdir -p "$_lib"
    if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
      # rm first: cp -a of a directory ONTO an existing one nests it rather
      # than replacing it, which would leave a stale tree one level down.
      rm -rf "$_lib/$PKG"
      cp -a "$_root/libexec/$PKG" "$_lib/$PKG"
    else
      ln -sfn "$_root/libexec/$PKG" "$_lib/$PKG"
    fi
  fi
  if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
    echo "$PKG: COPIED the tools (+ man, hooks) into $PREFIX"
  else
    echo "$PKG: linked the tools (+ man, hooks) into $PREFIX"
  fi
}

do_service() {
  mkdir -p "$_usr"
  ln -sfn "$_unit" "$_usr/vigilance-logind.service"
  systemctl --user enable vigilance-logind.service 2>/dev/null || true
  echo "$PKG: linked + enabled the --user Session.Lock listener"
  # The SUPERVISION timer, and the loop it drives. Shipped and enabled here
  # rather than left to an integrator, because a supervision loop nothing runs
  # is exactly the dead tier this project keeps finding: `due.d` was designed,
  # enumerated, and read by nothing for the whole refactor. Report-only by
  # default, so enabling it cannot cross an edge on its own.
  for _eu in vigilance-enforce.service vigilance-enforce.timer \
             vigilance-audit.service vigilance-audit.timer \
             vigilance-idle.service; do
    ln -sfn "$_root/systemd/$_eu" "$_usr/$_eu"
  done
  systemctl --user enable vigilance-enforce.timer 2>/dev/null || true
  systemctl --user enable vigilance-audit.timer 2>/dev/null || true
  # vigilance-idle.service is PLACED but never enabled: the COMPOSITOR starts
  # it, because only the compositor knows when WAYLAND_DISPLAY has been imported
  # and a display exists to connect to. Enabling it against a target would start
  # swayidle into a void.
  echo "$PKG: linked + enabled the supervision + audit timers"
  echo "$PKG: placed vigilance-idle.service (the compositor starts it:"
  echo "  systemctl --user start vigilance-idle.service from its autostart)"
  echo "  (supervision is report-only;"
  echo "  VIGILANCE_ENFORCE=force lets it cross an overdue edge)"
  echo "$PKG: the SYSTEM units need root -- place lock-on-sleep.service and"
  echo "  vigilance-resume.service from $_root/systemd under /etc/systemd/"
  echo "  system (both are @USER@/@UID@-templated)."
  echo "  Also root-only: $_root/udev/99-vigilance.rules under /etc/udev/"
  echo "  rules.d, plus a 'vigilant' group holding every user that runs"
  echo "  vigilance. Without it the peripheral hooks silently no-op."
}

# A COPY cannot be identified by readlink, so in copy mode remove by NAME: the
# names come from this clone, so we only ever remove what we would install.
_unplace() {   # <installed-path> <clone-source>
  if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
    rm -f "$1"
  else
    [ "$(readlink "$1" 2>/dev/null)" = "$2" ] && rm -f "$1" || :
  fi
}

do_uninstall() {
  for _t in "$_root"/bin/*; do _place_l=$_bin/$(basename "$_t")
    _unplace "$_place_l" "$_t"; done
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    _unplace "$_l" "$_m"; done
  [ "$(readlink "$_usr/vigilance-logind.service" 2>/dev/null)" = "$_unit" ] \
    && rm -f "$_usr/vigilance-logind.service" || :
  for _eu in vigilance-enforce.service vigilance-enforce.timer \
             vigilance-audit.service vigilance-audit.timer \
             vigilance-idle.service; do
    [ "$(readlink "$_usr/$_eu" 2>/dev/null)" = "$_root/systemd/$_eu" ] \
      && rm -f "$_usr/$_eu" || :
  done
  if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
    rm -rf "$_lib/$PKG"
  else
    [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ] \
      && rm -f "$_lib/$PKG" || :
  fi
  echo "$PKG: removed the ~/.local symlinks (+ the --user listener)"
}

# DEVICE ACCESS, which this file's own header declares as a hard requirement and
# nothing verified -- so the requirement was a comment. On a real box the user
# was in none of input/video/i2c, every brightnessctl write was denied, and
# hook_dark/hook_lit swallow that failure BY DESIGN, so vigilant logged clean
# crossings while the hardware never moved.
#
# Reading files cannot see this. It has to ask the group database about the
# RUNNING user, which is the difference between a documented prerequisite and an
# enforced one.
#
# A MISSING GROUP WARNS, a non-member FAILS. The gradient is deliberate: a host
# with no backlight and no LEDs legitimately needs neither, but a group that
# EXISTS was created by someone who intended it to be used, and a user left out
# of it is a misconfiguration rather than a choice.
_check_access() {
  if getent group vigilant >/dev/null 2>&1; then
    ok "group 'vigilant' exists"
    if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx vigilant; then
      ok "$(id -un) is a member of 'vigilant'"
    else
      bad "$(id -un) is NOT in 'vigilant': peripheral hooks will be denied and"\
" will no-op SILENTLY (log out and back in after being added)"
    fi
  else
    warn "no 'vigilant' group; the peripheral hooks will silently no-op"
  fi
  if [ -e /etc/udev/rules.d/99-vigilance.rules ]; then
    ok "udev rule placed (/etc/udev/rules.d/99-vigilance.rules)"
  else
    warn "udev/99-vigilance.rules not in /etc/udev/rules.d (needs root);"\
" without it the group grants nothing"
  fi
}

# THE UNITS, because a tool on PATH that no unit invokes crosses no edges. Every
# security guarantee in this suite is a unit: the suspend lock, the Session.Lock
# listener, the supervision timers. `check` audited the binaries and the plugins
# and said nothing about the things that actually run them.
#
# Placement only. Whether a unit is ENABLED and whether its ExecStart RUNS are
# `vigilant report`'s questions, asked against live systemd -- deliberately not
# duplicated here.
#
# TWO LEGITIMATE LOCATIONS for a --user unit, mirroring the two hook scopes:
#
#   ~/.config/systemd/user   this user only (what './setup.sh service' places)
#   /etc/systemd/user        EVERY user's --user instance, a greeter included
#
# An integrator covering a greeter MUST use the second, since the greeter runs
# as its own user with its own home. Checking only the first cried wolf at once:
# all four units reported "not placed" on a correctly wired box while systemd
# had them active from /etc/systemd/user. Caught by running the new check.
_check_units() {
  for _u in vigilance-logind.service vigilance-enforce.timer \
            vigilance-audit.timer vigilance-idle.service; do
    if [ -e "$_usr/$_u" ]; then ok "--user unit $_u placed (this user)"
    elif [ -e "/etc/systemd/user/$_u" ]; then
      ok "--user unit $_u placed (/etc/systemd/user; every user)"
    else warn "--user unit $_u not placed (run './setup.sh service')"; fi
  done
  # Root-placed, so their absence is an integrator task rather than our failure.
  for _u in lock-on-sleep.service vigilance-resume.service; do
    if [ -e "/etc/systemd/system/$_u" ]; then ok "SYSTEM unit $_u placed"
    else warn "SYSTEM unit $_u not placed (needs root; $_root/systemd)"; fi
  done
}

do_check() {
  echo "== $PKG (lock / screen-power / idle) =="
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    if command -v "$_n" >/dev/null 2>&1; then ok "$_n present"
    else bad "$_n not on PATH"; fi; done
  for _d in $DEPS; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent: $(_dep_why "$_d") degrades"; done
  for _k in hooks providers triggers; do
    for _h in "$_root"/libexec/"$PKG"/"$_k"/*; do
      [ -x "$_h" ] || continue
      _n=$(basename "$_h")
      if [ -x "$_lib/$PKG/$_k/$_n" ]; then ok "${_k%s} $_n available"
      else bad "${_k%s} $_n not installed ($_lib/$PKG/$_k/$_n)"; fi
    done
  done
  # MAN PAGES, which `install` claims in its own success message ("+ man") and
  # nothing confirmed. Iterated as a glob rather than via _man_pages, because
  # that prints, and a `while read` over a pipe runs in a SUBSHELL where
  # bad() could not raise RC -- a check that cannot fail is not a check.
  for _m in "$_root"/man/man*/*.[0-9]; do
    [ -e "$_m" ] || continue
    _md=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    if [ -e "$_md" ]; then ok "man $(basename "$_m") installed"
    else bad "man $(basename "$_m") not installed ($_md)"; fi
  done
  _check_units
  _check_access
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
