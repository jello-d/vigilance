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
# other user: a greeter following one gets nothing. More generally a system
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
# it). They are @USER@/@UID@/@HOME@-templated, and @HOME@ is NOT %h: in a
# SYSTEM unit %h resolves to ROOT's home regardless of User=, which is exactly
# how the suspend lock 203/EXEC'd on every sleep for a whole refactor.
#
# udev/99-vigilance.rules is the same shape: root-only, so a host places it,
# and it grants the `vigilant` group write on exactly the nodes the peripheral
# hooks drive. WITHOUT IT those hooks silently no-op, because brightnessctl is
# denied and hook_dark/hook_lit swallow the failure by design. The group must
# exist and the users that run vigilance must be in it, including the greeter
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

# THE PAYLOAD: one self-contained tree per package, COPIES of what the repo
# ships, with links into it. The rule and the recipe are
# `_install-placement.md` and `_place-conversion.md` in shared-notes; what
# follows is only what is SPECIFIC to this package.
#
# WHY A DEPARTED PACKAGE CANNOT SYMLINK INTO ITS CLONE. This installs from
# ~/.cache/tackup/pkgs/vigilance, which is re-cloned on every sweep and wiped on
# demand, so every ~/.local link into it dangles the moment that happens. Two
# such links were dangling on this box before the conversion, left by tools
# retired on 2026-09-01.
#
# THE SELF-LOCATION HERE RUNS THE OPPOSITE WAY FROM THE RECIPE'S CASE, and that
# is the one thing a reader must not optimise away. `bin/vigilant` reads no
# libexec at all; it is the PLUGINS that locate the COMMAND, each one resolving
# its own real path and walking up:
#
#   libexec/vigilance/hooks/*      . "$(dirname "$_self")/../hook_lib"
#   libexec/vigilance/triggers/*   ../../../bin/vigilant
#   libexec/vigilance/providers/*  ../../../bin/vigilant
#
# So the payload must contain `bin/` AND `libexec/` at exactly that relative
# depth. Dropping `bin/` from the payload on the grounds that `vigilant` is also
# published system-wide would leave every hook and trigger unable to find it,
# silently: `_hooks_in` lists a hook only `if [ -x ]`, so a plugin that cannot
# resolve its own dependency does not FAIL, it stops existing.
_pay=$_shr/$PKG

