#!/bin/sh
# test/triggers.t - can a hardware gesture reach the ladder, and does report
# say so when it cannot.
#
# WHAT THIS IS ABOUT. A lock request arriving from the hardware (a lid closing,
# a power button) is wired through logind, and a desktop power manager takes a
# BLOCK inhibitor on those handlers so it can implement its own policy. logind
# then logs the event and acts on nothing, so the gesture SILENTLY cannot reach
# the ladder while every piece of wiring reads as correct. Measured in the xfce
# guest, where xfce4-power-manager holds all four handlers.
#
# THREE OUTCOMES, and the test owes an assertion to each, because the value is
# in telling them apart rather than in any one of them:
#
#   gesture present, uninhibited     OK
#   gesture present, inhibited       WARN, naming the handler
#   gesture absent                   INFO, and deliberately not a warning
#
# THE LAST ONE IS THE CRY-WOLF GUARD and it is the half most likely to rot. A
# desktop keeps its default lid policy and a display manager inhibits the
# handler anyway, so without a lid-presence test this section would warn on
# every desktop forever, which is how a report stops being read. This project
# has been bitten by an always-on warning three times, so the no-lid case is
# asserted as hard as the finding itself.
#
# SCOPED TO THE SECTION, never to report's exit code: that folds in a dozen
# sections and several read the real host, so a test keying on the whole status
# passes for free wherever the host is red and keeps passing with the check it
# claims to cover deleted. Fifth time this suite has paid for that.
set -eu
. "$(dirname "$0")/harness_lib"
. "$(dirname "$0")/scenario_lib"
scenario_init triggers

# A sysfs input tree we own, so the lid question is answered by a FIXTURE and
# never by the developer's own laptop, which has one and would make the no-lid
# case unreachable here.
SYSIN=$T/sys-input
mkdir -p "$SYSIN"
VIGILANCE_SYS_INPUT=$SYSIN; export VIGILANCE_SYS_INPUT

_dev() {   # <name> <sw-hex>: an input device advertising that switch bitmap
  mkdir -p "$SYSIN/$1/capabilities"
  printf '%s\n' "$2" > "$SYSIN/$1/capabilities/sw"
}

# THE SECTION ALONE. `report` prints a dozen of them and `machinery` reads the
# real systemd, so anything wider is a verdict about the host.
_sec() {   # -> the triggers section only
  "$VIGILANT" report 2>/dev/null \
    | awk '/^-- triggers --$/ { f = 1; next } /^-- / { f = 0 } f' || true
}

# --- 1. NO GESTURE AT ALL is INFO, not a warning ----------------------------
# A headless server and this guest have nothing to lose, and the ladder is
# reached there by timer and by command.
VIGILANCE_SWITCH_DEVICES='' ; export VIGILANCE_SWITCH_DEVICES
VIGILANCE_BLOCK_INHIBITED='' ; export VIGILANCE_BLOCK_INHIBITED
_o=$(_sec)
case "$_o" in
  *'[--]'*'no hardware gesture'*) ;;
  *) fail "with no power-switch device the section should report INFO and say
the ladder is reached by timer and command only, got:
$_o" ;;
esac
case "$_o" in
  *'[WARN]'*) fail "a machine with no gesture produced a WARNING. There is
nothing to fix on such a box, and a warning that fires on every headless server
forever is how a report stops being read:
$_o" ;;
esac

# --- 2. A GESTURE PRESENT AND UNINHIBITED is OK -----------------------------
VIGILANCE_SWITCH_DEVICES='event0
event1'
_o=$(_sec)
case "$_o" in
  *'[OK]'*'2 device(s) tagged power-switch'*) ;;
  *) fail "two gesture devices and nothing inhibited should be OK and should
COUNT them, got:
$_o" ;;
esac

# --- 3. INHIBITED, WITH A LID PRESENT, is the finding -----------------------
# SW_LID is bit 0 of the `sw` capability, so an odd last hex digit means a lid.
_dev lid-ish 1
VIGILANCE_BLOCK_INHIBITED='handle-power-key:handle-lid-switch'
_o=$(_sec)
case "$_o" in
  *'[WARN]'*handle-lid-switch*) ;;
  *) fail "handle-lid-switch is block-inhibited and a lid is present, which is
the whole finding: logind logs the close and acts on nothing. Expected a WARN
naming the handler, got:
$_o" ;;
esac
# THE HANDLER MUST BE NAMED, because the operator's remedy is at that handler
# and "a gesture is unreachable" sends them hunting. The same reason the DDC
# drift check names the bus.
case "$_o" in
  *handle-power-key*) ;;
  *) fail "handle-power-key is inhibited too and was not reported. Reporting
one inhibited handler and silently dropping another is worse than reporting
neither, because it reads as a complete answer:
$_o" ;;
esac

