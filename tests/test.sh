#!/bin/bash
# Tests for hooks/needs-you.sh and bin/nb-autopilot.
#
# Fake terminal-notifier, osascript and open come first on PATH, and HOME points
# at a temp folder. Nothing shows on screen and no real state is touched.
# Usage: bash tests/test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/needs-you.sh"
AP="$ROOT/bin/nb-autopilot"
WORK=$(mktemp -d /tmp/needs-you-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
FAIL=0

cat > "$WORK/bin/terminal-notifier" <<'EOF'
#!/bin/bash
echo "BANNER $*" >> "$FAKE_LOG"
exit "${FAKE_BANNER_EXIT:-1}"
EOF
cat > "$WORK/bin/osascript" <<'EOF'
#!/bin/bash
# After "--" come the title, the message and the button labels.
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
title="$1"; msg="$2"; labels=$(( $# - 2 ))
echo "SHOW [$title] $msg (labels: $labels)" >> "$FAKE_LOG"
trap 'echo "CLOSED $msg" >> "$FAKE_LOG"; exit 143' TERM
sleep "${FAKE_DIALOG_SECS:-3}" &
wait $!
printf '%s\n' "${FAKE_ANSWER:-Later}"
EOF
cat > "$WORK/bin/open" <<'EOF'
#!/bin/bash
echo "OPEN $*" >> "$FAKE_LOG"
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

# A fresh home per scenario. By default the session is a desktop-app session
# named "my-app | checkout bug".
setup() {
  export HOME="$WORK/$1" FAKE_LOG="$WORK/$1.log"
  export CLAUDE_CODE_HOST_SESSION_ID="local_test"
  unset FAKE_BANNER_EXIT FAKE_DIALOG_SECS FAKE_ANSWER
  mkdir -p "$HOME/Library/Application Support/Claude/claude-code-sessions/acct/org"
  echo '{"title":"my-app | checkout bug"}' \
    > "$HOME/Library/Application Support/Claude/claude-code-sessions/acct/org/local_test.json"
  : > "$FAKE_LOG"
}
ask() {
  jq -nc --arg q "$1" '{hook_event_name:"PreToolUse", tool_name:"AskUserQuestion",
    session_id:"cli-1", cwd:"/work/my-repo", tool_input:{questions:[{question:$q}]}}'
}
fire() { ask "$1" | "$HOOK"; }
expect() {  # name, fixed string to count in the log, wanted count
  local got
  got=$(grep -c -F -- "$2" "$FAKE_LOG")
  if [ "$got" = "$3" ]; then echo "PASS $1"
  else echo "FAIL $1: '$2' x$got, want $3"; cat "$FAKE_LOG"; FAIL=1; fi
}
check() {  # name, text, fixed string, 1 = must be present / 0 = must be absent
  local got=0
  printf '%s' "$2" | grep -q -F -- "$3" && got=1
  if [ "$got" = "$4" ]; then echo "PASS $1"
  else echo "FAIL $1: '$3' present=$got, want $4"; printf '%s\n' "$2"; FAIL=1; fi
}

# --- Needs You ---------------------------------------------------------------

# A newer request replaces the dialog on screen; it is never dropped.
setup newer
fire "Question A"; sleep 1; fire "Question B"; sleep 6
expect newer-shown "] Question B" 1
expect older-closed "CLOSED Question A" 1
expect title-from-app "SHOW [Claude needs you: my-app | checkout bug]" 2

# A lock left by a crashed dialog does not swallow new requests.
setup stale
mkdir -p "$HOME/Library/Caches/needs-you/dialog-local_test.lock"
touch -t 202601010000 "$HOME/Library/Caches/needs-you/dialog-local_test.lock"
fire "Question C"; sleep 5
expect stale-lock "] Question C" 1

setup dead-owner
mkdir -p "$HOME/Library/Caches/needs-you/dialog-local_test.lock"
echo 999999 > "$HOME/Library/Caches/needs-you/dialog-local_test.lock/pid"
fire "Question D"; sleep 5
expect dead-owner "] Question D" 1

# "Open" opens that exact session.
setup open
export FAKE_ANSWER="Open" FAKE_DIALOG_SECS=1
fire "Question E"; sleep 3
expect open-link "OPEN claude://claude.ai/epitaxy/local_test" 1

# The same request twice within 2 minutes shows once.
setup dedupe
export FAKE_DIALOG_SECS=1
fire "Question F"; sleep 2; fire "Question F"; sleep 2
expect dedupe "] Question F" 1

# When the banner works, there is no dialog.
setup banner
export FAKE_BANNER_EXIT=0
fire "Question G"; sleep 2
expect banner-sent "BANNER" 1
expect banner-links-session "-open claude://claude.ai/epitaxy/local_test" 1
expect banner-no-dialog "SHOW" 0

# A burst ends on the latest request and leaves nothing behind.
setup burst
export FAKE_DIALOG_SECS=2
fire "Question H1"; sleep 0.5; fire "Question H2"; sleep 0.5; fire "Question H3"; sleep 6
expect burst-latest "] Question H3" 1
left=$(find "$HOME/Library/Caches/needs-you" -maxdepth 1 \( -name 'dialog-*' -o -name 'closing-*' \) | wc -l | tr -d ' ')
if [ "$left" = 0 ]; then echo "PASS no-leftovers"; else echo "FAIL no-leftovers: $left"; FAIL=1; fi

# A terminal session: titled by its folder, no link, one button, its own lock.
setup terminal
unset CLAUDE_CODE_HOST_SESSION_ID
export FAKE_DIALOG_SECS=1
fire "Question I"; sleep 3
expect terminal-title "SHOW [Claude needs you: my-repo] Question I (labels: 0)" 1
expect terminal-no-open "OPEN" 0
expect terminal-banner-no-link "-open" 0

# Other events.
setup events
export FAKE_DIALOG_SECS=1
echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}' | "$HOOK"; sleep 2
expect plan "] A plan is waiting for your approval" 1
echo '{"hook_event_name":"PermissionDenied","tool_name":"Bash","agent_id":"sub-1"}' | "$HOOK"; sleep 2
expect subagent-denial-silent "Blocked" 0
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"recap":"done"}}' | "$HOOK"); sleep 1
check wrap-up-without-question-silent "$out$(cat "$FAKE_LOG")" "recap" 0
out=$(echo 'not json' | "$HOOK"; echo "exit=$?")
check garbage-input-is-harmless "$out" "exit=0" 1

