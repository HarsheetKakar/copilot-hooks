#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helper functions dot-sourced by all Copilot CLI hook scripts.
.DESCRIPTION
    Provides helper functions used across hook scripts:

    Phase 1 (audit logging):
      Get-HookInput    — reads and parses the JSON payload from stdin
      Get-LogDirectory — resolves the hooks log directory, creating it if absent
      Write-AuditEntry — appends one JSONL line with automatic 10 MB rotation
      Get-ArgHash      — SHA-256 fingerprint of tool args (first 12 hex chars)
      Get-CurrentUser  — git config user.name → $env:USERNAME → "unknown"

    Phase 2 (gate enforcement):
      Get-GateConfig       — reads ~/.copilot/config.json hooks section; safe defaults
      Write-GateDecision   — writes compact JSON decision to stdout

    Dot-source at the top of each hook script:
        . (Join-Path $PSScriptRoot '_Common.ps1')

    Test isolation: set $env:PA_HOOKS_LOG_DIR before invoking hook scripts
    to redirect all log output to a temp directory.
    Set $env:PA_GATE_CONFIG_PATH to override the gate config file path.

.NOTES
    Do NOT run directly. Intended for dot-sourcing only.
    $PSScriptRoot in this file resolves to the CALLING script's directory.
    All log scripts live in scripts/ (one level above logs/), so the default
    log path computation — Join-Path $PSScriptRoot '..' 'logs' — is correct.
#>

# Force UTF-8 on both Console streams — Windows defaults to the OEM codepage
# (CP437 for US English) which corrupts multibyte characters when Copilot CLI
# sends UTF-8 bytes on stdin (e.g., em-dash U+2014 → mojibake "ΓÇö").
# Set once at dot-source time; affects only this PowerShell process.
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Read-HookJson {
    <#
    .SYNOPSIS
        Parses a raw JSON string into a PSCustomObject.
    .DESCRIPTION
        Factored out of Get-HookInput for testability. Takes an already-decoded
        string; returns $null (silently) if the string is empty or whitespace,
        and returns $null (with a warning) if the JSON is malformed.
        Never throws — callers must guard against a $null return value.
    .PARAMETER InputString
        The raw JSON string to parse.
    .OUTPUTS
        [PSCustomObject] Parsed payload, or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InputString
    )

    if ([string]::IsNullOrWhiteSpace($InputString)) { return $null }
    return $InputString | ConvertFrom-Json
}

function Get-HookInput {
    <#
    .SYNOPSIS
        Reads the JSON payload from stdin and returns a PSCustomObject.
    .DESCRIPTION
        Reads all stdin via [Console]::In.ReadToEnd() and delegates parsing to
        Read-HookJson. Console.InputEncoding is forced to UTF-8 at module load
        time (see top of _Common.ps1) so UTF-8 bytes from Copilot CLI are never
        mis-decoded as CP437/Windows-1252.
        Returns $null with a warning if stdin is empty or the JSON is malformed.
        Never throws — callers must guard against a $null return value.
    .OUTPUTS
        [PSCustomObject] Parsed payload, or $null on failure.
    #>
    [CmdletBinding()]
    param()

    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning 'Get-HookInput: stdin was empty — returning $null'
            return $null
        }
        return Read-HookJson -InputString $raw
    }
    catch {
        Write-Warning "Get-HookInput: failed to parse stdin as JSON — $($_.Exception.Message)"
        return $null
    }
}

function Get-LogDirectory {
    <#
    .SYNOPSIS
        Returns the absolute path to the hooks log directory, creating it if absent.
    .DESCRIPTION
        Default resolution: one level above the calling script's PSScriptRoot,
        then into logs/ (i.e. .github/hooks/logs/ when scripts live in scripts/).

        Override by setting $env:PA_HOOKS_LOG_DIR — used for Pester test isolation
        so that tests never write to the real .github/hooks/logs/ directory.
    .OUTPUTS
        [string] Absolute path to the log directory.
    #>
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:PA_HOOKS_LOG_DIR)) {
        $logDir = $env:PA_HOOKS_LOG_DIR
    }
    else {
        $logDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'logs'))
    }

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-Verbose "Get-LogDirectory: created $logDir"
    }

    return $logDir
}

