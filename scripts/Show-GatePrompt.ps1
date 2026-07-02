#Requires -Version 7.0
<#
.SYNOPSIS
    Renders a WinForms popup gate prompt with Approve/Deny buttons.

.DESCRIPTION
    Displays a native Windows Forms dialog asking the user to approve or deny
    a high-risk tool action. Used by Gate-HighRiskTools.ps1 to render the
    Phase 2.1 popup gate.

    Uses a custom [System.Windows.Forms.Form] (not [MessageBox]::Show) so that
    a countdown timer can close the dialog automatically if the user does not
    respond within TimeoutSeconds.

    Return values (case-sensitive strings):
      Allow   — user clicked Approve
      Deny    — user clicked Deny (or closed the window)
      Timeout — timer elapsed; caller treats this as a hard deny
      NoGui   — WinForms assembly unavailable or non-interactive session;
                caller falls back to CLI 'ask' mode

    Invocation patterns:
      # Direct (child-process):
      pwsh -NoProfile -File Show-GatePrompt.ps1 -Title "Approve?" -Body "To: a@b.com"

      # Dot-source and call:
      . ./Show-GatePrompt.ps1
      $result = Show-GatePrompt -Title "Approve?" -Body "To: a@b.com" -TimeoutSeconds 60

.PARAMETER Title
    Text shown in the popup title bar.

.PARAMETER Body
    Multi-line body text shown to the user (e.g. tool name + key args).

.PARAMETER TimeoutSeconds
    Seconds before the dialog auto-closes with result 'Timeout'. Default: 120.

