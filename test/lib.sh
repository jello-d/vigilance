# test/lib.sh - harness for vigilance's shell tests (test/*.t), sourced by each.
#
# Call `harness_init <name>`: sets HERE (the repo root, so a test reaches
# bin/, install, systemd/), a private scratch dir T (removed on exit), and the
# pass/fail helpers. Everything a test touches is confined to T; nothing outside
# it is written. POSIX sh; run one with `sh test/<name>.t`, all with test/run.
harness_init() {   # <name>
  TEST_NAME=$1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT INT TERM
}
pass() { printf 'ok   %s%s\n' "$TEST_NAME" "${1:+ ($1)}"; }
fail() { printf 'FAIL %s: %s\n' "$TEST_NAME" "$1" >&2; exit 1; }

# require <capability>: declare a substrate need. The stub substrate cannot
# provide systemd/logind/suspend/hardware, so it SKIPS and says so. The VM
# substrate sets SCENARIO_CAPS to the list it can honour.
#
# HERE RATHER THAN IN scenario.sh, because the SESSION tier needs it and wants
# none of scenario.sh's recorder setup. Gating which substrate a test may run
# on is a harness question, not a scenario one.
require() {   # <capability>...
  for _c in "$@"; do
    case " ${SCENARIO_CAPS:-} " in
      *" $_c "*) ;;
      *) printf 'skip %s (needs %s)\n' "$TEST_NAME" "$_c"; SKIPPED=1; exit 0 ;;
    esac
  done
}


# report's EXIT CODE folds in the `-- machinery --` section, which reads the
# HOST's real systemd: whether vigilance's three units are enabled. That is
# legitimately different between substrates, and the suite's own rule forbids
# stubbing systemd to flatten it.
#
# So a test that wants "report saw nothing wrong HERE" must scope to the section
# under test rather than take the whole verdict. The VM tier caught this on its
# first run: rescue.t was green in the stub substrate and red in the VM, failing
# on units it was never testing. Exactly the integration gap two tiers exist to
# expose, and the reason the stub tier alone is not trusted.
#
# Assertions of FAILURE still use the exit code: an extra failure elsewhere
# cannot turn a red verdict green.
_section() {   # <report-output> <section-name>
  printf '%s\n' "$1" | awk -v s="-- $2 --" '
    $0 == s { inside = 1; next } /^-- / { inside = 0 } inside'
}
_no_fail_in() {   # <report-output> <section> <why>
  _sec=$(_section "$1" "$2")
  case "$_sec" in
    *"[FAIL]"*) printf '%s\n' "$_sec" >&2; fail "$3" ;;
  esac
}

# _fail_in: the positive twin, and the reason both exist is that REPORT HAS ONE
# EXIT CODE for nine sections, several of which read the real host (machinery
# asks the live systemd whether vigilance's units are enabled).
#
# So `report ... && fail "it should have failed"` is not an assertion about the
# code under test. It passes for free on any host that is red for an unrelated
# reason, and a test that cannot fail is worse than no test: it reports
# confidence it does not have. greeter.t hit exactly this in the VM.
#
# Scope the claim to the section that owns it. A test about actuators asserts
# about the actuators section, and its verdict is then the same on every
# substrate.
_fail_in() {   # <report-output> <section> <why>
  _sec=$(_section "$1" "$2")
  case "$_sec" in
    *"[FAIL]"*) return 0 ;;
  esac
  printf '%s\n' "$_sec" >&2
  fail "$3"
}
