#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI hook: logs a postToolUse event to audit.jsonl.
.DESCRIPTION
    Fires on the postToolUse lifecycle hook. Reads the JSON payload from stdin,
    writes one JSONL entry to .github/hooks/logs/audit.jsonl, and exits 0.

    Phase 1 PII rule: toolArgs and toolResult.textResultForLlm are NEVER logged
    raw. Only a 12-character SHA-256 hash of toolArgs is written (argHash).

    Never blocks tool execution — all errors are caught and logged as warnings.

    Expected stdin fields : sessionId, timestamp, cwd, toolName, toolArgs,
                            toolResult.resultType
    Written JSONL fields  : event, timestamp, sessionId, toolName, resultType,
                            argHash

    Log directory override for test isolation: set $env:PA_HOOKS_LOG_DIR.
.EXAMPLE
    $json = '{"sessionId":"s1","timestamp":"2026-05-05T09:00:00Z","toolName":"obsidian-read_note","toolArgs":{"path":"notes/x.md"},"toolResult":{"resultType":"success"}}'
    echo $json | pwsh -NoProfile -File Log-ToolUse.ps1
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

try {
    $payload = Get-HookInput
    $logDir  = Get-LogDirectory
    $logPath = Join-Path $logDir 'audit.jsonl'

    # Preserve ISO 8601 timestamps: ConvertFrom-Json auto-converts date strings
    # to [DateTime] objects, so we re-format to 'o' (round-trip) when needed.
    $tsRaw = if ($payload) { $payload.timestamp } else { $null }
    $ts    = if ($tsRaw -is [datetime]) { $tsRaw.ToString('o') } elseif ($tsRaw) { [string]$tsRaw } else { (Get-Date -Format 'o') }

    $entry = @{
        event      = 'postToolUse'
        timestamp  = $ts
        sessionId  = if ($payload -and $payload.sessionId)                                     { [string]$payload.sessionId }                        else { 'unknown' }
        toolName   = if ($payload -and $payload.toolName)                                      { [string]$payload.toolName }                         else { 'unknown' }
        resultType = if ($payload -and $payload.toolResult -and $payload.toolResult.resultType) { [string]$payload.toolResult.resultType }            else { 'unknown' }
        argHash    = Get-ArgHash -ToolArgs ($payload ? $payload.toolArgs : $null)
    }

    Write-AuditEntry -Path $logPath -Entry $entry
    Write-Verbose "Log-ToolUse: $($entry.toolName) [$($entry.resultType)] in session $($entry.sessionId)"
}
catch {
    Write-Warning "Log-ToolUse: unexpected error — $($_.Exception.Message)"
}

exit 0