function Write-AuditEntry {
    <#
    .SYNOPSIS
        Appends a single JSONL line to an audit log file with 10 MB rotation.
    .DESCRIPTION
        Serialises Entry as compact JSON and appends one line to Path using
        UTF-8 without BOM. Before appending, checks the current file size:
        if the file is >= 10 MB it is renamed to {stem}.{yyyyMMddHHmmss}.jsonl
        and a fresh file is started. Creates the parent directory if absent.

        JSONL files are append-only by design. Deduplication, if needed,
        happens at analysis time — not at write time.
    .PARAMETER Path
        Full path to the target .jsonl file.
    .PARAMETER Entry
        Hashtable of fields to serialise and append as one JSON line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    # Ensure parent directory exists
    $parentDir = Split-Path $Path -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        Write-Verbose "Write-AuditEntry: created directory $parentDir"
    }

    # Rotation guard: rename the current file when it reaches 10 MB
    if (Test-Path $Path) {
        $fileSizeBytes = (Get-Item $Path).Length
        if ($fileSizeBytes -ge 10MB) {
            $ts      = Get-Date -Format 'yyyyMMddHHmmss'
            $stem    = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $rotName = "$stem.$ts.jsonl"
            Rename-Item -Path $Path -NewName $rotName
            Write-Verbose "Write-AuditEntry: rotated $(Split-Path $Path -Leaf) → $rotName"
        }
    }

    $line = $Entry | ConvertTo-Json -Compress -Depth 10
    Add-Content -Path $Path -Value $line -Encoding utf8NoBOM
    Write-Verbose "Write-AuditEntry: appended to $Path"
}

function Get-ArgHash {
    <#
    .SYNOPSIS
        Returns the first 12 hex characters of the SHA-256 hash of the serialised args.
    .DESCRIPTION
        Serialises ToolArgs with ConvertTo-Json -Compress -Depth 10, computes SHA-256
        over the UTF-8 bytes, and returns the first 12 lowercase hex characters.
        Used to fingerprint tool arguments without storing raw (potentially sensitive)
        values in audit logs.
    .PARAMETER ToolArgs
        The tool arguments object to hash (typically payload.toolArgs).
    .OUTPUTS
        [string] 12-character lowercase hex string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ToolArgs
    )

    $json   = $ToolArgs | ConvertTo-Json -Compress -Depth 10
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    $hex = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    return $hex.Substring(0, 12)
}

function Get-CurrentUser {
    <#
    .SYNOPSIS
        Returns a user identifier suitable for audit log entries.
    .DESCRIPTION
        Resolution order:
          1. git config user.name  (trimmed)
          2. $env:USERNAME
          3. "unknown"

        Returns only runtime-resolved values — never a hard-coded name.
    .OUTPUTS
        [string] User identifier.
    #>
    [CmdletBinding()]
    param()

    try {
        $gitUser = git config user.name 2>$null
        if (-not [string]::IsNullOrWhiteSpace($gitUser)) {
            return $gitUser.Trim()
        }
    }
    catch {
        Write-Verbose "Get-CurrentUser: git config lookup failed — $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        return $env:USERNAME
    }

    return 'unknown'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Feature Flags (toggle hook capabilities without editing scripts)
# ═══════════════════════════════════════════════════════════════════════════════

function Get-HookFeatureConfig {
    <#
    .SYNOPSIS
        Reads the hook feature-flag config (hook-features.json) from the hooks root.
    .DESCRIPTION
        Resolves the file from PA_HOOK_FEATURES_PATH (test/override) or from the
        hooks root (one level above scripts/). Returns the "features" object if
        present, otherwise the top-level object, otherwise $null. Never throws —
        a $null return means "no config; callers fall back to enabled-by-default".
    .OUTPUTS
        [object] Parsed features object (PSCustomObject), or $null when unavailable.
    #>
    [CmdletBinding()]
    param()

    try {
        $configPath = if (-not [string]::IsNullOrWhiteSpace($env:PA_HOOK_FEATURES_PATH)) {
            $env:PA_HOOK_FEATURES_PATH
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'hook-features.json'))
        }

        if (-not (Test-Path $configPath)) {
            Write-Verbose "Get-HookFeatureConfig: no config at $configPath — defaults apply"
            return $null
        }

        $raw = Get-Content $configPath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        $json = $raw | ConvertFrom-Json
        if ($null -eq $json) { return $null }
        if ($json.PSObject.Properties['features'] -and $null -ne $json.features) {
            return $json.features
        }
        return $json
    }
    catch {
        Write-Verbose "Get-HookFeatureConfig: $($_.Exception.Message) — defaults apply"
        return $null
    }
}

