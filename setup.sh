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
# The MACHINE hook root, same default and same override name vigilant uses, so
# the two cannot disagree about where machine-scope wiring lives and a test can
# sandbox both with one variable.
MACHINE_HOOK_ROOT=${VIGILANCE_MACHINE_HOOKS:-/etc/vigilance/hooks}
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

# `if`, not `[ -e ] && printf`. With an EMPTY or absent man dir the glob does
# not match, the test fails on the last iteration, the for loop inherits that
# status, and the FUNCTION returns it. A function call returning non-zero IS
# subject to set -e, so every verb calling this aborted before doing its job.
# Proven, not theorised: dash exits 1 on an empty man dir with the old form.
#
# The AND-list itself is exempt from set -e; what is not exempt is the function
# CALL that inherits its status. That distinction is why this shape is safe in
# mid-function and fatal at the end of one.
_man_pages() {
  for _m in "$_root"/man/man*/*.[0-9]; do
    if [ -e "$_m" ]; then printf '%s\n' "$_m"; fi
  done
}

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
    if [ "$(id -u)" = 0 ]; then
      chown -R root:root "$2"
      # And strip group/other write. `cp -a` preserves the SOURCE's mode too,
      # and a clone made under a user's umask is 0775/0664, so ownership alone
      # left root-group-writable binaries in a system prefix.
      chmod -R go-w "$2"
    fi
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
      # THE SAME `cp -a` TRAP _place DOCUMENTS, and which _place fixed only for
      # the BINARIES. --preserve=all carries the SOURCE's ownership AND mode
      # across even when the copy runs as root, and the clone lives in a user's
      # home with a user's umask. So a root install produced
      # /opt/vigilance/libexec/vigilance owned jello:jello and group-WRITABLE.
      #
      # That is not untidiness once the tree is shared: the machine-scope hook
      # wiring symlinks into it, and a GREETER executes those hooks. A file the
      # unprivileged account can rewrite, executed by another security context,
      # is the thing "Install placement" bans outright -- anything root reads or
      # runs must be root-owned and not user-writable.
      #
      # Found on a real box after the migration: 19 entries under /opt/vigilance
      # were jello:jello, including every hook and hooklib.sh itself.
      if [ "$(id -u)" = 0 ]; then
        chown -R root:root "$_lib/$PKG"
        # Strip group/other write as well. Ownership alone is not enough: a
        # 0775 root-owned dir is still writable by anyone in the root group.
        chmod -R go-w "$_lib/$PKG"
      fi
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

# UNITS ARE RENDERED, NOT SYMLINKED, because they carry placeholders now.
#
# @VIGILANT@ is the published path of the `vigilant` command and @PLUGINS@ the
# installed plugin tree. Neither can be home-relative any more: `vigilant` is
# classified as a SHARED command (one root-owned tree, one link on PATH), and
# a unit that hardcoded ~/.local would break the moment a box installs in shared
# mode -- which is precisely how the idle timer died once already, armed with a
# path that had been swept out from under it.
#
# Substituting at install is what keeps ONE fact in ONE place: the installer
# already knows where it put things, so no unit has to guess and no second copy
# of the prefix exists to drift. A symlinked unit could not be substituted at
# all, which is why this stopped being a symlink.
_render_unit() {   # <src> <dst>
  sed -e "s|@VIGILANT@|$_bin/vigilant|g" \
      -e "s|@PLUGINS@|$_lib/$PKG|g" "$1" > "$2.tmp" \
    && mv -f "$2.tmp" "$2"
}

do_service() {
  mkdir -p "$_usr"
  _render_unit "$_unit" "$_usr/vigilance-logind.service"
  systemctl --user enable vigilance-logind.service 2>/dev/null || true
  echo "$PKG: rendered + enabled the --user Session.Lock listener"
  # The SUPERVISION timer, and the loop it drives. Shipped and enabled here
  # rather than left to an integrator, because a supervision loop nothing runs
  # is exactly the dead tier this project keeps finding: `due.d` was designed,
  # enumerated, and read by nothing for the whole refactor. Report-only by
  # default, so enabling it cannot cross an edge on its own.
  for _eu in vigilance-enforce.service vigilance-enforce.timer \
             vigilance-audit.service vigilance-audit.timer \
             vigilance-idle.service; do
    _render_unit "$_root/systemd/$_eu" "$_usr/$_eu"
  done
  systemctl --user enable vigilance-enforce.timer 2>/dev/null || true
  systemctl --user enable vigilance-audit.timer 2>/dev/null || true
  # vigilance-idle.service is PLACED but never enabled: the COMPOSITOR starts
  # it, because only the compositor knows when WAYLAND_DISPLAY has been imported
  # and a display exists to connect to. Enabling it against a target would start
  # swayidle into a void.
  echo "$PKG: rendered + enabled the supervision + audit timers"
  echo "$PKG: placed vigilance-idle.service (the compositor starts it:"
  echo "  systemctl --user start vigilance-idle.service from its autostart)"
  echo "  (supervision is report-only;"
  echo "  VIGILANCE_ENFORCE=force lets it cross an overdue edge)"
  echo "$PKG: the SYSTEM units need root -- place lock-on-sleep.service and"
  echo "  vigilance-resume.service from $_root/systemd under /etc/systemd/"
  echo "  system (they are @USER@/@UID@/@VIGILANT@-templated; render, do not"
  echo "  symlink -- and point @VIGILANT@ at the SHARED copy, never a home)."
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
  # RENDERED units are plain files, so readlink can no longer identify them as
  # ours. Remove by NAME, safe for the same reason copy-mode removal is: the
  # names come from this clone, so only what we would install is ever removed.
  # A unit an integrator wrote under a different name is untouched.
  for _eu in vigilance-logind.service vigilance-enforce.service \
             vigilance-enforce.timer vigilance-audit.service \
             vigilance-audit.timer vigilance-idle.service; do
    rm -f "$_usr/$_eu"
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

# ONE COMMAND, ONE PATH ENTRY. The house rule ("Install placement" in
# ~/src/CLAUDE.md) bans a command being installed into two directories that are
# both on PATH, because /usr/local/bin precedes ~/.local/bin and the system copy
# then SHADOWS the live one and rots behind it. That is not theory here: it bit
# twice in one day -- a stale system swayidle-mgr won `command -v` and made an
# idle-suspend seam added that morning inert, then a stale system `vigilant`
# outranked a current user install for three hours.
#
# The correct shared layout is ONE root-owned tree plus ONE symlink onto PATH,
# so a shared command and a user install can never both answer. This asserts the
# property rather than the layout, so it stays true however the trees move.
#
# The PATH it reads is overridable for the same reason `report`'s sysfs roots
# and locker probe are: otherwise a SANDBOXED install asserts against the
# DEVELOPER's live PATH and fails on a shadow that has nothing to do with the
# install under test. It caught exactly that on its first run here. Production
# never sets it.
_check_path_unique() {   # <cmd>...
  for _u_cmd in "$@"; do
    _u_n=0 _u_found=
    _u_ifs=$IFS; IFS=:
    for _u_d in ${VIGILANCE_CHECK_PATH:-$PATH}; do
      IFS=$_u_ifs
      [ -n "$_u_d" ] || continue
      if [ -x "$_u_d/$_u_cmd" ]; then
        _u_n=$((_u_n + 1)); _u_found="$_u_found $_u_d/$_u_cmd"
      fi
      IFS=:
    done
    IFS=$_u_ifs
    if [ "$_u_n" -eq 0 ]; then
      bad "$_u_cmd not on PATH"
    elif [ "$_u_n" -eq 1 ]; then
      ok "$_u_cmd resolves from exactly one place ($_u_found)"
    else
      bad "$_u_cmd resolves from $_u_n places; the FIRST wins and the rest are"\
" SHADOWED and will rot:$_u_found"
    fi
  done
}

# LEFTOVERS FROM THE OTHER MODE. Switching modes has to leave no crumbs, and the
# crumb that matters is a second PLUGIN TREE: the hook wiring points at one by
# absolute path, so a stale tree is a set of hooks that still run and are no
# longer the ones being edited. Dropping a root-owned tree needs sudo, so when
# this cannot remove it, it says so LOUDLY rather than letting it rot.
_check_stale_trees() {
  # ASK THE WIRING WHICH TREE IS LIVE, rather than assuming it is this install's
  # own prefix. On a hybrid box it is NOT: `vigilant` is shared, so both scopes
  # symlink into the SHARED tree even though setup.sh itself may be running
  # against the user prefix.
  #
  # The first version assumed, and so named /opt -- the tree every hook actually
  # resolves to -- as the suspicious one, while the genuinely unused ~/.local
  # copy went unmentioned. A warning that fingers the live tree is worse than no
  # warning: it sends you to delete the thing that is working.
  _inuse=
  for _p in "$MACHINE_HOOK_ROOT"/*/* "$_cfg/$PKG/hooks"/*/*; do
    if [ ! -e "$_p" ]; then continue; fi
    _t=$(readlink -f "$_p" 2>/dev/null || true)
    case "${_t:-}" in
      */libexec/$PKG/*) _inuse=${_t%%/libexec/$PKG/*}/libexec/$PKG; break ;;
    esac
  done
  for _st in "$_lib/$PKG" /opt/$PKG/libexec/$PKG /usr/local/libexec/$PKG; do
    if [ ! -e "$_st" ]; then continue; fi
    if [ -n "$_inuse" ] && [ "$_st" = "$_inuse" ]; then continue; fi
    if [ -z "$_inuse" ]; then
      warn "plugin tree at $_st, but no wiring resolves into any tree"
    else
      warn "unused plugin tree at $_st; every wired hook resolves into"\
" $_inuse, so this one is a leftover and edits to it change nothing"
    fi
  done
  if [ -n "$_inuse" ]; then ok "wiring resolves into one tree ($_inuse)"; fi
}

# NO USER-WRITABLE FILE REACHABLE AS A ROOT INPUT. This is the second half of
# what "Install placement" calls the load-bearing check, and the half that was
# missing: PATH uniqueness was asserted, this was not.
#
# It matters the moment a package goes shared. The machine hook wiring symlinks
# into the installed plugin tree, and a GREETER (a different security context)
# executes those hooks. If the unprivileged account can rewrite them, that is
# the privilege boundary the placement rule exists to draw.
#
# Caught exactly that here: after the /opt migration, 19 entries under the
# shared tree were still jello:jello and group-writable, because `cp -a` keeps
# the source's ownership and mode even when root runs it. The install now chowns
# and strips write; this is what notices when it has not.
#
# A USER prefix is exempt, and deliberately so: ~/.local is SUPPOSED to be
# user-owned, and flagging it would train the reader to ignore this line.
#
# KEYED ON THE ROOT-VISIBLE TREES THE RULE ITSELF NAMES (/usr, /etc, /opt, /var)
# rather than on "not under $HOME". The first version used the latter and failed
# the suite immediately: a sandboxed install to a /tmp prefix is neither a user
# prefix nor a shared one, and demanding root ownership of a test fixture is a
# verdict about the harness, not the package.
_check_root_inputs() {
  # THE TREE THE HOOKS ACTUALLY RESOLVE INTO, which on a hybrid box is the
  # SHARED one, not this install's prefix. _check_stale_trees resolved it from
  # the wiring just above; falling back to the local prefix only when nothing is
  # wired. Checking the prefix instead would have asserted ownership of a tree
  # nothing executes while the executed one went unexamined -- which is how it
  # read "[OK] user-owned, correct for a user prefix" on a box whose live tree
  # was 19 files owned by the login user.
  _tree=${_inuse:-$_lib/$PKG}
  case "$_tree" in
    /usr/*|/etc/*|/opt/*|/var/*)
      if [ ! -d "$_tree" ]; then
        return 0
      fi
      _nonroot=$(find "$_tree" \! -user root 2>/dev/null | wc -l)
      _writable=$(find "$_tree" -perm /022 2>/dev/null | wc -l)
      if [ "$_nonroot" = 0 ] && [ "$_writable" = 0 ]; then
        ok "shared plugin tree is root-owned and not writable by anyone else"
      else
        bad "shared plugin tree has $_nonroot non-root and $_writable"\
" group/other-writable entries under $_tree; a greeter executes these"\
" hooks, so the login user must not be able to rewrite them"
      fi ;;
    "$HOME"/*) ok "plugin tree is user-owned, correct for a user prefix" ;;
    *) ;;   # neither a system nor a home prefix: nothing to assert
  esac
  # And the wiring that REACHES them. A machine-scope hook is executed by
  # sessions that are not the owner's, so its target must not be user-writable
  # either -- the symlink being root-owned says nothing about what it points at.
  _badtgt=
  for _mh in "$MACHINE_HOOK_ROOT"/*/*; do
    [ -e "$_mh" ] || continue
    _t=$(readlink -f "$_mh" 2>/dev/null || true)
    [ -n "$_t" ] || continue
    if [ -w "$_t" ] && [ "$(id -u)" != 0 ]; then
      _badtgt="$_badtgt ${_mh#"$MACHINE_HOOK_ROOT"/}"
    fi
  done
  if [ -n "$_badtgt" ]; then
    warn "machine-scope hooks whose target THIS user can write:$_badtgt"
  fi
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
  _check_path_unique vigilant
  _check_stale_trees
  _check_root_inputs
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