# A SHAPE GUARD, because the next thing this path meets is `rm -rf`, and the
# house rule is that no variable reaches that command unchecked. Keyed on SHAPE
# rather than on a literal prefix: the conversion is verified under a scratch
# PREFIX (/var/tmp/...), so a guard demanding $HOME would refuse exactly the
# safe rehearsal it exists to protect.
_pay_sane() {
  case ${_pay:-} in
    /*/"$PKG") [ "$(dirname "$_pay")" != / ] ;;
    *)         return 1 ;;
  esac
}
_cfg=${XDG_CONFIG_HOME:-$HOME/.config}
_usr=$_cfg/systemd/user
# The MACHINE hook root, same default and same override name vigilant uses, so
# the two cannot disagree about where machine-scope wiring lives and a test can
# sandbox both with one variable.
MACHINE_HOOK_ROOT=${VIGILANCE_MACHINE_HOOKS:-/etc/vigilance/hooks}
_unit=$_root/systemd/vigilance-logind.service
# External runtime deps. brightnessctl was MISSING from this list while three
# shipped hooks (kbd-backlight, panel-backlight, mute-leds) called it by name,
# so the one dependency whose absence is SILENT (hook_dark/hook_lit swallow
# its failure by design) was the one `check` did not look for.
DEPS="swaylock swayidle wlopm ddcutil brightnessctl"

# NAME THE CONSUMER, not just the package. "dep ddcutil absent" says nothing
# about what stops working; the marker contract is meant to be actionable, and
# one shared message ("powers spanning/DDC") was wrong for most of them.
_dep_why() {   # dep -> what stops working without it
  case "$1" in
    swaylock)      echo "the DEFAULT locker (VIGILANCE_LOCKER names another)" ;;
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
# the package that morning was inert: the tool that ran had never heard of it.
#
# Keyed on COPY MODE, which is already defined as "what a shared/system prefix
# needs" (see the header). A symlinking install to a user prefix is unaffected.
SYSTEM_TOOLS="vigilant"

_wanted_at_prefix() {   # <tool-name>
  [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ] || return 0   # user prefix: all
  for _w in $SYSTEM_TOOLS; do [ "$1" = "$_w" ] && return 0; done
  return 1
}

# STAGE BESIDE THE LIVE TREE AND SWAP, rather than writing into it. A copying
# install re-runs on every provision sweep, so it has to be idempotent, and a
# half-written payload is worse than an old one: the hooks inside it are what a
# greeter and a lock edge execute. Staging means the live tree is only ever
# replaced by a complete one.
#
# THE SHIPPED DIRS AND NOTHING ELSE. `bin` and `libexec` are load-bearing at a
# fixed relative depth (see the _pay comment); `man` rides along so the payload
# is the single thing to remove on uninstall. The repo has no `share/`.
_payload_stage() {
  if ! _pay_sane; then
    echo "$PKG: refusing to stage a payload at '${_pay:-}'" >&2
    return 1
  fi
  # DERIVED FROM A PATH JUST GUARDED, which is the only form in which these two
  # names may reach `rm -rf`. The guard is immediately above on purpose.
  _paynew=$_pay.new
  _payold=$_pay.old
  rm -rf -- "$_paynew" "$_payold"
  mkdir -p "$_paynew"
  for _pd in bin lib libexec man; do
    if [ -d "$_root/$_pd" ]; then cp -R "$_root/$_pd" "$_paynew/$_pd"; fi
  done
  mkdir -p "$(dirname "$_pay")"
  if [ -e "$_pay" ]; then mv -- "$_pay" "$_payold"; fi
  mv -- "$_paynew" "$_pay"
  rm -rf -- "$_payold"
}

do_install() {
  # A PAYLOAD IN USER MODE ONLY. Copy mode is the SHARED/system install, which
  # copies into a root-owned prefix and already satisfies place-not-link; giving
  # it a payload as well would mean two copies and a second thing to keep in
  # step. So this branch leaves /opt behaviour byte-identical.
  _srcroot=$_root
  if [ "${VIGILANCE_INSTALL_COPY:-0}" != 1 ]; then
    _payload_stage || return 1
    _srcroot=$_pay
  fi
  mkdir -p "$_bin"
  for _t in "$_root"/bin/*; do
    _n=$(basename "$_t")
    if _wanted_at_prefix "$_n"; then
      _place "$_srcroot/bin/$_n" "$_bin/$_n"
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
  # THE LINK TARGET IS THE PAYLOAD'S COPY in user mode, so the source is
  # rewritten relative to $_srcroot rather than taken from the clone. Enumerated
  # from the repo either way, because that is what decides WHICH pages ship.
  _man_pages | while IFS= read -r _m; do
    _d=$_man/$(basename "$(dirname "$_m")")
    mkdir -p "$_d"
    _place "$_srcroot/${_m#"$_root"/}" "$_d/$(basename "$_m")"; done
  # libexec carries the shipped PLUGINS: hooks/ (peripheral actuators, alert
  # sinks, block guards), providers/ (how to bring a locker up) and triggers/
  # (what crosses an edge). All installed AVAILABLE but never WIRED: which
  # plugin runs where is policy, and policy is the integrator's. One that
  # shipped pre-enabled would be vigilance deciding policy, which is the
  # mistake mute-on-lock was moved out to avoid.
  if [ -d "$_root/libexec" ]; then
    mkdir -p "$_lib"
    if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
      # rm first: cp -a of a directory ONTO an existing one nests it rather
      # than replacing it, which would leave a stale tree one level down.
      rm -rf "$_lib/$PKG"
      # THE `cp -a` TRAP _place DOCUMENTS, and which _place fixed only for the
      # BINARIES. --preserve=all carries the SOURCE's ownership AND mode across
      # even when the copy runs as root, and the clone lives in a user's home
      # with a user's umask. So a root install produced a /opt/vigilance tree
      # owned jello:jello and group-WRITABLE.
      #
      # That is not untidiness once the tree is shared: the machine-scope hook
      # wiring symlinks into it, and a GREETER executes those hooks. A file the
      # unprivileged account can rewrite, executed by another security context,
      # is the thing "Install placement" bans outright: anything root reads or
      # runs must be root-owned and not user-writable.
      #
      # Found on a real box after the migration: 19 entries under /opt/vigilance
      # were jello:jello, including every hook and hook_lib itself.
      #
      # IN THE LOOP, AGAINST THE SAME VARIABLE THAT WAS COPIED, which is the
      # whole point rather than a tidy-up: it used to chown a SEPARATELY WRITTEN
      # path, and when the tree flattened the copy moved and the chown did not,
      # so it named a directory that no longer existed. The install then died on
      # `chown: cannot access`, which took tackup's lock phase down with it. One
      # variable for rm, cp, chown and chmod cannot drift from itself.
      # STAGED, THEN SWAPPED, so a failure never destroys a working tree.
      #
      # THIS IS THE LESSON FROM 2026-10-03 PAID FORWARD. The old form was
      # `rm -rf` then `cp`, so when the chown below died mid-install the live
      # /opt tree had ALREADY been replaced by a half-written one: the box was
      # left worse than before the install ran, with the rendered units still
      # naming the previous layout. The payload install has staged through
      # `.new` since its conversion; the privileged one never did, and the
      # privileged one is the half a greeter executes.
      #
      # THE WINDOW SHRINKS, IT DOES NOT CLOSE, and saying so matters: the swap
      # is two renames, so the path is absent for microseconds rather than for
      # the length of a whole recursive copy. A truly atomic replace needs a
      # symlink flip, which would put an extra level under every wired hook
      # path for a gap this narrow.
      #
      # NO GENERATION IS KEPT. Rolling back is a re-install from the clone at
      # the last proven ref (tackup's install engine owns that), so a retained
      # `.old` here would be a SECOND answer to "what was good", free to
      # disagree with the first.
      for _cd in lib libexec; do
        _cdst=$PREFIX/$_cd
        case $_cdst in
        /*/"$_cd") ;;
        *) echo "$PKG: refusing to replace '$_cdst'" >&2; return 1 ;;
        esac
        # DERIVED FROM A PATH JUST GUARDED, which is the only form in which
        # these names may reach `rm -rf`: the guard is immediately above.
        _cnew=$_cdst.new
        _cold=$_cdst.old
        rm -rf -- "$_cnew" "$_cold"
        # Everything that must be true of the live tree is made true of the
        # STAGED one first, so the swap is the only thing that can half-happen.
        if ! cp -a "$_root/$_cd" "$_cnew"; then
          echo "$PKG: could not stage $_cd; $_cdst left as it was" >&2
          rm -rf -- "$_cnew"; return 1
        fi
        if [ "$(id -u)" = 0 ]; then
          # Strip group/other write as well. Ownership alone is not enough: a
          # 0775 root-owned dir is still writable by anyone in the root group.
          # ONE VERB PER LINE, at line start, because the static guard in
          # test/setup.t reads these: the privileged branch cannot be executed
          # by a test, so its only coverage is that it can be found and read.
          _hard=0
          chown -R root:root "$_cnew" || _hard=1
          chmod -R go-w "$_cnew" || _hard=1
          if [ "$_hard" != 0 ]; then
            echo "$PKG: could not harden the staged $_cd; $_cdst left as it"\