function Test-HookFeatureEnabled {
    <#
    .SYNOPSIS
        Returns whether a hook feature is enabled. Defaults to enabled.
    .DESCRIPTION
        Precedence (highest first):
          1. Env override: PA_HOOK_FEATURE_<NAME> where <NAME> is the dotted Name
             upper-cased with '.' and '-' replaced by '_'. Truthy values
             (1/true/on/yes/enable[d]) → $true; falsy (0/false/off/no/disable[d])
             → $false. Any other value is ignored and precedence falls through.
             NOTE: shellGuardrails.* features ignore env overrides entirely — the
             shell command gate must never be disableable from the environment.
             Only the config file may toggle shellGuardrails.
          2. The features config object (pass via -Config; read once per script
             with Get-HookFeatureConfig). A leaf boolean is honored.
          3. The -Default value ($true) — used when the key is absent/null or the
             config is $null. This is what preserves current behavior when the
             config file is missing.
        Never throws.
    .PARAMETER Name
        Dotted feature path, e.g. 'notifications.clickback' or 'shellGuardrails.enabled'.
    .PARAMETER Config
        Features object from Get-HookFeatureConfig (or $null).
    .PARAMETER Default
        Value returned when neither env nor config resolves the flag. Default $true.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Config,

        [bool]$Default = $true
    )

    # 1. Environment variable override (highest priority) — NOT honored for
    #    shellGuardrails.* features. The shell command gate must never be
    #    disableable via an environment variable; only the config file may
    #    toggle it. Notification features still support env overrides.
    if ($Name -notlike 'shellGuardrails*') {
        $envName = 'PA_HOOK_FEATURE_' + (($Name -replace '[.\-]', '_').ToUpperInvariant())
        $envVal  = [System.Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) {
            switch ($envVal.Trim().ToLowerInvariant()) {
                '0'        { return $false }
                'false'    { return $false }
                'off'      { return $false }
                'no'       { return $false }
                'disable'  { return $false }
                'disabled' { return $false }
                '1'        { return $true }
                'true'     { return $true }
                'on'       { return $true }
                'yes'      { return $true }
                'enable'   { return $true }
                'enabled'  { return $true }
            }
        }
    }

    # 2. Config file lookup (walk the dotted path)
    if ($null -eq $Config) { return $Default }
    $node = $Config
    foreach ($seg in ($Name -split '\.')) {
        if ($null -eq $node -or -not $node.PSObject -or -not $node.PSObject.Properties[$seg]) {
            return $Default
        }
        $node = $node.PSObject.Properties[$seg].Value
    }

    if ($null -eq $node)   { return $Default }
    if ($node -is [bool])  { return [bool]$node }

    # 3. Non-boolean leaf (e.g. a nested object) — treat as not explicitly disabled
    return $Default
}

