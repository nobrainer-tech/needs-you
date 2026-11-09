#!/bin/bash
# needs-you: one Claude Code hook, two jobs.
#
#   Needs You   When a session waits for you (a question, a plan to approve, a
#               permission prompt), show a macOS notification. Clicking it opens
#               that exact session in the Claude desktop app.
#   Autopilot   While `nb-autopilot` is on, a question is refused with an
#               instruction to take the session's own recommended answer. Every
#               decision is logged. Permission prompts are never answered.
#
# Reads the hook JSON on stdin. Prints nothing, or a PreToolUse "deny" under
# autopilot. Any failure is silent: this hook must never break a session.
# https://github.com/nobrainer-tech/needs-you

PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
command -v jq >/dev/null 2>&1 || exit 0

HEADLINE="${NEEDS_YOU_TITLE:-Claude needs you}"
OPEN_LABEL="${NEEDS_YOU_OPEN:-Open}"
LATER_LABEL="${NEEDS_YOU_LATER:-Later}"
DATA="$HOME/.claude/needs-you"            # autopilot.json, decisions.jsonl
STATE="$HOME/Library/Caches/needs-you"    # "already shown" marks, dialog locks

INPUT=$(cat)
field() { printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null; }
EVENT=$(field .hook_event_name)
TOOL=$(field .tool_name)

case "$EVENT:$TOOL" in
  PreToolUse:AskUserQuestion)        MSG=$(field '.tool_input.questions[0].question') ;;
  PreToolUse:mcp__ccd_turn__wrap_up) MSG=$(field '.tool_input.ask'); [ -n "$MSG" ] || exit 0 ;;
  PreToolUse:ExitPlanMode)           MSG="A plan is waiting for your approval" ;;
  Notification:*)                    MSG=$(field .message) ;;
  PermissionRequest:*)               MSG="Permission needed: $TOOL" ;;
  PermissionDenied:*)                [ -z "$(field .agent_id)" ] || exit 0; MSG="Blocked: $TOOL" ;;
  *) exit 0 ;;
esac
[ -n "$MSG" ] || MSG="A session is waiting for you"

# Which session is this? The desktop app sets CLAUDE_CODE_HOST_SESSION_ID and
# keeps the session title in a JSON file; a terminal session has neither.
APP_ID="${CLAUDE_CODE_HOST_SESSION_ID:-}"
SID=$(printf '%s' "${APP_ID:-$(field .session_id)}" | tr -c 'A-Za-z0-9_.-' '_')
SID="${SID:-none}"
TITLE=""
LINK=""
if [ -n "$APP_ID" ]; then
  FILE=$(find "$HOME/Library/Application Support/Claude/claude-code-sessions" \
    -name "$APP_ID.json" -type f -print -quit 2>/dev/null)
  [ -n "$FILE" ] && TITLE=$(jq -r '.title // empty' "$FILE" 2>/dev/null)
  LINK="claude://claude.ai/epitaxy/$APP_ID"
fi
[ -n "$TITLE" ] || TITLE=$(basename "$(field .cwd)" 2>/dev/null)
[ -n "$TITLE" ] || TITLE="Claude Code"