" was (a tree a greeter executes must be root-owned)" >&2
            rm -rf -- "$_cnew"; return 1
          fi
        fi
        if [ -e "$_cdst" ] && ! mv -- "$_cdst" "$_cold"; then
          echo "$PKG: could not move the live $_cd aside; left as it was" >&2
          rm -rf -- "$_cnew"; return 1
        fi
        if ! mv -- "$_cnew" "$_cdst"; then
          echo "$PKG: the $_cd swap failed; restoring the previous tree" >&2
          [ -e "$_cold" ] && mv -- "$_cold" "$_cdst"
          return 1
        fi
        rm -rf -- "$_cold"
      done
    else
      # THE STRUCK ROOT. `~/.local/libexec/<pkg>` is gone as a concept: it was
      # a symlink into the clone, so it dangled on every re-clone, and the
      # plugins live in the payload now where their `../../../bin/vigilant`
      # resolves. RETIRED here rather than only on uninstall, because install is
      # what every box runs and a conversion that waits for an uninstall never
      # happens.
      #
      # ONLY IF IT IS OURS. A symlink into this clone is unambiguously the old
      # install's; anything else at that path is somebody's own and is left
      # exactly alone.
      if [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ]
      then
        rm -f "$_lib/$PKG"
        echo "$PKG: retired $_lib/$PKG (the payload carries the plugins now)"
      fi
    fi
  fi
  # THE CRUMBS A RETIREMENT LEFT, which no amount of correct uninstall logic can
  # reach: `do_uninstall` enumerates `$_root/bin/*`, so a tool deleted from the
  # repo is never named again and its link outlives the package forever.
  # smart-lock and smart-trigger were retired on 2026-09-01 and both were still
  # dangling into the clone on this box when the conversion measured it.
  #
  # BY NAME, DELIBERATELY, and only when the link points into THIS clone. A
  # name-keyed sweep is the only thing that can see a path the repo has
  # forgotten, and the readlink test is what keeps it from touching a file an
  # integrator put there under the same name.
  for _gone in smart-lock smart-trigger; do
    case "$(readlink "$_bin/$_gone" 2>/dev/null)" in
      "$_root"/bin/"$_gone")
        rm -f "$_bin/$_gone"
        echo "$PKG: swept $_bin/$_gone (retired 2026-09-01, link had dangled)"
        ;;
    esac
  done
  # AND THEIR SYSTEMD ENABLE LINKS, which nothing swept. Found on a real box
  # 2026-10-05: default.target.wants/smart-trigger.service in the --user unit
  # dir, still pointing at /etc/systemd/user/smart-trigger.service, retired
  # with the tool on 2026-09-01. Inert (measured: user manager running, zero
  # failed units, nothing in the journal, since systemd ignores a .wants link
  # with no target) but it outlives the package forever and reads as an enabled
  # unit to anyone looking.
  #
  # BY RETIRED NAME, AND ONLY WHEN IT DANGLES, deliberately narrow. A GENERIC
  # sweep of dangling .wants links is the obvious idea and is dangerous here:
  # between a clone wipe and the next PRIVILEGED reinstall, this package's own
  # vigilance-logind.service target is legitimately absent, so a generic sweep
  # would remove its enable link and silently disable the Session.Lock
  # listener, which is the lid-close lock. A retired name cannot come back.
  for _gone in smart-lock.service smart-trigger.service; do
    for _gw in "$_usr"/*.wants/"$_gone"; do
      [ -h "$_gw" ] || continue
      [ -e "$_gw" ] && continue       # the unit exists: not ours to judge
      rm -f "$_gw"
      echo "$PKG: swept $_gw (enable link for a unit retired 2026-09-01)"
    done
  done
  if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]; then
    echo "$PKG: COPIED the tools (+ man, hooks) into $PREFIX"
  else
    echo "$PKG: staged the payload at $_pay and linked into $PREFIX"
  fi
}

# UNITS ARE RENDERED, NOT SYMLINKED, because they carry placeholders now.
#
# @VIGILANT@ is the published path of the `vigilant` command and @PLUGINS@ the
# installed plugin tree. Neither can be home-relative any more: `vigilant` is
# classified as a SHARED command (one root-owned tree, one link on PATH), and
# a unit that hardcoded ~/.local would break the moment a box installs in shared
# mode, which is precisely how the idle timer died once already, armed with a
# path that had been swept out from under it.
#
# Substituting at install is what keeps ONE fact in ONE place: the installer
# already knows where it put things, so no unit has to guess and no second copy
# of the prefix exists to drift. A symlinked unit could not be substituted at
# all, which is why this stopped being a symlink.
_render_unit() {   # <src> <dst>
  sed -e "s|@VIGILANT@|$_bin/vigilant|g" \
      -e "s|@PLUGINS@|$_lib|g" "$1" > "$2.tmp" \
    && mv -f "$2.tmp" "$2"
}

# ENABLE, AND THEN SAY WHAT ACTUALLY HAPPENED.
#
# `systemctl --user enable` fails wherever there is no user systemd instance to
# talk to: a provisioner, a container, an ssh session before the user bus
# exists. Swallowing that and printing "enabled" anyway is the same false claim
# this package keeps finding elsewhere, and here it matters, because the
# listener it names is what crosses the `lock` edge on logind's Session.Lock.
# Believing it is armed when it is not is precisely the gap that leaves a
# machine unlocked.
#
# The swallow itself stays: PLACING the units is still correct on a box with no
# user bus, and aborting an install over it would be worse. Only the sentence
# has to be honest.
_enable_user() {   # <unit>...
  _eu_bad=
  for _eu_u in "$@"; do
    systemctl --user enable "$_eu_u" >/dev/null 2>&1 \
      || _eu_bad="$_eu_bad $_eu_u"
  done
  if [ -n "$_eu_bad" ]; then
    echo "$PKG: PLACED but could NOT enable:$_eu_bad"
    echo "  no user systemd instance is reachable here, so these will never"
    echo "  start on their own; enable them from a live session"
    return 1
  fi
  return 0
}

do_service() {
  mkdir -p "$_usr"
  _render_unit "$_unit" "$_usr/vigilance-logind.service"
  if _enable_user vigilance-logind.service; then
    echo "$PKG: rendered + enabled the --user Session.Lock listener"
  else
    echo "$PKG: rendered the --user Session.Lock listener (NOT enabled)"
  fi
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
  _timers_on=1
  _enable_user vigilance-enforce.timer vigilance-audit.timer || _timers_on=0
  # vigilance-idle.service is PLACED but never enabled: the COMPOSITOR starts
  # it, because only the compositor knows when WAYLAND_DISPLAY has been imported
  # and a display exists to connect to. Enabling it against a target would start
  # swayidle into a void.
  if [ "$_timers_on" = 1 ]; then
    echo "$PKG: rendered + enabled the supervision + audit timers"
  else
    echo "$PKG: rendered the supervision + audit timers (NOT enabled, so"
    echo "  nothing supervises this box until they are)"
  fi
  echo "$PKG: placed vigilance-idle.service (the compositor starts it:"
  echo "  systemctl --user start vigilance-idle.service from its autostart)"
  echo "  (supervision is report-only;"
  echo "  VIGILANCE_ENFORCE=force lets it cross an overdue edge)"
  echo "$PKG: the SYSTEM units need root: place lock-on-sleep.service and"
  echo "  vigilance-resume.service from $_root/systemd under /etc/systemd/"
  echo "  system (they are @USER@/@UID@/@VIGILANT@-templated; render, do not"
  echo "  symlink, and point @VIGILANT@ at the SHARED copy, never a home)."
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
  # THE EXPECTED TARGET IS THE PAYLOAD in user mode, and that is not cosmetic:
  # `_unplace` only removes a link whose target MATCHES, which is what stops it
  # deleting an integrator's own link of the same name. Pass it the clone path
  # after a conversion and it matches nothing, so uninstall silently leaves
  # every link behind.
  #
  # BOTH ARE ACCEPTED, because a box may still carry pre-conversion links when
  # this runs: the old install put them there and only an uninstall from this
  # version can clear them.
  _unsrc=$_root
  if [ "${VIGILANCE_INSTALL_COPY:-0}" != 1 ]; then _unsrc=$_pay; fi
  for _t in "$_root"/bin/*; do
    _n=$(basename "$_t")
    _unplace "$_bin/$_n" "$_unsrc/bin/$_n"
    _unplace "$_bin/$_n" "$_t"
  done
  for _gone in smart-lock smart-trigger; do
    _unplace "$_bin/$_gone" "$_root/bin/$_gone"
  done
  _man_pages | while IFS= read -r _m; do
    _l=$_man/$(basename "$(dirname "$_m")")/$(basename "$_m")
    _unplace "$_l" "$_unsrc/${_m#"$_root"/}"
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
    # Both FHS dirs the copy install places, plus the legacy nested one so a
    # box installed either side of the flattening is left clean.
    rm -rf "$_lib/$PKG"
    for _cd in lib libexec; do
      _cdst=$PREFIX/$_cd
      case $_cdst in
      /*/"$_cd") rm -rf -- "$_cdst" ;;
      *) echo "$PKG: refusing to remove '$_cdst'" >&2 ;;
      esac
    done
  else
    # The STRUCK ROOT again, for a box that still has the old one. Only when it
    # is a link into this clone, as on install.
    [ "$(readlink "$_lib/$PKG" 2>/dev/null)" = "$_root/libexec/$PKG" ] \
      && rm -f "$_lib/$PKG" || :
    # AND THE PAYLOAD, which is the only directory this version created.
    # Guarded, then removed through a value that cannot be anything else: the
    # house rule is that no unchecked variable reaches `rm -rf`, and this is the
    # one place in the file that deletes a TREE under a user prefix.
    if [ -d "$_pay" ] && _pay_sane; then
      rm -rf -- "$_pay"
      echo "$PKG: removed the payload at $_pay"
    elif [ -e "$_pay" ] && ! _pay_sane; then
      echo "$PKG: refusing to remove '$_pay' (not a payload-shaped path)" >&2
    fi
  fi
  echo "$PKG: removed the ~/.local links (+ the --user listener)"
}