function Get-GateConfig {
    <#
    .SYNOPSIS
        Reads hook gate configuration from .copilot/config.json.
    .DESCRIPTION
        Resolves the config file path from PA_GATE_CONFIG_PATH env var (test override)
        or from $env:USERPROFILE (Windows) / $HOME (Unix) + .copilot/config.json.
        Looks for a "hooks" key in the JSON; falls back to top-level keys if absent.
        Returns a hashtable with gate configuration keys. Returns safe defaults if the
        file is missing, empty, or malformed. Never throws.
    .OUTPUTS
        [hashtable] Gate configuration with keys: gateMode, logActivity, quietHours.
    #>
    [CmdletBinding()]
    param()

    $defaults = @{
        gateMode    = 'enforce'
        logActivity = $true
        quietHours  = @{
            enabled = $false
            start   = '22:00'
            end     = '07:00'
        }
    }

    try {
        $configPath = if (-not [string]::IsNullOrWhiteSpace($env:PA_GATE_CONFIG_PATH)) {
            $env:PA_GATE_CONFIG_PATH
        }
        else {
            $homeDir = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $env:USERPROFILE
            }
            else {
                $HOME
            }
            Join-Path $homeDir '.copilot' 'config.json'
        }

        if (-not (Test-Path $configPath)) {
            Write-Verbose "Get-GateConfig: config not found at $configPath — using defaults"
            return $defaults
        }

        $raw = Get-Content $configPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Verbose "Get-GateConfig: config file is empty — using defaults"
            return $defaults
        }

        $json = $raw | ConvertFrom-Json
        $src  = if ($json -and $json.hooks) { $json.hooks } else { $json }
        if ($null -eq $src) {
            Write-Verbose "Get-GateConfig: config parsed to null — using defaults"
            return $defaults
        }

        return @{
            gateMode    = if (-not [string]::IsNullOrWhiteSpace($src.gateMode))                                    { [string]$src.gateMode }         else { $defaults.gateMode }
            logActivity = if ($null -ne $src.logActivity)                                                          { [bool]$src.logActivity }         else { $defaults.logActivity }
            quietHours  = @{
                enabled = if ($src.quietHours -and ($null -ne $src.quietHours.enabled))                            { [bool]$src.quietHours.enabled }  else { $defaults.quietHours.enabled }
                start   = if ($src.quietHours -and (-not [string]::IsNullOrWhiteSpace($src.quietHours.start)))     { [string]$src.quietHours.start }  else { $defaults.quietHours.start }
                end     = if ($src.quietHours -and (-not [string]::IsNullOrWhiteSpace($src.quietHours.end)))       { [string]$src.quietHours.end }    else { $defaults.quietHours.end }
            }
        }
    }
    catch {
        Write-Verbose "Get-GateConfig: error reading config — $($_.Exception.Message) — using defaults"
        return $defaults
    }
}

function Write-GateDecision {
    <#
    .SYNOPSIS
        Writes a compact JSON gate decision to stdout.
    .DESCRIPTION
        Outputs a single JSON line to stdout for consumption by the Copilot
        CLI hooks subsystem. Uses Write-Output (not Write-Host) so that the
        decision is captured on stdout, not the console information stream.
        Always exits 0 after calling this — the CLI reads the decision from
        stdout, not from the exit code.
    .PARAMETER Decision
        The gate decision: 'allow', 'deny', or 'ask'.
        - 'allow': tool execution proceeds without prompting.
        - 'deny': tool execution is blocked outright.
        - 'ask': CLI prompts the user for permission before executing.
    .PARAMETER Reason
        Human-readable explanation of the decision (surfaced in audit logs
        and CLI debug output).
    .OUTPUTS
        [string] Single-line compact JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('allow','deny','ask')]
        [string]$Decision,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $obj = [ordered]@{
        permissionDecision       = $Decision
        permissionDecisionReason = $Reason
    }
    Write-Output ($obj | ConvertTo-Json -Compress)
}

# ═══════════════════════════════════════════════════════════════════════════════
# Notification Context Helpers (shared by Notify-Waiting & Notify-Question)
# ═══════════════════════════════════════════════════════════════════════════════

