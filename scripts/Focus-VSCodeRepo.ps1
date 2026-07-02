#requires -Version 5.1
<#
.SYNOPSIS
    Clickback handler for the `copilot-clickback://` custom URL protocol.

.DESCRIPTION
    Invoked by Windows when the user clicks a Copilot notification toast whose
    activation URI is `copilot-clickback://open?path=<urlencoded-repo-path>`.

    Decodes the repo path from the URI query string and focuses/reuses the
    matching VS Code window via `code -r <repoPath>`. In this user's workflow
    each repo has its own VS Code window, so `-r` (reuse window) raises the
    existing window for that folder instead of spawning a fresh instance the
    way the generic `vscode://file/<path>` protocol handler did.

    Registered per-user under HKCU\Software\Classes\copilot-clickback (see
    Register-CopilotClickbackProtocol in _Common.ps1). Fully reversible — see
    README.md "Custom clickback protocol" rollback section.

.PARAMETER Uri
    The full activation URI passed by Windows as %1, e.g.
    `copilot-clickback://open?path=C%3A%5CUsers%5Cme%5Crepo`.

.NOTES
    Fail-open and non-interactive: never blocks, never prompts, never throws to
    the OS. Diagnostic outcomes are appended to logs/clickback.jsonl.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Uri
)

$ErrorActionPreference = 'Stop'

# Resolve the hooks log directory relative to this script (scripts\ -> ..\logs).
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
$logPath = Join-Path $logDir 'clickback.jsonl'

function Write-ClickbackLog {
    param([hashtable]$Entry)
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $Entry['timestamp'] = (Get-Date -Format 'o')
        ($Entry | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $logPath -Encoding utf8
    }
    catch {
        # Logging must never break clickback.
    }
}

try {
    if (-not $Uri) {
        Write-ClickbackLog @{ event = 'clickback_error'; error = 'no_uri_argument' }
        return
    }

    # Parse the URI and extract the `path` query parameter.
    $repoPath = $null
    try {
        $parsed = [System.Uri]$Uri
        $query = $parsed.Query  # e.g. ?path=C%3A%5C...
        if ($query -and $query.Length -gt 1) {
            $pairs = $query.TrimStart('?') -split '&'
            foreach ($pair in $pairs) {
                $kv = $pair -split '=', 2
                if ($kv.Length -eq 2 -and $kv[0] -eq 'path') {
                    $repoPath = [System.Uri]::UnescapeDataString($kv[1])
                    break
                }
            }
        }
    }
    catch {
        Write-ClickbackLog @{ event = 'clickback_error'; error = ('uri_parse_failed: ' + $_.Exception.Message) }
        return
    }

    if (-not $repoPath) {
        Write-ClickbackLog @{ event = 'clickback_error'; error = 'no_path_param' }
        return
    }

    # Normalise and validate the decoded path before launching anything.
    $repoPath = $repoPath.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $repoPath)) {
        Write-ClickbackLog @{ event = 'clickback_error'; error = 'path_not_found'; repoName = (Split-Path $repoPath -Leaf) }
        return
    }

    # Focus/reuse the existing VS Code window for this folder. `code` is a .cmd
    # shim, so route through cmd.exe for reliable resolution. -r reuses the
    # matching window instead of opening a new instance.
    Start-Process -FilePath 'cmd.exe' `
        -ArgumentList '/c', 'code', '-r', ('"' + $repoPath + '"') `
        -WindowStyle Hidden

    Write-ClickbackLog @{ event = 'clickback_focus'; method = 'code -r'; repoName = (Split-Path $repoPath -Leaf) }
}
catch {
    Write-ClickbackLog @{ event = 'clickback_error'; error = $_.Exception.Message }
}