# DEVICE ACCESS, which this file's own header declares as a hard requirement and
# nothing verified, so the requirement was a comment. On a real box the user
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
# `vigilant report`'s questions, asked against live systemd, deliberately not
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
# AND THE RENDERED PATH STILL RESOLVES, which is a PLACEMENT question and so
# belongs here rather than with the liveness ones above. These units carry a
# SUBSTITUTED @VIGILANT@ or @PLUGINS@, so a layout change moves the target out
# from under a unit already on disk, and that is the one failure neither this
# check nor `vigilant report` could see.
#
# MEASURED 2026-10-04, and it is why this exists: a copy-mode install placed the
# flattened libexec and then DIED before re-rendering, leaving
# vigilance-logind.service pointing at a triggers/ path one directory level that
# no longer had. systemd read `active (running)` for 23 hours, because the
# process had been started while the file still existed and the kernel holds the
# inode of a deleted one. So the Session.Lock listener worked and could never
# RESTART: the next logout, reboot or crash would have left AC lid-close and
# `loginctl lock-session` silently not locking. For the one unit that crosses
# the lock edge, that is the dangerous direction.
# THE SYSTEM --user UNIT DIR IS A SEAM, for the reason VIGILANCE_CHECK_PATH is
# one: without it a SANDBOXED check falls back to the host's /etc/systemd/user
# and renders a verdict about the developer's box rather than about the install
# under test. Found immediately: the ExecStart assertion below read the host's
# real (and genuinely broken) logind unit from inside a scratch prefix.
SYS_USER_UNITS=${VIGILANCE_SYS_USER_UNITS:-/etc/systemd/user}
SYS_UNITS=${VIGILANCE_SYS_UNITS:-/etc/systemd/system}