function Get-NotificationContext {
    <#
    .SYNOPSIS
        Extracts enriched context (session ID, repo name, user prompt snippet)
        from the hook payload, falling back to recent session logs if needed.
    .DESCRIPTION
        Returns a hashtable with keys: sessionId, repoName, promptSnippet, cwd.
        All values are defensive — missing data returns 'unknown' or $null rather
        than throwing. Never logs raw prompt text; only returns a truncated snippet
        (max 60 chars) for local display in tray notifications.
    .PARAMETER Payload
        The parsed JSON payload from stdin.
    .OUTPUTS
        [hashtable] With keys: sessionId, repoName, promptSnippet, cwd
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Payload
    )

    $ctx = @{
        sessionId    = 'unknown'
        repoName     = 'unknown'
        promptSnippet = $null
        cwd          = $null
    }

    if ($null -eq $Payload) { return $ctx }

    # ── Session ID ──────────────────────────────────────────────────────────
    foreach ($field in @('sessionId', 'session_id', 'sessionID')) {
        $val = $Payload.PSObject.Properties[$field]
        if ($val -and -not [string]::IsNullOrWhiteSpace($val.Value)) {
            $sid = [string]$val.Value
            # Show short form if it's a UUID (first 8 chars)
            if ($sid.Length -gt 12) { $sid = $sid.Substring(0, 8) }
            $ctx.sessionId = $sid
            break
        }
    }

    # ── CWD / workspace ────────────────────────────────────────────────────
    foreach ($field in @('cwd', 'workspace', 'workspacePath', 'workingDirectory')) {
        $val = $Payload.PSObject.Properties[$field]
        if ($val -and -not [string]::IsNullOrWhiteSpace($val.Value)) {
            $ctx.cwd = [string]$val.Value
            break
        }
    }

    # ── Repo name from cwd ─────────────────────────────────────────────────
    if ($ctx.cwd) {
        $ctx.repoName = Split-Path $ctx.cwd -Leaf
    }

    # ── If no CWD from payload, try recent sessions.jsonl ──────────────────
    if (-not $ctx.cwd) {
        $ctx = Resolve-ContextFromSessionLog -Context $ctx
    }

    # ── User prompt / question snippet (privacy-safe: max 60 chars) ────────
    $ctx.promptSnippet = Get-PromptSnippet -Payload $Payload -MaxLength 60

    return $ctx
}

function Resolve-ContextFromSessionLog {
    <#
    .SYNOPSIS
        Falls back to the most recent entry in sessions.jsonl to fill in
        missing session context (cwd, sessionId, repoName).
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Context
    )

    try {
        $sessLog = if (-not [string]::IsNullOrWhiteSpace($env:PA_HOOKS_LOG_DIR)) {
            Join-Path $env:PA_HOOKS_LOG_DIR 'sessions.jsonl'
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'logs' 'sessions.jsonl'))
        }

        if (Test-Path $sessLog) {
            $lastLine = Get-Content $sessLog -Tail 1 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($lastLine)) {
                $sess = $lastLine | ConvertFrom-Json -ErrorAction Stop
                if ($Context.sessionId -eq 'unknown' -and $sess.sessionId) {
                    $sid = [string]$sess.sessionId
                    if ($sid.Length -gt 12) { $sid = $sid.Substring(0, 8) }
                    $Context.sessionId = $sid
                }
                if (-not $Context.cwd -and $sess.cwd) {
                    $Context.cwd = [string]$sess.cwd
                    $Context.repoName = Split-Path $Context.cwd -Leaf
                }
            }
        }
    }
    catch {
        Write-Verbose "Resolve-ContextFromSessionLog: $($_.Exception.Message)"
    }

    return $Context
}

function Get-PromptSnippet {
    <#
    .SYNOPSIS
        Extracts a truncated, privacy-safe snippet of the user's prompt/question
        from the notification payload for local display only.
    .DESCRIPTION
        Checks multiple possible payload fields. Returns $null if nothing found.
        NEVER returns more than MaxLength characters. Intended for local tray
        display — callers MUST NOT persist this value to log files.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Payload,
        [int]$MaxLength = 60
    )

    if ($null -eq $Payload) { return $null }

    $text = $null

    # preToolUse ask_user payload: toolArgs.question
    $toolArgs = $Payload.PSObject.Properties['toolArgs']
    if ($toolArgs -and $toolArgs.Value) {
        $q = $toolArgs.Value.PSObject.Properties['question']
        if ($q -and -not [string]::IsNullOrWhiteSpace($q.Value)) {
            $text = [string]$q.Value
        }
    }

    # notification payload: message, body, title (in order of preference for prompt)
    if (-not $text) {
        foreach ($field in @('message', 'body', 'title', 'reason', 'userMessage', 'user_message')) {
            $val = $Payload.PSObject.Properties[$field]
            if ($val -and -not [string]::IsNullOrWhiteSpace($val.Value)) {
                $text = [string]$val.Value
                break
            }
        }
    }

    if (-not $text) { return $null }

    # Normalise whitespace and truncate
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt $MaxLength) {
        $text = $text.Substring(0, $MaxLength - 1) + [char]0x2026
    }
    return $text
}