.EXAMPLE
    # Direct invocation — outputs the decision string to stdout
    pwsh -NoProfile -File .github/hooks/scripts/Show-GatePrompt.ps1 `
         -Title "Approve email send?" `
         -Body "To: alice@example.com`nSubject: Meeting notes" `
         -TimeoutSeconds 30

.EXAMPLE
    # Dot-source pattern used by Gate-HighRiskTools.ps1
    . (Join-Path $PSScriptRoot 'Show-GatePrompt.ps1')
    $decision = Show-GatePrompt -Title $Title -Body $Body

.NOTES
    Author  : Chapel (Systems Coder)
    Created : 2026-05-06T00:22:32+05:30
    No external dependencies — System.Windows.Forms is in-box on Windows pwsh 7.
    NEVER throws an unhandled exception; all error paths return a string.
#>

param(
    [string] $Title,
    [string] $Body,
    [int]    $TimeoutSeconds = 120,
    [string] $PreviewHtml   = $null
)

# ─── Function definition ─────────────────────────────────────────────────────

function Show-GatePrompt {
    <#
    .SYNOPSIS
        Shows a WinForms popup asking Approve / Deny. Returns 'Allow', 'Deny',
        'Timeout', or 'NoGui'. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [Parameter(Mandatory)]
        [string] $Body,

        [int] $TimeoutSeconds = 120,

        [Parameter()]
        [string] $PreviewHtml = $null
    )

    # ── Test hatch ──────────────────────────────────────────────────────────
    # PA_GATE_TEST_THROW_PROMPT: if set to '1', throws immediately — simulates
    # a popup failure so Gate-HighRiskTools.ps1's gatePopupError catch path
    # can be exercised in tests without a real GUI.
    # NEVER set this env var in normal operation.
    if ($env:PA_GATE_TEST_THROW_PROMPT -eq '1') {
        throw 'Test-triggered popup error (PA_GATE_TEST_THROW_PROMPT=1)'
    }

    # ── Step 1: GUI availability check ──────────────────────────────────────
    try {
        Add-Type -AssemblyName 'System.Windows.Forms' -ErrorAction Stop
        Add-Type -AssemblyName 'System.Drawing'       -ErrorAction Stop
    }
    catch {
        return 'NoGui'
    }

    if (-not [System.Windows.Forms.SystemInformation]::UserInteractive) {
        return 'NoGui'
    }

    # ── Step 2: Build and show the form ─────────────────────────────────────
    $script:TimedOut = $false

    try {
        # --- Compute form height based on body line count -------------------
        $lineCount  = ([regex]::Matches($Body, "`n")).Count + 1
        $bodyHeight = [Math]::Min(($lineCount * 18) + 40, 300)   # cap body portion
        $formHeight = [Math]::Min(140 + $bodyHeight, 600)

        # --- Form ----------------------------------------------------------
        $form                  = [System.Windows.Forms.Form]::new()
        $form.Text             = $Title
        $form.FormBorderStyle  = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.StartPosition    = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.MinimizeBox      = $false
        $form.MaximizeBox      = $false
        $form.TopMost          = $true
        $form.ShowInTaskbar    = $true
        $form.ClientSize       = [System.Drawing.Size]::new(560, $formHeight)
        $form.Padding          = [System.Windows.Forms.Padding]::new(12)

        # --- Body label ----------------------------------------------------
        $label              = [System.Windows.Forms.Label]::new()
        $label.Text         = $Body
        $label.AutoSize     = $false
        $label.Location     = [System.Drawing.Point]::new(12, 12)
        $label.Size         = [System.Drawing.Size]::new(536, ($formHeight - 70))
        $label.Font         = [System.Drawing.Font]::new('Segoe UI', 10)

        # --- Buttons -------------------------------------------------------
        $btnApprove                  = [System.Windows.Forms.Button]::new()
        $btnApprove.Text             = 'Approve'
        $btnApprove.DialogResult     = [System.Windows.Forms.DialogResult]::Yes
        $btnApprove.Size             = [System.Drawing.Size]::new(90, 30)
        $btnApprove.Location         = [System.Drawing.Point]::new(
            (560 - 12 - 90 - 8 - 90),
            ($formHeight - 50)
        )
        $btnApprove.Anchor           = [System.Windows.Forms.AnchorStyles]::Bottom -bor
                                       [System.Windows.Forms.AnchorStyles]::Right

        $btnDeny                     = [System.Windows.Forms.Button]::new()
        $btnDeny.Text                = 'Deny'
        $btnDeny.DialogResult        = [System.Windows.Forms.DialogResult]::No
        $btnDeny.Size                = [System.Drawing.Size]::new(90, 30)
        $btnDeny.Location            = [System.Drawing.Point]::new(
            (560 - 12 - 90),
            ($formHeight - 50)
        )
        $btnDeny.Anchor              = [System.Windows.Forms.AnchorStyles]::Bottom -bor
                                       [System.Windows.Forms.AnchorStyles]::Right

        # --- Preview button (optional — only when PreviewHtml is provided) --
        # Store in script scope so the click-handler closure can reach it.
        $script:PreviewHtmlContent = $PreviewHtml
        if (-not [string]::IsNullOrEmpty($PreviewHtml)) {
            $btnPreview          = [System.Windows.Forms.Button]::new()
            $btnPreview.Text     = 'Preview'
            $btnPreview.Size     = [System.Drawing.Size]::new(90, 30)
            $btnPreview.Location = [System.Drawing.Point]::new(12, ($formHeight - 50))
            $btnPreview.Anchor   = [System.Windows.Forms.AnchorStyles]::Bottom -bor
                                   [System.Windows.Forms.AnchorStyles]::Left
            $btnPreview.TabIndex = 0
            $btnApprove.TabIndex = 1
            $btnDeny.TabIndex    = 2

            $btnPreview.Add_Click({
                try {
                    $tempPath = [System.IO.Path]::Combine(
                        $env:TEMP,
                        "pa-popup-preview-$([guid]::NewGuid().ToString('N')).html"
                    )
                    $fullHtml = (
                        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Email preview</title>' +
                        '<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:720px;margin:24px auto;' +
                        'padding:0 16px;color:#222;line-height:1.5}hr{border:none;border-top:1px solid #ddd;' +
                        'margin:16px 0}code{background:#f4f4f4;padding:2px 6px;border-radius:3px}</style>' +
                        '</head><body>'
                    ) + $script:PreviewHtmlContent + '</body></html>'
                    [System.IO.File]::WriteAllText(
                        $tempPath, $fullHtml, [System.Text.UTF8Encoding]::new($false)
                    )
                    Start-Process $tempPath
                } catch {
                    Write-Warning "Show-GatePrompt: Preview failed — $_"
                }
            })
            $form.Controls.Add($btnPreview)
        }

        $form.AcceptButton = $btnApprove
        $form.CancelButton = $btnDeny

        # --- Timer ---------------------------------------------------------
        $timer          = [System.Windows.Forms.Timer]::new()
        $timer.Interval = $TimeoutSeconds * 1000

        $timer.Add_Tick({
            $timer.Stop()
            $script:TimedOut = $true
            $form.Close()
        })

        # --- Foreground activation on Shown --------------------------------
        $form.Add_Shown({
            $form.Activate()
            $form.BringToFront()
        })

        # --- Wire up controls ----------------------------------------------
        $form.Controls.Add($label)
        $form.Controls.Add($btnApprove)
        $form.Controls.Add($btnDeny)

        # --- Show ----------------------------------------------------------
        $timer.Start()
        try {
            $result = $form.ShowDialog()
        }
        finally {
            $timer.Stop()
            $timer.Dispose()
        }

        # --- Map result ----------------------------------------------------
        if ($script:TimedOut) {
            return 'Timeout'
        }
        elseif ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            return 'Allow'
        }
        elseif ($result -eq [System.Windows.Forms.DialogResult]::No) {
            return 'Deny'
        }
        else {
            # Closed via X button — treat as explicit deny
            return 'Deny'
        }
    }
    catch {
        return 'NoGui'
    }
    finally {
        if ($null -ne $form) {
            $form.Dispose()
        }
    }
}

# ─── Direct invocation entry point ──────────────────────────────────────────
# When invoked as a child process (pwsh -File ...) with -Title and -Body,
# call the function and write the result to stdout for the caller to capture.
if (-not [string]::IsNullOrWhiteSpace($Title) -and -not [string]::IsNullOrWhiteSpace($Body)) {
    Show-GatePrompt -Title $Title -Body $Body -PreviewHtml $PreviewHtml -TimeoutSeconds $TimeoutSeconds
}
