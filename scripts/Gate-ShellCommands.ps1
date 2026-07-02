#Requires -Version 7.0
<#
.SYNOPSIS
    Copilot CLI preToolUse hook: gates gh, az, and git shell commands via rule files.
.DESCRIPTION
    Fires on preToolUse for powershell/bash tools. Extracts the command line from
    toolArgs.command, detects if it invokes gh, az, or git CLI, loads the corresponding
    guardrails JSON (gh-guardrails.json, az-guardrails.json, or git-guardrails.json),
    and evaluates rules in first-match-wins order.

    Rule actions:
      deny  — block outright, emit deny decision
      ask   — invoke Show-GatePrompt.ps1 popup (or fallback to CLI ask)
      allow — pass through silently

    Default posture (unmatched commands): ALLOW.

    Graceful degradation:
      - Missing guardrails JSON = allow + warning (don't crash)
      - Missing Show-GatePrompt.ps1 = fall back to CLI 'ask'
      - Malformed JSON = allow + warning
      - Any uncaught error = allow (fail-OPEN for shell commands — we don't want
        to break every shell session on a config bug)

    Audit: All deny/ask decisions are logged to audit.jsonl.
.NOTES
    Located at: ~/.copilot/hooks/scripts/Gate-ShellCommands.ps1
    Dependencies: _Common.ps1 (same directory), Show-GatePrompt.ps1 (optional)
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Common.ps1')

# ─── Helper: Load guardrails JSON ────────────────────────────────────────────
function Get-GuardrailRules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JsonPath
    )

    if (-not (Test-Path $JsonPath)) {
        Write-Verbose "Get-GuardrailRules: file not found at $JsonPath — no rules loaded"
        return $null
    }

    try {
        $raw = Get-Content $JsonPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = $raw | ConvertFrom-Json
        return $parsed
    }
    catch {
        Write-Warning "Get-GuardrailRules: failed to parse $JsonPath — $($_.Exception.Message)"
        return $null
    }
}

# ─── Helper: Extract the CLI invocation from a command string ─────────────────
function Get-CliInvocation {
    <#
    .SYNOPSIS
        Extracts the first gh, az, or git invocation from a command string.
    .DESCRIPTION
        Handles common patterns:
          gh pr list ...
          & gh pr merge ...
          pwsh -c "gh ..."
          az group list ...
          & az vm delete ...
          git push --force origin main
          & git status
          git.exe status
        Returns the CLI name ('gh', 'az', or 'git') and the full command portion
        starting from that token. Returns $null if no gated CLI is found.

        IMPORTANT: Token matching is exact. 'gh' does NOT match 'git' — the
        regex uses alternation with word boundaries to prevent collisions.
        The .exe suffix is stripped for matching (git.exe → git).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }

    # Match git, gh, or az as a standalone token. Order matters: 'git' before 'gh'
    # to prevent 'gh' from greedily matching the 'g' in 'git'.
    # Handles: leading &, pwsh -c ", cmd /c, quoted strings, .exe suffix
    # The (?:\.exe)? handles git.exe / gh.exe / az.exe variants.
    if ($CommandLine -match '(?:^|[&|;"\s])((git|gh|az)(?:\.exe)?\s+.*)') {
        $matched = $Matches[1].TrimEnd('"', "'", ';')
        $cli = $Matches[2]
        # Normalize: strip .exe from the command for rule matching
        $matched = $matched -replace '^(git|gh|az)\.exe\s', '$1 '
        return @{ Cli = $cli; Command = $matched }
    }
    # Handle: command starts directly with git/gh/az (with optional .exe)
    if ($CommandLine -match '^(git|gh|az)(?:\.exe)?\s+') {
        $cli = $Matches[1]
        $normalized = $CommandLine -replace '^(git|gh|az)\.exe\s', '$1 '
        return @{ Cli = $cli; Command = $normalized }
    }

    return $null
}

