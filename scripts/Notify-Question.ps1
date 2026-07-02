#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI preToolUse hook: plays a sound and shows an enriched tray
    notification (or BurntToast toast) when the agent prompts the user with a
    question that requires input (the `ask_user` tool).
.DESCRIPTION
    Fires on the preToolUse lifecycle hook, scoped by the hook config matcher to
    the `ask_user` tool. Reads the JSON payload from stdin, plays the Windows
    "Question" notification sound, and shows an enriched notification with:
      - Notification type: "question"
      - Session ID (short)
      - Repo/folder name (derived from cwd or session logs)
      - Question preview (compact, for local display only)
      - Clickback: clicking the notification focuses the VS Code window on the repo

    Clickback behavior:
      - If BurntToast is installed: uses native toast with ActivatedAction.
      - Otherwise: uses System.Windows.Forms tray balloon with a 2.5s wait loop
        for the BalloonTipClicked event (capped within 5s hook timeout).
      - Clickback runs: code -r "<repoPath>" to focus the VS Code window.

    This complements Notify-Waiting.ps1 (which fires on generic waiting/idle/
    completed notification events). The two share the same cooldown state file
    (state/last-notification.json) so a single attention moment never produces a
    double ping — whichever hook fires first wins for the cooldown window.

    Fail-open: always exits 0 — never blocks Copilot. Emits NOTHING to stdout so
    the CLI applies its default decision (allow) and the question is presented
    normally.

    Environment toggles:
      PA_HOOK_NOTIFY_DISABLE=1    — silences ALL notifications (early exit 0)
      PA_HOOK_QUESTION_DISABLE=1  — silences only question pings (early exit 0)
      PA_HOOK_NOTIFY_FORCE=1      — bypasses cooldown (testing)

    Cooldown state: ~/.copilot/hooks/state/last-notification.json (shared)
    Log output:     ~/.copilot/hooks/logs/notifications.jsonl (compact, non-sensitive)
.EXAMPLE
    $json = '{"toolName":"ask_user","toolArgs":{"question":"Which database should I use?","choices":["PostgreSQL","MySQL"]},"sessionId":"abc12345-xyz","cwd":"C:\\repos\\myapp"}'
    echo $json | pwsh -NoProfile -File Notify-Question.ps1
.EXAMPLE
    $env:PA_HOOK_NOTIFY_FORCE = '1'
    echo '{"toolName":"ask_user","toolArgs":{"question":"Proceed?"}}' | pwsh -NoProfile -File Notify-Question.ps1
    $env:PA_HOOK_NOTIFY_FORCE = $null
.NOTES
    PII rule: NEVER log the raw question text, choices, or tool args. Only log
    event metadata (event kind, timestamp, whether a notification was shown,
    cooldown status, clickback availability). The question preview and enriched
    context are shown locally but never persisted.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

[string]$script:ScriptVersion = '2.0.0'

# ── Configurable constants ──────────────────────────────────────────────────
$CooldownSeconds  = 30
$MaxSummaryLength = 120
$BalloonTimeoutMs = 8000
$GenericMessage   = 'Copilot has a question and is waiting for your input.'
$BalloonTitle     = 'GitHub Copilot — needs your input'

# ── Helper: resolve state directory (shared with Notify-Waiting) ────────────
function Get-StateDirectory {
    [CmdletBinding()]
    param()
    if (-not [string]::IsNullOrWhiteSpace($env:PA_HOOKS_STATE_DIR)) {
        $dir = $env:PA_HOOKS_STATE_DIR
    }
    else {
        $dir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'state'))
    }
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

# ── Helper: cooldown check and update (shared state file) ───────────────────
function Test-CooldownExpired {
    [CmdletBinding()]
    param(
        [string]$StatePath,
        [int]$CooldownSec
    )
    $now = [DateTimeOffset]::UtcNow

    if (Test-Path $StatePath) {
        try {
            $raw  = Get-Content $StatePath -Raw -ErrorAction Stop
            $json = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($json.lastNotificationUtc) {
                $last = [DateTimeOffset]::Parse($json.lastNotificationUtc)
                $elapsed = ($now - $last).TotalSeconds
                if ($elapsed -lt $CooldownSec) {
                    Write-Verbose "Cooldown active: ${elapsed}s < ${CooldownSec}s"
                    return $false
                }
            }
        }
        catch {
            Write-Verbose 'Cooldown state unreadable — treating as expired'
        }
    }

    $state = @{ lastNotificationUtc = $now.ToString('o') } | ConvertTo-Json -Compress
    $state | Set-Content -Path $StatePath -Encoding utf8NoBOM -Force
    return $true
}