# --- 3b. THE HOLDER IS A FIELD, NOT A SUBSTRING OF THE LINE -----------------
# `_trig_holder` matched the whole ROW, so the WHY prose counted as readily as
# the WHAT column. For a short handler name that is not a corner case:
# MEASURED on this fleet with NO idle inhibitor held at all, asking for `idle`
# answered "swayidle", because the row reads "Swayidle is preventing sleep".
# The inhibit-bound alert was about to use that, and would have named
# vigilance's OWN idle timer as the thing to go and kill.
#
# STUBBED, which also stops this case reading the developer's real inhibitors:
# the holder half was previously exercised by nothing, so whatever the host
# happened to be holding leaked into the message while no assertion looked.
mkdir -p "$T/ibin"
#
# THE DECOY'S WHY CARRIES THE HANDLER AS A STANDALONE WORD, which is the case
# that matters and the one a bare field match still gets wrong: for `idle` it
# is thoroughly ordinary ("Inhibiting idle while playing video"). Only locating
# the WHAT column answers it.
cat > "$T/ibin/systemd-inhibit" <<'EOF'
#!/bin/sh
echo "WHO UID USER PID COMM WHAT WHY MODE"
echo "decoyproc 1000 jello 111 dec sleep handle-lid-switch yes block"
echo "realholder 1000 jello 222 rea sleep:handle-lid-switch why block"
EOF
chmod +x "$T/ibin/systemd-inhibit"
# INHERITING case 3's inhibitor string ON PURPOSE, rather than setting one.
# Narrowing it here left case 4 asserting about a power key that was no longer
# inhibited, and it failed two cases later with a message about the section
# being switched off. A case that changes shared state its neighbours read is
# not a case, which is the trap this file's own header warns about.
_o=$(PATH=$T/ibin:$PATH; export PATH; _sec)
case "$_o" in
  *realholder*) ;;
  *) fail "the holder whose WHAT column IS the handler was not named. A
colon-joined WHAT ('sleep:handle-lid-switch') is how logind reports an
inhibitor taking several handlers, so matching it per element is the whole
point:
$_o" ;;
esac
case "$_o" in
  *decoyproc*) fail "a row that merely MENTIONS the handler in its WHY prose was
reported as holding it. That is the measured swayidle case, and it points the
operator at the wrong process, which is worse than naming none:
$_o" ;;
esac

# --- 4. THE CRY-WOLF GUARD: inhibited, NO lid, says nothing about the lid ----
# The same inhibitor string, on a machine whose only switch is an audio jack.
# `sw` NON-ZERO IS NOT A LID: measured on this fleet, HDMI outputs report 0x140
# and a headset jack 0x14, so a naive "has a switch" read would claim a lid on
# every desktop and warn about it forever.
rm -rf "$SYSIN"
mkdir -p "$SYSIN"
_dev hdmi-ish 140
_dev headset-ish 14
_o=$(_sec)
case "$_o" in
  *handle-lid-switch*) fail "there is no lid here (the only switches are an
HDMI output at 0x140 and a headset jack at 0x14, neither with bit 0 set) and the
section still warned about handle-lid-switch. That fires on every desktop
forever, which is the cry-wolf this guard exists to prevent:
$_o" ;;
esac
# ...and the key handler IS still reported, so case 4 is not passing merely
# because the whole section went quiet.
case "$_o" in
  *'[WARN]'*handle-power-key*) ;;
  *) fail "the lid was correctly not warned about, but neither was the
inhibited POWER KEY, so this case would pass with the section switched off
entirely:
$_o" ;;
esac

# --- 5. "I COULD NOT ASK" IS NOT "NOTHING IS INHIBITED" ---------------------
# Both are an empty string from logind, and they are opposite findings. The
# whole n/a contract in this package exists because a tier that could not look
# must never read as one that looked and was satisfied.
#
# A FAILING busctl, PREPENDED, rather than a stripped PATH. The first attempt
# replaced PATH wholesale and the test died on "mkdir: not found", and even
# fixed it would have been wrong: the runner needs a dozen tools, so a failure
# then says nothing about busctl in particular. One shim changes one answer.
#
# AND IT SHIMS A FAILURE, NOT AN ABSENCE, on purpose. An absent busctl is
# already handled by `command -v`; the interesting case is the one that EXISTS
# and cannot answer, because that is the branch where a pipeline's status
# silently became head's. This case found exactly that defect.
unset VIGILANCE_BLOCK_INHIBITED
mkdir -p "$T/nobus"
printf '#!/bin/sh\nexit 1\n' > "$T/nobus/busctl"
chmod +x "$T/nobus/busctl"
_PATH_WAS=$PATH
PATH=$T/nobus:$PATH; export PATH
_o=$(_sec)
PATH=$_PATH_WAS; export PATH
case "$_o" in
  *'UNKNOWN rather than fine'*) ;;
  *) fail "with no busctl the section cannot read logind's inhibitors, and it
must say the reachability is UNKNOWN. An empty BlockInhibited and an
unanswerable one are the same string and opposite findings:
$_o" ;;
esac
case "$_o" in
  *'[OK]'*) fail "the section claimed OK while it could not ask logind
anything. That is 'I could not look' reported as 'I looked and it is fine',
which is the conflation exit 78 exists to break:
$_o" ;;
esac

# ONE OUTPUT LINE, and that is the runner's contract rather than brevity:
# test/run reads the LAST line for the verdict, so an embedded newline buries it
# and the run reports "NO VERDICT: exited 0 without reaching pass or skip".
# Second time in one sitting, the first being skip_now.
#
# THE DISTINCTION IS THE BACKSLASH, which is why several other tests wrap their
# pass message perfectly safely: `"text\` plus a newline is joined by the shell
# into one word, while `"text` plus a newline is a real newline in the string.
# NO STATIC RATCHET for it, deliberately: a quote-counting check flags perf.t,
# whose `$(( ))` legitimately spans lines, and the runner already names this
# exactly when it happens, which is how both instances were found.
pass "absent INFO, present OK, inhibited named, no-lid quiet, unasked not OK"
