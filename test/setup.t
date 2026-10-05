#!/bin/sh
# setup.t - setup.sh install -> assert bin + man links (and NOT the --user unit,
# which is the separate `service` verb) -> check -> uninstall -> assert gone. A
# scratch HOME; nothing outside it is touched. `service` is not exercised: its
# `systemctl --user enable` would reach the real session manager.
. "$(dirname "$0")/harness_lib"
harness_init setup

BIN=$T/bin; SHR=$T/share; CFG=$T/config
run() {
  env PREFIX="$T" XDG_BIN_HOME="$BIN" XDG_DATA_HOME="$SHR" \
    XDG_CONFIG_HOME="$CFG" NO_COLOR=1 sh "$HERE/setup.sh" "$@"
}

# install: every bin/ tool + the man page linked; the --user unit is NOT (that
# is `service`, kept out so a host wiring systemd itself gets no duplicate).
run install >/dev/null 2>&1 || fail "install errored"
# THE LINKS POINT INTO THE PAYLOAD, NOT THE CLONE, which is the whole of the
# place-not-link conversion. A departed package installs from
# ~/.cache/tackup/pkgs/<pkg>, which is re-cloned on every sweep and wiped on
# demand, so a link into it dangles the moment that happens: two were dangling
# on a live box before this, left by tools retired on 2026-09-01.
PAY=$SHR/vigilance
for _t in "$HERE"/bin/*; do _n=$(basename "$_t")
  [ "$(readlink "$BIN/$_n")" = "$PAY/bin/$_n" ] \
    || fail "$_n links to '$(readlink "$BIN/$_n")' rather than into the
payload at $PAY/bin/$_n: a link into the source tree is what this removes"
done
[ -e "$SHR/man/man1/vigilance.1" ] || fail "man page not linked"
[ -d "$PAY" ] && [ ! -L "$PAY" ] \
  || fail "the payload at $PAY is not a real directory"

# AND THE PLUGINS CAN STILL FIND THE COMMAND, which is this package's own
# invariant and the one a reader is most likely to break. `bin/vigilant` reads
# no libexec at all; it is the PLUGINS that locate the COMMAND, each resolving
# its own real path and walking up: a hook sources `../hook_lib`, and a trigger
# or provider execs `../../../bin/vigilant`. So bin and libexec must sit at that
# exact relative depth INSIDE the payload.
#
# DROPPING bin/ FROM THE PAYLOAD WOULD LOOK HARMLESS, since `vigilant` is also
# published system-wide, and it would silently disable every hook: `_hooks_in`
# lists a hook only `if [ -x ]`, so a plugin that cannot resolve its dependency
# does not fail, it stops existing.
[ -x "$PAY/bin/vigilant" ] \
  || fail "no $PAY/bin/vigilant, so every trigger and provider in the payload
resolves its command to nothing"
[ -r "$PAY/lib/hook_lib" ] \
  || fail "no hook_lib in the payload, so every shipped hook exits 2"
# Proven by RUNNING one through the payload path, not by checking the files are
# adjacent: the hook sources hook_lib by a relative path and only an execution
# shows that the path resolves.
env VIGILANCE_KIND=verify VIGILANCE_EDGE=sleep \
    VIGILANCE_SYS_BACKLIGHT="$T/nobl" VIGILANCE_SCREEN_LUMA=0 \
    VIGILANCE_SCREEN_PEAK=0 \
    sh "$PAY/libexec/hooks/screen-dark" sleep >/dev/null 2>&1 \
  || fail "a shipped hook could not run from inside the payload, so its
relative source of hook_lib does not resolve there"
[ -e "$CFG/systemd/user/vigilance-logind.service" ] \
  && fail "install linked the --user unit (should be service-only)"
# Same for the supervision timer: `install` is bin + man, nothing that runs.
for _u in vigilance-enforce.service vigilance-enforce.timer \
         vigilance-audit.service vigilance-audit.timer \
         vigilance-idle.service; do
  [ -e "$CFG/systemd/user/$_u" ] \
    && fail "install linked $_u; units belong to the service verb"
done

# libexec: the shipped hooks are installed AVAILABLE...
[ -x "$PAY/libexec/providers/swaylock" ] \
  || fail "a shipped provider is not reachable through the install"
# ...AND THE STRUCK ROOT IS NOT RECREATED. `~/.local/libexec/<pkg>` is gone as a
# concept: it was a symlink into the clone, so it dangled on every re-clone, and
# an install that recreates it puts the violation straight back.
[ -e "$T/libexec/vigilance" ] \
  && fail "install recreated the struck root at $T/libexec/vigilance; the
payload carries the plugins now"
# ...and never WIRED. A hook that shipped pre-enabled would be vigilance
# deciding policy, which is exactly what mute-on-lock was moved out to avoid.
for _e in lock sleep suspend unlock wake resume; do
  [ -e "$CFG/vigilance/hooks/$_e.d" ] \
    && fail "install wired $_e.d; which hooks run is the integrator's call"
done

# check runs (tools are on the sandbox PATH via BIN).
#
# VIGILANCE_CHECK_PATH scopes the one-command-one-PATH-entry assertion to the
# SANDBOX. Without it that check reads the developer's real PATH and fails on
# whatever their box happens to have installed: a verdict about the host rather
# than about this install. Set to the sandbox bindir alone, so the
# assertion is both meaningful and about the thing under test.
# AND THE SYSTEM UNIT DIRS ARE SANDBOXED for the same reason as PATH above:
# _check_units falls back to /etc/systemd/user when this prefix has no copy, so
# without these the check reads the HOST's units and renders a verdict about the
# developer's box. Caught the moment the ExecStart assertion was added: a
# scratch install reported the host's real broken logind unit.
PATH="$BIN:$PATH" VIGILANCE_CHECK_PATH="$BIN" \
  VIGILANCE_SYS_USER_UNITS="$T/sysuser" VIGILANCE_SYS_UNITS="$T/sys" \
  run check >"$T/check.out" 2>&1 || { cat "$T/check.out" >&2
    fail "check failed post-install"; }

# AND IT MUST NOT REACH PAST ITS OWN SEAM. `check` used to test for
# `~/.config/shapes` and WARN when it was absent. That tree belongs to the
# INTEGRATOR (it carries mako and wallpaper config too) and nothing in this
# package reads it: measured, those were the only three `shapes` references in
# the whole shipped tree. So every box that is not one specific fleet carried a
# permanent warning about a directory it has no reason to own, which is the
# always-on warning that makes a report stop being read.
if grep -qi 'shapes' "$T/check.out"; then
  cat "$T/check.out" >&2
  fail "check mentions 'shapes' again. That path is the integrator's, not
this package's, and asserting it warns forever on any other setup"
fi

# THE SEAM THAT DOES EXIST is `vigilance-lock-argv`, the optional helper the
# provider asks for locker-specific arguments, and its ABSENCE is a supported
# configuration rather than a gap. Asserted as "never a WARN about it", which
# is structural here because both branches are `ok`: whichever one this sandbox
# takes, a reintroduced warning is the regression worth catching.
if grep -iE '\[WARN\].*(lock argv|lock-argv|plain lock)' "$T/check.out"; then
  fail "the lock argv helper was reported as a WARNING. Not supplying an
optional helper is intent, not a fault, and the provider's plain-lock fallback
is deliberate"
fi
grep -q 'vigilance-lock-argv' "$T/check.out" \
  || { cat "$T/check.out" >&2
       fail "check says nothing about the lock argv helper either way. The
point of the change was to report the seam this package HAS, not to go quiet"; }

# uninstall: the bin + man symlinks are removed
run uninstall >/dev/null 2>&1 || fail "uninstall errored"
for _t in "$HERE"/bin/*; do _n=$(basename "$_t")
  [ -e "$BIN/$_n" ] && fail "$_n symlink not removed"; done
[ -e "$SHR/man/man1/vigilance.1" ] && fail "man page not removed"
[ -e "$T/libexec/vigilance" ] && fail "libexec hooks link not removed"
# AND THE PAYLOAD GOES WITH IT. It is the only directory this install creates,
# so leaving it behind would make uninstall a half-measure and the next install
# a swap against a tree nobody owns.
[ -e "$PAY" ] && fail "uninstall left the payload at $PAY"

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
[ -f "$T/copy/libexec/hooks/ddc-monitor" ] \
  || fail "copy mode did not copy the plugin tree"
# A RETIRED UNIT'S ENABLE LINK IS SWEPT, by name and only when it dangles.
# Found live: default.target.wants/smart-trigger.service pointed at a unit
# retired with the tool on 2026-09-01 and nothing had ever removed it.
mkdir -p "$CFG/systemd/user/default.target.wants"
ln -sfn /nonexistent/smart-trigger.service \
  "$CFG/systemd/user/default.target.wants/smart-trigger.service"
# AND A LIVE ONE IS SPARED, which is the half that matters: a generic sweep of
# dangling .wants links would remove this package's OWN logind enable link
# whenever the privileged tree is mid-reinstall, silently disabling the
# lid-close lock. Modelled with a link whose target exists.
: > "$CFG/systemd/user/vigilance-logind.service"
ln -sfn "$CFG/systemd/user/vigilance-logind.service" \
  "$CFG/systemd/user/default.target.wants/vigilance-logind.service"
run install >/dev/null 2>&1 || :   # the retirement sweep is on INSTALL
[ -h "$CFG/systemd/user/default.target.wants/smart-trigger.service" ] \
  && fail "the retired unit's enable link survived; it outlives the package and
reads as an enabled unit to anyone looking"
# NAME-SCOPED: nothing but the two retired names is considered at all, which is
# what keeps this away from the package's own enable links.
[ -h "$CFG/systemd/user/default.target.wants/vigilance-logind.service" ] \
  || fail "the sweep reached a name it was not given. A generic one would
remove this link whenever the privileged tree is mid-reinstall, silently
disabling the Session.Lock listener, which is the lid-close lock"
# AND THE DANGLE GUARD IS REAL, tested on the case it is actually for: a
# RETIRED name whose unit exists anyway, which means an integrator wrote their
# own under that name. Ours is gone, so a file there is not ours to delete.
: > "$CFG/systemd/user/smart-trigger.service"
ln -sfn "$CFG/systemd/user/smart-trigger.service" \
  "$CFG/systemd/user/default.target.wants/smart-trigger.service"
run install >/dev/null 2>&1 || :
[ -h "$CFG/systemd/user/default.target.wants/smart-trigger.service" ] \
  || fail "swept a retired-name enable link whose unit EXISTS. The name is
retired for US; a file an integrator put there under it is theirs"
rm -f "$CFG/systemd/user/default.target.wants/smart-trigger.service" \
  "$CFG/systemd/user/smart-trigger.service"

# THE PRIVILEGED BRANCH, WHICH THIS TEST CANNOT EXECUTE, so it is asserted
# STATICALLY instead. copy-mode install chowns the tree root:root and strips
# group/other write, because a greeter executes those hooks and the login user
# must not be able to rewrite them. That runs only under `id -u` = 0, so a test
# running as a user reaches `cp` and never `chown`. That is exactly how the
# flattening shipped a chown still naming the vacated libexec/<pkg> path. The
# install then died on `chown: cannot access` and took tackup's lock phase with
# it, on a real box, with this suite green.
#
# ASSERTED AS "the same variable the copy used", not as "not the old path": a
# chown of a SEPARATELY WRITTEN path is the defect, whatever that path says
# today, and one variable for cp, chown and chmod cannot drift from itself.
# Anchored on the comment unique to this block, not on the INSTALL_COPY test:
# that test appears four times (here, _place, uninstall, check) and a range from
# the first one lands in _place.
_cpblk=$(sed -n '/THE .cp -a. TRAP _place DOCUMENTS/,/^      done$/p' \
         "$HERE/setup.sh")
[ -n "$_cpblk" ] || fail "premise: cannot extract the copy-mode install block"
printf '%s' "$_cpblk" | grep -q 'cp -a "$_root/$_cd" "$_cnew"' \
  || fail "copy-mode install no longer stages through \$_cnew, so the checks
below cannot tell whether the hardening follows the copy"
for _pv in chown chmod; do
  _tgts=$(printf '%s' "$_cpblk" | grep -E "^\s*(if ! )?$_pv -R " \
          | grep -oE '"\$[A-Za-z_]+"' | sort -u)
  [ -n "$_tgts" ] || fail "copy-mode install has no $_pv -R: the privileged
hardening that keeps a greeter-executed hook out of the login user's reach is
gone, and no test here can execute that branch to notice"
  [ "$_tgts" = '"$_cnew"' ] \
    || fail "copy-mode $_pv -R targets $_tgts, not \"\$_cnew\" (the path the
copy stages into). Hardening a path the copy did not write is what broke when
the tree flattened; hardening the LIVE tree instead would also defeat the
staging, since the point is that nothing touches it until the swap."
done
# AND THE LIVE TREE IS NOT DESTROYED BEFORE THE STAGE, which is the atomicity
# property itself and is checkable without root. The old form was `rm -rf` then
# `cp` straight onto the live path, so a failure anywhere in the copy left the
# box with no working tree at all; that is precisely what happened on
# 2026-10-03 and left /opt flat while the units still named the old layout.
printf '%s' "$_cpblk" | grep -qE '^\s*rm -rf -- "\$_cdst"' \
  && fail "copy-mode install removes the LIVE tree (\$_cdst) directly, so a
failure partway leaves no working tree. Stage into \$_cnew and swap."

[ -f "$T/copy/lib/hook_lib" ] \
  || fail "copy mode did not copy lib/, so every plugin exits 2 unable to
source hook_lib"
[ -L "$T/copy/libexec" ] \
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
[ -e "$T/copy/libexec/libexec" ] || [ -e "$T/copy/lib/lib" ] \
  && fail "re-copy nested a tree inside itself"

crun uninstall >/dev/null 2>&1 || fail "copy uninstall errored"
[ -e "$CBIN/vigilant" ] && fail "copy uninstall left vigilant behind"
[ -d "$T/copy/libexec" ] && fail "copy uninstall left the libexec tree behind"
[ -d "$T/copy/lib" ] && fail "copy uninstall left the lib tree behind"

pass "install + check + uninstall + copy mode"