# --- Autopilot -------------------------------------------------------------
# Only questions are answered. Plans, permission prompts and blocked actions
# fall through to the notification below. An end time more than a day away is
# not a real setting (nb-autopilot never writes one), so it counts as off.
NOW=$(date +%s)
UNTIL_EPOCH=$(jq -r '.until_epoch // 0' "$DATA/autopilot.json" 2>/dev/null)
if [ "$EVENT" = PreToolUse ] && [ "$TOOL" != ExitPlanMode ] &&
   [ "${UNTIL_EPOCH:-0}" -gt "$NOW" ] 2>/dev/null &&
   [ "$(( UNTIL_EPOCH - NOW ))" -le 86400 ] 2>/dev/null; then
  UNTIL=$(jq -r '.until // empty' "$DATA/autopilot.json" 2>/dev/null)
  if [ "$TOOL" = AskUserQuestion ]; then
    # Per question: the option whose label ends with "(Recommended)", else the
    # first option. "not recommended" inside a label does not count.
    DECISION=$(printf '%s' "$INPUT" | jq -r '
      [.tool_input.questions[]?
       | .question + " -> "
         + (([.options[]?.label | strings | select(test("\\(recommended\\)\\s*$"; "i"))][0])
            // ([.options[]?.label | strings][0]) // "your recommendation")]
      | join(" | ")' 2>/dev/null)
    HOW="Do not ask. Take your recommended answer and continue the work: $DECISION."
  elif [ -n "$(field '.tool_input.actions[0].action')" ]; then
    # The first answer is an app action (commit, open or merge a pull request,
    # and so on): a go-ahead that belongs to the owner, never to autopilot.
    DECISION="$MSG -> left for the owner ($(field '.tool_input.actions[0].action'))"
    HOW="Do not end the turn with a question, and do not take that step: it needs the owner's go-ahead. Finish the turn without a question and leave it in your final message."
  else
    PICK=$(field '.tool_input.actions[0].label')
    DECISION="$MSG -> ${PICK:-your recommendation}"
    HOW="Do not end the turn with a question. Act on your recommended answer now ($DECISION), then finish the turn without a question."
  fi
  REASON="Autopilot is on until $UNTIL: the owner is away and will not answer. $HOW Never decide these yourself: logins or passwords, payments or purchases, merging, pushing or deploying, publishing or sending anything to other people, deleting data, irreversible production changes, granting permissions. For such a step: skip it, finish the rest and leave the question in your final message. This decision is logged for the owner's morning report."
  mkdir -p "$DATA"
  jq -nc --argjson ts "$NOW" --arg time "$(date '+%F %H:%M')" --arg session "$SID" \
    --arg title "$TITLE" --arg tool "$TOOL" --arg decision "$DECISION" \
    '{ts:$ts,time:$time,session:$session,title:$title,tool:$tool,decision:$decision}' \
    >> "$DATA/decisions.jsonl" 2>/dev/null
  jq -n --arg r "$REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# --- Needs You -------------------------------------------------------------
# The same message from the same session shows once per 2 minutes.
mkdir -p "$STATE"
KEY=$(printf '%s|%s' "$SID" "$MSG" | md5 -q)
[ -n "$(find "$STATE/$KEY" -mmin -2 2>/dev/null)" ] && exit 0
touch "$STATE/$KEY"
find "$STATE" -maxdepth 1 -type f -mmin +120 -delete 2>/dev/null
# A dialog gives up after 60 minutes, so an older lock belongs to a crashed one.
find "$STATE" -maxdepth 1 -type d -name 'dialog-*' -mmin +70 -exec rm -rf {} + 2>/dev/null

# One line, at most 180 characters. jq counts characters, so a letter outside
# ASCII is never cut in half, whatever the locale of the hook's environment.
MSG=$(jq -rn --arg m "$MSG" '$m | gsub("[\r\n]+"; " ") | .[0:180]')

# A banner when macOS allows it, otherwise a dialog that needs no permission.
#
# Dialog state per session lives in one directory, $LOCK:
#   absent        no dialog
#   pid           the process that owns the dialog loop (alive = dialog open)
#   dialog_pid    the osascript currently on screen
#   next          a newer request waiting to replace the one on screen
# A newer request is handed to the live owner, which closes the old dialog and
# shows the new one. A lock whose owner is dead is taken over. Files in $LOCK
# are written under another name and renamed, so a reader never sees half of one.
# The text goes through argv, never into the script.
LOCK="$STATE/dialog-$SID.lock"

# True when the process is alive and its command line contains the word: a
# recycled process id of some unrelated program does not pass.
is_ours() {  # pid, word
  [ -n "$1" ] && ps -p "$1" -o command= 2>/dev/null | grep -q -- "$2"
}
owner_alive() { is_ours "$(cat "$LOCK/pid" 2>/dev/null)" needs-you; }

# Hand the request to the live owner; fails when there is none.
hand_off() {
  owner_alive || return 1
  printf '%s' "$MSG" > "$LOCK/next.tmp.$$" 2>/dev/null &&
    mv "$LOCK/next.tmp.$$" "$LOCK/next" 2>/dev/null || return 1
  local shown
  shown=$(cat "$LOCK/dialog_pid" 2>/dev/null)
  is_ours "$shown" osascript && kill -TERM "$shown" 2>/dev/null
  return 0
}

# A lock with a dead owner, or one with no owner after 10 s, belongs to a crash.
lock_is_stale() {
  [ -d "$LOCK" ] || return 1
  if [ -f "$LOCK/pid" ]; then
    owner_alive && return 1
    return 0
  fi
  [ $(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) )) -gt 10 ]
}

claim_lock() {
  sh -c 'echo $PPID' > "$LOCK/pid.tmp" && mv "$LOCK/pid.tmp" "$LOCK/pid"
}

# Runs as the background job itself (exec), so $! is osascript and killing it
# closes the dialog on screen. Prints the clicked button.
dialog() {
  if [ -n "$LINK" ]; then
    exec osascript -e 'on run argv' -e 'activate' \
      -e 'set r to display dialog (item 2 of argv) with title (item 1 of argv) buttons {item 3 of argv, item 4 of argv} default button 2 giving up after 3600' \
      -e 'return button returned of r' -e 'end run' \
      -- "$HEADLINE: $TITLE" "$1" "$LATER_LABEL" "$OPEN_LABEL" 2>/dev/null
  fi
  exec osascript -e 'on run argv' -e 'activate' \
    -e 'display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1 giving up after 3600' \
    -e 'end run' -- "$HEADLINE: $TITLE" "$1" >/dev/null 2>&1
}

run_dialog_loop() {
  claim_lock
  local msg="$1" answer closing
  while :; do
    dialog "$msg" > "$LOCK/answer" &
    echo $! > "$LOCK/dialog_pid.tmp" && mv "$LOCK/dialog_pid.tmp" "$LOCK/dialog_pid"
    # A request that arrived while no dialog was up replaces this one at once.
    [ -f "$LOCK/next" ] && kill -TERM $! 2>/dev/null
    wait $! 2>/dev/null
    answer=$(cat "$LOCK/answer" 2>/dev/null)
    if [ -n "$LINK" ] && [ "$answer" = "$OPEN_LABEL" ]; then open "$LINK"; break; fi
    if mv "$LOCK/next" "$LOCK/current" 2>/dev/null; then msg=$(cat "$LOCK/current"); continue; fi
    # Close atomically, then pick up a request that arrived in the meantime.
    closing="$STATE/closing-$$-$RANDOM"
    mv "$LOCK" "$closing" 2>/dev/null || break
    if [ -f "$closing/next" ] && mkdir "$LOCK" 2>/dev/null; then
      msg=$(cat "$closing/next"); rm -rf "$closing"
      claim_lock; continue
    fi
    rm -rf "$closing"; return 0
  done
  rm -rf "$LOCK"
}

deliver() {
  if command -v terminal-notifier >/dev/null 2>&1; then
    # terminal-notifier reads a value that starts with "-", "(", "[" or "{" as
    # an option or a list, so such a title gets the same mark as the message.
    local sub="$TITLE"
    case "$sub" in [-\(\[\{]*) sub="▸ $sub" ;; esac
    if [ -n "$LINK" ]; then
      terminal-notifier -title "$HEADLINE" -subtitle "$sub" -message "▸ $MSG" \
        -open "$LINK" -group "needs-you-$SID" -sound default && return 0
    else
      terminal-notifier -title "$HEADLINE" -subtitle "$sub" -message "▸ $MSG" \
        -group "needs-you-$SID" -sound default && return 0
    fi
  fi

  for _ in 1 2 3 4 5; do
    mkdir "$LOCK" 2>/dev/null && { run_dialog_loop "$MSG"; return 0; }
    hand_off && return 0
    lock_is_stale && rm -rf "$LOCK"
    sleep 0.2
  done
}
( deliver ) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
