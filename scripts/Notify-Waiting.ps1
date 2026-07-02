#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI hook: plays a notification sound and shows an enriched tray
    notification (or BurntToast toast) when the agent needs attention.
.DESCRIPTION
    Fires on the notification lifecycle hook. Reads the JSON payload from stdin,
    determines if the event indicates the agent needs attention (waiting, idle,
    input-needed, completed), plays a Windows notification sound, and shows an
    enriched notification with:
      - Notification type/kind
      - Session ID (short)
      - Repo/folder name (derived from cwd or session logs)
      - User prompt snippet (compact, for local display only)
      - Clickback: clicking the notification focuses the VS Code window on the repo

    Clickback behavior:
      - If BurntToast is installed: uses native toast with ActivatedAction (persistent,
        no wait loop needed).
      - Otherwise: uses System.Windows.Forms tray balloon with a 2.5s wait loop for
        the BalloonTipClicked event (capped to stay within 5s hook timeout).
      - Clickback runs: code -r "<repoPath>" to focus/open the VS Code window.

    Fail-open: always exits 0 — never blocks Copilot.

    Environment toggles:
      PA_HOOK_NOTIFY_DISABLE=1  — silences all notifications (early exit 0)
      PA_HOOK_NOTIFY_FORCE=1    — bypasses cooldown and event filtering (testing)

    Cooldown state: ~/.copilot/hooks/state/last-notification.json
    Log output:     ~/.copilot/hooks/logs/notifications.jsonl (compact, non-sensitive)

    Payload tolerance: supports event/type/notificationType for event kind, and
    title/message/body/reason/notification for summary text. Unknown shapes are
    handled gracefully.
.EXAMPLE
    $json = '{"event":"notification","notification_type":"agent_completed","title":"Task complete","message":"Finished refactoring","sessionId":"abc123","cwd":"C:\\repos\\myapp"}'
    echo $json | pwsh -NoProfile -File Notify-Waiting.ps1
.EXAMPLE
    $env:PA_HOOK_NOTIFY_FORCE = '1'
    echo '{}' | pwsh -NoProfile -File Notify-Waiting.ps1
    $env:PA_HOOK_NOTIFY_FORCE = $null
.NOTES
    PII rule: NEVER log raw prompts, assistant text, tool args, personal content,
    or the tray summary text. Only log event metadata (event kind, timestamp,
    whether notification was shown, cooldown status, clickback availability).
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

[string]$script:ScriptVersion = '2.0.0'

# ── Configurable constants ──────────────────────────────────────────────────
$CooldownSeconds     = 30
$MaxSummaryLength    = 120
$BalloonTimeoutMs    = 8000
$GenericMessage      = 'Copilot finished and is waiting for your input.'
$BalloonTitle        = 'GitHub Copilot'

# Event keywords that indicate the agent needs user attention.
$WaitingKeywords = @(
    'waiting', 'idle', 'input-needed', 'input_needed', 'inputneeded',
    'completed', 'complete', 'done', 'finished',
    'needs-input', 'needs_input', 'needsinput',
    'paused', 'blocked', 'suspended',
    'agent_completed', 'shell_completed'
)

# ── Helper: resolve state directory ─────────────────────────────────────────
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

# ── Helper: extract event kind from payload ─────────────────────────────────
function Get-NotificationKind {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Payload
    )
    if ($null -eq $Payload) { return '' }

    foreach ($field in @('notification_type', 'notificationType', 'type', 'event', 'level')) {
        $val = $Payload.PSObject.Properties[$field]
        if ($val -and -not [string]::IsNullOrWhiteSpace($val.Value)) {
            return ([string]$val.Value).Trim().ToLowerInvariant()
        }
    }
    return ''
}

# ── Helper: extract summary text from payload ───────────────────────────────
function Get-NotificationSummary {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Payload,
        [string]$FallbackMessage,
        [int]$MaxLength
    )
    if ($null -eq $Payload) { return $FallbackMessage }

    $parts = @()
    foreach ($field in @('title', 'message', 'body', 'reason', 'notification')) {
        $val = $Payload.PSObject.Properties[$field]
        if ($val -and -not [string]::IsNullOrWhiteSpace($val.Value)) {
            $parts += ([string]$val.Value).Trim()
        }
    }

    if ($parts.Count -eq 0) { return $FallbackMessage }

    $combined = if ($parts.Count -ge 2 -and $parts[0] -ne $parts[1]) {
        "$($parts[0]): $($parts[1])"
    } else {
        $parts[0]
    }

    $combined = ($combined -replace '\s+', ' ').Trim()
    if ($combined.Length -gt $MaxLength) {
        $combined = $combined.Substring(0, $MaxLength - 1) + [char]0x2026
    }
    return $combined
}

# ── Helper: test if event kind matches waiting keywords ─────────────────────
function Test-IsWaitingEvent {
    [CmdletBinding()]
    param(
        [string]$Kind,
        [string[]]$Keywords
    )
    if ([string]::IsNullOrWhiteSpace($Kind)) { return $false }
    $k = $Kind.ToLowerInvariant()
    foreach ($kw in $Keywords) {
        if ($k -eq $kw -or $k.Contains($kw)) { return $true }
    }
    return $false
}