# ─── Helper: Evaluate rules ──────────────────────────────────────────────────
function Invoke-RuleEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$CommandLine
    )

    if ($null -eq $Config -or $null -eq $Config.rules) {
        return @{ Action = 'allow'; Reason = 'No rules loaded — default allow' }
    }

    foreach ($rule in $Config.rules) {
        if ([string]::IsNullOrWhiteSpace($rule.pattern)) { continue }
        try {
            if ($CommandLine -match $rule.pattern) {
                return @{
                    Action  = $rule.action
                    Reason  = $rule.reason
                    Pattern = $rule.pattern
                }
            }
        }
        catch {
            # Invalid regex — skip this rule, don't crash
            Write-Warning "Invoke-RuleEvaluation: invalid regex '$($rule.pattern)' — $($_.Exception.Message)"
            continue
        }
    }

    # No match — use default action from config
    $defaultAction = if ($Config.defaultAction) { $Config.defaultAction } else { 'allow' }
    return @{ Action = $defaultAction; Reason = 'No rule matched — default posture' }
}

# ─── Helper: Normalize git global options ─────────────────────────────────────
function Normalize-GitCommand {
    <#
    .SYNOPSIS
        Strips git global options from between 'git' and the subcommand.
    .DESCRIPTION
        Git accepts global options before the subcommand (e.g. git --no-pager push,
        git -c key=value commit, git -C /path status). Rule patterns like 'git\s+push'
        won't match these variants. This function normalizes the command by removing
        global options so rules match consistently.

        Handles:
          - Simple flags: --no-pager, --bare, --no-optional-locks, -p, --paginate, etc.
          - Flags with =value: --git-dir=/path, --work-tree=/path, --config-env=NAME=VAR
          - Flags with separate value: -c key=value, -C /path, --git-dir /path

        If the command is not a git command, it is returned unchanged.
        Unrecognized flags are left intact (fail-safe: the original command
        passes to rule evaluation, which defaults to allow on no match).
    .PARAMETER Command
        The full git command string (starting with 'git ').
    .OUTPUTS
        [string] Normalized git command with global options removed.
    .EXAMPLE
        Normalize-GitCommand -Command 'git --no-pager push origin main'
        # Returns: 'git push origin main'
    .EXAMPLE
        Normalize-GitCommand -Command 'git -c user.name=test --no-pager commit -m "fix"'
        # Returns: 'git commit -m "fix"'
    .EXAMPLE
        Normalize-GitCommand -Command 'git -C /repo --bare status'
        # Returns: 'git status'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    if ($Command -notmatch '^git(?:\.exe)?\s') { return $Command }

    # Separate 'git' prefix from the rest
    $rest = $Command -replace '^git(?:\.exe)?\s+', ''

    # Iteratively strip global options from the front until none remain.
    # Each pass may reveal another option behind the one just stripped.
    $changed = $true
    while ($changed) {
        $before = $rest

        # Flags with =value: --git-dir=X, --work-tree=X, --namespace=X,
        # --exec-path=X, --config-env=X, --super-prefix=X, --list-cmds=X
        $rest = $rest -replace "^--(git-dir|work-tree|namespace|exec-path|config-env|super-prefix|list-cmds)=\S+\s*", ''

        # -c key=value (separate argument — handles quoted values too)
        $rest = $rest -replace '^-c\s+(?:"[^"]*"|''[^'']*''|\S+)\s*', ''

        # -C path (separate argument — handles quoted paths)
        $rest = $rest -replace '^-C\s+(?:"[^"]*"|''[^'']*''|\S+)\s*', ''

        # --git-dir path, --work-tree path, --namespace path (separate argument form)
        $rest = $rest -replace '^--(git-dir|work-tree|namespace)\s+(?:"[^"]*"|''[^'']*''|\S+)\s*', ''

        # Simple flags (no argument)
        $rest = $rest -replace '^(-p|--paginate|--no-pager|--bare|--no-replace-objects|--no-optional-locks|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--html-path|--man-path|--info-path)\s*', ''

        $changed = ($rest -ne $before)
    }

    if ([string]::IsNullOrWhiteSpace($rest)) { return 'git' }
    return "git $rest"
}