function Test-BurntToastAvailable {
    <#
    .SYNOPSIS
        Returns $true if the BurntToast PowerShell module is installed and importable.
    #>
    [CmdletBinding()]
    param()
    try {
        $mod = Get-Module -ListAvailable BurntToast -ErrorAction Stop
        return ($null -ne $mod -and $mod.Count -gt 0)
    }
    catch { return $false }
}

function Test-VsCodeAvailable {
    <#
    .SYNOPSIS
        Returns $true if the VS Code CLI ('code') is on PATH.
    #>
    [CmdletBinding()]
    param()
    try {
        $cmd = Get-Command code -ErrorAction Stop
        return ($null -ne $cmd)
    }
    catch { return $false }
}

# ── Custom clickback protocol (copilot-clickback://) ────────────────────────
# The generic `vscode://file/<path>` protocol opens/raises VS Code but does NOT
# reliably focus the existing per-repo window. A custom per-user URL protocol
# routes the click to Focus-VSCodeRepo.ps1, which runs `code -r <repoPath>` to
# reuse the matching window. Registered under HKCU only; fully reversible.

$script:CopilotClickbackProtocol = 'copilot-clickback'

function Get-CopilotClickbackHelperPath {
    <#
    .SYNOPSIS
        Returns the absolute path to the Focus-VSCodeRepo.ps1 clickback helper.
    #>
    [CmdletBinding()]
    param()
    return (Join-Path $PSScriptRoot 'Focus-VSCodeRepo.ps1')
}

function Get-CopilotClickbackCommand {
    <#
    .SYNOPSIS
        Builds the registry "shell\open\command" string for the custom protocol.
    .DESCRIPTION
        Prefers PowerShell 7 (pwsh.exe) and falls back to Windows PowerShell.
        Returns $null if neither host nor the helper script can be resolved.
    #>
    [CmdletBinding()]
    param()
    $helper = Get-CopilotClickbackHelperPath
    if (-not (Test-Path -LiteralPath $helper)) { return $null }

    $psHost = $null
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $psHost = $pwsh.Source
    }
    else {
        $wp = Get-Command powershell -ErrorAction SilentlyContinue
        if ($wp) { $psHost = $wp.Source }
    }
    if (-not $psHost) { return $null }

    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $psHost, $helper)
}