# --- Autopilot ---------------------------------------------------------------

setup autopilot
export FAKE_DIALOG_SECS=1
check ap-on "$("$AP" on 23:59)" "Autopilot ON until" 1
check ap-status-on "$("$AP" status)" "Autopilot ON until" 1

Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Which path?","options":[{"label":"Path A"},{"label":"Path B (Recommended)"}]},
  {"question":"Which name?","options":[{"label":"alpha"},{"label":"beta"}]}]}}'
out=$(printf '%s' "$Q" | "$HOOK"); sleep 2
check ap-deny "$out" '"permissionDecision": "deny"' 1
check ap-picks-recommended "$out" "Which path? -> Path B (Recommended)" 1
check ap-else-first-option "$out" "Which name? -> alpha" 1
check ap-names-exceptions "$out" "Never decide these yourself" 1
expect ap-no-popup "SHOW" 0
expect ap-no-banner "BANNER" 0

# "not recommended" inside a label is not the marker.
Q='{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[
  {"question":"Drop the old table?","options":[{"label":"Keep it"},{"label":"Drop it now (not recommended)"}]}]}}'
out=$(printf '%s' "$Q" | "$HOOK")
check ap-not-recommended-is-not-picked "$out" "Drop the old table? -> Keep it" 1

W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Run the slow tests too?","actions":[{"label":"Yes, run them"},{"label":"No"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-end-of-turn "$out" "Run the slow tests too? -> Yes, run them" 1
check ap-end-of-turn-names-exceptions "$out" "Never decide these yourself" 1
check ap-exceptions-cover-merging "$out" "merging, pushing or deploying" 1

# An end-of-turn question whose first answer is an app action (merge, commit,
# open a pull request) is a go-ahead for the owner: autopilot never takes it.
W='{"hook_event_name":"PreToolUse","tool_name":"mcp__ccd_turn__wrap_up","tool_input":{"ask":"Merge the pull request?","actions":[{"action":"merge"}]}}'
out=$(printf '%s' "$W" | "$HOOK")
check ap-app-action-denied "$out" '"permissionDecision": "deny"' 1
check ap-app-action-left-for-owner "$out" "do not take that step" 1
check ap-app-action-not-taken "$out" "Act on your recommended answer now" 0