# ── Helper: play system notification sound ──────────────────────────────────
function Invoke-NotificationSound {
    [CmdletBinding()]
    param()
    try {
        [System.Media.SystemSounds]::Question.Play()
    }
    catch {
        Write-Verbose "Sound playback failed — $($_.Exception.Message)"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
try {
    # ── Early-exit: disabled via env ────────────────────────────────────────
    if ($env:PA_HOOK_NOTIFY_DISABLE -eq '1' -or $env:PA_HOOK_QUESTION_DISABLE -eq '1') {
        exit 0
    }

    $forceMode = $env:PA_HOOK_NOTIFY_FORCE -eq '1'

    # ── Feature flags (toggle capabilities without editing this script) ─────
    $features = Get-HookFeatureConfig
    if (-not (Test-HookFeatureEnabled -Name 'notifications.enabled' -Config $features)) {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'question_disabled_by_flag'
            flag          = 'notifications.enabled'
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
        exit 0
    }
    $featRichContext = Test-HookFeatureEnabled -Name 'notifications.richContext'         -Config $features
    $featPromptSnip  = Test-HookFeatureEnabled -Name 'notifications.promptSnippet'       -Config $features
    $featClickback   = Test-HookFeatureEnabled -Name 'notifications.clickback'           -Config $features
    $featBurntToast  = Test-HookFeatureEnabled -Name 'notifications.burntToast'          -Config $features
    $featTrayBalloon = Test-HookFeatureEnabled -Name 'notifications.trayBalloonFallback' -Config $features

    # ── Read payload ────────────────────────────────────────────────────────
    $payload = Get-HookInput

    # ── Defensive tool-name check (the config matcher already scopes this) ───
    $toolName = if ($payload -and $payload.PSObject.Properties['toolName']) {
        ([string]$payload.toolName).Trim().ToLowerInvariant()
    } else { '' }

    if ($toolName -and $toolName -ne 'ask_user' -and -not $forceMode) {
        exit 0
    }

    # ── Cooldown check (shared with Notify-Waiting; unless forced) ──────────
    $stateDir  = Get-StateDirectory
    $statePath = Join-Path $stateDir 'last-notification.json'

    $cooldownOk = if ($forceMode) { $true } else {
        Test-CooldownExpired -StatePath $statePath -CooldownSec $CooldownSeconds
    }

    if (-not $cooldownOk) {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'question_cooldown'
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
        exit 0
    }

    # ── Extract enriched context ────────────────────────────────────────────
    $ctx = Get-NotificationContext -Payload $payload

    # Apply feature flags: strip prompt snippet when disabled.
    if (-not $featPromptSnip) { $ctx.promptSnippet = $null }

    # ── Build enriched notification text ────────────────────────────────────
    # Compose enriched body: [question] repo | session | question snippet
    $enrichedParts = @('[question]')
    if ($featRichContext -and $ctx.repoName -ne 'unknown') { $enrichedParts += $ctx.repoName }
    if ($featRichContext -and $ctx.sessionId -ne 'unknown') { $enrichedParts += "session:$($ctx.sessionId)" }
    $enrichedHeader = $enrichedParts -join ' | '

    $enrichedBody = if ($ctx.promptSnippet) {
        "$enrichedHeader`n`"$($ctx.promptSnippet)`""
    } else {
        "$enrichedHeader`n$GenericMessage"
    }

    # ── Play sound ──────────────────────────────────────────────────────────
    Invoke-NotificationSound

    # ── Show enriched notification with clickback ───────────────────────────
    $notifyResult = Show-EnrichedNotification `
        -Title $BalloonTitle `
        -Text $enrichedBody `
        -Kind 'question' `
        -RepoPath $ctx.cwd `
        -TimeoutMs $BalloonTimeoutMs `
        -AllowBurntToast $featBurntToast `
        -AllowTrayFallback $featTrayBalloon `
        -AllowClickback $featClickback

    # ── Log (compact, non-sensitive metadata only) ──────────────────────────
    $logDir  = Get-LogDirectory
    $logPath = Join-Path $logDir 'notifications.jsonl'
    Write-AuditEntry -Path $logPath -Entry @{
        event             = 'question_shown'
        sessionId         = $ctx.sessionId
        repoName          = $ctx.repoName
        hasPreview        = ($null -ne $ctx.promptSnippet)
        clickbackAttached = $notifyResult.clickbackAttached
        protocolClickback = $notifyResult.protocolClickback
        customProtocol    = $notifyResult.customProtocol
        clickbackTarget   = $notifyResult.clickbackTarget
        burntToast        = $notifyResult.burntToast
        notifyMethod      = $notifyResult.method
        forced            = $forceMode
        flagRichContext   = $featRichContext
        flagPromptSnippet = $featPromptSnip
        flagClickback     = $featClickback
        flagBurntToast    = $featBurntToast
        flagTrayBalloon   = $featTrayBalloon
        timestamp         = (Get-Date -Format 'o')
        scriptVersion     = $script:ScriptVersion
    }
}
catch {
    # Fail-open: log the error but never crash or return non-zero
    try {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'question_error'
            error         = $_.Exception.Message
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
    }
    catch {
        Write-Warning "Notify-Question: failed to log error — $($_.Exception.Message)"
    }
}

exit 0