# ── Helper: cooldown check and update ───────────────────────────────────────
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
            Write-Verbose "Cooldown state unreadable — treating as expired"
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
        [System.Media.SystemSounds]::Exclamation.Play()
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
    if ($env:PA_HOOK_NOTIFY_DISABLE -eq '1') {
        exit 0
    }

    $forceMode = $env:PA_HOOK_NOTIFY_FORCE -eq '1'

    # ── Feature flags (toggle capabilities without editing this script) ─────
    $features = Get-HookFeatureConfig
    if (-not (Test-HookFeatureEnabled -Name 'notifications.enabled' -Config $features)) {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'notification_disabled_by_flag'
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

    # ── Determine notification kind ─────────────────────────────────────────
    $kind = Get-NotificationKind -Payload $payload

    # ── Filter: only fire for waiting-type events (unless forced) ───────────
    $isWaiting = Test-IsWaitingEvent -Kind $kind -Keywords $WaitingKeywords
    if (-not $isWaiting -and -not $forceMode) {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'notification_skipped'
            kind          = if ($kind) { $kind } else { 'unknown' }
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
        exit 0
    }

    # ── Cooldown check (unless forced) ──────────────────────────────────────
    $stateDir  = Get-StateDirectory
    $statePath = Join-Path $stateDir 'last-notification.json'

    $cooldownOk = if ($forceMode) { $true } else {
        Test-CooldownExpired -StatePath $statePath -CooldownSec $CooldownSeconds
    }

    if (-not $cooldownOk) {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'notification_cooldown'
            kind          = if ($kind) { $kind } else { 'unknown' }
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
        exit 0
    }

    # ── Extract enriched context ────────────────────────────────────────────
    $ctx = Get-NotificationContext -Payload $payload

    # Apply feature flags: strip prompt snippet / rich context when disabled.
    if (-not $featPromptSnip) { $ctx.promptSnippet = $null }

    # ── Build enriched notification text ────────────────────────────────────
    $summary = Get-NotificationSummary -Payload $payload `
        -FallbackMessage $GenericMessage -MaxLength $MaxSummaryLength

    # Compose enriched body: [kind] repo | session | prompt snippet
    $enrichedParts = @()
    $kindLabel = if ($kind) { "[$kind]" } else { '[notification]' }
    $enrichedParts += $kindLabel
    if ($featRichContext -and $ctx.repoName -ne 'unknown') { $enrichedParts += $ctx.repoName }
    if ($featRichContext -and $ctx.sessionId -ne 'unknown') { $enrichedParts += "session:$($ctx.sessionId)" }
    $enrichedHeader = $enrichedParts -join ' | '

    $enrichedBody = if ($ctx.promptSnippet) {
        "$enrichedHeader`n$summary`n`"$($ctx.promptSnippet)`""
    } else {
        "$enrichedHeader`n$summary"
    }

    # ── Play sound ──────────────────────────────────────────────────────────
    Invoke-NotificationSound

    # ── Show enriched notification with clickback ───────────────────────────
    $notifyResult = Show-EnrichedNotification `
        -Title $BalloonTitle `
        -Text $enrichedBody `
        -Kind $kind `
        -RepoPath $ctx.cwd `
        -TimeoutMs $BalloonTimeoutMs `
        -AllowBurntToast $featBurntToast `
        -AllowTrayFallback $featTrayBalloon `
        -AllowClickback $featClickback

    # ── Log (compact, non-sensitive metadata only) ──────────────────────────
    $logDir  = Get-LogDirectory
    $logPath = Join-Path $logDir 'notifications.jsonl'
    Write-AuditEntry -Path $logPath -Entry @{
        event            = 'notification_shown'
        kind             = if ($kind) { $kind } else { 'unknown' }
        sessionId        = $ctx.sessionId
        repoName         = $ctx.repoName
        hasSummary       = ($summary -ne $GenericMessage)
        hasPromptSnippet = ($null -ne $ctx.promptSnippet)
        clickbackAttached = $notifyResult.clickbackAttached
        protocolClickback = $notifyResult.protocolClickback
        customProtocol    = $notifyResult.customProtocol
        clickbackTarget   = $notifyResult.clickbackTarget
        burntToast        = $notifyResult.burntToast
        notifyMethod     = $notifyResult.method
        forced           = $forceMode
        flagRichContext  = $featRichContext
        flagPromptSnippet = $featPromptSnip
        flagClickback    = $featClickback
        flagBurntToast   = $featBurntToast
        flagTrayBalloon  = $featTrayBalloon
        timestamp        = (Get-Date -Format 'o')
        scriptVersion    = $script:ScriptVersion
    }
}
catch {
    # Fail-open: log the error but never crash or return non-zero
    try {
        $logDir  = Get-LogDirectory
        $logPath = Join-Path $logDir 'notifications.jsonl'
        Write-AuditEntry -Path $logPath -Entry @{
            event         = 'notification_error'
            error         = $_.Exception.Message
            timestamp     = (Get-Date -Format 'o')
            scriptVersion = $script:ScriptVersion
        }
    }
    catch {
        Write-Warning "Notify-Waiting: failed to log error — $($_.Exception.Message)"
    }
}

exit 0
