---
name: needs-you
description: "Set up, test or troubleshoot the Needs You popup: a macOS notification when a Claude Code session waits for the owner (a question, a plan to approve, a permission prompt) that opens that exact session. Use for needs-you, notify me when Claude asks, the popup does not show, test the popup, or change the popup text."
---

# Needs You

One hook, `hooks/needs-you.sh`, runs when a session waits for the owner and shows
a macOS notification with the session's title and the question. In the Claude
desktop app, clicking it opens that exact session. The hook never answers a
permission prompt and never blocks a session.

| When the session | The popup says |
|---|---|
| asks a question (`AskUserQuestion`) | the question |
| ends a turn with a question (desktop app) | that question |
| has a plan to approve (`ExitPlanMode`) | "A plan is waiting for your approval" |
| needs a permission | the prompt, or "Permission needed: <tool>" |
| had an action blocked | "Blocked: <tool>" |

## Check the setup

Run `nb-autopilot doctor` (or `${CLAUDE_PLUGIN_ROOT}/bin/nb-autopilot doctor`).
It needs `jq` and `osascript`; `terminal-notifier` is optional.

- With `terminal-notifier` and its notification permission: a banner with sound.
- Without either: a dialog with "Later" and "Open". The dialog takes focus, so
  the banner is the better mode. To get it: `brew install terminal-notifier`,
  then System Settings → Notifications → terminal-notifier → allow. Only the
  owner can grant that permission.

## Test it

Write the test event to a file with the Write tool, then pipe it to the hook:

```json
{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Test: this is the Needs You popup."}]}}
```

```bash
"${CLAUDE_PLUGIN_ROOT}/hooks/needs-you.sh" < /path/to/event.json
```

A popup appears within a second. Tell the owner before you run it: it shows on
their screen. The same message from the same session shows once per 2 minutes.

## When it does not show

1. `nb-autopilot status`: while autopilot is on, questions get an answer instead
   of a popup. That is intended.
2. `nb-autopilot doctor`: `jq` missing means the hook exits silently. If
   `terminal-notifier` is installed and nothing shows at all, its notification
   permission is the first thing to check.
3. Hooks load when a session starts. A session that was open before the plugin
   was installed needs a restart.
4. A session in a terminal has no deep link: the popup shows the folder name and
   an "OK" button.

## Change the text

Set these in the `env` block of `~/.claude/settings.json`:

| Variable | Default |
|---|---|
| `NEEDS_YOU_TITLE` | `Claude needs you` |
| `NEEDS_YOU_OPEN` | `Open` |
| `NEEDS_YOU_LATER` | `Later` |

Do not edit the hook to answer permission prompts or to click for the owner.
For working through the night, use the `autopilot` skill: it answers questions
only and logs every decision.
