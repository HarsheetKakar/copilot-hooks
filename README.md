# User-Level Copilot CLI Hooks

Location: `~/.copilot/hooks/`

## Architecture — Four Layers

| Layer | Location | Scope | Purpose |
|-------|----------|-------|---------|
| **1. User-level audit** | `~/.copilot/hooks/copilot-audit.json` | All repos, all sessions | Always-on session/tool logging to `logs/audit.jsonl` |
| **2. User-level shell guardrails** | `~/.copilot/hooks/copilot-shell-guardrails.json` | All repos, all sessions | Gates `gh`, `az`, and `git` CLI commands via popup/CLI prompt |
| **3. User-level waiting notifications** | `~/.copilot/hooks/copilot-notify.json` | All repos, all sessions | Plays a sound and shows a tray notification when Copilot is waiting for input |
| **4. User-level question notifications** | `~/.copilot/hooks/copilot-question-notify.json` | All repos, all sessions | Plays a sound and shows a tray notification when the agent asks you a question (`ask_user`) |
| **5. Repo-level PA guardrails** | `.github/hooks/pa-guardrails.json` | This repo only | Gates mailtools/calendartools MCP tools |

All layers are **additive** (user hooks fire first, then repo hooks). They are scoped to different hook events/tool names so there is **no double-fire**.

## Feature Flags (`hook-features.json`)

Toggle individual hook capabilities **without editing any script**. The flags live in
`~/.copilot/hooks/hook-features.json` and are read at the start of every hook invocation
(no Copilot restart needed — changes apply to the *next* notification / shell command).

### Schema & Defaults

```json
{
  "version": 1,
  "features": {
    "notifications": {
      "enabled": true,
      "richContext": true,
      "promptSnippet": true,
      "clickback": true,
      "burntToast": true,
      "trayBalloonFallback": true
    },
    "shellGuardrails": {
      "enabled": true,
      "prompts": true
    }
  }
}
```

| Flag | Default | Effect when `false` |
|------|---------|---------------------|
| `notifications.enabled` | `true` | No waiting/question notifications at all (logged as `*_disabled_by_flag`). |
| `notifications.richContext` | `true` | Drops repo name + session id from the notification header. |
| `notifications.promptSnippet` | `true` | Omits the local prompt/question preview line. |
| `notifications.clickback` | `true` | Notification no longer opens/focuses VS Code on click. |
| `notifications.burntToast` | `true` | Skips native BurntToast toast (uses tray balloon if allowed). |
| `notifications.trayBalloonFallback` | `true` | Skips the tray-balloon fallback (sound-only when BurntToast also off/absent). |
| `shellGuardrails.enabled` | `true` | Shell gate OFF — all `gh`/`az`/`git` commands allowed (logged as `shellGateDisabledByFlag`). |
| `shellGuardrails.prompts` | `true` | **Audit-only**: `ask` rules auto-allow but are logged (`shellGateAskAuditOnly`); hard `deny` rules stay enforced. |

**Fail-safe defaults:** if `hook-features.json` is missing, empty, malformed, or a key is
absent, the feature is treated as **enabled** — current behavior is preserved. Disabling a
feature requires setting it explicitly to `false`.

### Environment Variable Overrides

Notification flags can be overridden per-session by an env var named
`PA_HOOK_FEATURE_<DOTTED_NAME_UPPERCASED_WITH_UNDERSCORES>`. The env var takes
precedence over the JSON file. Truthy: `1/true/on/yes/enable[d]`; falsy:
`0/false/off/no/disable[d]`.

```powershell
# Disable clickback just for this session (file unchanged):
$env:PA_HOOK_FEATURE_NOTIFICATIONS_CLICKBACK = '0'
```

> **Note:** `shellGuardrails.*` features ignore env overrides. The shell command
> gate cannot be enabled or disabled from the environment — edit
> `hook-features.json` to toggle it. This keeps the gate non-bypassable.

Legacy env vars still work and are independent of these flags:
`PA_HOOK_NOTIFY_DISABLE=1` (silence all notifications), `PA_HOOK_QUESTION_DISABLE=1`,
`PA_HOOK_NOTIFY_FORCE=1`.

### Logging

Flag-driven decisions are recorded (no sensitive payloads):
- `notifications.jsonl`: `notification_disabled_by_flag`, `question_disabled_by_flag`, plus
  `flag*` booleans on every `notification_shown` / `question_shown` entry.
