#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI hook: logs a sessionStart event to sessions.jsonl.
.DESCRIPTION
    Fires on the sessionStart lifecycle hook. Reads the JSON payload from stdin,
    writes one JSONL entry to .github/hooks/logs/sessions.jsonl, and exits 0.

    Never blocks session start — all errors are caught and logged as warnings.

    Expected stdin fields : sessionId, cwd, timestamp
    Written JSONL fields  : event, sessionId, cwd, timestamp, user, scriptVersion

    Log directory override for test isolation: set $env:PA_HOOKS_LOG_DIR.
.EXAMPLE
    $json = '{"sessionId":"s1","cwd":"C:\\work","timestamp":"2026-05-05T09:00:00Z"}'
    echo $json | pwsh -NoProfile -File Log-SessionStart.ps1
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

[string]$script:ScriptVersion = '1.0.0'

try {
    $payload = Get-HookInput
    $logDir  = Get-LogDirectory
    $logPath = Join-Path $logDir 'sessions.jsonl'

    # Preserve ISO 8601 timestamps: ConvertFrom-Json auto-converts date strings
    # to [DateTime] objects, so we re-format to 'o' (round-trip) when needed.
    $tsRaw = if ($payload) { $payload.timestamp } else { $null }
    $ts    = if ($tsRaw -is [datetime]) { $tsRaw.ToString('o') } elseif ($tsRaw) { [string]$tsRaw } else { (Get-Date -Format 'o') }

    $entry = @{
        event         = 'sessionStart'
        sessionId     = if ($payload -and $payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }
        cwd           = if ($payload -and $payload.cwd)       { [string]$payload.cwd }       else { '' }
        timestamp     = $ts
        user          = Get-CurrentUser
        scriptVersion = $script:ScriptVersion
    }

    Write-AuditEntry -Path $logPath -Entry $entry
    Write-Verbose "Log-SessionStart: wrote entry for session $($entry.sessionId)"
}
catch {
    Write-Warning "Log-SessionStart: unexpected error — $($_.Exception.Message)"
}

exit 0