_check_unit_exec() {   # <unit> <unit-file>
  _ex=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$2" | head -1)
  [ -n "$_ex" ] || return 0
  # systemd's prefixes: `-` tolerates failure, `@` overrides argv0. Neither is
  # part of the path.
  _ex=${_ex#-}; _ex=${_ex#@}
  # ANY systemd SPECIFIER IS SKIPPED, %h included, and that is the scope rather
  # than a shortcut. This asks whether a SUBSTITUTED path still resolves: the
  # rendering replaces @VIGILANT@ and @PLUGINS@ with absolute paths this
  # installer chose, so it is answerable for those. `%h/.local/bin/swayidle-mgr`
  # is the unit's own fixed contract, expanded per user by systemd, and its
  # absence means the tool is not installed, which the binary checks above
  # already report. Expanding it against OUR $HOME also answers the wrong
  # question for a /etc/systemd/user unit: each user there has its own.
  case $_ex in
    *%*) return 0 ;;
  esac
  if [ -x "$_ex" ]; then
    ok "$1 ExecStart resolves"
  else
    bad "$1 ExecStart is $_ex, which is not an executable"\
" file. The unit cannot RESTART, and systemd can read it active meanwhile"\
" from a process started while the file still existed. Re-render it with"\
" './setup.sh service'."
  fi
}
_check_units() {
  for _u in vigilance-logind.service vigilance-enforce.timer \
            vigilance-audit.timer vigilance-idle.service; do
    _uf=
    if [ -e "$_usr/$_u" ]; then
      _uf=$_usr/$_u; ok "--user unit $_u placed (this user)"
    elif [ -e "$SYS_USER_UNITS/$_u" ]; then
      _uf=$SYS_USER_UNITS/$_u
      ok "--user unit $_u placed ($SYS_USER_UNITS; every user)"
    else warn "--user unit $_u not placed (run './setup.sh service')"; fi
    if [ -n "$_uf" ]; then _check_unit_exec "$_u" "$_uf"; fi
  done
  # Root-placed, so their absence is an integrator task rather than our failure.
  # THEIR ExecStart IS CHECKED TOO, and these are the more security-critical
  # pair: lock-on-sleep is the Before=sleep.target oneshot that BLOCKS suspend
  # until the screen is locked, so a stale path there suspends UNLOCKED.
  # Covering the --user units and not these is one gap invisible in two places.
  for _u in lock-on-sleep.service vigilance-resume.service; do
    if [ -e "$SYS_UNITS/$_u" ]; then
      ok "SYSTEM unit $_u placed"
      _check_unit_exec "$_u" "$SYS_UNITS/$_u"
    else warn "SYSTEM unit $_u not placed (needs root; $_root/systemd)"; fi
  done
}