# Autopilot never answers a permission prompt or a plan: those still pop up.
out=$(echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}' | "$HOOK"); sleep 2
check ap-permission-not-answered "$out" "permissionDecision" 0
expect ap-permission-pops-up "] Permission needed: Bash" 1
out=$(echo '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}' | "$HOOK"); sleep 2
check ap-plan-not-answered "$out" "permissionDecision" 0
expect ap-plan-pops-up "] A plan is waiting for your approval" 1

report=$("$AP" report)
check ap-report-question "$report" "Which path? -> Path B (Recommended)" 1
check ap-report-end-of-turn "$report" "Run the slow tests too? -> Yes, run them" 1
check ap-report-left-for-owner "$report" "Merge the pull request? -> left for the owner (merge)" 1
check ap-report-session "$report" "my-app | checkout bug" 1

# Switching on again keeps the start of the report; off keeps the report.
since=$(jq -r .since_epoch "$HOME/.claude/needs-you/autopilot.json")
sleep 1; "$AP" on 23:58 >/dev/null
check ap-on-again-keeps-start "$(jq -r .since_epoch "$HOME/.claude/needs-you/autopilot.json")" "$since" 1
check ap-off "$("$AP" off)" "Autopilot OFF" 1
check ap-status-off "$("$AP" status)" "Autopilot OFF" 1
check ap-report-after-off "$("$AP" report)" "Which path?" 1
out=$(fire "Question after autopilot"); sleep 2
check ap-off-no-deny "$out" "permissionDecision" 0
expect ap-off-popup "] Question after autopilot" 1

"$AP" on 25:00 >/dev/null 2>&1
check ap-rejects-bad-time "exit=$?" "exit=2" 1
check ap-doctor "$("$AP" doctor)" "ok       jq" 1

# A failed write is reported, not hidden behind "Autopilot OFF".
"$AP" on 23:59 >/dev/null
chmod 500 "$HOME/.claude/needs-you"
out=$("$AP" off 2>&1; echo "exit=$?")
chmod 700 "$HOME/.claude/needs-you"
check ap-off-failure-is-reported "$out" "could not write" 1
check ap-off-failure-exit-code "$out" "exit=1" 1
"$AP" off >/dev/null

# An end time more than a day away is not a real setting: autopilot is off.
setup far-future
export FAKE_DIALOG_SECS=1
mkdir -p "$HOME/.claude/needs-you"
echo '{"until_epoch":99999999999,"since_epoch":0,"until":"never"}' > "$HOME/.claude/needs-you/autopilot.json"
out=$(fire "Question with a forged end time"); sleep 2
check far-future-no-deny "$out" "permissionDecision" 0
expect far-future-popup "] Question with a forged end time" 1
check far-future-status-off "$("$AP" status)" "Autopilot OFF" 1

# A long question is cut by characters, not bytes: a letter outside ASCII at the
# cut stays whole even when the hook runs in the C locale, as it does in the app.
setup non-ascii
export FAKE_DIALOG_SECS=1
long=$(printf 'x%.0s' $(seq 1 179))
ask "${long}ąęść and the rest of a long question" | LC_ALL=C "$HOOK"; sleep 2
expect non-ascii-cut-on-a-character "${long}ą (labels: 2)" 1
if iconv -f UTF-8 -t UTF-8 "$FAKE_LOG" >/dev/null 2>&1; then echo "PASS non-ascii-valid-utf8"
else echo "FAIL non-ascii-valid-utf8"; FAIL=1; fi

# An expired autopilot is off.
setup expired
export FAKE_DIALOG_SECS=1
mkdir -p "$HOME/.claude/needs-you"
echo '{"until_epoch":1,"since_epoch":0,"until":"past"}' > "$HOME/.claude/needs-you/autopilot.json"
out=$(fire "Question after the end time"); sleep 2
check expired-no-deny "$out" "permissionDecision" 0
expect expired-popup "] Question after the end time" 1
check expired-report-empty "$("$AP" report)" "No autopilot decisions." 1

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
