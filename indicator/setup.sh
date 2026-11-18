#!/bin/sh
# setup.sh - set up vigilance-indicator (the SNI tray icon for who is keeping
# the screen awake) for the CURRENT user. An integrator reaches it through the
# package's own `setup.sh indicator [verb]`, so the steps are identical whether
# or not one drives it. It is OPTIONAL: vigilance works fully without it.
#
#   setup.sh install     build the app env + install & enable the service
#   setup.sh app         just the app: an isolated venv + a ~/.local/bin link
#   setup.sh service     just the systemd --user unit (install, enable, start)
#   setup.sh check       verify the install ([OK]/[FAIL] markers)
#   setup.sh uninstall   remove the unit + the ~/.local/bin link
#
# All userspace: NO sudo. Idempotent. Needs python3 and, for the service, a
# systemd --user manager; a tray HOST (waybar's tray, or any desktop's) and
# `vigilant` on PATH are runtime needs.
# Overrides:
#   VI_VENV   venv dir   (default ~/.local/share/vigilance/venv-indicator)
#   VI_BIN    bin dir    (default ~/.local/bin)
#   VI_SKIP_BUILD  adopt an existing venv (a test's stub) instead of pip
set -eu

self=$0
case $self in */*) ;; *) self=$(command -v -- "$self" || echo "$self") ;; esac
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)

# THE VENV LIVES IN vigilance'S PAYLOAD, per the fleet place-not-link rule, and
# the core's payload swap carries `venv*` across, so a core install does not
# delete the tray's environment.
VENV=${VI_VENV:-${XDG_DATA_HOME:-$HOME/.local/share}/vigilance/venv-indicator}
BIN_DIR=${VI_BIN:-$HOME/.local/bin}
APP=vigilance-indicator
UNIT=$APP.service
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

# Install WITHOUT writing into the source: pip builds in tree, and a deployed
# clone may be root-owned. Copied from usher's, deliberately: the two
# installers share no library. The scratch dir is checked before any rm.
_pip_from_copy() {
  _pc_v=$1 _pc_s=$2
  _pc_t=$(mktemp -d) || return 1
  case $_pc_t in
  /*/*) ;;
  *) echo "$APP: refusing a scratch dir at '$_pc_t'" >&2; return 1 ;;
  esac
  _pc_rc=0
  cp -R "$_pc_s/." "$_pc_t/" \
    && chmod -R u+w "$_pc_t" \
    && "$_pc_v/bin/pip" install -q "$_pc_t" \
    && "$_pc_v/bin/pip" install -q --force-reinstall --no-deps "$_pc_t" \
    || _pc_rc=$?
  rm -rf -- "$_pc_t"
  return "$_pc_rc"
}

app() {
  if [ -z "${VI_SKIP_BUILD:-}" ]; then
    mkdir -p "$(dirname "$VENV")"
    [ -d "$VENV" ] || python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
    _pip_from_copy "$VENV" "$PKG_DIR"
  fi
  mkdir -p "$BIN_DIR"
  ln -sfn "$VENV/bin/$APP" "$BIN_DIR/$APP"
  echo "$APP: app -> $BIN_DIR/$APP (venv $VENV)"
}

service() {
  mkdir -p "$UNIT_DIR"
  install -m 0644 "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "$UNIT" 2>/dev/null || true
  # restart, not just enable --now, so a re-run picks up a code change; a
  # headless install (no user bus yet) falls through to the next login.
  systemctl --user restart "$UNIT" 2>/dev/null || true
  echo "$APP: service $UNIT installed + enabled"
}

uninstall() {
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT" "$BIN_DIR/$APP"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "$APP: uninstalled (venv $VENV left in place)"
}

# INSTALLED is the unit or the link existing; the core's own `check` asks this
# so it says nothing at all on a box that chose not to have the tray.
installed() {
  [ -e "$UNIT_DIR/$UNIT" ] || [ -e "$BIN_DIR/$APP" ] || [ -L "$BIN_DIR/$APP" ]
}

check() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _e=$(printf '\033')
    _G="$_e[1;32m"; _R="$_e[1;31m"; _O="$_e[0m"
  else _G=; _R=; _O=; fi
  RC=0
  ok()  { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$*"; }
  bad() { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$*"; RC=1; }

  if [ -x "$VENV/bin/$APP" ]; then ok "indicator venv app ($VENV)"
  else bad "indicator venv app missing ($VENV); run: indicator install"; fi
  if "$VENV/bin/python" -c 'import dbus_next, PIL' 2>/dev/null
  then ok "indicator deps import (dbus-next, Pillow)"
  else bad "indicator deps not importable in the venv"; fi
  # CURRENT, not merely present: the code lives in the venv, copied at install,
  # so a pull of the source changes nothing that runs. An integrator that
  # reinstalls only when this check fails would otherwise never deploy a
  # change to the tray at all.
  _site=$("$VENV/bin/python" -c 'import os, vigilance_indicator as m
print(os.path.dirname(m.__file__))' 2>/dev/null || true)
  if [ -z "$_site" ]; then
    bad "indicator package not importable in the venv; run: indicator install"
  else
    _stale=
    for _f in "$PKG_DIR"/vigilance_indicator/*.py; do
      cmp -s "$_f" "$_site/${_f##*/}" || _stale="$_stale ${_f##*/}"
    done
    if [ -z "$_stale" ]; then ok "indicator code current with its source"
    else bad "indicator code stale ($_stale ); run: indicator install"; fi
  fi
  if [ -x "$BIN_DIR/$APP" ]; then ok "indicator $BIN_DIR link"
  else bad "indicator $BIN_DIR/$APP missing"; fi
  if cmp -s "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT" 2>/dev/null
  then ok "$UNIT current"; else bad "$UNIT missing or stale"; fi
  # RUNNING, not merely enabled: a tray icon nobody can see is the state this
  # line exists to tell apart from a working one.
  _st=$(systemctl --user is-active "$UNIT" 2>/dev/null || true)
  if [ "$_st" = active ]; then ok "$UNIT running"
  else bad "$UNIT installed but not running (${_st:-unknown})"; fi
  return "$RC"
}

case "${1:-install}" in
  install)   app; service ;;
  app)       app ;;
  service)   service ;;
  check)     check ;;
  installed) installed ;;
  uninstall) uninstall ;;
  *) echo "usage: setup.sh [install|app|service|check|uninstall]" >&2
     exit 2 ;;
esac