- `audit.jsonl`: `shellGateDisabledByFlag`, `shellGateAskAuditOnly`.

### Rollback

The flag system is fully reversible — restore default behavior by either:
1. Setting every flag back to `true` in `hook-features.json`, **or**
2. Deleting `hook-features.json` entirely (missing file = all features enabled), **or**
3. `git checkout -- hook-features.json scripts/_Common.ps1 scripts/Notify-Waiting.ps1 scripts/Notify-Question.ps1 scripts/Gate-ShellCommands.ps1 README.md`
   to revert the code changes.

## Shell Command Guardrails (Layer 2)

### How It Works

1. Copilot CLI invokes the `powershell` (or `bash`) tool
2. The `preToolUse` hook fires, running `Gate-ShellCommands.ps1`
3. The script extracts the command line from `toolArgs.command`
4. If the command starts with `gh`, `az`, or `git`, loads the corresponding rules JSON
5. Rules are evaluated **first-match-wins**
6. Result: `allow` (silent), `ask` (popup/CLI prompt), or `deny` (hard block)

### Rule Files

- **`gh-guardrails.json`** — Rules for GitHub CLI commands
- **`az-guardrails.json`** — Rules for Azure CLI commands
- **`git-guardrails.json`** — Rules for git commands (enforces "never rewrite history" directive)

### Rule Schema

```json
{
  "version": 1,
  "defaultAction": "allow",
  "rules": [
    {
      "action": "deny|ask|allow",
      "pattern": "regex pattern matched against the command",
      "reason": "Human-readable explanation"
    }
  ]
}
```

### Default Posture