function Test-CopilotClickbackProtocol {
    <#
    .SYNOPSIS
        Returns $true if the custom protocol is registered under HKCU AND its
        command points at this hooks folder's Focus-VSCodeRepo.ps1 helper.
    #>
    [CmdletBinding()]
    param()
    try {
        $cmdKey = "Registry::HKEY_CURRENT_USER\Software\Classes\$($script:CopilotClickbackProtocol)\shell\open\command"
        if (-not (Test-Path $cmdKey)) { return $false }
        $cmd = (Get-ItemProperty -Path $cmdKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
        if (-not $cmd) { return $false }
        $helper = Get-CopilotClickbackHelperPath
        # Validate the registered command references our helper script only.
        return ($cmd -like ('*' + $helper + '*'))
    }
    catch { return $false }
}

function Register-CopilotClickbackProtocol {
    <#
    .SYNOPSIS
        Registers (idempotently) the copilot-clickback:// URL protocol under
        HKCU\Software\Classes pointing at Focus-VSCodeRepo.ps1. Returns $true on
        success. Never writes outside HKCU; safe and reversible.
    #>
    [CmdletBinding()]
    param()
    try {
        $command = Get-CopilotClickbackCommand
        if (-not $command) { return $false }

        $root    = "Registry::HKEY_CURRENT_USER\Software\Classes\$($script:CopilotClickbackProtocol)"
        $cmdKey  = "$root\shell\open\command"

        New-Item -Path $cmdKey -Force | Out-Null
        Set-ItemProperty -Path $root   -Name '(default)'    -Value 'URL:Copilot Clickback Protocol'
        Set-ItemProperty -Path $root   -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path $cmdKey -Name '(default)'    -Value $command

        return (Test-CopilotClickbackProtocol)
    }
    catch { return $false }
}

function Initialize-CopilotClickbackProtocol {
    <#
    .SYNOPSIS
        Ensures the custom protocol is available, registering it if missing.
        Returns $true if usable, $false to signal callers to fall back to the
        vscode:// protocol. Self-healing and fail-open.
    #>
    [CmdletBinding()]
    param()
    if (Test-CopilotClickbackProtocol) { return $true }
    return (Register-CopilotClickbackProtocol)
}

function Show-EnrichedNotification {
    <#
    .SYNOPSIS
        Shows an enriched tray balloon (or BurntToast toast if available) with
        session context, repo name, prompt snippet, and clickback to VS Code.
    .DESCRIPTION
        Tries BurntToast first. The BurntToast toast wires its click to a
        `vscode://file/<repoPath>` protocol URI (BurntToast -Launch /
        -ActivationType Protocol, plus an "Open in VS Code" protocol button).
        Because activation is OS-handled, the clickback opens/focuses VS Code on
        the repo even AFTER this hook process has exited — no living wait loop.

        Falls back to a System.Windows.Forms tray balloon with a short message-pump
        wait loop. NOTE: tray-balloon clickback is best-effort only — if the user
        clicks after the hook process exits, the in-process handler is gone and the
        click does nothing. The notification itself still displays either way.
    .PARAMETER Title
        Notification title line.
    .PARAMETER Text
        Notification body text.
    .PARAMETER Kind
        Notification type label (e.g. 'completed', 'question', 'waiting').
    .PARAMETER RepoPath
        Absolute path to the repo/folder for clickback. If empty, clickback disabled.
    .PARAMETER TimeoutMs
        Tray balloon display duration in ms (only used for fallback tray balloon).
    .OUTPUTS
        [hashtable] With keys:
          method            ('burnttoast'|'trayballoon'|'none')
          clickbackAttached [bool]  — a click action of any kind is attached
          protocolClickback [bool]  — clickback uses OS-handled protocol activation
                                       (survives hook process exit). True for the
                                       BurntToast path (custom or vscode protocol).
          customProtocol    [bool]  — clickback uses the copilot-clickback:// custom
                                       protocol (code -r, focuses existing window)
          clickbackTarget   [string]— which target is attached:
                                       'custom-protocol'|'vscode-protocol'|'trayballoon'|'none'
          burntToast        [bool]  — the BurntToast toast path was used
    #>
    [CmdletBinding()]
    param(
        [string]$Title,
        [string]$Text,
        [string]$Kind,
        [string]$RepoPath,
        [int]$TimeoutMs = 8000,
        [bool]$AllowBurntToast = $true,
        [bool]$AllowTrayFallback = $true,
        [bool]$AllowClickback = $true
    )

    $result = @{
        method            = 'none'
        clickbackAttached = $false
        protocolClickback = $false
        customProtocol    = $false
        clickbackTarget   = 'none'
        burntToast        = $false
    }
    $vsCodeAvailable = Test-VsCodeAvailable
    # Clickback is suppressed when disabled by feature flag.
    if (-not $AllowClickback) { $RepoPath = $null }

    # ── Try BurntToast (OS-handled protocol activation) ──────────────────
    # The toast click is wired to a `vscode://file/<repoPath>` protocol URI via
    # BurntToast's -Launch/-ActivationType Protocol (whole-toast click) plus a
    # protocol button. Windows itself launches the URI when the user clicks, so
    # the clickback works even after THIS hook process has already exited — unlike
    # an -ActivatedAction scriptblock, which dies with the process.
    if ($AllowBurntToast -and (Test-BurntToastAvailable)) {
        try {
            Import-Module BurntToast -ErrorAction Stop

            # Choose the best clickback URI for this repo:
            #   1. copilot-clickback://open?path=<encoded>  → Focus-VSCodeRepo.ps1
            #      runs `code -r <repoPath>` (focuses the existing per-repo window).
            #   2. vscode://file/<path>  → generic VS Code open (graceful fallback
            #      if the custom protocol can't be registered).
            $protocolUri     = $null
            $clickbackTarget = 'none'
            if ($RepoPath -and (Test-Path $RepoPath)) {
                if (Initialize-CopilotClickbackProtocol) {
                    $encoded = [System.Uri]::EscapeDataString($RepoPath)
                    $protocolUri = "$($script:CopilotClickbackProtocol)://open?path=$encoded"
                    $clickbackTarget          = 'custom-protocol'
                    $result.customProtocol    = $true
                }
                else {
                    $protocolUri = ('vscode://file/' + ($RepoPath -replace '\\', '/')) -replace ' ', '%20'
                    $clickbackTarget = 'vscode-protocol'
                }
            }

            $bindingChildren = @(
                (New-BTText -Content $Title),
                (New-BTText -Content $Text)
            )
            $visual = New-BTVisual -BindingGeneric (New-BTBinding -Children $bindingChildren)

            if ($protocolUri) {
                $button  = New-BTButton -Content 'Open in VS Code' -Arguments $protocolUri -ActivationType Protocol
                $action  = New-BTAction -Buttons $button
                $content = New-BTContent -Visual $visual -Actions $action -Launch $protocolUri -ActivationType Protocol
                $result.clickbackAttached = $true
                $result.protocolClickback = $true
                $result.clickbackTarget   = $clickbackTarget
            }
            else {
                $content = New-BTContent -Visual $visual
            }

            Submit-BTNotification -Content $content
            $result.method     = 'burnttoast'
            $result.burntToast  = $true
            return $result
        }
        catch {
            Write-Verbose "BurntToast failed, falling back to tray balloon: $($_.Exception.Message)"
        }
    }

    # ── Fallback: tray balloon with message-pump click loop ─────────────────
    # Suppressed entirely when the tray-balloon fallback feature is disabled —
    # the caller still played the sound, so notification is audible-only.
    if (-not $AllowTrayFallback) {
        Write-Verbose 'Show-EnrichedNotification: tray-balloon fallback disabled by feature flag'
        return $result
    }
    # Previous implementation used Start-Sleep which does NOT pump the Windows
    # message queue — BalloonTipClicked events never dispatched. Fix: use
    # Application.DoEvents() in a tight loop so the OS delivers click messages.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $icon = [System.Windows.Forms.NotifyIcon]::new()
        $icon.Icon = if ($Kind -match 'question|ask') {
            [System.Drawing.SystemIcons]::Question
        } else {
            [System.Drawing.SystemIcons]::Information
        }
        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText  = $Text
        $icon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
        $icon.ShowBalloonTip($TimeoutMs)

        # Mutable state in script scope — guarantees .NET event handler
        # scriptblocks can resolve it regardless of invocation context.
        $script:_notifyClickDone = $false
        $script:_notifyRepoPath = $RepoPath

        # Attach click handler via .add_* (runs synchronously during DoEvents)
        if ($vsCodeAvailable -and $RepoPath -and (Test-Path $RepoPath)) {
            $icon.add_BalloonTipClicked([System.EventHandler]{
                param($sender, $e)
                Start-Process 'code' -ArgumentList '-r', "`"$script:_notifyRepoPath`"" -WindowStyle Hidden
                $sender.Visible = $false
                $script:_notifyClickDone = $true
            })
            $result.clickbackAttached = $true
            $result.clickbackTarget   = 'trayballoon'
        } else {
            $icon.add_BalloonTipClicked([System.EventHandler]{
                param($sender, $e)
                $script:_notifyClickDone = $true
            })
        }

        $icon.add_BalloonTipClosed([System.EventHandler]{
            param($sender, $e)
            $script:_notifyClickDone = $true
        })

        # Pump Windows messages for up to 2.5s (within 5s hook timeout).
        # DoEvents() processes pending messages, allowing click/close events to fire.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 2500 -and -not $script:_notifyClickDone) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $sw.Stop()

        # Cleanup: hide and dispose if event handlers didn't already
        try { $icon.Visible = $false; $icon.Dispose() } catch {}

        $result.method = 'trayballoon'
    }
    catch {
        Write-Verbose "Tray balloon failed — $($_.Exception.Message)"
    }

    return $result
}