# ONE COMMAND, ONE PATH ENTRY. The house rule ("Install placement" in
# ~/src/CLAUDE.md) bans a command being installed into two directories that are
# both on PATH, because /usr/local/bin precedes ~/.local/bin and the system copy
# then SHADOWS the live one and rots behind it. That is not theory here: it bit
# twice in one day: a stale system swayidle-mgr won `command -v` and made an
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
      # Nowhere on THIS shell's PATH. That is not the same as missing, and the
      # difference has an owner: where we installed it is ours, what is on the
      # caller's PATH is the caller's. An integrator checking from a non-login
      # context (ssh command, cron, agent) has no ~/.local/bin by construction,
      # so failing here is a false finding it cannot clear. A genuinely absent
      # install is caught by do_check's own loop, which looks on disk.
      warn "$_u_cmd not on THIS shell's PATH (cannot audit shadowing)"
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
  # The first version assumed, and so named /opt (the tree every hook actually
  # resolves to) as the suspicious one, while the genuinely unused ~/.local
  # copy went unmentioned. A warning that fingers the live tree is worse than no
  # warning: it sends you to delete the thing that is working.
  _inuse=
  _inuse_pfx=
  for _p in "$MACHINE_HOOK_ROOT"/*/* "$_cfg/$PKG/hooks"/*/*; do
    if [ ! -e "$_p" ]; then continue; fi
    _t=$(readlink -f "$_p" 2>/dev/null || true)
    case "${_t:-}" in
      # THE LEGACY NESTED SHAPE FIRST, because the flat pattern below matches a
      # nested path too and would answer one level too high. Both are live:
      # a box runs whichever tree its last install placed.
      */libexec/$PKG/*)
        _inuse=${_t%%/libexec/$PKG/*}/libexec/$PKG
        _inuse_pfx=${_t%%/libexec/$PKG/*}; break ;;
      */libexec/*)
        _inuse=${_t%%/libexec/*}/libexec
        _inuse_pfx=${_t%%/libexec/*}; break ;;
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
  # nothing executes while the executed one went unexamined, which is how it
  # read "[OK] user-owned, correct for a user prefix" on a box whose live tree
  # was 19 files owned by the login user.
  # BOTH IMPLEMENTATION DIRS, since the flattening: a hook the greeter executes
  # SOURCES lib/hook_lib, so a login-user-writable lib/ is the same escalation
  # as a writable libexec/ and was not being looked at.
  #
  # AND COUNTING WHAT IT EXAMINED, because the previous form returned 0 when its
  # ONE path was absent, and after the flattening it always was: it reported
  # nothing at all, silently, where the whole point of this function is
  # to refuse a tree the login user can rewrite. An empty examination must stay
  # silent, but it must not be reachable by naming the wrong directory.
  _pfx=${_inuse_pfx:-$PREFIX}
  case "$_pfx" in
    /usr/*|/etc/*|/opt/*|/var/*)
      _nonroot=0; _writable=0; _seen=0
      for _td in lib libexec; do
        [ -d "$_pfx/$_td" ] || continue
        _seen=$((_seen + 1))
        _nonroot=$((_nonroot + $(find "$_pfx/$_td" \! -user root 2>/dev/null \
          | wc -l)))
        _writable=$((_writable + $(find "$_pfx/$_td" -perm /022 2>/dev/null \
          | wc -l)))
      done
      if [ "$_seen" = 0 ]; then
        return 0
      fi
      if [ "$_nonroot" = 0 ] && [ "$_writable" = 0 ]; then
        ok "shared plugin tree is root-owned and not writable by anyone else"
      else
        bad "shared plugin tree has $_nonroot non-root and $_writable"\
" group/other-writable entries under $_pfx; a greeter executes these"\
" hooks, so the login user must not be able to rewrite them"
      fi ;;
    "$HOME"/*) ok "plugin tree is user-owned, correct for a user prefix" ;;
    *) ;;   # neither a system nor a home prefix: nothing to assert
  esac
  # And the wiring that REACHES them. A machine-scope hook is executed by
  # sessions that are not the owner's, so its target must not be user-writable
  # either: the symlink being root-owned says nothing about what it points at.
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
  # Installed is OURS (a failure); on the caller's PATH is THEIRS (a warning).
  # Check both prefixes: an integrator may PUBLISH a command system-wide
  # (/usr/local/bin -> /opt/<pkg>) and delete the ~/.local copy so exactly one
  # lands on PATH, which is what tackup does for its shared tools.
  for _t in "$_root"/bin/*; do _n=$(basename "$_t")
    if command -v "$_n" >/dev/null 2>&1; then ok "$_n present"
    elif [ -e "$_bin/$_n" ] || [ -e "/usr/local/bin/$_n" ]; then
      warn "$_n installed but not on THIS shell's PATH"
    else bad "$_n not installed ($_bin/$_n)"; fi; done
  for _d in $DEPS; do
    command -v "$_d" >/dev/null 2>&1 && ok "dep $_d present" \
      || warn "dep $_d absent: $(_dep_why "$_d") degrades"; done
  # WHERE THE INSTALLED PLUGINS LIVE, which the two modes answer differently and
  # which this check asked for in ONE place before the conversion. It looked
  # under the struck `$_lib/$PKG`, so after the payload move it would have
  # reported every hook, provider and trigger as not installed on a correct box:
  # a conversion that leaves its own verifier pointing at the old layout turns a
  # success into a wall of red.
  _plugin_root() {
    if [ "${VIGILANCE_INSTALL_COPY:-0}" = 1 ]
    then printf '%s' "$PREFIX/libexec"
    else printf '%s' "$_pay/libexec"; fi
  }
  _pr=$(_plugin_root)
  for _k in hooks providers triggers; do
    for _h in "$_root"/libexec/"$_k"/*; do
      [ -x "$_h" ] || continue
      _n=$(basename "$_h")
      if [ -x "$_pr/$_k/$_n" ]; then ok "${_k%s} $_n available"
      else bad "${_k%s} $_n not installed ($_pr/$_k/$_n)"; fi
    done
  done

  # THE PAYLOAD INVARIANTS, which are what the conversion actually promises.
  # Copy mode is exempt: it installs into a root-owned system prefix and has no
  # payload by design.
  if [ "${VIGILANCE_INSTALL_COPY:-0}" != 1 ]; then
    if [ -d "$_pay" ] && [ ! -L "$_pay" ]; then
      ok "payload is a real directory ($_pay)"
    else
      bad "payload missing or a symlink ($_pay); a departed package must own a
  real tree, because a link into the clone dangles on the next re-clone"
    fi
    # THE PLUGINS' OWN DEPENDENCY, asserted rather than assumed. A hook finds
    # `hook_lib` at `../hook_lib` and a trigger finds the command at
    # `../../../bin/vigilant`, both from inside the payload, so bin and libexec
    # have to sit at that exact relative depth. If they do not, nothing fails
    # loudly: `_hooks_in` lists a hook only `if [ -x ]`, so a plugin that cannot
    # resolve its dependency stops EXISTING as far as the runner is concerned.
    if [ -x "$_pay/bin/vigilant" ]; then
      ok "plugins can reach vigilant at ../../../bin/vigilant"
    else
      bad "no $_pay/bin/vigilant, so every trigger and provider in the payload
  resolves its command to nothing and the hooks silently stop existing"
    fi
    if [ -r "$_pay/lib/hook_lib" ]; then
      ok "plugins can source hook_lib at ../../lib/hook_lib"
    else
      bad "no $_pay/lib/hook_lib, so every shipped hook exits 2"
    fi
    # AND NOTHING MAY RESOLVE BACK INTO THE SOURCE TREE. This is the rule the
    # conversion exists for, and the only assertion that can see a half-done
    # one: a single surviving link into the clone re-breaks on the next sweep.
    _leak=
    for _ld in "$_bin" "$_man" "$_lib"; do
      [ -d "$_ld" ] || continue
      for _lf in "$_ld"/* "$_ld"/*/*; do
        [ -L "$_lf" ] || continue
        case "$(readlink -f "$_lf" 2>/dev/null)" in
          "$_root"/*) _leak="$_leak $_lf" ;;
        esac
      done
    done
    if [ -z "$_leak" ]; then
      ok "no installed link resolves into the source tree"
    else bad "these resolve into the source tree, so they dangle when it is
  re-cloned or wiped:$_leak"; fi
  fi
  # MAN PAGES, which `install` claims in its own success message ("+ man") and
  # nothing confirmed. Iterated as a glob rather than via _man_pages, because
  # that prints, and a `while read` over a pipe runs in a SUBSHELL where
  # bad() could not raise RC: a check that cannot fail is not a check.
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
  # THE SEAM IS THE HELPER, NOT ANOTHER PACKAGE'S LAYOUT. This used to test for
  # `~/.config/shapes` and WARN when it was missing, which was wrong twice
  # over: that tree belongs to the integrator (it is tackup's, holding mako and
  # wallpaper config too) and NOTHING in vigilance reads it. Measured before
  # changing it: those three lines were the only `shapes` reference in the whole
  # shipped package.
  #
  # So every box that is not this fleet carried a permanent WARN about a
  # directory it has no reason to own, which is the same always-on warning that
  # makes a report stop being read. What vigilance actually has is
  # `vigilance-lock-argv`, the optional hook the provider asks for
  # locker-specific arguments, and its absence is a SUPPORTED configuration: the
  # provider falls back to a plain lock on purpose.
  #
  # INFO, NEVER WARN, for that reason. "You did not supply an optional helper"
  # is a statement about intent, not a fault, and the one thing a check here
  # must not do is imply a working box is misconfigured.
  # BOTH BRANCHES ARE `ok`, and that is deliberate rather than lazy. This file
  # emits a THREE-marker contract a host integrator styles ([OK]/[FAIL]/[WARN])
  # and there is no INFO, so the choice is between passing with precise words
  # and inventing a fourth marker that every consumer would have to learn. The
  # state is acceptable either way: the marker says the check passed and the
  # sentence says what was found.
  if command -v vigilance-lock-argv >/dev/null 2>&1; then
    ok "lock argv helper present (vigilance-lock-argv): the provider asks it"\
" for locker-specific arguments"
  else
    ok "no vigilance-lock-argv on PATH, so the provider uses a plain lock:"\
" a supported configuration rather than a gap"
  fi
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