- **Unmatched commands → ALLOW** (won't break normal shell usage)
- **Read-only patterns → explicit ALLOW** (short-circuits before ASK rules)
- **Destructive patterns → ASK** (popup with 120s timeout)
- **Catastrophic patterns → DENY** (hard block, no recourse)

### Git Guardrails — Project Directive Enforcement

The `git-guardrails.json` rules enforce the project directive: **"Never rewrite git history."**

**DENY (hard block — history rewriting):**
- Force-push to protected branches (`main`, `master`, `develop`, `release/*`)
- `git filter-branch` / `git filter-repo` (bulk history rewrite)
- `git reflog expire --expire=now` (destroys recovery safety net)
- `git gc --prune=now` (destroys unreachable objects)
- `git push --mirror` (overwrites all remote refs)
- `git push --delete` on protected branches
- `git update-ref -d` on protected branch refs

**ASK (confirm before proceeding):**
- Force-push to feature branches (legitimate in some workflows)
- `git reset --hard` (discards changes)
- `git clean -fdx` (removes untracked files)
- `git rebase` (rewrites local history)
- `git commit --amend` (modifies last commit)
- `git branch -D` (force-delete branch)
- `git stash drop/clear`, `git cherry-pick`, `git revert`
- `git config --global` (user-wide config change)
- Tag deletion, remote removal, submodule deinit

**ALLOW (pass-through, no prompt):**
- Read-only: `status`, `log`, `diff`, `show`, `blame`, `branch`, `tag`, `remote`
- Normal operations: `add`, `commit` (without `--amend`), `push` (without force), `pull`, `fetch`
- Branch switching: `checkout <branch>`, `switch <branch>`
- Safe stash: `stash push/pop/apply/list/show`
- Init/clone, `--version`, `help`

### Adding/Editing Rules

1. Edit the appropriate JSON file (`gh-guardrails.json`, `az-guardrails.json`, or `git-guardrails.json`)
2. Add a rule object to the `rules` array — **order matters** (first match wins)
3. **Restart the Copilot CLI session** — hook configs load only at session start; there is no hot-reload

### Rule Actions

| Action | Behavior |
|--------|----------|
| `deny` | Hard block. Command does not execute. Logged to audit. |
| `ask` | Popup appears (120s timeout). If no GUI, falls back to CLI prompt. |
| `allow` | Command executes silently. |

### Non-Bypassable by Design

The shell command gate has **no env-var escape hatch**. There is no override
variable to auto-allow gated commands, and `shellGuardrails.*` feature flags
cannot be toggled from the environment (only via `hook-features.json`). Gate
errors fail toward the safe outcome and the gate always runs.

### Graceful Degradation

| Failure Mode | Behavior |
|--------------|----------|
| Missing guardrails JSON | Allow + warning (don't crash) |
| Malformed JSON | Allow + warning |
| Missing Show-GatePrompt.ps1 | Fall back to CLI `ask` prompt |
| Script error | Allow (fail-open — shell commands are too broad to fail-closed) |
| No GUI available | Fall back to CLI `ask` prompt |

### Testing / Dry-Run

Pipe a fake payload to the gate script. On a headless session (no GUI) the gate
falls back to a CLI `ask` decision automatically, so you can observe the decision
without a popup:

```powershell
$payload = @{
    sessionId = 'test-1'
    timestamp = '2026-01-01T00:00:00Z'
    toolName  = 'powershell'
    toolArgs  = @{ command = 'gh pr merge 42' }
} | ConvertTo-Json -Compress

$payload | pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\scripts\Gate-ShellCommands.ps1"
```

### Audit Log

All deny/ask decisions are recorded in `~/.copilot/hooks/logs/audit.jsonl` with fields:
- `event`: `shellGateDeny`, `shellGateAsk`, `shellGateOverride`
- `cli`: `gh`, `az`, or `git`
- `command`: first 120 chars of the matched command
- `pattern`: the regex that matched
- `reason`: human explanation

## Waiting Notifications (Layer 3)

### How It Works

1. Copilot CLI emits a `notification` hook event when the agent reaches an attention-needed state.
2. `copilot-notify.json` invokes `scripts\Notify-Waiting.ps1`.
3. The script detects waiting/idle/completed/input-needed notifications.
4. It plays a Windows system sound and shows a notification with a compact completion summary when the hook payload provides one.

### Clickback (open VS Code)

When the **BurntToast** module is installed (`Install-Module BurntToast -Scope CurrentUser`), the notification is shown as a native Windows toast whose click is wired to an **OS-handled protocol** URI (BurntToast `-Launch`/`-ActivationType Protocol`, plus an "Open in VS Code" protocol button). Because activation is OS-handled, clicking the toast focuses VS Code on the repo even after the short-lived hook process has already exited.

**Clickback target selection** (best first):

1. **`copilot-clickback://` custom protocol** (preferred). Registered per-user under `HKCU\Software\Classes\copilot-clickback`, it routes the click to `scripts\Focus-VSCodeRepo.ps1`, which decodes the repo path and runs `code -r <repoPath>` to **focus/reuse the existing per-repo VS Code window**. This fixes the prior behavior where `vscode://file/<path>` opened VS Code but did not focus the exact existing window. The protocol is self-registered on first notification (`Initialize-CopilotClickbackProtocol`) and self-heals if removed.
2. **`vscode://file/<repoPath>` protocol** (graceful fallback). Used only if the custom protocol cannot be registered (e.g. no `pwsh`/`powershell`, or the helper script is missing). Opens VS Code on the folder but may not focus the existing window.
3. **`System.Windows.Forms` tray balloon** (fallback when BurntToast is absent). The balloon still displays and its in-process handler runs `code -r <repoPath>`, but clickback is best-effort: if you click after the hook process exits, nothing happens. Install BurntToast for reliable clickback.

The attached target is recorded in `logs/notifications.jsonl` as `clickbackTarget` (`custom-protocol` | `vscode-protocol` | `trayballoon` | `none`) plus the booleans `customProtocol`, `protocolClickback`, `clickbackAttached`. Helper clickback outcomes are logged to `logs/clickback.jsonl`.

#### Custom clickback protocol — registration & rollback

The protocol is registered automatically, but you can manage it manually:

```powershell
# Inspect the registered protocol
reg query "HKCU\Software\Classes\copilot-clickback" /s

# Re-register (idempotent) — run from a PowerShell session:
. "$env:USERPROFILE\.copilot\hooks\scripts\_Common.ps1"; Register-CopilotClickbackProtocol

# ROLLBACK — remove the custom protocol entirely (reverts to vscode:// fallback):
Remove-Item -Path "HKCU:\Software\Classes\copilot-clickback" -Recurse -Force
```

Removing the registry key is safe: the next notification falls back to the `vscode://file` protocol (and self-re-registers the custom protocol unless the helper is also removed). The registry command points only to `scripts\Focus-VSCodeRepo.ps1` inside this hooks folder.

To fully revert the clickback changes, restore the backed-up scripts from `state\clickback-backup-<timestamp>\` (`_Common.ps1`, `Notify-Waiting.ps1`, `Notify-Question.ps1`), delete `scripts\Focus-VSCodeRepo.ps1`, and remove the registry key as above.

### Privacy and Noise Controls

| Control | Behavior |
|---------|----------|
| `PA_HOOK_NOTIFY_DISABLE=1` | Silences notification pings entirely for the current session. |
| `PA_HOOK_NOTIFY_FORCE=1` | Bypasses event filtering and cooldown for manual testing. |
| Cooldown | Suppresses repeated pings within the default cooldown window. Runtime state is stored under `state/`. |
| Logging | Writes compact metadata to `logs/notifications.jsonl`; the local tray summary is never persisted. |

The notification hook is fail-open: errors in sound playback, tray UI, logging, or payload parsing never block Copilot.

## Question Notifications (Layer 4)

### How It Works

1. Copilot CLI emits a `preToolUse` hook event when the agent calls the `ask_user` tool to prompt you with a question.
2. `copilot-question-notify.json` (matcher `^ask_user$`) invokes `scripts\Notify-Question.ps1`.
3. The script plays the Windows **Question** system sound (distinct from the Exclamation sound used for completed/idle events) and shows a tray balloon previewing the question.
4. The hook emits **nothing** to stdout, so the CLI applies its default decision (allow) and the question is presented to you normally — the hook never blocks or alters the prompt.

This is the input-needed counterpart to Layer 3: Layer 3 fires when the agent finishes/idles, Layer 4 fires the moment the agent asks you something.

### Privacy and Noise Controls

| Control | Behavior |
|---------|----------|
| `PA_HOOK_QUESTION_DISABLE=1` | Silences only question pings for the current session. |
| `PA_HOOK_NOTIFY_DISABLE=1` | Silences ALL notifications (waiting + questions). |
| `PA_HOOK_NOTIFY_FORCE=1` | Bypasses cooldown for manual testing. |
| Shared cooldown | Uses the same `state/last-notification.json` as Layer 3, so a single attention moment (e.g. agent asks a question, then idles) produces only one ping. |
| Logging | Writes compact metadata to `logs/notifications.jsonl` (`question_shown`/`question_cooldown`). The question text and choices are **never** logged or persisted — they appear only in the local tray balloon. |

The question hook is fail-open: any error in sound playback, tray UI, logging, or payload parsing exits 0 and never blocks the `ask_user` prompt.

### Testing

```powershell
$env:PA_HOOK_NOTIFY_FORCE = '1'
'{"toolName":"ask_user","toolArgs":{"question":"Which database should I use?","choices":["PostgreSQL","MySQL"]}}' |
    pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\scripts\Notify-Question.ps1"
$env:PA_HOOK_NOTIFY_FORCE = $null
```

## Files

```
~/.copilot/hooks/
├── copilot-audit.json              # Layer 1: audit hook config
├── copilot-shell-guardrails.json   # Layer 2: shell guardrails hook config
├── copilot-notify.json             # Layer 3: waiting notification hook config
├── copilot-question-notify.json    # Layer 4: question (ask_user) notification hook config
├── hook-features.json              # Feature flags: toggle hook capabilities (no restart)
├── gh-guardrails.json              # gh CLI rule definitions
├── az-guardrails.json              # az CLI rule definitions
├── git-guardrails.json             # git CLI rule definitions (history-rewrite deny)
├── scripts/
│   ├── _Common.ps1                 # Shared helpers (UTF-8, JSON, audit)
│   ├── Gate-ShellCommands.ps1      # Shell command gate logic (gh/az/git)
│   ├── Show-GatePrompt.ps1        # WinForms popup (approve/deny)
│   ├── Notify-Waiting.ps1         # Sound + tray notification on waiting/idle
│   ├── Notify-Question.ps1        # Sound + tray notification on ask_user (question)
│   ├── Log-SessionStart.ps1       # Audit: session start
│   ├── Log-SessionEnd.ps1         # Audit: session end
│   └── Log-ToolUse.ps1            # Audit: tool use
└── logs/
    └── audit.jsonl                 # Append-only audit log (10MB rotation)
```
