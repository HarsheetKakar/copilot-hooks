#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI hook: logs a sessionEnd event with tool-call tally to sessions.jsonl.
.DESCRIPTION
    Fires on the sessionEnd lifecycle hook. Reads the JSON payload from stdin,
    counts matching sessionId entries in the last 1000 lines of audit.jsonl (to
    avoid a full-file scan on large logs), writes one JSONL summary entry to
    sessions.jsonl, and exits 0.

    Never blocks session end — all errors are caught and logged as warnings.

    Expected stdin fields : sessionId, timestamp
    Written JSONL fields  : event, sessionId, timestamp, toolCallCount

    Log directory override for test isolation: set $env:PA_HOOKS_LOG_DIR.
.EXAMPLE
    $json = '{"sessionId":"s1","timestamp":"2026-05-05T10:00:00Z"}'
    echo $json | pwsh -NoProfile -File Log-SessionEnd.ps1
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

try {
    $payload     = Get-HookInput
    $logDir      = Get-LogDirectory
    $auditPath   = Join-Path $logDir 'audit.jsonl'
    $sessionPath = Join-Path $logDir 'sessions.jsonl'

    $sessionId = if ($payload -and $payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }

    # Tally tool calls for this session from the last 1000 lines of audit.jsonl.
    # Reading only the tail avoids a full-file scan on large audit logs.
    $toolCallCount = 0
    if (Test-Path $auditPath) {
        $tail = Get-Content $auditPath -Tail 1000
        foreach ($line in $tail) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $parsed = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($parsed -and $parsed.sessionId -eq $sessionId) {
                    $toolCallCount++
                }
            }
            catch {
                # Malformed line — skip silently, don't break the tally
            }
        }
    }

    # Preserve ISO 8601 timestamps: ConvertFrom-Json auto-converts date strings
    # to [DateTime] objects, so we re-format to 'o' (round-trip) when needed.
    $tsRaw = if ($payload) { $payload.timestamp } else { $null }
    $ts    = if ($tsRaw -is [datetime]) { $tsRaw.ToString('o') } elseif ($tsRaw) { [string]$tsRaw } else { (Get-Date -Format 'o') }

    $entry = @{
        event         = 'sessionEnd'
        sessionId     = $sessionId
        timestamp     = $ts
        toolCallCount = $toolCallCount
    }

    Write-AuditEntry -Path $sessionPath -Entry $entry
    Write-Verbose "Log-SessionEnd: session $sessionId ended with $toolCallCount tool calls"
}
catch {
    Write-Warning "Log-SessionEnd: unexpected error — $($_.Exception.Message)"
}

exit 0