# ─── Main ────────────────────────────────────────────────────────────────────
try {
    $payload = Get-HookInput
    if ($null -eq $payload) {
        # Can't parse payload — allow (fail-open for shell to avoid breaking sessions)
        Write-GateDecision -Decision 'allow' -Reason 'Empty/invalid payload — allowing shell command'
        exit 0
    }

    # Extract the command line from toolArgs
    $toolArgs = $payload.toolArgs
    # Handle double-serialized toolArgs (string instead of object)
    if ($toolArgs -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$toolArgs)) {
        try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { }
    }

    $commandLine = $null
    if ($null -ne $toolArgs) {
        # Copilot CLI powershell tool: toolArgs.command contains the shell command
        if ($toolArgs.PSObject -and $toolArgs.PSObject.Properties['command']) {
            $commandLine = [string]$toolArgs.command
        }
        elseif ($toolArgs -is [string]) {
            $commandLine = $toolArgs
        }
    }

    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        # No command to evaluate — allow
        Write-GateDecision -Decision 'allow' -Reason 'No command line found in toolArgs'
        exit 0
    }

    # Detect gh, az, or git invocation
    $cliInfo = Get-CliInvocation -CommandLine $commandLine
    if ($null -eq $cliInfo) {
        # Not a gh/az/git command — allow (we only gate those)
        Write-GateDecision -Decision 'allow' -Reason 'Not a gh/az/git command'
        exit 0
    }

    $cli = $cliInfo.Cli
    $cliCommand = $cliInfo.Command

    # Normalize git commands: strip global options (e.g. --no-pager, -c key=val)
    # that appear between 'git' and the subcommand so rule patterns match.
    if ($cli -eq 'git') {
        $cliCommand = Normalize-GitCommand -Command $cliCommand
    }

    # ── Feature flags ───────────────────────────────────────────────────────
    # shellGuardrails.enabled=false turns the gate OFF (allow all gated CLIs).
    # shellGuardrails.prompts=false runs audit-only: 'ask' rules auto-allow but
    # are still logged; hard 'deny' rules stay enforced for safety.
    $features          = Get-HookFeatureConfig
    $featGuardEnabled  = Test-HookFeatureEnabled -Name 'shellGuardrails.enabled' -Config $features
    $featGuardPrompts  = Test-HookFeatureEnabled -Name 'shellGuardrails.prompts' -Config $features

    if (-not $featGuardEnabled) {
        try {
            $logDir    = Get-LogDirectory
            $auditPath = Join-Path $logDir 'audit.jsonl'
            Write-AuditEntry -Path $auditPath -Entry @{
                event     = 'shellGateDisabledByFlag'
                flag      = 'shellGuardrails.enabled'
                cli       = $cli
                command   = $cliCommand.Substring(0, [Math]::Min($cliCommand.Length, 120))
                sessionId = if ($payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }
                timestamp = (Get-Date).ToString('o')
            }
        } catch { }
        Write-GateDecision -Decision 'allow' -Reason "Shell guardrails disabled by feature flag — allowing $cli command"
        exit 0
    }

    # Load the appropriate guardrails JSON
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $jsonPath = Join-Path $hooksDir "$cli-guardrails.json"
    $config = Get-GuardrailRules -JsonPath $jsonPath

    if ($null -eq $config) {
        # Missing or broken config — allow with warning (graceful degradation)
        Write-GateDecision -Decision 'allow' -Reason "No guardrails config for $cli — allowing by default"
        exit 0
    }

    # Evaluate rules
    $result = Invoke-RuleEvaluation -Config $config -CommandLine $cliCommand

    switch ($result.Action) {
        'deny' {
            # Log and deny
            try {
                $logDir    = Get-LogDirectory
                $auditPath = Join-Path $logDir 'audit.jsonl'
                Write-AuditEntry -Path $auditPath -Entry @{
                    event     = 'shellGateDeny'
                    cli       = $cli
                    command   = $cliCommand.Substring(0, [Math]::Min($cliCommand.Length, 120))
                    pattern   = $result.Pattern
                    reason    = $result.Reason
                    sessionId = if ($payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }
                    timestamp = (Get-Date).ToString('o')
                }
            } catch { }
            Write-GateDecision -Decision 'deny' -Reason "BLOCKED: $($result.Reason)"
            exit 0
        }
        'ask' {
            # Audit-only mode: when prompts are disabled, skip the popup and
            # auto-allow, but still record the decision for visibility.
            if (-not $featGuardPrompts) {
                try {
                    $logDir    = Get-LogDirectory
                    $auditPath = Join-Path $logDir 'audit.jsonl'
                    Write-AuditEntry -Path $auditPath -Entry @{
                        event     = 'shellGateAskAuditOnly'
                        flag      = 'shellGuardrails.prompts'
                        cli       = $cli
                        command   = $cliCommand.Substring(0, [Math]::Min($cliCommand.Length, 120))
                        pattern   = $result.Pattern
                        reason    = $result.Reason
                        sessionId = if ($payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }
                        timestamp = (Get-Date).ToString('o')
                    }
                } catch { }
                Write-GateDecision -Decision 'allow' -Reason "Audit-only (prompts disabled): $($result.Reason)"
                exit 0
            }

            # Try popup; fall back to CLI ask
            $popupResult = $null
            $showGateScript = Join-Path $PSScriptRoot 'Show-GatePrompt.ps1'

            if (Test-Path $showGateScript) {
                try {
                    . $showGateScript
                    $truncCmd = if ($cliCommand.Length -gt 80) { $cliCommand.Substring(0, 77) + '...' } else { $cliCommand }
                    $popupResult = Show-GatePrompt `
                        -Title "Approve $cli command?" `
                        -Body "$($result.Reason)`n`nCommand: $truncCmd" `
                        -TimeoutSeconds 120
                }
                catch {
                    # Popup failed — fall through to CLI ask
                    $popupResult = $null
                }
            }

            # Audit the decision
            try {
                $logDir    = Get-LogDirectory
                $auditPath = Join-Path $logDir 'audit.jsonl'
                Write-AuditEntry -Path $auditPath -Entry @{
                    event      = 'shellGateAsk'
                    cli        = $cli
                    command    = $cliCommand.Substring(0, [Math]::Min($cliCommand.Length, 120))
                    pattern    = $result.Pattern
                    reason     = $result.Reason
                    popup      = if ($popupResult) { $popupResult } else { 'fallback' }
                    sessionId  = if ($payload.sessionId) { [string]$payload.sessionId } else { 'unknown' }
                    timestamp  = (Get-Date).ToString('o')
                }
            } catch { }

            # Map popup result to decision
            switch ($popupResult) {
                'Allow' {
                    Write-GateDecision -Decision 'allow' -Reason "User approved: $($result.Reason)"
                    exit 0
                }
                'Deny' {
                    Write-GateDecision -Decision 'deny' -Reason "User denied: $($result.Reason)"
                    exit 0
                }
                'Timeout' {
                    Write-GateDecision -Decision 'deny' -Reason "Popup timeout — denied: $($result.Reason)"
                    exit 0
                }
                default {
                    # NoGui, null, or popup not available — fall back to CLI ask
                    Write-GateDecision -Decision 'ask' -Reason "$($result.Reason)"
                    exit 0
                }
            }
        }
        default {
            # 'allow' or unrecognized action
            Write-GateDecision -Decision 'allow' -Reason $result.Reason
            exit 0
        }
    }
}
catch {
    # Fail-OPEN for shell commands — we don't want to break every shell session
    # on a script bug. This is intentionally different from Gate-HighRiskTools
    # which fails CLOSED (for MCP tool safety). Shell commands have a broader
    # blast radius if blocked incorrectly.
    Write-GateDecision -Decision 'allow' -Reason "Gate script error (fail-open): $($_.Exception.Message)"
    exit 0
}
