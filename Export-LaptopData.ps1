# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY
# Source modules: ordered explicitly in Build-Deployment.ps1
# Build command: powershell -ExecutionPolicy Bypass -File .\\Build-Deployment.ps1
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
    STO Building Group Laptop Transfer - Export Script
    Captures user data, settings, and generates import script for new machine.

.DESCRIPTION
    This script automates the data collection phase of laptop transfers:
    - Copies user folders (Documents, Desktop, Downloads, etc.)
    - Captures AppData (Bluebeam, Signatures, Quick Access)
    - Documents installed programs
    - Captures system settings (power, lid, mapped drives)
    - Generates an Import script for the new machine
    - Creates an HTML report of all actions

.PARAMETER TargetUserProfile
    The user profile path to export. Used when running elevated to preserve original user context.

.PARAMETER TargetUserName
    The username to export. Used when running elevated to preserve original user context.

.NOTES
    Version: 1.0
    Author: STO IT
    Run as: The user being transferred (IT admin logged in as user)
#>

#Requires -Version 5.1

# Bootstrap runs first.  It defines command-line inputs and process-wide
# presentation state before any feature module is loaded.  Nothing here copies
# user data; it establishes the environment in which the later modules run.

param(
    [string]$TargetUserProfile = "",
    [string]$TargetUserName = "",
    [string]$TargetAppDataRoaming = "",
    [string]$TargetAppDataLocal = "",
    [ValidateSet("", "Local", "Online")]
    [string]$TransferMode = "",
    # Parent folder for the transfer package. When omitted, Windows displays a
    # folder picker after the transfer mode is selected.
    [string]$DestinationPath = "",
    # Optional override for the Online payload ceiling in GB (default: 5).
    [double]$OnlineMaxTransferGB = 0,
    # Internal: preserves choices made in Transfer Settings across the UAC
    # relaunch. Technicians do not need to supply either parameter.
    [string]$RuntimeSettings = "",
    [switch]$ElevatedFromSettings,
    # Intended for logged/automated validation. It keeps normal technician
    # runs unchanged, skips prompts, and does not open the HTML report.
    [switch]$NonInteractive
)

# ============================================================================
# CONSOLE ENCODING & ANSI SETUP
# ============================================================================
# Enable UTF-8 output so box-drawing, glyphs, and gradient accents render
# correctly. This also underpins correct symbol output in the HTML report.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

# Try to enable ANSI (virtual terminal) processing so 24-bit color works in
# legacy conhost. Windows Terminal / PowerShell 7 already support it.
$Script:AnsiEnabled = $false
try {
    if ($Host.UI.SupportsVirtualTerminal) {
        $Script:AnsiEnabled = $true
    }
    else {
        # Attempt to flip the console mode flag for legacy conhost (Win10+)
        $sig = @'
using System;
using System.Runtime.InteropServices;
public static class VT {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@
        if (-not ("VT" -as [type])) { Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue }
        $h = [VT]::GetStdHandle(-11)
        $mode = 0
        if ([VT]::GetConsoleMode($h, [ref]$mode)) {
            if ([VT]::SetConsoleMode($h, $mode -bor 0x0004)) { $Script:AnsiEnabled = $true }
        }
    }
}
catch { $Script:AnsiEnabled = $false }

# ============================================================================
# CONSOLE UI / THEME
# ============================================================================
# A small, centralized styling layer so every screen looks consistent. Brand
# accent runs cyan (#00d4ff) -> purple (#7c3aed), matching the HTML report.

$Script:Theme = @{
    Esc        = [char]27
    AccentFrom = @(0, 212, 255)    # #00d4ff cyan
    AccentTo   = @(124, 58, 237)   # #7c3aed purple
    Width      = 60
    Glyphs     = @{ OK = [char]0x2713; WARN = [char]0x26A0; FAIL = [char]0x2717; INFO = [char]0x2139; SKIP = [char]0x2022; ARROW = [char]0x25B8 }
    Box        = @{ TL=[char]0x2554; TR=[char]0x2557; BL=[char]0x255A; BR=[char]0x255D; H=[char]0x2550; V=[char]0x2551; ML=[char]0x2560; MR=[char]0x2563 }
    Bar        = @{ Full=[char]0x2588; Light=[char]0x2591 }
    Spinner    = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)
}

$Script:DevelopmentConfig = @{
    # This is a PowerShell data file, not executable code.  Build-Deployment.ps1
    # reads it as trusted configuration and selectively embeds the supported
    # values into the runtime configuration created by 03-core.ps1.  Keeping
    # the allowlists in the runtime prevents an accidental config key from
    # changing an unrelated implementation detail.
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    # Every backup stage is enabled by default.
    Backup = @{
        UserData          = $true
        # Optional comprehensive profile copy. It excludes data captured by
        # the standard user-folder, AppData, and browser stages.
        EntireUserProfile = $false
        AdditionalAppData = $false
        Downloads         = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        AppDataCandidateInventory = $true
        Printers          = $true
        # Off, BookmarksAndPasswords, or FullProfile.
        Chrome            = 'BookmarksAndPasswords'
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
        TaskbarLayout     = $true
        DefaultApps       = $true
    }

    Import = @{
        # Restores AppData\Lotus_Local when it is present in a transfer package.
        LotusNotes = $true

        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true

        # The normal user-context import launches a separate elevated helper
        # after all user-scoped restoration finishes. Only power and PrintBRM
        # run in that helper.
        EnableAdminHelper = $true
        AppComparison = $true
        AppDataReview = $true
        # These technical and managed uninstall entries are excluded from the
        # user-facing missing-app report. Adobe, ClickShare, Lenovo, Microsoft,
        # and Windows-related apps are handled through standard imaging and
        # post-transfer configuration, rather than as handoff actions.
        AppComparisonExcludePatterns = @(
            '^Microsoft Visual C\+\+', '^Microsoft \.NET', '^Microsoft Windows Desktop Runtime', '^Microsoft ASP\.NET Core',
            '^Microsoft Edge( WebView2 Runtime| Update)?$', '^Microsoft Update Health Tools', '^Microsoft OneDrive',
            '^Microsoft Teams Meeting Add-in', '^Windows (Desktop Runtime|Software Development Kit)', '^KB\d+',
            '\bAdobe\b', '\bClickShare\b', '\bLenovo\b', '\bMicrosoft\b', '\bWindows\b',
            'Driver', 'Firmware', 'Intel.*(Driver|Component)',
            'Realtek.*(Driver|Audio)', 'NVIDIA.*(Driver|FrameView)', 'AMD.*(Driver|Software)'
        )

        # At the end of an import, the report always opens.  The technician
        # can optionally open this standard handoff set as well.  Future
        # additions only require another target/alternative here; no importer
        # code changes are needed.  Desktop shortcuts are checked in the user,
        # OneDrive, and Public Desktop folders before command fallbacks.
        PostImportLaunch = @{
            Enabled = $true
            DesktopFolders = @('Desktop', 'OneDrive - STO Building Group\Desktop', 'C:\Users\Public\Desktop')
            Targets = @(
                @{ Name = 'PDF application'; Alternatives = @(
                    @{ Name = 'Adobe Acrobat'; DesktopShortcuts = @('Adobe Acrobat.lnk'); Commands = @('Acrobat.exe', 'AcroRd32.exe') },
                    @{ Name = 'Bluebeam Revu'; DesktopShortcuts = @('Bluebeam Revu.lnk', 'Bluebeam Revu 21.lnk'); Commands = @('Revu.exe') }
                ) },
                @{ Name = 'Classic Outlook'; Alternatives = @(@{ Name = 'Classic Outlook'; DesktopShortcuts = @('Outlook.lnk'); Commands = @('OUTLOOK.EXE') }) },
                @{ Name = 'Microsoft Teams'; Alternatives = @(@{ Name = 'Microsoft Teams'; DesktopShortcuts = @('Microsoft Teams.lnk', 'Teams.lnk'); Commands = @('ms-teams.exe', 'Teams.exe') }) },
                @{ Name = 'Cisco Secure Client'; Alternatives = @(@{ Name = 'Cisco Secure Client'; DesktopShortcuts = @('Cisco Secure Client.lnk') }) },
                @{ Name = 'CMiC'; Alternatives = @(@{ Name = 'CMiC'; DesktopShortcuts = @('CMiC.lnk') }) },
                @{ Name = 'Microsoft Edge'; Alternatives = @(@{ Name = 'Microsoft Edge'; DesktopShortcuts = @('Microsoft Edge.lnk'); Commands = @('msedge.exe') }) },
                @{ Name = 'STOBG Intranet'; Alternatives = @(@{ Name = 'STOBG Intranet'; DesktopShortcuts = @('STOBG Intranet.lnk', 'STO Intranet.lnk') }) },
                @{ Name = 'Knowledge Exchange'; Alternatives = @(@{ Name = 'Knowledge Exchange'; DesktopShortcuts = @('Knowledge Exchange.lnk') }) },
                @{ Name = 'Freshservice'; Alternatives = @(@{ Name = 'Freshservice'; DesktopShortcuts = @('Freshservice.url') }) },
                @{ Name = 'Firefox'; Alternatives = @(@{ Name = 'Firefox'; DesktopShortcuts = @('Firefox.lnk'); Commands = @('firefox.exe') }) },
                @{ Name = 'Google Chrome'; Alternatives = @(@{ Name = 'Google Chrome'; DesktopShortcuts = @('Google Chrome.lnk'); Commands = @('chrome.exe') }) },
                @{ Name = 'HR Hub'; Alternatives = @(@{ Name = 'HR Hub'; DesktopShortcuts = @('HR Hub.lnk') }) }
            )
        }
    }

    Export = @{
        # RECOMMENDED for a complete PrintBRM package and full power-plan file.
        # When enabled, request UAC only after normal user-context export is
        # complete. It is off by default for both Basic and Advanced presets.
        RequestAdministratorPrivileges = $false
    }

    # These values override the regular Import defaults when the technician
    # selects an Online transfer. They can still be changed for one transfer
    # in the runtime settings menu.
    Online = @{
        # Online transfers warn before starting when selected payload exceeds this size.
        MaxTransferGB = 5
        # Bypass the per-folder 5 GB Downloads confirmation for this transfer.
        OverrideDownloadsCap = $false
        # Online transfers create a ZIP beside the transfer folder by default.
        CreateZipArchive = $true

        # Build network-bound packages in the transferring user's Local AppData,
        # then upload one ZIP instead of thousands of small network writes.
        StageNetworkTransfersLocally = $true

        # Advanced Online controls. Keep only portable Chrome bookmarks and
        # the optional native password CSV by default; a raw profile archive
        # can be enabled for recovery/reference when its estimated size fits.
        IncludeChromeProfileArchive = $false
        IncludeAdditionalUserFolders = $false
        AdditionalFolderCapGB = 1
        IncludeOcsDocuments = $false
        DetailedAppDataCandidateInventory = $false

        Import = @{
            LotusNotes                  = $true
            DeletePrintBrmAfterImport   = $true
            EnableAdminHelper            = $true
            AppComparison                = $true
            AppDataReview                = $true
        }
    }
}

$Script:TransferReportTemplate = @'
<!--
  Static presentation template for the transfer ledger.  09-report.ps1
  replaces {{TOKEN}} placeholders with HTML-encoded values before writing the
  final report.  Keep layout/CSS here and counting/classification logic there.
-->
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Laptop Transfer Report - {{USER}}</title>
  <style>
    :root{color-scheme:dark;--ink:#f5f9ff;--muted:#9daec6;--panel:#111d33;--panel2:#172744;--line:rgba(173,204,255,.17);--blue:#29b8ff;--violet:#9d7bff;--green:#44dda4;--amber:#ffc45d;--red:#ff7185}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 15% -10%,#235e91 0,transparent 38%),radial-gradient(circle at 90% 5%,#4d327b 0,transparent 31%),#08111f;color:var(--ink);font:15px/1.5 "Segoe UI",system-ui,sans-serif}.container{max-width:1160px;margin:auto;padding:32px 20px 48px}.hero,.section,.stat,.route-card,.duration-card{border:1px solid var(--line);background:linear-gradient(145deg,rgba(27,45,76,.93),rgba(12,23,41,.94));box-shadow:0 18px 50px rgba(0,0,0,.19)}.hero{border-radius:24px;padding:30px;margin-bottom:18px;overflow:hidden;position:relative}.hero:after{content:"";position:absolute;width:280px;height:280px;border-radius:50%;right:-100px;top:-165px;background:radial-gradient(circle,rgba(41,184,255,.22),transparent 70%);pointer-events:none}.eyebrow,.label{font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}h1{margin:5px 0 4px;font-size:clamp(28px,4vw,42px);line-height:1.1;letter-spacing:-.035em}.accent{color:var(--blue)}.meta{color:var(--muted);margin:0}.route{display:grid;grid-template-columns:1fr auto 1fr;gap:14px;align-items:stretch;margin-top:25px}.route-card{min-width:0;border-radius:16px;padding:16px;background:rgba(7,17,31,.55)}.route-name{overflow-wrap:anywhere;font-size:20px;font-weight:700;color:#fff;margin-top:4px}.route-arrow{align-self:center;color:var(--blue);font-size:28px;text-align:center}.duration-card{border-radius:16px;margin-top:16px;padding:18px 20px;display:flex;justify-content:space-between;align-items:center;background:linear-gradient(100deg,rgba(41,184,255,.14),rgba(157,123,255,.14))}.duration{font-size:clamp(34px,5vw,56px);line-height:1;font-weight:800;letter-spacing:-.06em;color:#fff}.duration-copy{text-align:right;color:var(--muted)}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:18px 0}.stat{border-radius:16px;padding:18px}.number{font-size:30px;font-weight:800;line-height:1.1}.success .number,.success-text{color:var(--green)}.warning .number{color:var(--amber)}.error .number{color:var(--red)}.skipped .number{color:#c8d2e3}.section{border-radius:18px;margin:18px 0;overflow:hidden}.section-header{padding:17px 20px;background:rgba(255,255,255,.035);font-size:17px;font-weight:700}.section-subtitle{display:block;margin-top:2px;color:var(--muted);font-size:12px;font-weight:400}.section-content{padding:20px}.app-summary{border:1px solid rgba(41,184,255,.35);border-radius:14px;padding:18px;background:linear-gradient(110deg,rgba(41,184,255,.1),rgba(157,123,255,.08))}.app-summary h3{margin:0 0 6px;font-size:19px}.app-summary p{margin:0;color:var(--muted)}.app-summary.ready{border-color:rgba(255,196,93,.55)}.app-summary.ok{border-color:rgba(68,221,164,.55)}.app-list{margin:16px 0 0;padding:0;list-style:none;display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:9px}.app-list li{min-width:0;padding:11px 12px;border-radius:10px;background:rgba(6,15,28,.55);border:1px solid var(--line);overflow-wrap:anywhere}.missing-app-list{margin:16px 0 0;padding-left:22px}.missing-app-list li{padding:8px 0;border-bottom:1px solid var(--line);overflow-wrap:anywhere}.missing-app-list li:last-child{border-bottom:0}.app-list small,.missing-app-list small,.manual-task p,.manual-task pre{display:block;max-width:100%;overflow-wrap:anywhere;word-break:break-word}.app-list small,.missing-app-list small{color:var(--muted);margin-top:2px}table{width:100%;border-collapse:collapse;table-layout:fixed}th,td{padding:12px 10px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere;word-break:break-word}th{font-size:11px;color:var(--muted);letter-spacing:.1em;text-transform:uppercase}.status{display:inline-block;border-radius:999px;padding:4px 9px;font-size:12px;white-space:nowrap}.status-success{background:rgba(68,221,164,.15);color:#84f2c6}.status-warning{background:rgba(255,196,93,.14);color:#ffda91}.status-error{background:rgba(255,113,133,.16);color:#ffb3be}.status-skipped{background:rgba(187,202,224,.13);color:#d9e2f0}.critical-warning{border:1px solid rgba(255,113,133,.7);background:rgba(127,29,29,.28);border-radius:18px;padding:20px;margin:18px 0}.critical-warning h2{margin:0 0 4px;color:#ffbac4}.critical-warning p{margin:0;color:#ffd1d8}.admin-success{border-radius:16px;padding:15px 20px;margin:18px 0;color:#a1f6d1}.manual-task{border-left:3px solid var(--violet);border-radius:0 10px 10px 0;background:rgba(157,123,255,.1);padding:14px 16px;margin-bottom:10px}.manual-task.critical{border-color:var(--red);background:rgba(255,113,133,.1)}.manual-task h4{margin:0 0 4px}.manual-task p{margin:0;color:var(--muted)}.manual-task pre{white-space:pre-wrap;margin:10px 0 0;color:#dfeaff;font:12px/1.45 Consolas,monospace}details.section{padding:0}details summary{cursor:pointer;list-style:none;padding:18px 20px;font-size:17px;font-weight:700;background:rgba(255,255,255,.035)}details summary::-webkit-details-marker{display:none}details summary:after{content:'+';float:right;color:var(--blue);font-size:22px;line-height:.8}details[open] summary:after{content:'−'}details summary span{display:block;color:var(--muted);font-size:12px;font-weight:400;margin-top:2px}details ul{margin:0;padding-left:22px}details li{margin:9px 0;color:#dce8fa}footer{text-align:center;color:#7f91ac;font-size:12px;padding:10px}@media(max-width:700px){.container{padding:18px 14px 35px}.hero{padding:22px}.route{grid-template-columns:1fr}.route-arrow{transform:rotate(90deg);padding:0}.duration-card{align-items:flex-start;gap:12px;flex-direction:column}.duration-copy{text-align:left}.stats{grid-template-columns:repeat(2,1fr)}.section-content{overflow:auto;padding:14px}table{table-layout:auto}}
    /* Compact handoff view: keep long action ledgers scannable at 100% zoom. */
    body{font-size:14px;line-height:1.45}.container{padding:24px 18px 38px}.hero{padding:24px;margin-bottom:14px;border-radius:20px}h1{font-size:clamp(24px,3.4vw,36px)}.route{gap:12px;margin-top:20px}.route-card{padding:13px;border-radius:14px}.route-name{font-size:17px}.duration-card{margin-top:14px;padding:15px 17px;border-radius:14px}.duration{font-size:clamp(28px,4vw,44px)}.stats{gap:10px;margin:14px 0}.stat{padding:14px;border-radius:14px}.number{font-size:25px}.section-header,details summary{font-size:16px;padding:14px 17px}.section-content{padding:16px}th,td{padding:10px 8px}
  </style>
</head>
<body>
<main class="container">
  <header class="hero">
    <div class="eyebrow">STO · laptop handoff</div>
    <h1>Transfer <span class="accent">handoff report</span></h1>
    <p class="meta">Prepared for {{USER}} · {{DATE}} · {{MODE}} transfer</p>
    <div class="route">
      <div class="route-card"><div class="label">Old computer · export source</div><div class="route-name">{{SOURCE_COMPUTER}}</div></div>
      <div class="route-arrow" aria-hidden="true">→</div>
      <div class="route-card"><div class="label">New computer · import destination</div><div class="route-name"><!-- DESTINATION_COMPUTER -->{{DESTINATION_COMPUTER}}<!-- /DESTINATION_COMPUTER --></div></div>
    </div>
    <div class="duration-card"><div><div class="label">Transfer time</div><div class="duration"><!-- TRANSFER_DURATION -->{{DURATION}}<!-- /TRANSFER_DURATION --></div></div><div class="duration-copy"><!-- TRANSFER_DURATION_COPY -->Export time; import time is added after import completes<!-- /TRANSFER_DURATION_COPY --></div></div>
  </header>
  {{ADMIN_BANNER}}
  <!-- TRANSFER_SUMMARY --><section class="stats"><div class="stat success"><div class="number">{{SUCCESS_COUNT}}</div><div class="label">Successful</div></div><div class="stat warning"><div class="number">{{WARNING_COUNT}}</div><div class="label">Warnings</div></div><div class="stat error"><div class="number">{{ERROR_COUNT}}</div><div class="label">Errors</div></div><div class="stat skipped"><div class="number">{{SKIPPED_COUNT}}</div><div class="label">Skipped</div></div></section><!-- /TRANSFER_SUMMARY -->
  <section class="section"><div class="section-header">Application readiness<span class="section-subtitle">Apps present on the old computer but absent from the new one</span></div><div class="section-content"><!-- APP_MIGRATION_SECTION -->{{APP_MIGRATION_SECTION}}<!-- /APP_MIGRATION_SECTION --></div></section>
  <!-- IMPORT_RESULTS --><!-- /IMPORT_RESULTS -->
  <section class="section"><div class="section-header">Export actions<span class="section-subtitle">Items needing attention are listed first</span></div><div class="section-content"><table><thead><tr><th>Category</th><th>Item</th><th>Status</th><th>Details</th></tr></thead><tbody>{{ACTION_ROWS}}</tbody></table></div></section>
  {{RUNTIME_ALERTS}}
  <section class="section"><div class="section-header">Other manual tasks</div><div class="section-content">{{MANUAL_TASKS}}</div></section>
  <details class="section"><summary>Post-transfer checklist<span>Collapsed by default — expand while completing the handoff</span></summary><div class="section-content"><h3>Manual Configuration</h3><ol><li>Set default apps</li><li>Log into all auto-opened apps and verify they work</li><li>Log into M365 apps (Teams, Onedrive, Outlook)</li><li>Configure Adobe/Bluebeam Revu</li><li>Configure Bluebeam Stapler (If installed, sign in/out of Bluebeam)</li><li>Connect to STOBG WiFi</li></ol><h3>Verification/Checks</h3><ol><li>Perform a Teams test call</li><li>Verify/Resolve Imaging Errors</li><li>Verify/Run Lenovo System Update</li><li>Verify/Run Windows Updates</li><li>Verify Bitlocker is Enabled</li><li>Verify Lotus Notes (If still used)</li><li>Verify taskbar has no MS Store</li><li>Verify data is successfully transferred over</li><li>Verify power settings match</li><li>Verify printers match</li><li>Verify manual drive mappings</li></ol></div></details>
  <footer>Generated by STO Laptop Transfer Tool v{{VERSION}} · {{YEAR}}</footer>
</main>
</body>
</html>
'@

# UI helpers are deliberately side-effect-light: they format text or write to
# the console, while the feature modules own filesystem and registry changes.
# This keeps progress output consistent and makes non-interactive validation
# possible without duplicating the transfer logic.

function Get-VisibleLength {
    # ANSI color sequences occupy characters in the raw string but no columns
    # on screen, so remove them before calculating padding and alignment.
    # Length of a string ignoring ANSI escape sequences (for correct padding)
    param([string]$Text)
    return ([regex]::Replace($Text, "$([char]27)\[[0-9;]*m", "")).Length
}

function Out-HtmlEncoded {
    # Encode a value for safe insertion into HTML. Folder names, details, and
    # bookmark titles routinely contain & < > which otherwise break rendering.
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Convert-ToGradient {
    # Returns a string with per-character 24-bit color from AccentFrom -> AccentTo
    param([string]$Text, [int[]]$From = $Script:Theme.AccentFrom, [int[]]$To = $Script:Theme.AccentTo)
    if (-not $Script:AnsiEnabled) { return $Text }
    $e = $Script:Theme.Esc
    $len = $Text.Length
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $len; $i++) {
        $t = if ($len -le 1) { 0 } else { $i / ($len - 1) }
        $r = [int]($From[0] + ($To[0] - $From[0]) * $t)
        $g = [int]($From[1] + ($To[1] - $From[1]) * $t)
        $b = [int]($From[2] + ($To[2] - $From[2]) * $t)
        [void]$sb.Append("$e[38;2;$r;$g;${b}m$($Text[$i])")
    }
    [void]$sb.Append("$e[0m")
    return $sb.ToString()
}

function Write-Banner {
    # Draws a gradient-bordered box with centered, gradient title text
    param([string]$Title, [string]$Subtitle = "", [int]$Width = $Script:Theme.Width)
    $b = $Script:Theme.Box
    $inner = $Width - 2
    $top = "$($b.TL)$([string]$b.H * $inner)$($b.TR)"
    $bot = "$($b.BL)$([string]$b.H * $inner)$($b.BR)"

    $titlePad = [math]::Max(0, ($inner - $Title.Length))
    $tLeft = [math]::Floor($titlePad / 2)
    $tRight = $titlePad - $tLeft
    $titleLine = "$($b.V)$(' ' * $tLeft)$(Convert-ToGradient $Title)$(' ' * $tRight)$($b.V)"

    Write-Host ""
    Write-Host (Convert-ToGradient $top)
    Write-Host $titleLine
    if ($Subtitle) {
        $sPad = [math]::Max(0, ($inner - $Subtitle.Length))
        $sLeft = [math]::Floor($sPad / 2)
        $sRight = $sPad - $sLeft
        Write-Host "$($b.V)$(' ' * $sLeft)" -NoNewline
        Write-Host $Subtitle -ForegroundColor DarkGray -NoNewline
        Write-Host "$(' ' * $sRight)$($b.V)"
    }
    Write-Host (Convert-ToGradient $bot)
    Write-Host ""
}

function Write-Section {
    # A lightweight section header: accent arrow + gradient rule
    param([string]$Title, [int]$Width = $Script:Theme.Width)
    $rule = [string]$Script:Theme.Box.H * [math]::Max(4, ($Width - $Title.Length - 4))
    Write-Host ""
    Write-Host "$($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White -NoNewline
    Write-Host "  $(Convert-ToGradient $rule)"
}

function Write-Status {
    # Aligned status line: glyph + padded label + dimmed detail
    param(
        [string]$Label,
        [ValidateSet("OK","WARN","FAIL","INFO","SKIP")][string]$Status,
        [string]$Detail = "",
        [int]$LabelWidth = 34
    )
    $glyph = $Script:Theme.Glyphs[$Status]
    $color = @{ OK="Green"; WARN="Yellow"; FAIL="Red"; INFO="Cyan"; SKIP="DarkGray" }[$Status]
    $padded = if ($Label.Length -gt $LabelWidth) { $Label.Substring(0, $LabelWidth) } else { $Label.PadRight($LabelWidth) }
    Write-Host "  $glyph " -ForegroundColor $color -NoNewline
    Write-Host $padded -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host " $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
}

function Write-KeyValue {
    # Render a two-column diagnostic row.  Values are intentionally strings so
    # callers can pass formatted sizes, paths, or settings without conversion
    # rules leaking into the presentation layer.
    param([string]$Key, [string]$Value, [int]$KeyWidth = 18)
    Write-Host "    $($Key.PadRight($KeyWidth))" -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor White
}

function Write-SummaryCard {
    # Bordered receipt-style summary at the end of a run
    param([int]$Success, [int]$Warning, [int]$Errors, [int]$Skipped, [string]$Duration, [int]$Width = $Script:Theme.Width)
    $b = $Script:Theme.Box
    $inner = $Width - 2
    Write-Host ""
    Write-Host (Convert-ToGradient "$($b.TL)$([string]$b.H * $inner)$($b.TR)")
    $rows = @(
        @{ L="Successful"; V=$Success;  C="Green" }
        @{ L="Warnings";   V=$Warning;  C="Yellow" }
        @{ L="Errors";     V=$Errors;   C="Red" }
        @{ L="Skipped";    V=$Skipped;  C="DarkGray" }
    )
    foreach ($r in $rows) {
        $line = "  $($Script:Theme.Glyphs.ARROW) $($r.L)"
        $val = "$($r.V)"
        $pad = $inner - $line.Length - $val.Length - 2
        Write-Host "$($b.V)" -NoNewline
        Write-Host $line -ForegroundColor $r.C -NoNewline
        Write-Host "$(' ' * [math]::Max(1,$pad))$val  " -ForegroundColor $r.C -NoNewline
        Write-Host "$($b.V)"
    }
    Write-Host "$($b.V)$(' ' * $inner)$($b.V)"
    $durLine = "  Duration: $Duration"
    Write-Host "$($b.V)" -NoNewline
    Write-Host $durLine -ForegroundColor DarkGray -NoNewline
    Write-Host "$(' ' * [math]::Max(0, $inner - $durLine.Length))$($b.V)"
    Write-Host (Convert-ToGradient "$($b.BL)$([string]$b.H * $inner)$($b.BR)")
    Write-Host ""
}

function Write-StoLogo {
    # Compact Unicode wordmark, gradient-accented
    $l = @(
        "  ___ _____ ___    ",
        " / __|_   _/ _ \   ",
        " \__ \ | || (_) |  ",
        " |___/ |_| \___/   "
    )
    Write-Host ""
    foreach ($line in $l) { Write-Host (Convert-ToGradient $line) }
    Write-Host "  BUILDING GROUP" -ForegroundColor DarkGray
    Write-Host ""
}

function Clear-StoScreen {
    # Clear-Host accesses RawUI, which is unavailable when the script runs
    # through a redirected, remoted, or log-capturing host. The UI is still
    # readable without clearing, so never let this cosmetic action stop work.
    try { Clear-Host -ErrorAction Stop } catch { }
}

function Read-UserInput {
    # Keep input acquisition centralized so prompts have the same indentation
    # and can be replaced or bypassed by an automation harness.
    param([string]$Prompt)
    Write-Host $Prompt
    return Read-Host '  > '
}

# ============================================================================
# ADMIN ELEVATION
# ============================================================================

# Core owns shared state and cross-cutting services.  It resolves the source
# identity, builds the effective configuration, manages asynchronous size
# estimates, writes logs/results, and provides the common copy primitive used
# by user-data, settings, browser, and destination modules.

# Track if we have admin privileges
$Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# If no target profile was passed, use current user's profile (we're not elevated yet, or user chose not to elevate)
if ([string]::IsNullOrEmpty($TargetUserProfile)) {
    $Script:OriginalUserProfile = $env:USERPROFILE
    $Script:OriginalUserName = $env:USERNAME
    $Script:OriginalAppDataRoaming = $env:APPDATA
    $Script:OriginalAppDataLocal = $env:LOCALAPPDATA
}
else {
    # Use the passed values (we're running elevated)
    $Script:OriginalUserProfile = $TargetUserProfile
    $Script:OriginalUserName = $TargetUserName
    $Script:OriginalAppDataRoaming = $TargetAppDataRoaming
    $Script:OriginalAppDataLocal = $TargetAppDataLocal
}

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version = "1.0"
    TransferFolderName = "LaptopTransfer_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    # Printer driver binaries in the PrintBRM package. Network printers also
    # have a driverless, non-admin connection restore. TRUE bundles drivers
    # when PrintBRM is permitted to create the package; FALSE (-NOBIN) makes a
    # smaller package.
    IncludePrinterDrivers = $true

    # Elevation is opt-in from the Transfer Settings screen. It retries only
    # PrintBRM and the full power-plan export after user-context capture.
    Export = @{
        RequestAdministratorPrivileges = $false
    }
    
    # User profile folders to copy (relative to user profile)
    UserFolders = @(
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Videos",
        "Music",
        "Favorites",
        # Start Menu is stored under Roaming AppData, not at the profile-root
        # junction. Resolve-ExportUserFolderPath handles that canonical path.
        "Start Menu"
    )
    
    # AppData paths to check/copy (relative to AppData\Roaming)
    AppDataRoaming = @{
        "Signatures" = "Microsoft\Signatures"
        "QuickAccess" = "Microsoft\Windows\Recent\AutomaticDestinations"
        # On-Screen Takeoff keeps user-scoped settings under the On Center
        # Software vendor tree.  Preserve it separately from general AppData
        # so it can be restored to the matching location on the new PC.
        "OnScreenTakeoff" = "On Center Software\On-Screen Takeoff"
    }
    
    # AppData\Local paths to check/copy
    AppDataLocal = @{
        "Lotus" = "Lotus"
        "OnScreenTakeoff" = "On Center Software\On-Screen Takeoff"
    }
    
    # Bluebeam can be in different locations - check these paths
    BluebeamPaths = @(
        "Bluebeam Software",
        "Bluebeam"
    )
    
    # Robocopy settings
    # /Z (restartable mode) writes extra recovery state and is noticeably
    # slower for normal local/USB copies. A failed copy can be rerun safely,
    # so favor throughput with parallel file copies. (/J remains in use for
    # the one-file ZIP upload, where unbuffered I/O is beneficial.)
    RobocopyArgs = @("/E", "/XJ", "/R:2", "/W:3", "/MT:16", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")

    # ---- Transfer mode ----
    # "Local"  = full copy (USB/on-site).  "Online" = trimmed for slow/remote links.
    # Resolved at runtime from the -TransferMode param or an interactive prompt.
    TransferMode = "Local"

    Transfer = @{
        # Local packages default to folders; Online defaults below enable ZIP.
        CreateZipArchive = $false
    }

    # Online-mode trimming rules (only applied when TransferMode = "Online")
    Online = @{
        DownloadsCapGB   = 5
        MaxTransferGB    = 5
        Downloads = $true
        OverrideDownloadsCap = $false
        # Lotus Notes local data is the other usual heavy hitter; omit by default.
        SkipLotusNotes   = $true
        # Any other user folder above this size prompts the tech (skip / copy anyway).
        LargeFolderPromptGB = 10
        # Skip the OneDrive force-hydration step (it would re-download everything
        # over the same constrained link).
        SkipOneDriveHydration = $true
        # Create a portable ZIP beside the transfer folder after an online export.
        CreateZipArchive = $true
        # Avoid direct file-by-file exports to a network destination.
        StageNetworkTransfersLocally = $true
        # Advanced Online controls. These are deliberately conservative so
        # slow links carry only data that can be restored or imported.
        IncludeChromeProfileArchive = $false
        IncludeAdditionalUserFolders = $false
        AdditionalFolderCapGB = 1
        IncludeOcsDocuments = $false
        DetailedAppDataCandidateInventory = $false
        # Import defaults used only when the selected transfer mode is Online.
        Import = @{
            LotusNotes = $true
            DeletePrintBrmAfterImport = $true
            EnableAdminHelper = $true
            AppComparison = $true
            AppDataReview = $true
        }
    }

    # These switches are supplied by src\00-development-config.psd1 at build
    # time and remain embedded in the single deployment script.
    Backup = @{
        UserData          = $true
        Downloads         = $true
        EntireUserProfile = $false
        AdditionalAppData = $false
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        AppDataCandidateInventory = $true
        Printers          = $true
        Chrome            = 'BookmarksAndPasswords'
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
        TaskbarLayout     = $true
        DefaultApps       = $true
    }
    Import = @{
        LotusNotes = $true
        DeletePrintBrmAfterImport = $true
        EnableAdminHelper = $true
        AppComparison = $true
        AppDataReview = $true
    }
}

# Apply only known Boolean development switches so invalid additions cannot
# unexpectedly change the behavior of a technician deployment.
foreach ($sectionName in @("Backup", "Import", "Export", "Transfer")) {
    if (-not ($Script:DevelopmentConfig -is [hashtable]) -or
        -not $Script:DevelopmentConfig.ContainsKey($sectionName) -or
        -not ($Script:DevelopmentConfig[$sectionName] -is [hashtable])) {
        continue
    }

    # Snapshot the keys before changing values. PowerShell's hashtable
    # enumerator can treat a value assignment as a collection modification.
    foreach ($switchName in @($Script:Config[$sectionName].Keys)) {
        if ($Script:DevelopmentConfig[$sectionName].ContainsKey($switchName) -and
            $Script:DevelopmentConfig[$sectionName][$switchName] -is [bool]) {
            $Script:Config[$sectionName][$switchName] = $Script:DevelopmentConfig[$sectionName][$switchName]
        }
    }
}

if ($Script:DevelopmentConfig -is [hashtable] -and $Script:DevelopmentConfig.Backup -is [hashtable] -and
    $Script:DevelopmentConfig.Backup.Chrome -in @('Off', 'BookmarksAndPasswords', 'FullProfile')) {
    $Script:Config.Backup.Chrome = $Script:DevelopmentConfig.Backup.Chrome
}

# Online transfer behavior has a nested import-default section. Keep its
# allowlist separate so config-file additions cannot alter unrelated settings.
if ($Script:DevelopmentConfig -is [hashtable] -and
    $Script:DevelopmentConfig.ContainsKey("Online") -and
    $Script:DevelopmentConfig.Online -is [hashtable]) {
    $developmentOnline = $Script:DevelopmentConfig.Online
    foreach ($switchName in @("Downloads", "OverrideDownloadsCap", "CreateZipArchive", "StageNetworkTransfersLocally", "IncludeChromeProfileArchive", "IncludeAdditionalUserFolders", "IncludeOcsDocuments", "DetailedAppDataCandidateInventory")) {
        if ($developmentOnline.ContainsKey($switchName) -and
            $developmentOnline[$switchName] -is [bool]) {
            $Script:Config.Online[$switchName] = $developmentOnline[$switchName]
        }
    }

    if ($developmentOnline.ContainsKey("Import") -and
        $developmentOnline.Import -is [hashtable]) {
        foreach ($switchName in @($Script:Config.Online.Import.Keys)) {
            if ($developmentOnline.Import.ContainsKey($switchName) -and
                $developmentOnline.Import[$switchName] -is [bool]) {
                $Script:Config.Online.Import[$switchName] = $developmentOnline.Import[$switchName]
            }
        }
    }
    if ($developmentOnline.ContainsKey("MaxTransferGB") -and [double]$developmentOnline.MaxTransferGB -gt 0) {
        $Script:Config.Online.MaxTransferGB = [double]$developmentOnline.MaxTransferGB
    }
    if ($developmentOnline.ContainsKey("AdditionalFolderCapGB") -and [double]$developmentOnline.AdditionalFolderCapGB -gt 0) {
        $Script:Config.Online.AdditionalFolderCapGB = [double]$developmentOnline.AdditionalFolderCapGB
    }
}

if ($OnlineMaxTransferGB -gt 0) {
    $Script:Config.Online.MaxTransferGB = $OnlineMaxTransferGB
}

# A UAC relaunch starts a new PowerShell process. Restore the settings chosen
# immediately before that relaunch so the technician does not need to repeat
# the Transfer Settings screen.
if ($RuntimeSettings) {
    try {
        $savedSettings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RuntimeSettings)) | ConvertFrom-Json
        foreach ($sectionName in @('Backup', 'Import', 'Export')) {
            if ($null -eq $savedSettings.$sectionName) { continue }
            foreach ($switchName in @($Script:Config[$sectionName].Keys)) {
                if ($null -ne $savedSettings.$sectionName.$switchName -and $savedSettings.$sectionName.$switchName -is [bool]) {
                    $Script:Config[$sectionName][$switchName] = $savedSettings.$sectionName.$switchName
                }
            }
        }
        foreach ($settingName in @('Downloads', 'OverrideDownloadsCap', 'CreateZipArchive', 'StageNetworkTransfersLocally', 'IncludeChromeProfileArchive', 'IncludeAdditionalUserFolders', 'IncludeOcsDocuments', 'DetailedAppDataCandidateInventory')) {
            if ($null -ne $savedSettings.Online.$settingName -and $savedSettings.Online.$settingName -is [bool]) {
                $Script:Config.Online[$settingName] = $savedSettings.Online.$settingName
            }
        }
        foreach ($settingName in @('MaxTransferGB', 'AdditionalFolderCapGB')) {
            if ($null -ne $savedSettings.Online.$settingName -and [double]$savedSettings.Online.$settingName -gt 0) {
                $Script:Config.Online[$settingName] = [double]$savedSettings.Online.$settingName
            }
        }
        if ($null -ne $savedSettings.AdditionalAppData) {
            $Script:SelectedAdditionalAppData = @($savedSettings.AdditionalAppData)
        }
        if ($savedSettings.TransferStartedAt) {
            $parsedTransferStart = [datetime]::MinValue
            if ([datetime]::TryParse([string]$savedSettings.TransferStartedAt, [ref]$parsedTransferStart)) {
                $Script:TransferStartedAt = $parsedTransferStart
            }
        }
    }
    catch {
        Write-Host "  Could not restore Transfer Settings after elevation; using the configured defaults." -ForegroundColor Yellow
    }
}

function Apply-OnlineTransferDefaults {
    # Online mode is a policy overlay: it changes only the switches that are
    # explicitly online-sensitive, leaving the base configuration intact.
    if ($Script:Config.TransferMode -ne "Online") { return }

    $Script:Config.Backup.Downloads = $Script:Config.Online.Downloads
    $Script:Config.Transfer.CreateZipArchive = $Script:Config.Online.CreateZipArchive
    if ($Script:Config.Online.IncludeChromeProfileArchive -and $Script:Config.Backup.Chrome -ne 'Off') {
        $Script:Config.Backup.Chrome = 'FullProfile'
    }
    elseif (-not $Script:Config.Online.IncludeChromeProfileArchive -and $Script:Config.Backup.Chrome -eq 'FullProfile') {
        $Script:Config.Backup.Chrome = 'BookmarksAndPasswords'
    }
    foreach ($switchName in $Script:Config.Online.Import.Keys) {
        $Script:Config.Import[$switchName] = $Script:Config.Online.Import[$switchName]
    }
}

function Set-SettingsPreset {
    # Presets mutate the selected backup switches as a group.  The UI can later
    # change individual values, so this function is a starting state, not a
    # second configuration source.
    param([ValidateSet('Basic', 'Advanced')][string]$Name)

    $Script:Config.Backup.EntireUserProfile = ($Name -eq 'Advanced')
    $Script:Config.Backup.AdditionalAppData = ($Name -eq 'Advanced')
    # Advanced is the complete profile preset, including Chrome's full
    # profile rather than only its portable bookmark/password handoff.
    if ($Name -eq 'Advanced') { $Script:Config.Backup.Chrome = 'FullProfile' }
    if ($Name -eq 'Basic') { $Script:SelectedAdditionalAppData = @() }
    $Script:SettingsPreset = $Name
}

function Resolve-ExportUserFolderPath {
    # Most profile folders resolve below the profile root; Start Menu is the
    # exception and is stored under roaming AppData.  Centralizing this mapping
    # prevents export and size-estimation paths from disagreeing.
    param([string]$Folder)
    if ($Folder -eq 'Start Menu') {
        return (Join-Path $Script:OriginalAppDataRoaming 'Microsoft\Windows\Start Menu')
    }
    return (Join-Path $Script:OriginalUserProfile $Folder)
}

function Start-TransferSizeEstimateJob {
    # Run expensive recursive directory enumeration in a background job so the
    # settings screen remains responsive.  The job returns plain objects only;
    # UI state is updated by Receive-TransferSizeEstimateJob in the foreground.
    # Run the initial inventory out-of-process so Transfer Settings remains
    # responsive while large profiles are being scanned.
    # Keep large profile-related payloads near the end and normal user folders
    # last. This avoids Documents/Desktop/Downloads competing with the more
    # useful early estimates while the background job is still running.
    # Edge transfers only its small Bookmarks files; scanning its entire cache
    # tree for an estimate was both inaccurate and exceptionally slow.
    $normalPaths = @()
    # A complete profile walk is intentionally deferred. It can take hours on
    # redirected/OneDrive profiles and estimates must never delay the menu.
    $heavyPaths = @()
    if ($Script:Config.Backup.AppData) {
        $heavyPaths += @($Script:Config.BluebeamPaths | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
        $heavyPaths += @($Script:Config.AppDataRoaming.Values | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
    }
    if ($Script:Config.Backup.LotusNotes) { $heavyPaths += Join-Path $Script:OriginalAppDataLocal 'Lotus' }
    if ($Script:Config.Backup.Chrome -eq 'FullProfile') { $heavyPaths += Join-Path $Script:OriginalAppDataLocal 'Google\Chrome\User Data' }
    if ($Script:Config.Backup.Firefox) {
        $heavyPaths += @((Join-Path $Script:OriginalAppDataRoaming 'Mozilla\Firefox'), (Join-Path $Script:OriginalAppDataLocal 'Mozilla\Firefox'))
    }
    $userDataPaths = @($Script:Config.UserFolders | ForEach-Object { Resolve-ExportUserFolderPath $_ })
    if ($Script:Config.Backup.EntireUserProfile) { $heavyPaths += $Script:OriginalUserProfile }
    $seenPaths = @{}; $inventoryPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($normalPaths + $heavyPaths + $userDataPaths)) {
        if ($path -and -not $seenPaths.ContainsKey($path)) { $seenPaths[$path] = $true; [void]$inventoryPaths.Add($path) }
    }
    return Start-Job -ArgumentList (,$inventoryPaths) -ScriptBlock {
        param([string[]]$InventoryPaths)
        foreach ($path in $InventoryPaths) {
            $bytes = 0L; $count = 0
            try {
                if (Test-Path -LiteralPath $path) {
                    # Keep this pipeline streaming.  Materializing the whole
                    # file list before measuring it makes large profiles much
                    # slower and consumes substantial memory.
                    $measure = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
                        Measure-Object -Property Length -Sum
                    $bytes = [long]$(if ($null -eq $measure.Sum) { 0 } else { $measure.Sum }); $count = $measure.Count
                }
            }
            catch { }
            [PSCustomObject]@{ Path = $path; FileCount = $count; Bytes = $bytes }
        }
    }
}

function Get-CachedFolderSizeBytes {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Script:FolderInventoryCache) { return $null }
    $key = $Path.TrimEnd([char]92)
    if ($Script:FolderInventoryCache.ContainsKey($key)) { return [long]$Script:FolderInventoryCache[$key].Bytes }
    return $null
}

function Get-CachedFolderSizeSum {
    param([string[]]$Paths)
    $sum = [long]0
    foreach ($path in @($Paths)) {
        $bytes = Get-CachedFolderSizeBytes -Path $path
        if ($null -eq $bytes) { return $null }
        $sum += $bytes
    }
    return $sum
}

function Get-TransferSizeDisplayEstimate {
    # This version deliberately reads only completed background-job entries.
    # It must never fall back to Get-FolderInventory, which would make the
    # interactive menu perform a competing foreground recursive scan.
    $sizes = @{}
    foreach ($key in @($Script:Config.Backup.Keys)) { $sizes[$key] = [long]0 }
    foreach ($key in @('UserData', 'Downloads', 'EntireUserProfile', 'AdditionalAppData', 'AppData', 'LotusNotes', 'Firefox')) {
        if ($Script:Config.Backup[$key]) { $sizes[$key] = $null }
    }
    if ($Script:Config.Backup.Edge) { $sizes.Edge = [long]0 }
    if ($Script:Config.Backup.UserData) {
        $userDataPaths = @($Script:Config.UserFolders | Where-Object { $_ -ne 'Downloads' } | ForEach-Object { Resolve-ExportUserFolderPath $_ })
        $sizes.UserData = Get-CachedFolderSizeSum -Paths $userDataPaths
    }
    if ($Script:Config.Backup.Downloads) {
        $sizes.Downloads = Get-CachedFolderSizeBytes -Path (Resolve-ExportUserFolderPath 'Downloads')
    }
    if ($Script:Config.Backup.AppData) {
        $appDataPaths = @($Script:Config.BluebeamPaths | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ }) + @($Script:Config.AppDataRoaming.Values | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
        $sizes.AppData = Get-CachedFolderSizeSum -Paths $appDataPaths
    }
    if ($Script:Config.Backup.LotusNotes) { $sizes.LotusNotes = Get-CachedFolderSizeBytes -Path (Join-Path $Script:OriginalAppDataLocal 'Lotus') }
    if ($Script:Config.Backup.Chrome -eq 'FullProfile') { $sizes.Chrome = Get-CachedFolderSizeBytes -Path (Join-Path $Script:OriginalAppDataLocal 'Google\Chrome\User Data') }
    elseif ($Script:Config.Backup.Chrome -eq 'BookmarksAndPasswords') { $sizes.Chrome = [long]0 }
    if ($Script:Config.Backup.Firefox) { $sizes.Firefox = Get-CachedFolderSizeSum -Paths @((Join-Path $Script:OriginalAppDataRoaming 'Mozilla\Firefox'), (Join-Path $Script:OriginalAppDataLocal 'Mozilla\Firefox')) }
    # Edge's export is only its Bookmarks files, so retain its placeholder
    # until the completed estimate performs that lightweight file calculation.
    if ($Script:Config.Backup.EntireUserProfile) {
        $profileBytes = Get-CachedFolderSizeBytes -Path $Script:OriginalUserProfile
        # Start Menu is already below AppData and must not be subtracted twice
        # from the optional remaining-profile estimate.
        $profileFolderPaths = @($Script:Config.UserFolders | Where-Object { $_ -ne 'Start Menu' } | ForEach-Object { Join-Path $Script:OriginalUserProfile $_ })
        $excludedBytes = Get-CachedFolderSizeSum -Paths @($profileFolderPaths + (Join-Path $Script:OriginalUserProfile 'AppData'))
        if ($null -ne $profileBytes -and $null -ne $excludedBytes) { $sizes.EntireUserProfile = [long]($profileBytes - $excludedBytes) }
    }
    if ($Script:Config.Backup.AdditionalAppData -and @($Script:SelectedAdditionalAppData | Where-Object { $null -eq $_.SizeBytes }).Count -eq 0) {
        $sizes.AdditionalAppData = [long](@($Script:SelectedAdditionalAppData | Measure-Object -Property SizeBytes -Sum).Sum)
    }
    $known = @($sizes.Values | Where-Object { $null -ne $_ })
    return [PSCustomObject]@{ ItemBytes = $sizes; TotalBytes = [long](($known | Measure-Object -Sum).Sum) }
}

function Receive-TransferSizeEstimateJob {
    # Drain completed estimate jobs and copy their results into the cache.
    # Stale or failed jobs are ignored because estimates are advisory and must
    # never prevent an otherwise valid transfer.
    if (-not $Script:TransferSizeEstimateJob) { return $false }
    $updated = $false
    foreach ($inventory in @(Receive-Job -Job $Script:TransferSizeEstimateJob -ErrorAction SilentlyContinue)) {
        if ($inventory -and $inventory.Path) {
            if (-not $Script:FolderInventoryCache) { $Script:FolderInventoryCache = @{} }
            $Script:FolderInventoryCache[$inventory.Path.TrimEnd([char]92)] = [PSCustomObject]@{ FileCount = [int]$inventory.FileCount; Bytes = [long]$inventory.Bytes }
            $updated = $true
        }
    }
    if ($updated) { $Script:TransferSizeDisplayEstimate = Get-TransferSizeDisplayEstimate }
    if ($Script:TransferSizeEstimateJob.State -eq 'Completed') {
        # The job has already walked these folders.  Never immediately walk
        # them again here: the former foreground estimate made completion look
        # stalled and doubled the I/O on large profiles.
        $Script:StartupPayloadEstimate = Get-TransferSizeDisplayEstimate
        $Script:TransferSizeDisplayEstimate = $Script:StartupPayloadEstimate
    }
    elseif ($Script:TransferSizeEstimateJob.State -in @('Failed', 'Stopped')) {
        $Script:StartupPayloadEstimate = [PSCustomObject]@{ ItemBytes = @{}; TotalBytes = [long]0 }
        foreach ($backupKey in $Script:Config.Backup.Keys) { $Script:StartupPayloadEstimate.ItemBytes[$backupKey] = [long]0 }
        $Script:TransferSizeDisplayEstimate = $Script:StartupPayloadEstimate
        Write-Log 'Folder-size background calculation did not complete; sizes are unavailable for this transfer.' -Level Warning
    }
    else { return $updated }
    Remove-Job -Job $Script:TransferSizeEstimateJob -Force -ErrorAction SilentlyContinue
    $Script:TransferSizeEstimateJob = $null
    return $true
}

function Read-MenuInputWithBackgroundRefresh {
    # A normal Read-Host blocks the foreground runspace, so completed jobs could
    # not update the overview until after the next keypress. Use Console input
    # when available and retain Read-Host only for redirected hosts.
    param([string]$Prompt, [scriptblock]$Poll)
    Write-Host $Prompt
    try {
        if (-not [Console]::IsInputRedirected) {
            Write-Host '  > ' -NoNewline
            $buffer = [Text.StringBuilder]::new()
            while ($true) {
                if ($Poll -and (& $Poll)) { Write-Host ''; return '__MENU_AUTO_REFRESH__' }
                if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 175; continue }
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; return $buffer.ToString().Trim() }
                if ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($buffer.Length) { [void]$buffer.Remove($buffer.Length - 1, 1); Write-Host "`b `b" -NoNewline }
                    continue
                }
                if (-not [char]::IsControl($key.KeyChar)) { [void]$buffer.Append($key.KeyChar); Write-Host $key.KeyChar -NoNewline }
            }
        }
    }
    catch { }
    if ($Poll) { [void](& $Poll) }
    return (Read-Host '  > ').Trim()
}

function Show-BackupOverview {
    while ($true) {
        [void](Receive-TransferSizeEstimateJob)
        Clear-StoScreen
        Write-Section 'OVERVIEW OF BACKUP INCLUDING ESTIMATED SIZE'
        $estimate = if ($Script:StartupPayloadEstimate) { $Script:StartupPayloadEstimate } else { $Script:TransferSizeDisplayEstimate }
        Write-KeyValue 'Transfer mode' $Script:Config.TransferMode
        $modeGuidance = if ($Script:Config.TransferMode -eq 'Online') { 'Use Online for a network or cloud-synced destination.' } else { 'Use Local for an external or secondary drive.' }
        Write-KeyValue 'Mode guidance' $modeGuidance
        Write-KeyValue 'Estimated size' $(if ($estimate) { Format-FileSize $estimate.TotalBytes } else { 'Calculating in background...' })
        $selection = Read-MenuInputWithBackgroundRefresh -Prompt '  [1] Start transfer  [2] Change settings  [3] Cancel' -Poll {
            $wasRunning = [bool]$Script:TransferSizeEstimateJob
            [void](Receive-TransferSizeEstimateJob)
            return ($wasRunning -and -not $Script:TransferSizeEstimateJob)
        }
        if ($selection -eq '__MENU_AUTO_REFRESH__') { continue }
        if ($selection -eq '1') {
            return $true
        }
        if ($selection -eq '3') { return $false }
        if ($selection -eq '2') { if (-not (Show-TransferSettingsMenu)) { return $false }; continue }
        Write-Host '  Enter 1, 2, or 3.' -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

function Start-ElevatedExport {
    # Relaunch the same script with RunAs while passing the original profile and
    # serialized settings.  The new process is the only elevated boundary;
    # ordinary user data remains handled in the original user context.
    # Do not relaunch the whole exporter: that changes the transferring user's
    # profile context. Start-ElevatedSystemExport later elevates only PrintBRM
    # and the full power-plan capture.
    if (-not $Script:IsAdmin -and $Script:Config.Export.RequestAdministratorPrivileges) {
        Write-Host "`n  User data stays in the signed-in user's context; PrintBRM and power will request UAC separately." -ForegroundColor Cyan
    }
    return $true
}

function Restart-AsAdministrator {
    # Build a quoted argument list for Start-Process.  The helper preserves
    # spaces in profile/destination paths and deliberately returns after the
    # child process exits so the parent cannot continue a duplicate export.
    if ($Script:IsAdmin) { Write-Host '  Already running as Administrator.' -ForegroundColor Green; return }
    try {
        Start-Process PowerShell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ErrorAction Stop
        exit
    }
    catch { Write-Host '  Could not elevate. Continuing without administrator rights.' -ForegroundColor Yellow }
}

function Add-DisabledBackupResult {
    # Disabled stages still get a result row.  This makes the report distinguish
    # intentional omission from a stage that was attempted and failed.
    param(
        [string]$Item,
        [string]$Category = "Backup"
    )

    Write-Log "$Item backup disabled by configuration" -Level Info
    Write-Status $Item "SKIP" "disabled by config"
    Add-Result -Category $Category -Item $Item -Status "Skipped" -Details "Disabled by configuration"
}

function Show-OnlineAdvancedSettingsMenu {
    # Present online-only payload controls and write the operator's selections
    # back to the shared configuration used by subsequent copy stages.
    while ($true) {
        Clear-StoScreen
        Write-Banner -Title "Advanced Online Controls" -Subtitle "These choices affect this transfer only"
        foreach ($setting in @(
            @{ Number = 1; Key = 'IncludeAdditionalUserFolders'; Label = 'Include additional user folders'; Detail = 'OFF skips unlisted profile folders in Online mode' }
            @{ Number = 2; Key = 'IncludeOcsDocuments'; Label = 'Include C:\\OCS Documents'; Detail = 'OFF skips this optional project folder in Online mode' }
            @{ Number = 3; Key = 'DetailedAppDataCandidateInventory'; Label = 'Detailed AppData candidate sizes'; Detail = 'OFF records names only and avoids recursive sizing' }
            @{ Number = 4; Key = 'IncludeChromeProfileArchive'; Label = 'Include Chrome full profile'; Detail = 'OFF keeps the lean bookmarks/password handoff only' }
        )) {
            $state = if ($Script:Config.Online[$setting.Key]) { 'ON ' } else { 'OFF' }
            $color = if ($Script:Config.Online[$setting.Key]) { 'Green' } else { 'DarkGray' }
            Write-Host "  [$($setting.Number)] $state " -ForegroundColor Cyan -NoNewline
            Write-Host $setting.Label -ForegroundColor $color -NoNewline
            Write-Host "  $($setting.Detail)" -ForegroundColor DarkGray
        }
        Write-Host "  [5] $($Script:Config.Online.AdditionalFolderCapGB) GB " -ForegroundColor Cyan -NoNewline
        Write-Host "Additional-folder cap" -ForegroundColor Yellow -NoNewline
        Write-Host "  folders above this require confirmation when included" -ForegroundColor DarkGray
        $selection = (Read-UserInput "  Select 1-5, [B] Back").Trim()
        if ($selection -match '^[Bb]$') { return }
        if ($selection -eq '5') {
            $value = 0.0; $entered = Read-UserInput "  Enter additional-folder cap in GB (current: $($Script:Config.Online.AdditionalFolderCapGB))"
            if ([double]::TryParse($entered, [ref]$value) -and $value -gt 0) { $Script:Config.Online.AdditionalFolderCapGB = $value }
            continue
        }
        $index = 0
        if ([int]::TryParse($selection, [ref]$index) -and $index -ge 1 -and $index -le 4) {
            $key = @('IncludeAdditionalUserFolders', 'IncludeOcsDocuments', 'DetailedAppDataCandidateInventory', 'IncludeChromeProfileArchive')[$index - 1]
            $Script:Config.Online[$key] = -not [bool]$Script:Config.Online[$key]
            if ($key -eq 'IncludeChromeProfileArchive') {
                if ($Script:Config.Online[$key]) { $Script:Config.Backup.Chrome = 'FullProfile' }
                elseif ($Script:Config.Backup.Chrome -eq 'FullProfile') { $Script:Config.Backup.Chrome = 'BookmarksAndPasswords' }
            }
            $Script:SettingsPreset = 'Custom'
        }
    }
}

function Show-TransferSettingsMenu {
    # This is the final preflight editor.  It validates combinations, displays
    # the effective payload, and returns control to the main workflow only after
    # the operator accepts or cancels the transfer.
    # These are the runtime counterparts of the switches in
    # src\00-development-config.psd1.  Values start with the compiled
    # defaults, but any changes made here apply only to the current transfer.
    $settings = @(
        @{ Section = "Backup"; Key = "UserData";          Label = "User data";          Detail = "Documents, Desktop, and other user folders" }
        @{ Section = "Backup"; Key = "Downloads";         Label = "Downloads";          Detail = "Downloads folder" }
        @{ Section = "Backup"; Key = "EntireUserProfile"; Label = "Entire user profile"; Detail = "Copy remaining profile folders; excludes data captured by other stages" }
        @{ Section = "Backup"; Key = "AdditionalAppData"; Label = "Additional AppData folders"; Detail = "Choose extra Local/Roaming folders with size estimates" }
        @{ Section = "Backup"; Key = "AppData";           Label = "AppData";            Detail = "Bluebeam, signatures, and Quick Access" }
        @{ Section = "Backup"; Key = "LotusNotes";        Label = "Lotus Notes";        Detail = "Local Lotus Notes data from AppData\\Local" }
        @{ Section = "Backup"; Key = "SystemSettings";    Label = "System settings";    Detail = "Power, drives, personalization, and related settings" }
        @{ Section = "Backup"; Key = "InstalledPrograms"; Label = "Installed programs"; Detail = "Installed-program inventory" }
        @{ Section = "Backup"; Key = "AppDataCandidateInventory"; Label = "AppData candidates"; Detail = "Review-only inventory of non-system application folders" }
        @{ Section = "Backup"; Key = "Printers";          Label = "Printers";           Detail = "PrintBRM package and printer connections" }
        @{ Section = "Backup"; Key = "Chrome"; Type = "ChromeMode"; Label = "Google Chrome"; Detail = "Off, bookmarks + passwords, or full profile" }
        @{ Section = "Backup"; Key = "Firefox";           Label = "Firefox";            Detail = "Firefox profile, bookmarks, logins, extensions, and settings" }
        @{ Section = "Backup"; Key = "Edge";              Label = "Microsoft Edge";     Detail = "Edge bookmarks and profile-specific favorites" }
        @{ Section = "Backup"; Key = "OneDrive";          Label = "OneDrive";           Detail = "Offline file availability check" }
        @{ Section = "Backup"; Key = "TaskbarLayout";     Label = "Taskbar layout";     Detail = "Pinned app shortcuts and taskbar layout" }
        @{ Section = "Backup"; Key = "DefaultApps";       Label = "Default apps";       Detail = "File and protocol default-app inventory" }
        @{ Section = "Export"; Key = "RequestAdministratorPrivileges"; Label = "RECOMMENDED: Admin printer + power export"; Detail = "OFF by default; at the end, UAC retries only PrintBRM and the full power plan" }
        @{ Section = "Import"; Key = "LotusNotes";        Label = "Import Lotus Notes"; Detail = "Restore exported Lotus local data on the new laptop" }
        @{ Section = "Import"; Key = "DeletePrintBrmAfterImport"; Label = "Delete PrintBRM after import"; Detail = "Remove the printer package after a successful restore" }
        @{ Section = "Import"; Key = "AppComparison"; Label = "Compare installed apps"; Detail = "Compare old and new PC installed-program inventories" }
        @{ Section = "Import"; Key = "AppDataReview"; Label = "Review AppData candidates"; Detail = "Include source AppData candidates in the technician review" }
        @{ Section = "Online"; Key = "MaxTransferGB"; Type = "Number"; Label = "Online payload limit"; Detail = "Warn before export when selected payload exceeds this many GB" }
        @{ Section = "Online"; Key = "OverrideDownloadsCap"; Label = "Override Downloads cap"; Detail = "Copy Downloads above $($Script:Config.Online.DownloadsCapGB) GB without the confirmation prompt" }
        @{ Section = "Transfer"; Key = "CreateZipArchive";  Label = "Create ZIP archive"; Detail = "Create a ZIP beside the package" }
        @{ Section = "Online"; Key = "StageNetworkTransfersLocally"; Label = "Stage network transfers locally"; Detail = "Build locally, then upload one ZIP to a network destination" }
    )
    $Script:TransferSettingsMenuItems = $settings

    # Render the settings screen first, then calculate once and redraw it with
    # populated sizes. Later toggles reuse the cached inventory.
    $estimate = if ($Script:StartupPayloadEstimate) { $Script:StartupPayloadEstimate } else { $Script:TransferSizeDisplayEstimate }
    if ($null -eq $estimate -and -not $Script:TransferSizeEstimateJob) { $Script:TransferSizeEstimateJob = Start-TransferSizeEstimateJob }

    while ($true) {
        [void](Receive-TransferSizeEstimateJob)
        $estimate = if ($Script:StartupPayloadEstimate) { $Script:StartupPayloadEstimate } else { $Script:TransferSizeDisplayEstimate }
        Clear-StoScreen
        Write-Banner -Title "Transfer Settings" -Subtitle "$($Script:Config.TransferMode) transfer - changes apply to this transfer only"
        Write-Section "Backup settings"

        for ($index = 0; $index -lt $settings.Count; $index++) {
            $setting = $settings[$index]
            if ($index -eq 16) {
                Write-Section "Export settings"
                Write-Host "  RECOMMENDED: Enable the next setting when you can approve UAC. It improves PrintBRM and full power-plan capture; all other export work stays as the signed-in user." -ForegroundColor Yellow
            }
            if ($index -eq 17) {
                Write-Section "Generated import settings"
            }
            if ($index -eq 24) {
                Write-Section "Online transfer settings"
            }

            if ($index -eq 0) {
                $presetStyle = switch ($Script:SettingsPreset) {
                    'Basic' { @{ Foreground = 'Black'; Background = 'Green' } }
                    'Advanced' { @{ Foreground = 'White'; Background = 'DarkMagenta' } }
                    default { @{ Foreground = 'Cyan'; Background = 'DarkBlue' } }
                }
                Write-Host "  SETTINGS PRESET: $($Script:SettingsPreset.ToUpper()) " -ForegroundColor $presetStyle.Foreground -BackgroundColor $presetStyle.Background -NoNewline
                Write-Host "  [B] Basic  [V] Advanced" -ForegroundColor Cyan
                Write-Host "  Basic disables full-profile transfer and extra AppData selection; Advanced enables both." -ForegroundColor DarkGray
                Write-Host "  Folder-size estimate shown below is refreshed before copying, not when toggles change." -ForegroundColor DarkGray
                Write-Host ''
            }

            $number = ($index + 1).ToString().PadLeft(2)
            $isNumber = $setting.Type -eq "Number"
            $isChromeMode = $setting.Type -eq 'ChromeMode'
            $isEnabled = if ($isNumber -or $isChromeMode) { $false } else { [bool]$Script:Config[$setting.Section][$setting.Key] }
            $state = if ($isNumber) { "$($Script:Config.Online.MaxTransferGB)GB" } elseif ($isChromeMode) { switch ($Script:Config.Backup.Chrome) { 'BookmarksAndPasswords' { 'BOOKMARKS + PASSWORDS' } 'FullProfile' { 'FULL PROFILE' } default { 'OFF' } } } elseif ($isEnabled) { "ON " } else { "OFF" }
            $color = if ($isNumber) { "Yellow" } elseif ($isChromeMode) { if ($Script:Config.Backup.Chrome -eq 'Off') { 'DarkGray' } else { 'Green' } } elseif ($isEnabled) { "Green" } else { "DarkGray" }
            $sizeText = if ($setting.Section -eq "Backup") {
                if ($null -eq $estimate -or $null -eq $estimate.ItemBytes[$setting.Key]) { 'calculating...' } else { "$(Format-FileSize ([long]$estimate.ItemBytes[$setting.Key]))" }
            } else { "" }

            Write-Host "  [$number] " -ForegroundColor Cyan -NoNewline
            Write-Host "$state " -ForegroundColor $color -NoNewline
            Write-Host $setting.Label.PadRight(30) -ForegroundColor White -NoNewline
            if ($sizeText) {
                Write-Host "$($sizeText.PadLeft(10)) " -ForegroundColor DarkCyan -NoNewline
            }
            Write-Host $setting.Detail -ForegroundColor DarkGray
        }

        Write-Host ""
        $advancedHint = if ($Script:Config.TransferMode -eq 'Online') { '; [A] Advanced Online Controls' } else { '' }
        Write-Host "  Select a number to toggle it; [B] Basic; [V] Advanced$advancedHint; [R] Refresh; select Online payload limit to enter a GB value." -ForegroundColor Gray
        Write-Host "  Select Chrome to cycle its three backup modes." -ForegroundColor DarkGray
        Write-Host "  The recommended printer + power admin retry is OFF by default and requests UAC only at the end of export." -ForegroundColor DarkGray
        Write-Host "  ZIP archives are optional for Local transfers and enabled by default for Online transfers." -ForegroundColor DarkGray
        Write-Host "  Import settings are written into the transfer package's generated import script." -ForegroundColor DarkGray

        if ($Script:TransferSizeEstimateJob) { Write-Host '  Calculating folder sizes in the background. Estimates are optional; you can start now.' -ForegroundColor Cyan }
        $selection = Read-MenuInputWithBackgroundRefresh -Prompt '  [S] Start transfer  [Q] Cancel  [R] Refresh' -Poll {
            $wasRunning = [bool]$Script:TransferSizeEstimateJob
            [void](Receive-TransferSizeEstimateJob)
            return ($wasRunning -and -not $Script:TransferSizeEstimateJob)
        }

        if ($selection -eq '__MENU_AUTO_REFRESH__' -or $selection -match '^[Rr]$') { continue }
        if ($selection -match "^[Ss]$") {
            return $true
        }
        if ($selection -match "^[Qq]$") { return $false }
        if ($selection -match "^[Bb]$") { Set-SettingsPreset -Name Basic; Update-AdvancedPayloadEstimate; continue }
        if ($selection -match "^[Vv]$") { Set-SettingsPreset -Name Advanced; $Script:SelectedAdditionalAppData = Select-AdditionalAppData; $Script:SkipAdditionalAppDataSizing = $false; Update-AdvancedPayloadEstimate; continue }
        if ($selection -match "^[Aa]$" -and $Script:Config.TransferMode -eq 'Online') { Show-OnlineAdvancedSettingsMenu; Update-AdvancedPayloadEstimate; continue }

        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $settings.Count) {
            $setting = $settings[$selectedIndex - 1]
            if ($setting.Type -eq "Number") {
                $value = 0.0
                $entered = Read-UserInput "  Enter Online payload limit in GB (current: $($Script:Config.Online.MaxTransferGB))"
                if ([double]::TryParse($entered, [ref]$value) -and $value -gt 0) { $Script:Config.Online.MaxTransferGB = $value }
                else { Write-Host "  Enter a positive number of GB." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
            elseif ($setting.Type -eq 'ChromeMode') {
                $Script:Config.Backup.Chrome = switch ($Script:Config.Backup.Chrome) { 'Off' { 'BookmarksAndPasswords' } 'BookmarksAndPasswords' { 'FullProfile' } default { 'Off' } }
                if ($Script:Config.TransferMode -eq 'Online') { $Script:Config.Online.IncludeChromeProfileArchive = $Script:Config.Backup.Chrome -eq 'FullProfile' }
                $Script:SettingsPreset = 'Custom'
                Update-AdvancedPayloadEstimate
            }
            else {
                $Script:Config[$setting.Section][$setting.Key] = -not [bool]$Script:Config[$setting.Section][$setting.Key]
                $Script:SettingsPreset = 'Custom'
                if ($setting.Section -eq 'Backup' -and $setting.Key -eq 'AdditionalAppData') {
                    if ($Script:Config.Backup.AdditionalAppData) { $Script:SelectedAdditionalAppData = Select-AdditionalAppData; $Script:SkipAdditionalAppDataSizing = $false }
                    else { $Script:SelectedAdditionalAppData = @() }
                    Update-AdvancedPayloadEstimate
                }
                else { Update-AdvancedPayloadEstimate }
            }
        }
        else {
            Write-Host "  Enter a setting number, S, or Q." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

# ============================================================================
# LOGGING & REPORTING
# ============================================================================

$Script:Log = [System.Collections.ArrayList]::new()
$Script:Results = @{
    StartTime = if ($Script:TransferStartedAt) { [datetime]$Script:TransferStartedAt } else { Get-Date }
    EndTime = $null
    UserName = $Script:OriginalUserName
    ComputerName = $env:COMPUTERNAME
    Actions = [System.Collections.ArrayList]::new()
    Errors = [System.Collections.ArrayList]::new()
    Warnings = [System.Collections.ArrayList]::new()
    # Console warnings are not always action outcomes (for example, an archive
    # security exclusion). Keep them separately so none disappear from handoff.
    RuntimeAlerts = [System.Collections.ArrayList]::new()
    ManualTasks = [System.Collections.ArrayList]::new()
}

function Write-Log {
    # Append a timestamped line to the package log and mirror it to the console.
    # Logging is best-effort so a locked log file cannot abort data collection.
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    [void]$Script:Log.Add($logEntry)
    if ($Level -in @('Warning', 'Error')) {
        if (-not $Script:Results.RuntimeAlerts) { $Script:Results.RuntimeAlerts = [System.Collections.ArrayList]::new() }
        [void]$Script:Results.RuntimeAlerts.Add([PSCustomObject]@{ Timestamp = $timestamp; Level = $Level; Message = $Message })
    }
    
    $color = switch ($Level) {
        "Info"    { "White" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host $logEntry -ForegroundColor $color
}

function Add-Result {
    # Results are structured records consumed by the HTML report and summary
    # counters.  Keep status vocabulary stable because report sorting matches it.
    param(
        [string]$Category,
        [string]$Item,
        [string]$Status,
        [string]$Details = ""
    )

    # Empty source folders are intentional omissions, not a fifth status that
    # the summary cards cannot classify. Normalize them at the ledger boundary
    # so terminal and HTML summaries always count the same categories.
    if ($Status -eq 'Empty') { $Status = 'Skipped' }
    
    $result = @{
        Category = $Category
        Item = $Item
        Status = $Status
        Details = $Details
        Timestamp = Get-Date -Format "HH:mm:ss"
    }
    
    [void]$Script:Results.Actions.Add($result)
}

function Get-TransferResultCounts {
    # Both the terminal receipt and handoff report call this exact classifier.
    # Keep presentation colors and totals aligned with the action ledger.
    $actions = @($Script:Results.Actions)
    return [PSCustomObject]@{
        Success = @($actions | Where-Object { $_.Status -eq 'Success' }).Count
        Warning = @($actions | Where-Object { $_.Status -in @('Warning', 'Manual', 'Pending') }).Count
        Errors = @($actions | Where-Object { $_.Status -eq 'Error' -or $_.Status -like 'NOT EXPORTED*' -or $_.Status -eq 'Admin Required' }).Count
        Skipped = @($actions | Where-Object { $_.Status -in @('Skipped', 'Empty') }).Count
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-RemainingTime {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) {
        return "calculating..."
    }

    $remaining = [int][math]::Ceiling($Seconds)
    if ($remaining -lt 60) { return "$remaining sec" }
    if ($remaining -lt 3600) { return "$([math]::Floor($remaining / 60)) min $($remaining % 60) sec" }
    return "$([math]::Floor($remaining / 3600)) hr $([math]::Floor(($remaining % 3600) / 60)) min"
}

function Copy-WithProgress {
    # Wrap robocopy and translate its bitmask exit code into application
    # statuses. Robocopy codes 0-7 represent success or acceptable
    # differences; 8 and above mean a copy failure.
    param(
        [string]$Source,
        [string]$Destination,
        [string]$FolderName,
        [string]$LogPath,
        [array]$RobocopyArgs
    )
    
    # Never allow a copy target below its own source. This protects against a
    # destination selected within the profile or behind a path alias/junction.
    if (Test-PathIsSameOrChild -Path $Destination -ParentPath $Source) {
        $message = "Skipped '$FolderName': destination is inside the source and would create a recursive copy."
        Write-Log $message -Level Warning
        Write-Host "  $($Script:Theme.Glyphs.WARN) $message" -ForegroundColor Yellow
        return @{ ExitCode = -1; FilesCopied = 0; BytesCopied = 0; Status = "Warning"; Duration = [TimeSpan]::Zero }
    }

    # Reuse a prior preflight/menu inventory when available. The first caller
    # performs the walk; all later callers use the cached result.
    $sourceInventory = Get-FolderInventory -Path $Source
    $totalFiles = $sourceInventory.FileCount
    $totalSize = $sourceInventory.Bytes
    
    if ($totalFiles -eq 0) {
        return @{ ExitCode = 0; FilesCopied = 0; Status = "Empty" }
    }
    
    # Create destination if needed
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    
    Write-Host ""
    Write-Host "  $($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $FolderName -ForegroundColor White -NoNewline
    Write-Host "  $(Format-FileSize $totalSize) / $totalFiles files" -ForegroundColor DarkGray
    
    $startTime = Get-Date
    $spinIndex = 0
    
    $robocopyArgString = ($RobocopyArgs -join " ")
    
    # Keep a direct handle to the Robocopy process.  This lets the technician
    # stop only the current copy instead of terminating the whole export.
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "robocopy.exe"
    $pinfo.Arguments = "`"$Source`" `"$Destination`" $robocopyArgString"
    # Do not attach PowerShell script blocks to OutputDataReceived. On Windows
    # PowerShell 5.1 those callbacks run on worker threads with no runspace,
    # which terminates the host as soon as Robocopy writes its first output.
    # Keep the process detached from console output and render a responsive
    # indeterminate display from this (runspace-owned) loop instead.
    $pinfo.RedirectStandardOutput = $false
    $pinfo.RedirectStandardError = $false
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    if (-not $process.Start()) {
        return @{ ExitCode = -1; FilesCopied = 0; BytesCopied = 0; Status = "Warning"; Duration = [TimeSpan]::Zero }
    }

    $abortedByOperator = $false
    Write-Host "    Press S to stop this copy and continue with the next step." -ForegroundColor DarkGray
    
    # Use only the owning PowerShell runspace while Robocopy runs. This keeps
    # stop-key handling responsive and avoids expensive destination rescans.
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 750

        # Console input is optional because the script may be run with a host
        # that does not expose a physical console (for example, remoting).
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::S) {
                    $abortedByOperator = $true
                    Write-Host "`r$(' ' * 120)`r    Stopping $FolderName and continuing..." -ForegroundColor Yellow
                    $process.Kill()
                    $process.WaitForExit()
                    break
                }
            }
        }
        catch { }
        
        # A spinner is reliable for both one large file and many small files;
        # deriving a percentage from asynchronous output is not safe in
        # Windows PowerShell 5.1.
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]
        $spinIndex++
        $elapsed = (Get-Date) - $startTime
        $statusLine = "    $spin Copying $totalFiles files ($(Format-FileSize $totalSize))  elapsed $([math]::Round($elapsed.TotalSeconds, 0)) sec   "
        Write-Host "`r$statusLine" -NoNewline
    }
    
    $exitCode = $process.ExitCode
    $logLines = @("Source: $Source", "Destination: $Destination", "Robocopy exit code: $exitCode", "Robocopy arguments: $robocopyArgString")
    $logLines | Set-Content -LiteralPath $LogPath -Encoding UTF8
    
    $elapsed = (Get-Date) - $startTime
    $copySucceeded = $exitCode -lt 8
    $copiedSize = if ($copySucceeded) { $totalSize } else { [long]0 }
    $copiedFiles = if ($copySucceeded) { $totalFiles } else { 0 }
    
    # Complete the progress bar (clear the line first, then draw the final state)
    if ($abortedByOperator) {
        Write-Host "`r$(' ' * 140)" -NoNewline
        Write-Host "`r    " -NoNewline
        Write-Host "$($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
        Write-Host "Skipped by operator after $([math]::Round($elapsed.TotalSeconds, 1))s; partial files may remain." -ForegroundColor Yellow
        return @{
            ExitCode = $exitCode
            FilesCopied = $copiedFiles
            BytesCopied = $copiedSize
            Status = "Skipped"
            Aborted = $true
            Duration = $elapsed
        }
    }

    # Keep the final status on one line in the standard 80-column console.
    # The prior 34-character bar left too little room for the size and
    # duration fields, causing the completion display to wrap.
    $progressBar = [string]$Script:Theme.Bar.Full * 16
    Write-Host "`r$(' ' * 140)" -NoNewline
    Write-Host "`r    " -NoNewline
    Write-Host "$($Script:Theme.Glyphs.OK) " -ForegroundColor Green -NoNewline
    Write-Host $progressBar -ForegroundColor Green -NoNewline
    Write-Host " 100%  $(Format-FileSize $copiedSize)  in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    
    # Determine status based on exit code and files copied
    $status = if ($copySucceeded) { "Success" } else { "Warning" }
    
    return @{
        ExitCode = $exitCode
        FilesCopied = $copiedFiles
        BytesCopied = $copiedSize
        Status = $status
        Duration = $elapsed
    }
}

function Add-ManualTask {
    # Record work that cannot be automated safely, such as protected browser
    # credentials or actions requiring a different security context.
    param(
        [string]$Task,
        [string]$Reason,
        [string]$Instructions = ""
    )
    
    $manual = @{
        Task = $Task
        Reason = $Reason
        Instructions = $Instructions
    }
    
    [void]$Script:Results.ManualTasks.Add($manual)
}

# ============================================================================
# DESTINATION SELECTION
# ============================================================================

# Destination code validates that the package does not overlap the source
# profile, supports local/removable/network targets, and creates the final
# archive.  It performs validation before copying so a bad target fails early
# rather than producing a partially self-overwriting package.

if (-not ('LaptopExport.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace LaptopExport {
    public static class NativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetFinalPathNameByHandle(
            IntPtr hFile,
            StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr hObject);
    }
}
'@ -ErrorAction Stop
}

function Get-CanonicalTransferPath {
    # Resolve the deepest existing path through the Win32 file handle API.
    # Unlike lexical normalization, this follows junctions and symbolic links.
    # Non-existent destination children are appended to the canonical parent.
    param([string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $probe = $fullPath
        $suffix = [System.Collections.Generic.List[string]]::new()
        while (-not (Test-Path -LiteralPath $probe)) {
            $leaf = Split-Path -Path $probe -Leaf
            $parent = Split-Path -Path $probe -Parent
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return $null }
            [void]$suffix.Insert(0, $leaf)
            $probe = $parent
        }

        $handle = [LaptopExport.NativeMethods]::CreateFile(
            $probe,
            0,
            7,
            [IntPtr]::Zero,
            3,
            0x02000000,
            [IntPtr]::Zero)
        if ($handle -eq [IntPtr](-1)) { return $null }
        try {
            $buffer = New-Object System.Text.StringBuilder 32768
            $length = [LaptopExport.NativeMethods]::GetFinalPathNameByHandle($handle, $buffer, [uint32]$buffer.Capacity, 0)
            if ($length -eq 0 -or $length -ge $buffer.Capacity) { return $null }
            $canonical = $buffer.ToString()
        }
        finally {
            [void][LaptopExport.NativeMethods]::CloseHandle($handle)
        }

        if ($canonical.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $canonical = '\\' + $canonical.Substring(8)
        }
        elseif ($canonical.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $canonical = $canonical.Substring(4)
        }
        foreach ($part in $suffix) {
            $canonical = Join-Path -Path $canonical -ChildPath $part
        }
        return [System.IO.Path]::GetFullPath($canonical)
    }
    catch {
        return $null
    }
}

function Test-PathIsSameOrChild {
    # Normalize both paths and compare with an explicit directory boundary;
    # a simple string prefix would incorrectly treat C:\Data2 as a child of
    # C:\Data.
    param(
        [string]$Path,
        [string]$ParentPath
    )

    try {
        $destination = Get-CanonicalTransferPath -Path $Path
        $parent = Get-CanonicalTransferPath -Path $ParentPath
        if ([string]::IsNullOrWhiteSpace($destination) -or [string]::IsNullOrWhiteSpace($parent)) {
            # Fail closed if canonicalization is unavailable.
            return $true
        }
        $destination = $destination.TrimEnd([char]92)
        $parent = $parent.TrimEnd([char]92)
        $parentPrefix = $parent + [System.IO.Path]::DirectorySeparatorChar
        return $destination.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
               $destination.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $true
    }
}

function Test-DestinationIsWithinSourceProfile {
    # Source-profile destinations are blocked except for the dedicated AppData
    # export area, which is an intentional supported fallback location.
    param([string]$Path)

    if (-not (Test-PathIsSameOrChild -Path $Path -ParentPath $Script:OriginalUserProfile)) { return $false }
    $appDataRoot = Join-Path $Script:OriginalUserProfile 'AppData'
    $exportsRoot = Join-Path $appDataRoot 'Exports'
    # The caller treats $true as blocked. AppData itself and its dedicated
    # Exports child are the only source-profile destinations allowed.
    $normalizedPath = Get-CanonicalTransferPath -Path $Path
    $normalizedAppData = Get-CanonicalTransferPath -Path $appDataRoot
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedAppData)) { return $true }
    $normalizedPath = $normalizedPath.TrimEnd([char]92)
    $normalizedAppData = $normalizedAppData.TrimEnd([char]92)
    if ($normalizedPath -eq $normalizedAppData -or (Test-PathIsSameOrChild -Path $Path -ParentPath $exportsRoot)) { return $false }
    return $true
}

function Show-NativeWindowsFolderPicker {
    # Use the COM Common Item Dialog so the operator receives a filesystem-only
    # folder picker.  The interop is loaded once and the selected path is
    # released after conversion to a managed string.
    param([string]$InitialPath = "")

    # Use Windows' Common Item Dialog: the modern Explorer-style picker used
    # by desktop applications, rather than the legacy Shell tree dialog.
    try {
        if (-not ("Sto.NativeFolderPicker" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Sto {
    [Flags]
    internal enum FOS : uint {
        FORCEFILESYSTEM = 0x00000040,
        PATHMUSTEXIST = 0x00000800,
        PICKFOLDERS = 0x00000020
    }

    internal enum SIGDN : uint {
        FILESYSPATH = 0x80058000
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(SIGDN sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(FOS fos);
        void GetOptions(out FOS pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName(out IntPtr pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialog { }

    public static class NativeFolderPicker {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SHCreateItemFromParsingName(
            string path, IntPtr pbc, ref Guid riid, out IShellItem shellItem);

        public static string Pick(string initialPath) {
            IFileDialog dialog = (IFileDialog)new FileOpenDialog();
            try {
                FOS options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | FOS.PICKFOLDERS | FOS.FORCEFILESYSTEM | FOS.PATHMUSTEXIST);
                dialog.SetTitle("Choose the laptop transfer destination");
                dialog.SetOkButtonLabel("Select Folder");

                if (!String.IsNullOrEmpty(initialPath)) {
                    IShellItem initialFolder;
                    Guid iid = typeof(IShellItem).GUID;
                    if (SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid, out initialFolder) == 0) {
                        try { dialog.SetFolder(initialFolder); }
                        finally { Marshal.ReleaseComObject(initialFolder); }
                    }
                }

                const int ERROR_CANCELLED = unchecked((int)0x800704C7);
                int result = dialog.Show(IntPtr.Zero);
                if (result == ERROR_CANCELLED) return null;
                if (result != 0) Marshal.ThrowExceptionForHR(result);

                IShellItem selected;
                dialog.GetResult(out selected);
                try {
                    IntPtr path;
                    selected.GetDisplayName(SIGDN.FILESYSPATH, out path);
                    try { return Marshal.PtrToStringUni(path); }
                    finally { Marshal.FreeCoTaskMem(path); }
                }
                finally { Marshal.ReleaseComObject(selected); }
            }
            finally { Marshal.ReleaseComObject(dialog); }
        }
    }
}
'@ -ErrorAction Stop
        }

        return [Sto.NativeFolderPicker]::Pick($InitialPath)
    }
    catch {
        throw "Windows folder picker could not be opened: $($_.Exception.Message)"
    }
}

function Select-TargetDrive {
    Write-KeyValue "Transferring" $Script:OriginalUserName
    Write-KeyValue "Computer" $env:COMPUTERNAME
    Write-KeyValue "Transfer" $Script:Config.TransferMode
    Write-Section "Select external or secondary drive"

    # Local mode keeps the existing drive selector rather than opening the
    # Windows folder picker. C: is deliberately excluded.
    try {
        $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
    }
    catch {
        Write-Host "`nUnable to look for external drives: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "No files were copied. Resolve the Windows disk-service issue, then run the export again." -ForegroundColor Yellow
        return $null
    }

    $drives = @($logicalDisks | Where-Object {
        $_.DriveType -in @(2, 3) -and $_.DeviceID -ne $env:SystemDrive -and $_.Size -gt 0
    } | ForEach-Object {
        $freeGB = [math]::Round($_.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($_.Size / 1GB, 2)
        $type = if ($_.DriveType -eq 2) { "Removable" } else { "Fixed" }
        [PSCustomObject]@{
            Letter = $_.DeviceID
            Type = $type
            Display = "$($_.DeviceID) [$($_.VolumeName)] - $type - $freeGB GB free of $totalGB GB"
        }
    })

    if (-not $drives) {
        Write-Host "`nNo external or secondary drives found." -ForegroundColor Red
        Write-Host "Connect an external drive and start the export again. No files were copied." -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $drives.Count; $i++) {
        $color = if ($drives[$i].Type -eq "Removable") { "Cyan" } else { "White" }
        Write-Host "  [$($i + 1)] $($drives[$i].Display)" -ForegroundColor $color
    }
    Write-Host "`n  [0] Cancel`n" -ForegroundColor Gray

    do {
        $selection = Read-UserInput "Select target drive (1-$($drives.Count))"
        if ($selection -eq "0") { return $null }

        $index = 0
        if ([int]::TryParse($selection, [ref]$index)) {
            $index--
            if ($index -ge 0 -and $index -lt $drives.Count) {
                $selectedDrive = $drives[$index]
                $confirm = Read-UserInput "Proceed with $($selectedDrive.Display)? (Y/N)"
                if ($confirm -match "^[Yy]") { return $selectedDrive.Letter }
                if ($confirm -match "^[Nn]$") { continue }
                Write-Host '  Enter Y or N.' -ForegroundColor Yellow
                continue
            }
        }
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
    } while ($true)
}

function Select-TargetDestination {
    Write-KeyValue "Transferring" $Script:OriginalUserName
    Write-KeyValue "Computer" $env:COMPUTERNAME
    if ($Script:IsAdmin) {
        Write-KeyValue "Mode" "Administrator"
    } else {
        Write-KeyValue "Mode" "Standard (some items manual)"
    }
    Write-KeyValue "Transfer" $Script:Config.TransferMode
    if ($Script:IsAdmin -and $Script:OriginalUserName -ne $env:USERNAME) {
        Write-KeyValue "Running as" "$env:USERNAME (elevated)"
    }

    Write-Section "Choose export destination"
    Write-Host "Select a network share, cloud-synced folder, or local folder for the zipped export." -ForegroundColor Gray

    $selectedPath = $DestinationPath
    if (-not $selectedPath) {
        try {
            $initialPath = if (Test-Path $env:SystemDrive) { $env:SystemDrive } else { "" }
            $selectedPath = Show-NativeWindowsFolderPicker -InitialPath $initialPath
            if (-not $selectedPath) {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                return $null
            }
        }
        catch {
            # Keep a console fallback for constrained PowerShell hosts.
            Write-Host "Could not open the Windows folder picker: $_" -ForegroundColor Yellow
            $selectedPath = Read-UserInput "Enter destination folder path (blank to cancel)"
            if (-not $selectedPath) { return $null }
        }
    }

    # Reject before creating anything. Otherwise a destination inside a source
    # folder causes Robocopy to see its own transfer package.
    if (Test-DestinationIsWithinSourceProfile -Path $selectedPath) {
        Write-Host "The destination is inside the profile being exported." -ForegroundColor Red
        Write-Host "Choose a folder outside the source profile to prevent a recursive export. No files were copied." -ForegroundColor Yellow
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $selectedPath -PathType Container)) {
            New-Item -ItemType Directory -Path $selectedPath -Force -ErrorAction Stop | Out-Null
        }
        $selectedPath = (Resolve-Path -LiteralPath $selectedPath -ErrorAction Stop).Path
    }
    catch {
        Write-Host "Unable to use destination folder '$selectedPath': $_" -ForegroundColor Red
        return $null
    }

    if (Test-DestinationIsWithinSourceProfile -Path $selectedPath) {
        Write-Host "The destination cannot be inside the profile being exported." -ForegroundColor Red
        Write-Host "Choose a different folder to prevent a recursive export. No files were copied." -ForegroundColor Yellow
        return $null
    }

    Write-KeyValue "Destination" $selectedPath
    return $selectedPath
}

# ============================================================================
# FOLDER OPERATIONS
# ============================================================================

function Test-FolderInventoryAbortRequested {
    if ($Script:SkipAdditionalAppDataSizing) { return $true }
    if (-not $Script:AdditionalAppDataSizingInProgress) { return $false }
    try {
        if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::S) {
            $Script:SkipAdditionalAppDataSizing = $true
            Write-Host "`r$(' ' * 120)`r  Additional AppData sizing skipped." -ForegroundColor Yellow
            return $true
        }
    }
    catch { }
    return $false
}

function Get-FolderInventory {
    # Enumerate folders while excluding reparse points to avoid traversing
    # junctions into unrelated data.  The inventory is used for size prompts,
    # not as the authoritative copy operation.
    param([string]$Path)

    if (-not $Script:FolderInventoryCache) { $Script:FolderInventoryCache = @{} }
    try { $key = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92) }
    catch { $key = $Path }
    if ($Script:FolderInventoryCache.ContainsKey($key)) { return $Script:FolderInventoryCache[$key] }
    if ($Script:SkipAdditionalAppDataSizing) {
        return [PSCustomObject]@{ FileCount = 0; Bytes = [long]0; Skipped = $true }
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $inventory = [PSCustomObject]@{ FileCount = 0; Bytes = [long]0 }
        $Script:FolderInventoryCache[$key] = $inventory
        return $inventory
    }

    # Cache one recursive walk for the settings screen, Online policy checks,
    # and copy setup. This avoids repeatedly walking the same browser/profile
    # tree before robocopy starts.
    $files = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (Test-FolderInventoryAbortRequested) { break }
        if (-not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { [void]$files.Add($_) }
    }
    if ($Script:SkipAdditionalAppDataSizing) {
        return [PSCustomObject]@{ FileCount = 0; Bytes = [long]0; Skipped = $true }
    }
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    $inventory = [PSCustomObject]@{ FileCount = $files.Count; Bytes = [long]$(if ($null -eq $sum) { 0 } else { $sum }) }
    $Script:FolderInventoryCache[$key] = $inventory
    return $inventory
}

function Get-FolderSizeBytes {
    # Sum file lengths defensively.  Files can disappear during enumeration,
    # therefore inaccessible items are skipped and the estimate is advisory.
    param([string]$Path)
    return (Get-FolderInventory -Path $Path).Bytes
}

function Get-TransferPayloadEstimate {
    $sizes = @{}
    foreach ($key in @("UserData","Downloads","EntireUserProfile","AdditionalAppData","AppData","LotusNotes","SystemSettings","InstalledPrograms","Printers","Chrome","Firefox","Edge","OneDrive")) {
        $sizes[$key] = [long]0
    }

    if ($Script:Config.Backup.UserData) {
        foreach ($folder in $Script:Config.UserFolders) {
            if ($folder -ne 'Downloads') { $sizes.UserData += Get-FolderSizeBytes (Resolve-ExportUserFolderPath $folder) }
        }
    }
    if ($Script:Config.Backup.Downloads) { $sizes.Downloads = Get-FolderSizeBytes (Resolve-ExportUserFolderPath 'Downloads') }

    if ($Script:Config.Backup.EntireUserProfile) {
        # The full-profile stage excludes standard user folders and AppData,
        # both of which are handled by their dedicated export stages.
        $sizes.EntireUserProfile = Get-FolderSizeBytes $Script:OriginalUserProfile
        foreach ($folder in $Script:Config.UserFolders) {
            $sizes.EntireUserProfile -= Get-FolderSizeBytes (Resolve-ExportUserFolderPath $folder)
        }
        $sizes.EntireUserProfile -= Get-FolderSizeBytes (Join-Path $Script:OriginalUserProfile 'AppData')
        if ($sizes.EntireUserProfile -lt 0) { $sizes.EntireUserProfile = 0 }
    }

    if (-not $Script:Config.Backup.EntireUserProfile) {
        $excludeFolders = @(
            'AppData', 'Application Data', 'Local Settings', 'NetHood', 'PrintHood',
            'Recent', 'SendTo', 'Start Menu', 'Templates', 'Cookies', 'Links',
            'Saved Games', 'Searches', 'Contacts', '3D Objects',
            'OneDrive', 'OneDrive - STO Building Group', 'STO Building Group',
            'Dropbox', 'Google Drive', 'iCloudDrive', 'Box', 'Box Sync'
        ) + $Script:Config.UserFolders
        $includeAdditional = $Script:Config.TransferMode -ne 'Online' -or $Script:Config.Online.IncludeAdditionalUserFolders
        if ($includeAdditional) {
            foreach ($folder in @(Get-ChildItem -LiteralPath $Script:OriginalUserProfile -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -notin $excludeFolders -and
                -not $_.Name.StartsWith('.') -and
                -not $_.Name.StartsWith('OneDrive') -and
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            })) {
                $sizes.UserData += Get-FolderSizeBytes $folder.FullName
            }
        }
        $looseFiles = @(Get-ChildItem -LiteralPath $Script:OriginalUserProfile -File -Force -ErrorAction SilentlyContinue | Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) -and
            $_.Extension -notin @('.ini', '.dat', '.log')
        })
        $sizes.UserData += [long]$(if ($looseFiles.Count) { ($looseFiles | Measure-Object -Property Length -Sum).Sum } else { 0 })
    }

    $ocsPath = 'C:\OCS Documents'
    if ((Test-Path -LiteralPath $ocsPath) -and ($Script:Config.TransferMode -ne 'Online' -or $Script:Config.Online.IncludeOcsDocuments)) {
        $sizes.UserData += Get-FolderSizeBytes $ocsPath
    }

    if ($Script:Config.Backup.AdditionalAppData) {
        foreach ($item in @($Script:SelectedAdditionalAppData)) {
            if ($null -ne $item -and $null -ne $item.SizeBytes) { $sizes.AdditionalAppData += [long]$item.SizeBytes }
        }
    }

    if ($Script:Config.Backup.AppData) {
        foreach ($path in $Script:Config.BluebeamPaths) {
            $candidate = Join-Path $Script:OriginalAppDataRoaming $path
            if (Test-Path -LiteralPath $candidate) { $sizes.AppData += Get-FolderSizeBytes $candidate; break }
        }
        foreach ($path in $Script:Config.AppDataRoaming.Values) {
            $sizes.AppData += Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataRoaming $path)
        }
    }

    if ($Script:Config.Backup.LotusNotes -and $Script:Config.Backup.AppData -and
        -not ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.SkipLotusNotes)) {
        $sizes.LotusNotes = Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Lotus")
    }
    if ($Script:Config.Backup.Chrome -eq 'FullProfile') { $sizes.Chrome = Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data") }
    if ($Script:Config.Backup.Firefox) {
        $sizes.Firefox = (Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataRoaming "Mozilla\Firefox")) +
                          (Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Mozilla\Firefox"))
    }
    if ($Script:Config.Backup.Edge) {
        $edgeRoot = Join-Path $Script:OriginalAppDataLocal "Microsoft\Edge\User Data"
        $sizes.Edge = [long]((Get-ChildItem -LiteralPath $edgeRoot -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
    }

    [PSCustomObject]@{
        ItemBytes = $sizes
        TotalBytes = [long](($sizes.Values | Measure-Object -Sum).Sum)
    }
}

function Update-AdvancedPayloadEstimate {
    # Recalculate all display rows from the completed inventory cache. This is
    # still a zero-I/O refresh, but it prevents toggles such as Chrome
    # FullProfile or Downloads from leaving the final estimate stale.
    if ($null -eq $Script:StartupPayloadEstimate) { return }
    $estimate = Get-TransferSizeDisplayEstimate
    $Script:StartupPayloadEstimate = $estimate
    $Script:TransferSizeDisplayEstimate = $estimate
}

function Get-DestinationFreeSpaceBytes {
    param([string]$Path)

    # PSDrive exposes capacity for local, mapped, and most UNC destinations.
    # It is intentionally best-effort because some cloud providers do not report it.
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSDrive -and $null -ne $item.PSDrive.Free) {
        return [long]$item.PSDrive.Free
    }

    $root = [System.IO.Path]::GetPathRoot($item.FullName)
    if ($root) {
        return [long]([System.IO.DriveInfo]::new($root).AvailableFreeSpace)
    }

    return $null
}

function Test-NetworkDestination {
    param([string]$Path)

    # UNC paths are always network destinations. For mapped drives, consult
    # the logical-drive type instead of assuming every drive letter is local.
    if ($Path -like "\\*") { return $true }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSDrive -and $item.PSDrive.Root -like "\\*") { return $true }

        if ($item.PSDrive -and $item.PSDrive.Name -match "^[A-Za-z]$") {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($item.PSDrive.Name):'" -ErrorAction Stop
            return $disk.DriveType -eq 4
        }
    }
    catch { }

    return $false
}

function Test-ArchiveAbortRequested {
    try {
        if ([Console]::KeyAvailable) {
            return ([Console]::ReadKey($true).Key -eq [ConsoleKey]::S)
        }
    }
    catch { }
    return $false
}

function Write-ArchiveProgress {
    param([string]$Label, [long]$Completed, [long]$Total, [datetime]$StartedAt)

    $percent = if ($Total -gt 0) { [math]::Min(100, [math]::Round(($Completed / $Total) * 100)) } else { 0 }
    $width = 34
    $filled = [math]::Round(($percent / 100) * $width)
    $bar = ([string]$Script:Theme.Bar.Full * $filled) + ([string]$Script:Theme.Bar.Light * ($width - $filled))
    $elapsed = (Get-Date) - $StartedAt
    $speed = if ($elapsed.TotalSeconds -gt 0) { $Completed / $elapsed.TotalSeconds } else { 0 }
    $remaining = [math]::Max([long]0, [long]($Total - $Completed))
    $eta = if ($speed -gt 0) { Format-RemainingTime ($remaining / $speed) } else { "calculating..." }
    Write-Host "`r    $Label  $bar $($percent.ToString().PadLeft(3))%  $(Format-FileSize $Completed) / $(Format-FileSize $Total)  $(Format-FileSize $speed)/s  ETA $eta   " -NoNewline
}

function Clear-ArchiveProgress {
    Write-Host "`r$(' ' * 160)`r" -NoNewline
}

function Publish-TransferArchive {
    # Compress the completed transfer folder into a sibling ZIP and report
    # progress.  The original folder remains available until the ZIP succeeds.
    param(
        [string]$ArchivePath,
        [string]$DestinationFolder,
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        Write-Log "Cannot upload ZIP archive because it was not created: $ArchivePath" -Level Error
        return $null
    }

    $archiveName = Split-Path -Path $ArchivePath -Leaf
    $destinationArchive = Join-Path $DestinationFolder $archiveName
    if (Test-Path -LiteralPath $destinationArchive) {
        Write-Log "Network ZIP upload skipped because the target already exists: $destinationArchive" -Level Warning
        Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Warning" -Details "Target already exists: $destinationArchive"
        return $null
    }

    try {
        $sourceFolder = Split-Path -Path $ArchivePath -Parent
        $arguments = "`"$sourceFolder`" `"$DestinationFolder`" `"$archiveName`" /Z /J /R:2 /W:3 /NP /NDL /NFL /NJH /NJS /LOG:`"$LogPath`""
        Write-Host "`n  Uploading ZIP archive to network destination..." -ForegroundColor Cyan
        Write-Log "Uploading ZIP archive to network destination: $destinationArchive" -Level Info
        $sourceSize = [long](Get-Item -LiteralPath $ArchivePath -ErrorAction Stop).Length
        Write-Host "    $(Format-FileSize $sourceSize). Press S to cancel the ZIP upload." -ForegroundColor DarkGray
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "robocopy.exe"
        $pinfo.Arguments = $arguments
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        if (-not $process.Start()) { throw "Could not start ZIP upload." }

        $uploadStartedAt = Get-Date
        $aborted = $false
        while (-not $process.HasExited) {
            Start-Sleep -Milliseconds 500
            $uploadedBytes = if (Test-Path -LiteralPath $destinationArchive -PathType Leaf) {
                [long](Get-Item -LiteralPath $destinationArchive -ErrorAction SilentlyContinue).Length
            }
            else { [long]0 }
            Write-ArchiveProgress -Label "UPLOAD" -Completed $uploadedBytes -Total $sourceSize -StartedAt $uploadStartedAt
            if (Test-ArchiveAbortRequested) {
                $aborted = $true
                $process.Kill()
                $process.WaitForExit()
                break
            }
        }
        if (-not $aborted) {
            Write-ArchiveProgress -Label "UPLOAD" -Completed $sourceSize -Total $sourceSize -StartedAt $uploadStartedAt
        }
        Clear-ArchiveProgress
        if ($aborted) {
            Remove-Item -LiteralPath $destinationArchive -Force -ErrorAction SilentlyContinue
            Write-Host "    $($Script:Theme.Glyphs.WARN) ZIP upload cancelled; incomplete upload removed." -ForegroundColor Yellow
            Write-Log "ZIP archive upload cancelled by operator; incomplete destination file removed" -Level Warning
            Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Skipped" -Details "Cancelled by operator; incomplete upload removed"
            return $null
        }

        $destinationSize = if (Test-Path -LiteralPath $destinationArchive -PathType Leaf) {
            (Get-Item -LiteralPath $destinationArchive -ErrorAction Stop).Length
        }
        else { -1 }

        if ($process.ExitCode -lt 8 -and $sourceSize -eq $destinationSize) {
            Write-Log "ZIP archive uploaded and size verified: $destinationArchive" -Level Success
            Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Success" -Details "Uploaded and size verified: $archiveName"
            return $destinationArchive
        }

        throw "Robocopy exit code $($process.ExitCode); source size $sourceSize, destination size $destinationSize"
    }
    catch {
        Write-Log "Could not upload ZIP archive to network destination: $_" -Level Error
        Add-Result -Category "Package" -Item "Network ZIP Upload" -Status "Error" -Details $_.Exception.Message
        return $null
    }
}

function New-TransferArchive {
    # Select the archive implementation and destination naming convention for
    # the current transfer mode, then return the created archive path.
    param([string]$TransferBase)

    $parentFolder = Split-Path -Path $TransferBase -Parent
    $archiveName = "$(Split-Path -Path $TransferBase -Leaf).zip"
    $archivePath = Join-Path $parentFolder $archiveName

    if (Test-Path -LiteralPath $archivePath) {
        Write-Log "ZIP archive already exists: $archivePath" -Level Warning
        Write-Host "A ZIP archive already exists: $archivePath" -ForegroundColor Yellow
        return $null
    }

    try {
        Write-Host "`n  Creating ZIP archive..." -ForegroundColor Cyan
        $allFiles = @(Get-ChildItem -LiteralPath $TransferBase -Recurse -File -Force -ErrorAction Stop)
        $sensitivePasswordFiles = @($allFiles | Where-Object {
            $relativePath = $_.FullName.Substring($TransferBase.Length).TrimStart([char]92)
            $relativePath -match '^BrowserData[\\/]+Chrome[\\/]+PasswordExport[\\/]+.+\.csv$'
        })
        $files = @($allFiles | Where-Object {
            $relativePath = $_.FullName.Substring($TransferBase.Length).TrimStart([char]92)
            $relativePath -notmatch '^BrowserData[\\/]+Chrome[\\/]+PasswordExport[\\/]+.+\.csv$'
        })
        if ($sensitivePasswordFiles.Count -gt 0) {
            Write-Log "Excluded $($sensitivePasswordFiles.Count) plaintext Chrome password CSV file(s) from ZIP archive" -Level Warning
            Add-ManualTask -Task "Transfer Chrome passwords securely" -Reason "Plaintext Chrome password CSV files are intentionally excluded from the ZIP archive" -Instructions "Use Chrome's native password import workflow from the uncompressed transfer folder or securely transfer the CSV separately, then delete it after verification."
        }
        $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
        $startedAt = Get-Date
        $completedBytes = [long]0
        $lastProgressAt = [datetime]::MinValue
        $aborted = $false
        Write-Host "    $($files.Count) files / $(Format-FileSize $totalBytes). Press S to cancel ZIP creation." -ForegroundColor DarkGray
        # ZipArchive/ZipArchiveMode live in System.IO.Compression, while the
        # ZipFile helper lives in System.IO.Compression.FileSystem. Windows
        # PowerShell does not always load the former when the latter is loaded.
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
        $buffer = New-Object byte[] 1048576
        try {
            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($TransferBase.Length).TrimStart([char]92)
                # Most transfer payloads (Office/PDF/media) are already
                # compressed. Fastest avoids spending minutes CPU-compressing
                # them again, while still packaging thousands of small files
                # into one network-friendly transfer.
                $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Fastest)
                $input = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $output = $entry.Open()
                try {
                    while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $output.Write($buffer, 0, $read)
                        $completedBytes += $read
                        if ((Get-Date) - $lastProgressAt -gt [TimeSpan]::FromMilliseconds(250)) {
                            Write-ArchiveProgress -Label "ZIP" -Completed $completedBytes -Total $totalBytes -StartedAt $startedAt
                            $lastProgressAt = Get-Date
                        }
                        if (Test-ArchiveAbortRequested) {
                            $aborted = $true
                            break
                        }
                    }
                }
                finally {
                    $output.Dispose()
                    $input.Dispose()
                }
                if ($aborted) { break }
            }
        }
        finally {
            $archive.Dispose()
        }

        if (-not $aborted) {
            Write-ArchiveProgress -Label "ZIP" -Completed $totalBytes -Total $totalBytes -StartedAt $startedAt
        }
        Clear-ArchiveProgress
        if ($aborted) {
            Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
            Write-Host "    $($Script:Theme.Glyphs.WARN) ZIP creation cancelled. The transfer folder was kept." -ForegroundColor Yellow
            Write-Log "ZIP creation cancelled by operator; transfer folder retained at $TransferBase" -Level Warning
            Add-Result -Category "Package" -Item $archiveName -Status "Skipped" -Details "ZIP creation cancelled by operator; transfer folder retained"
            return $null
        }

        Write-Log "ZIP archive created: $archivePath" -Level Success
        Add-Result -Category "Package" -Item $archiveName -Status "Success" -Details "Compressed transfer package"
        return $archivePath
    }
    catch {
        Write-Log "Could not create ZIP archive: $_" -Level Error
        Add-Result -Category "Package" -Item $archiveName -Status "Error" -Details "ZIP creation failed: $_"
        Write-Host "ZIP creation failed: $_" -ForegroundColor Red
        return $null
    }
}

function Resolve-TransferMode {
    # Prompt for transfer mode unless one was passed on the command line.
    if ($Script:Config.TransferMode -in @("Local", "Online") -and $TransferMode) {
        return  # already set from param
    }
    Write-Section "Transfer mode"
    Write-Host "  [1] Local  " -ForegroundColor Cyan -NoNewline
    Write-Host "- full copy (USB / on-site)" -ForegroundColor DarkGray
    Write-Host "  [2] Online " -ForegroundColor Cyan -NoNewline
    Write-Host "- Online Downloads default on; folders above $($Script:Config.Online.DownloadsCapGB)GB require confirmation" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $m = Read-UserInput "  Select transfer mode (1-2)"
        if ($m -eq "1") { $Script:Config.TransferMode = "Local"; break }
        if ($m -eq "2") { $Script:Config.TransferMode = "Online"; break }
        Write-Host "  Invalid selection." -ForegroundColor Red
    } while ($true)
}

# User-data copying is intentionally separate from AppData copying.  These
# stages use the source profile resolved by 03-core.ps1, preserve relative
# paths below UserData, and report each folder independently so one locked file
# does not hide the outcome of the other folders.

function Copy-UserFolders {
    # Apply online size gates before invoking robocopy, then record the result of
    # each folder.  Downloads has a distinct cap because it is commonly large
    # and is often less important to restore than profile settings.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Starting user folder copy..." -Level Info
    
    $userProfile = $Script:OriginalUserProfile
    $destUserData = Join-Path $DestinationBase "UserData"
    
    # Create logs directory
    $logsDir = Join-Path $DestinationBase "Logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    
    foreach ($folder in $Script:Config.UserFolders) {
        if ($folder -ne 'Downloads' -and -not $Script:Config.Backup.UserData) { continue }
        if ($folder -eq 'Downloads' -and -not $Script:Config.Backup.Downloads) {
            Add-DisabledBackupResult -Item 'Downloads' -Category 'User Folders'
            continue
        }
        $sourcePath = Resolve-ExportUserFolderPath $folder
        $destPath = Join-Path $destUserData $folder
        
        if (Test-Path $sourcePath) {
            # Check if folder has content (excluding junctions)
            $items = Get-ChildItem $sourcePath -Force -ErrorAction SilentlyContinue | 
                Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) }
            
            if ($items) {
                # ---- Online mode: size gating ----
                if ($Script:Config.TransferMode -eq "Online") {
                    $folderBytes = Get-FolderSizeBytes $sourcePath
                    $folderGB = [math]::Round($folderBytes / 1GB, 2)

                    if ($folder -eq 'Downloads' -and $folderGB -gt $Script:Config.Online.DownloadsCapGB -and -not $Script:Config.Online.OverrideDownloadsCap) {
                        if ($NonInteractive) {
                            Add-Result -Category 'User Folders' -Item 'Downloads' -Status 'Skipped' -Details "Non-interactive mode: $folderGB GB exceeds the Online Downloads cap"
                            Add-ManualTask -Task 'Review skipped Downloads folder' -Reason 'Non-interactive mode does not approve an over-cap Online Downloads transfer' -Instructions 'Run interactively to approve the transfer or enable the Downloads cap override.'
                            continue
                        }
                        $answer = Read-UserInput "  Downloads is $folderGB GB (Online cap: $($Script:Config.Online.DownloadsCapGB) GB). Copy it? (Y/N)"
                        if ($answer -notmatch '^[Yy]') {
                            Add-Result -Category 'User Folders' -Item 'Downloads' -Status 'Skipped' -Details "Online cap: $folderGB GB; operator chose skip"
                            Add-ManualTask -Task 'Copy Downloads folder manually (if needed)' -Reason 'Skipped above the Online Downloads cap' -Instructions "Copy C:\Users\$($Script:OriginalUserName)\Downloads separately if needed."
                            continue
                        }
                        Write-Log "Downloads above Online cap approved by operator: $folderGB GB" -Level Warning
                    }
                    elseif ($folder -eq 'Downloads' -and $folderGB -gt $Script:Config.Online.DownloadsCapGB) {
                        Write-Log "Downloads cap override enabled: copying $folderGB GB" -Level Warning
                        Write-Status 'Downloads' 'WARN' "$folderGB GB exceeds Online cap; override enabled"
                    }

                    # Any other large folder: ask the tech (skip / copy anyway).
                    if ($folderGB -gt $Script:Config.Online.LargeFolderPromptGB) {
                        if ($NonInteractive) {
                            Write-Log "$folder skipped in non-interactive Online mode because it exceeds the prompt threshold" -Level Warning
                            Write-Status $folder "SKIP" "$folderGB GB, non-interactive mode"
                            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Omitted in non-interactive mode: $folderGB GB exceeds the Online prompt threshold"
                            Add-ManualTask -Task "Review skipped $folder folder" -Reason "Non-interactive Online export cannot approve a large-folder prompt" -Instructions "Run interactively to approve the transfer if this folder is required."
                            continue
                        }
                        Write-Host ""
                        Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
                        Write-Host "$folder is $folderGB GB (over the $($Script:Config.Online.LargeFolderPromptGB) GB online threshold)." -ForegroundColor White
                        $ans = Read-UserInput "    Copy it anyway? (Y = copy / N = skip)"
                        if ($ans -notmatch "^[Yy]") {
                            Write-Log "$folder ($folderGB GB) skipped by operator (online mode)" -Level Warning
                            Write-Status $folder "SKIP" "$folderGB GB, skipped by operator"
                            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Omitted (online mode): $folderGB GB, operator chose skip"
                            Add-ManualTask -Task "Copy $folder folder manually (if needed)" -Reason "Skipped in online transfer: $folderGB GB" -Instructions "Copy C:\Users\$($Script:OriginalUserName)\$folder separately if the user needs it."
                            continue
                        }
                    }
                }

                $robocopyLog = Join-Path $logsDir "robocopy_$folder.log"
                
                # Use progress copy function
                $result = Copy-WithProgress -Source $sourcePath `
                                           -Destination $destPath `
                                           -FolderName $folder `
                                           -LogPath $robocopyLog `
                                           -RobocopyArgs $Script:Config.RobocopyArgs
                
                # Log result
                if ($result.Status -eq "Success") {
                    Write-Log "$folder completed: $($result.FilesCopied) files, $(Format-FileSize $result.BytesCopied)" -Level Success
                    Add-Result -Category "User Folders" -Item $folder -Status "Success" -Details "$($result.FilesCopied) files copied"
                }
                elseif ($result.Aborted) {
                    Write-Log "$folder copy stopped by operator" -Level Warning
                    Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Stopped by operator; partial files may remain and can be resumed by rerunning the export"
                }
                elseif ($result.Status -eq "Skipped") {
                    Write-Log "$folder has no copyable files (junctions only)" -Level Info
                    Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "No files to copy"
                }
                else {
                    Write-Log "$folder completed with warnings (exit: $($result.ExitCode))" -Level Warning
                    Add-Result -Category "User Folders" -Item $folder -Status "Warning" -Details "Check log for details"
                    [void]$Script:Results.Warnings.Add("${folder}: Robocopy exit code $($result.ExitCode)")
                }
                
                Write-Host ""
            }
            else {
                Write-Log "$folder is empty or contains only junctions, skipping" -Level Info
                Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Folder empty"
            }
        }
        else {
            Write-Log "$folder not found, skipping" -Level Info
            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "Folder not found"
        }
    }
    
    # Check for additional folders in user profile (excluding known system folders and cloud sync folders)
    Write-Log "Checking for additional user folders..." -Level Info
    
    # Explicit folders to exclude
    $excludeFolders = @(
        # System folders
        "AppData", "Application Data", "Local Settings", "NetHood", "PrintHood",
        "Recent", "SendTo", "Start Menu", "Templates", "Cookies", "Links",
        "Saved Games", "Searches", "Contacts", "3D Objects",
        # Cloud sync folders
        "OneDrive", "OneDrive - STO Building Group", "STO Building Group",
        "Dropbox", "Google Drive", "iCloudDrive", "Box", "Box Sync"
    ) + $Script:Config.UserFolders
    
    $additionalFolders = if ($Script:Config.Backup.EntireUserProfile) { @() } else { Get-ChildItem $userProfile -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { 
            $folderName = $_.Name
            # Exclude if in explicit list
            $folderName -notin $excludeFolders -and 
            # Exclude hidden folders
            -not $folderName.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            # Exclude any folder starting with "OneDrive"
            -not $folderName.StartsWith("OneDrive")
        } }
    
    foreach ($folder in $additionalFolders) {
        $items = Get-ChildItem $folder.FullName -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) }
        if ($items) {
            if ($Script:Config.TransferMode -eq 'Online' -and -not $Script:Config.Online.IncludeAdditionalUserFolders) {
                Write-Log "Additional folder $($folder.Name) omitted by Online policy" -Level Info
                Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Skipped" -Details "Omitted by Online policy; enable Advanced Online Controls to include it"
                Add-ManualTask -Task "Review additional folder $($folder.Name)" -Reason "Not included in the lean Online package" -Instructions "Copy C:\Users\$($Script:OriginalUserName)\$($folder.Name) separately if the user needs it."
                continue
            }
            if ($Script:Config.TransferMode -eq 'Online') {
                $folderBytes = Get-FolderSizeBytes -Path $folder.FullName
                $folderGB = [math]::Round($folderBytes / 1GB, 2)
                if ($folderGB -gt $Script:Config.Online.AdditionalFolderCapGB) {
                    if ($NonInteractive) {
                        Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Skipped" -Details "Non-interactive mode: $folderGB GB exceeds the Online additional-folder cap"
                        Add-ManualTask -Task "Review skipped additional folder $($folder.Name)" -Reason "Non-interactive mode does not approve an over-cap additional-folder transfer" -Instructions "Run interactively to approve the transfer if this folder is required."
                        continue
                    }
                    $answer = Read-UserInput "  Additional folder '$($folder.Name)' is $folderGB GB (cap: $($Script:Config.Online.AdditionalFolderCapGB) GB). Copy it? (Y/N)"
                    if ($answer -notmatch '^[Yy]') {
                        Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Skipped" -Details "Online size cap: $folderGB GB; operator chose skip"
                        Add-ManualTask -Task "Copy additional folder $($folder.Name) manually" -Reason "Skipped above the Online additional-folder cap" -Instructions "Copy C:\Users\$($Script:OriginalUserName)\$($folder.Name) separately if needed."
                        continue
                    }
                }
            }
            $destPath = Join-Path $destUserData "Additional\$($folder.Name)"
            $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_additional_$($folder.Name).log"
            
            $result = Copy-WithProgress -Source $folder.FullName `
                                       -Destination $destPath `
                                       -FolderName "Additional: $($folder.Name)" `
                                       -LogPath $robocopyLog `
                                       -RobocopyArgs $Script:Config.RobocopyArgs
            
            if ($result.Status -eq "Success") {
                Write-Log "Additional folder $($folder.Name) copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Success" -Details "$($result.FilesCopied) files"
            }
            elseif ($result.Aborted) {
                Write-Log "Additional folder $($folder.Name) copy stopped by operator" -Level Warning
                Add-Result -Category "Additional Folders" -Item $folder.Name -Status "Skipped" -Details "Stopped by operator; partial files may remain"
            }
            Write-Host ""
        }
    }
    
    if ($Script:Config.Backup.EntireUserProfile) {
        Write-Log "Copying remaining user-profile folders (standard folders and AppData are excluded)..." -Level Info
        $profileDestination = Join-Path $destUserData 'FullProfile'
        $profileExclusions = @(
            'AppData', 'Application Data', 'Local Settings', 'NetHood', 'PrintHood',
            'Recent', 'SendTo', 'Start Menu', 'Templates', 'Cookies', 'Links',
            'Saved Games', 'Searches', 'Contacts', '3D Objects',
            'OneDrive', 'OneDrive - STO Building Group', 'STO Building Group',
            'Dropbox', 'Google Drive', 'iCloudDrive', 'Box', 'Box Sync'
        ) + $Script:Config.UserFolders
        $remainingFolders = @(Get-ChildItem -LiteralPath $userProfile -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notin $profileExclusions -and
                -not $_.Name.StartsWith('.') -and
                -not $_.Name.StartsWith('OneDrive') -and
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
                -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)
            })

        foreach ($folder in $remainingFolders) {
            $result = Copy-WithProgress -Source $folder.FullName `
                                       -Destination (Join-Path $profileDestination $folder.Name) `
                                       -FolderName "Profile: $($folder.Name)" `
                                       -LogPath (Join-Path $logsDir "robocopy_profile_$($folder.Name).log") `
                                       -RobocopyArgs $Script:Config.RobocopyArgs
            Add-Result -Category 'Entire User Profile' -Item $folder.Name -Status $result.Status -Details "$($result.FilesCopied) files"
        }

        # Keep ordinary root files with the full-profile payload. Hidden and
        # system files remain excluded, matching the existing loose-file policy.
        $profileFiles = @(Get-ChildItem -LiteralPath $userProfile -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('.') -and -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) })
        if ($profileFiles.Count) {
            New-Item -ItemType Directory -Path $profileDestination -Force | Out-Null
            foreach ($file in $profileFiles) {
                try { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $profileDestination $file.Name) -Force -ErrorAction Stop }
                catch { Write-Log "Could not copy profile-root file '$($file.Name)': $($_.Exception.Message)" -Level Warning }
            }
            Add-Result -Category 'Entire User Profile' -Item 'Profile root files' -Status 'Success' -Details "$($profileFiles.Count) file(s)"
        }
    }

    # Check for loose files directly in user profile root (not in any subfolder)
    Write-Log "Checking for loose files in user profile root..." -Level Info
    
    $looseFiles = if ($Script:Config.Backup.EntireUserProfile) { @() } else { Get-ChildItem $userProfile -File -Force -ErrorAction SilentlyContinue |
        Where-Object { 
            -not $_.Name.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) -and
            $_.Extension -notin @(".ini", ".dat", ".log") # Skip system files
        } }
    
    if ($looseFiles -and $looseFiles.Count -gt 0) {
        Write-Log "Found $($looseFiles.Count) loose file(s) in profile root" -Level Info
        
        $destLooseFiles = Join-Path $destUserData "ProfileRoot"
        if (-not (Test-Path $destLooseFiles)) {
            New-Item -ItemType Directory -Path $destLooseFiles -Force | Out-Null
        }
        
        $copiedCount = 0
        $failedCount = 0
        
        foreach ($file in $looseFiles) {
            try {
                $destFile = Join-Path $destLooseFiles $file.Name
                Copy-Item $file.FullName -Destination $destFile -Force -ErrorAction Stop
                $copiedCount++
                Write-Log "  Copied: $($file.Name)" -Level Info
            }
            catch {
                $failedCount++
                Write-Log "  Failed: $($file.Name) - $_" -Level Warning
            }
        }
        
        if ($copiedCount -gt 0) {
            Write-Log "Loose files copied: $copiedCount file(s)" -Level Success
            Add-Result -Category "Loose Files" -Item "Profile Root Files" -Status "Success" -Details "$copiedCount file(s) from user profile root"
        }
        if ($failedCount -gt 0) {
            Add-Result -Category "Loose Files" -Item "Profile Root Files (partial)" -Status "Warning" -Details "$failedCount file(s) could not be copied"
        }
    }
    else {
        Write-Log "No loose files found in profile root" -Level Info
    }
    
    # Check for OCS Documents folder on C: drive
    Write-Log "Checking for OCS Documents on C: drive..." -Level Info
    
    $ocsPath = "C:\OCS Documents"
    if (Test-Path $ocsPath) {
        Write-Log "Found OCS Documents folder" -Level Info
        if ($Script:Config.TransferMode -eq 'Online' -and -not $Script:Config.Online.IncludeOcsDocuments) {
            Write-Log "OCS Documents omitted by Online policy" -Level Info
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Skipped" -Details "Omitted by Online policy; enable Advanced Online Controls to include it"
            Add-ManualTask -Task "Review OCS Documents" -Reason "Not included in the lean Online package" -Instructions "Copy C:\OCS Documents separately if the user needs it."
            return
        }
        if ($Script:Config.TransferMode -eq 'Online') {
            $ocsBytes = Get-FolderSizeBytes -Path $ocsPath
            $ocsGB = [math]::Round($ocsBytes / 1GB, 2)
            if ($ocsGB -gt $Script:Config.Online.AdditionalFolderCapGB) {
                if ($NonInteractive) {
                    Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Skipped" -Details "Non-interactive mode: $ocsGB GB exceeds the Online additional-folder cap"
                    Add-ManualTask -Task "Review skipped OCS Documents" -Reason "Non-interactive mode does not approve an over-cap OCS Documents transfer" -Instructions "Run interactively to approve the transfer if this folder is required."
                    return
                }
                $answer = Read-UserInput "  OCS Documents is $ocsGB GB (cap: $($Script:Config.Online.AdditionalFolderCapGB) GB). Copy it? (Y/N)"
                if ($answer -notmatch '^[Yy]') {
                    Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Skipped" -Details "Online size cap: $ocsGB GB; operator chose skip"
                    Add-ManualTask -Task "Copy OCS Documents manually" -Reason "Skipped above the Online additional-folder cap" -Instructions "Copy C:\OCS Documents separately if needed."
                    return
                }
            }
        }
        
        $destOcs = Join-Path $destUserData "OCS Documents"
        $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_ocs_documents.log"
        
        $result = Copy-WithProgress -Source $ocsPath `
                                   -Destination $destOcs `
                                   -FolderName "OCS Documents (C:\)" `
                                   -LogPath $robocopyLog `
                                   -RobocopyArgs $Script:Config.RobocopyArgs
        
        if ($result.Status -eq "Success") {
            Write-Log "OCS Documents copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Success" -Details "$($result.FilesCopied) files from C:\OCS Documents"
        }
        elseif ($result.Aborted) {
            Write-Log "OCS Documents copy stopped by operator" -Level Warning
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
        }
        else {
            Write-Log "OCS Documents copy had issues" -Level Warning
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Warning" -Details "Check log for details"
        }
        Write-Host ""
    }
    else {
        Write-Log "OCS Documents folder not found on C: drive" -Level Info
    }
}

function Copy-AppData {
    # Copy only known application payloads and the optional candidate inventory.
    # AppData is handled by explicit mappings so caches and machine-specific
    # state are not blindly moved into the replacement profile.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Copying AppData items..." -Level Info
    
    $roamingPath = $Script:OriginalAppDataRoaming
    $destAppData = Join-Path $DestinationBase "AppData"
    
    # ========== BLUEBEAM (check multiple possible locations) ==========
    Write-Log "Checking for Bluebeam..." -Level Info
    $bluebeamFound = $false
    
    foreach ($bluebeamFolder in $Script:Config.BluebeamPaths) {
        $bluebeamSource = Join-Path $roamingPath $bluebeamFolder
        
        if (Test-Path $bluebeamSource) {
            Write-Log "Found Bluebeam at: $bluebeamSource" -Level Info
            $bluebeamFound = $true
            
            $destPath = Join-Path $destAppData "Bluebeam"
            $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_bluebeam.log"
            
            $result = Copy-WithProgress -Source $bluebeamSource `
                                       -Destination $destPath `
                                       -FolderName "Bluebeam ($bluebeamFolder)" `
                                       -LogPath $robocopyLog `
                                       -RobocopyArgs $Script:Config.RobocopyArgs
            
            if ($result.Status -eq "Success") {
                Write-Log "Bluebeam copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Success" -Details "$($result.FilesCopied) files from $bluebeamFolder"
            }
            elseif ($result.Aborted) {
                Write-Log "Bluebeam copy stopped by operator" -Level Warning
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
            }
            else {
                Write-Log "Bluebeam copy had issues" -Level Warning
                Add-Result -Category "AppData" -Item "Bluebeam" -Status "Warning" -Details "Check log"
            }
            Write-Host ""
            break  # Found and copied, no need to check other paths
        }
    }
    
    if (-not $bluebeamFound) {
        Write-Log "Bluebeam not found in AppData\Roaming" -Level Info
        Add-Result -Category "AppData" -Item "Bluebeam" -Status "Skipped" -Details "Not installed"
    }
    
    # ========== OTHER ROAMING APPDATA ITEMS ==========
    foreach ($item in $Script:Config.AppDataRoaming.GetEnumerator()) {
        $sourcePath = Join-Path $roamingPath $item.Value
        $destPath = Join-Path $destAppData $item.Key
        
        if (Test-Path $sourcePath) {
            Write-Log "Copying $($item.Key)..." -Level Info
            
            try {
                if (-not (Test-Path $destPath)) {
                    New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                }
                
                # For QuickAccess - simply copy the database file (safest method)
                # DO NOT use Shell COM to enumerate - it can modify Quick Access!
                if ($item.Key -eq "QuickAccess") {
                    Write-Log "Backing up Quick Access database..." -Level Info
                    
                    if (-not (Test-Path $destPath)) {
                        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                    }
                    
                    # The correct file for Quick Access pins is f01b4d95cf55d32a.automaticDestinations-ms
                    $qaFile = Join-Path $sourcePath "f01b4d95cf55d32a.automaticDestinations-ms"
                    
                    if (Test-Path $qaFile) {
                        try {
                            # Simply copy the file - this preserves ALL Quick Access items
                            Copy-Item $qaFile -Destination $destPath -Force -ErrorAction Stop
                            
                            $fileSize = (Get-Item $qaFile).Length
                            Write-Log "Quick Access database copied ($(Format-FileSize $fileSize))" -Level Success
                            Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Success" -Details "Database file backed up"
                            
                            # Create instruction file for manual restore if needed
                            $instructionFile = Join-Path $destPath "RESTORE_INSTRUCTIONS.txt"
                            @"
Quick Access Pins Backup
========================
File: f01b4d95cf55d32a.automaticDestinations-ms
Backed up: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
From: $env:COMPUTERNAME

AUTOMATIC RESTORE:
The Import-LaptopData.ps1 script will automatically restore this file.

MANUAL RESTORE (if needed):
1. Close ALL File Explorer windows
2. Copy f01b4d95cf55d32a.automaticDestinations-ms to:
   %AppData%\Microsoft\Windows\Recent\AutomaticDestinations\
3. Restart Explorer:
   - Press Ctrl+Shift+Esc to open Task Manager
   - Find 'Windows Explorer' in the list
   - Right-click and select 'Restart'

NOTE: If paths don't exist on new machine (different username, etc.),
those pins may not work. You can manually re-pin folders:
Right-click folder > 'Pin to Quick access'
"@ | Out-File $instructionFile -Encoding UTF8
                            
                        }
                        catch {
                            Write-Log "Quick Access backup failed: $_" -Level Warning
                            Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Warning" -Details $_.Exception.Message
                        }
                    }
                    else {
                        Write-Log "Quick Access database file not found" -Level Warning
                        Add-Result -Category "AppData" -Item "Quick Access Pins" -Status "Skipped" -Details "No Quick Access data found"
                    }
                }
                else {
                    # Copy the folder through the shared progress runner so
                    # the technician can skip this individual transfer.
                    $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_$($item.Key).log"
                    $result = Copy-WithProgress -Source $sourcePath `
                                                -Destination $destPath `
                                                -FolderName "$($item.Key) (Roaming AppData)" `
                                                -LogPath $robocopyLog `
                                                -RobocopyArgs $Script:Config.RobocopyArgs
                    
                    if ($result.Status -eq "Success") {
                        Write-Log "$($item.Key) copied successfully" -Level Success
                        Add-Result -Category "AppData" -Item $item.Key -Status "Success"
                    }
                    elseif ($result.Aborted) {
                        Write-Log "$($item.Key) copy stopped by operator" -Level Warning
                        Add-Result -Category "AppData" -Item $item.Key -Status "Skipped" -Details "Stopped by operator; partial files may remain"
                    }
                    else {
                        Write-Log "$($item.Key) copy had issues (exit: $($result.ExitCode))" -Level Warning
                        Add-Result -Category "AppData" -Item $item.Key -Status "Warning" -Details "Exit code: $($result.ExitCode)"
                    }
                }
            }
            catch {
                Write-Log "Error copying $($item.Key)`: $_" -Level Error
                Add-Result -Category "AppData" -Item $item.Key -Status "Error" -Details $_.Exception.Message
                [void]$Script:Results.Errors.Add("$($item.Key)`: $($_.Exception.Message)")
            }
        }
        else {
            Write-Log "$($item.Key) not found at $sourcePath" -Level Info
            Add-Result -Category "AppData" -Item $item.Key -Status "Skipped" -Details "Not found"
        }
    }
    
    # ========== LOCAL APPDATA ITEMS (Lotus, etc.) ==========
    Write-Log "Checking AppData Local items..." -Level Info
    $localPath = $Script:OriginalAppDataLocal
    
    foreach ($item in $Script:Config.AppDataLocal.GetEnumerator()) {
        $sourcePath = Join-Path $localPath $item.Value
        $destPath = Join-Path $destAppData "$($item.Key)_Local"

        if ($item.Key -eq "Lotus" -and -not $Script:Config.Backup.LotusNotes) {
            Add-DisabledBackupResult -Item "Lotus Notes" -Category "AppData Local"
            continue
        }

        # Online mode: skip Lotus Notes local data by default (usually very large,
        # and Notes is reconfigured manually on the new machine anyway).
        if ($Script:Config.TransferMode -eq "Online" -and
            $item.Key -eq "Lotus" -and $Script:Config.Online.SkipLotusNotes) {
            if (Test-Path $sourcePath) {
                $lotusGB = [math]::Round((Get-FolderSizeBytes $sourcePath) / 1GB, 2)
                Write-Log "Lotus Notes local data omitted in online mode ($lotusGB GB)" -Level Warning
                Write-Status "Lotus Notes (Local)" "SKIP" "$lotusGB GB, omitted (online)"
                Add-Result -Category "AppData Local" -Item "Lotus" -Status "Skipped" -Details "Omitted (online mode): $lotusGB GB"
                Add-ManualTask -Task "Lotus Notes reconfiguration" -Reason "Local data omitted in online transfer ($lotusGB GB)" -Instructions "Lotus Notes is set up fresh on the new machine (see checklist). If the user has critical local (non-server) Notes data, copy it separately from AppData\Local\Lotus."
            }
            continue
        }

        if (Test-Path $sourcePath) {
            Write-Log "Found $($item.Key) in AppData\Local - copying..." -Level Info
            
            try {
                $robocopyLog = Join-Path $DestinationBase "Logs\robocopy_appdata_local_$($item.Key).log"
                
                $result = Copy-WithProgress -Source $sourcePath `
                                           -Destination $destPath `
                                           -FolderName "$($item.Key) (Local AppData)" `
                                           -LogPath $robocopyLog `
                                           -RobocopyArgs $Script:Config.RobocopyArgs
                
                if ($result.Status -eq "Success") {
                    Write-Log "$($item.Key) (Local) copied: $($result.FilesCopied) files" -Level Success
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Success" -Details "$($result.FilesCopied) files"
                }
                elseif ($result.Aborted) {
                    Write-Log "$($item.Key) (Local) copy stopped by operator" -Level Warning
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Skipped" -Details "Stopped by operator; partial files may remain"
                }
                else {
                    Write-Log "$($item.Key) (Local) copy had issues" -Level Warning
                    Add-Result -Category "AppData Local" -Item $item.Key -Status "Warning" -Details "Check log"
                }
                Write-Host ""
            }
            catch {
                Write-Log "Error copying $($item.Key) (Local): $_" -Level Error
                Add-Result -Category "AppData Local" -Item $item.Key -Status "Error" -Details $_.Exception.Message
            }
        }
        else {
            Write-Log "$($item.Key) not found in AppData\Local (user may not have this app)" -Level Info
        }
    }
}

# ============================================================================
# SETTINGS CAPTURE
# ============================================================================

# This module captures settings as portable evidence or importable artifacts.
# Registry exports, text/JSON snapshots, shortcut metadata, application lists,
# and printer packages have different portability and privilege rules; each
# function keeps those rules explicit instead of treating the entire profile as
# a raw filesystem copy.

function Test-OperatingSystemDriveBitLocker {
    # Get-BitLockerVolume and manage-bde generally require elevation. The
    # Windows Shell property exposes the operating-system drive's high-level
    # state to the signed-in user without changing anything.
    $mountPoint = if ($env:SystemDrive) { $env:SystemDrive + '\' } else { 'C:\' }
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application -ErrorAction Stop
        $folder = $shell.NameSpace($mountPoint)
        if ($null -eq $folder) { throw "Windows Shell could not open '$mountPoint'." }

        $rawStatus = $folder.Self.ExtendedProperty('System.Volume.BitLockerProtection')
        if ($null -eq $rawStatus) { throw "Windows did not return a BitLocker status for '$mountPoint'." }
        $status = [int]$rawStatus
    }
    finally {
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }

    # These values describe the Shell property, not the administrative
    # BitLocker cmdlet's ProtectionStatus values. Only 1 means protection is on.
    $result = switch ($status) {
        1 { [PSCustomObject]@{ Status = 'Success'; Details = "BitLocker protection is on for $mountPoint (Shell status 1)." }; break }
        2 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker is off for $mountPoint (fully decrypted; Shell status 2)." }; break }
        3 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker encryption is in progress or paused for $mountPoint; protection is not yet on (Shell status 3)." }; break }
        4 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker decryption is in progress or paused for $mountPoint (Shell status 4)." }; break }
        5 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker protection is suspended for $mountPoint (Shell status 5)." }; break }
        6 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker status for $mountPoint cannot be determined because the volume is locked (Shell status 6)." }; break }
        8 { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker is waiting for activation on $mountPoint (Shell status 8)." }; break }
        default { [PSCustomObject]@{ Status = 'Warning'; Details = "BitLocker returned unrecognized Shell status $status for $mountPoint." }; break }
    }

    Write-Status 'BitLocker OS drive' $(if ($result.Status -eq 'Success') { 'OK' } else { 'WARN' }) $result.Details
    return [PSCustomObject]@{ MountPoint = $mountPoint; ShellStatus = $status; Status = $result.Status; Details = $result.Details }
}

function Get-WindowsPowerMode {
    # The Power & battery "Power mode" selector is an overlay, not an ordinary
    # power-plan value.  Reading the old registry overlay values is not enough:
    # they can be absent or policy-derived.  Ask PowrProf for the mode Windows
    # is actually using so a destination can restore the same selector.
    if (-not ('StoPowerOverlayCapture' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StoPowerOverlayCapture {
    [DllImport("PowrProf.dll", EntryPoint="PowerGetActualOverlayScheme")]
    public static extern uint PowerGetActualOverlayScheme(out Guid overlaySchemeGuid);
    [DllImport("PowrProf.dll", EntryPoint="PowerGetEffectiveOverlayScheme")]
    public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlaySchemeGuid);
}
"@ -ErrorAction Stop
    }

    $actual = [guid]::Empty
    $effective = [guid]::Empty
    $actualResult = [StoPowerOverlayCapture]::PowerGetActualOverlayScheme([ref]$actual)
    $effectiveResult = [StoPowerOverlayCapture]::PowerGetEffectiveOverlayScheme([ref]$effective)
    if ($actualResult -ne 0 -and $effectiveResult -ne 0) {
        throw "Windows did not expose a Power mode overlay (actual=$actualResult; effective=$effectiveResult)."
    }

    $requestedGuid = if ($actualResult -eq 0) { $actual } else { $effective }
    $modeNames = @{
        '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency'
        '00000000-0000-0000-0000-000000000000' = 'Balanced'
        'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best performance'
    }
    $requestedText = $requestedGuid.ToString()
    return [ordered]@{
        RequestedOverlayGuid = $requestedText
        EffectiveOverlayGuid = if ($effectiveResult -eq 0) { $effective.ToString() } else { $null }
        DisplayName = if ($modeNames.ContainsKey($requestedText)) { $modeNames[$requestedText] } else { "Windows power-mode overlay $requestedText" }
        Source = if ($actualResult -eq 0) { 'PowerGetActualOverlayScheme' } else { 'PowerGetEffectiveOverlayScheme' }
    }
}

function Get-SystemExportProvenance {
    # Power and PrintBRM can be captured first in the transferring user's
    # session, then retried by the small UAC helper.  Keep their provenance in
    # a separate, durable manifest so the generated importer can accurately
    # tell a technician which attempt produced each artifact.
    param([string]$DestinationBase)

    $manifestPath = Join-Path $DestinationBase 'Settings\SystemExport.json'
    $existing = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try { $existing = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
        catch { Write-Log "Could not read existing system-export provenance: $($_.Exception.Message)" -Level Warning }
    }

    $existingPower = if ($existing) { $existing.Power } else { $null }
    $existingPrintBrm = if ($existing) { $existing.PrintBrm } else { $null }
    return [PSCustomObject]@{
        SchemaVersion = 1
        AdminExportRequested = [bool]$Script:Config.Export.RequestAdministratorPrivileges
        MainExporterWasAdministrator = [bool]$Script:IsAdmin
        UpdatedAt = (Get-Date).ToString('o')
        Power = [PSCustomObject]@{
            Attempted = if ($existingPower -and $null -ne $existingPower.Attempted) { [bool]$existingPower.Attempted } else { $false }
            CapturedWithAdministratorRights = if ($existingPower -and $null -ne $existingPower.CapturedWithAdministratorRights) { [bool]$existingPower.CapturedWithAdministratorRights } else { $false }
            Status = if ($existingPower -and $existingPower.Status) { [string]$existingPower.Status } else { 'NotAttempted' }
            Detail = if ($existingPower -and $existingPower.Detail) { [string]$existingPower.Detail } else { 'No full power-plan export was attempted.' }
            UpdatedAt = if ($existingPower -and $existingPower.UpdatedAt) { [string]$existingPower.UpdatedAt } else { $null }
        }
        PrintBrm = [PSCustomObject]@{
            Attempted = if ($existingPrintBrm -and $null -ne $existingPrintBrm.Attempted) { [bool]$existingPrintBrm.Attempted } else { $false }
            CapturedWithAdministratorRights = if ($existingPrintBrm -and $null -ne $existingPrintBrm.CapturedWithAdministratorRights) { [bool]$existingPrintBrm.CapturedWithAdministratorRights } else { $false }
            Status = if ($existingPrintBrm -and $existingPrintBrm.Status) { [string]$existingPrintBrm.Status } else { 'NotAttempted' }
            Detail = if ($existingPrintBrm -and $existingPrintBrm.Detail) { [string]$existingPrintBrm.Detail } else { 'No PrintBRM export was attempted.' }
            UpdatedAt = if ($existingPrintBrm -and $existingPrintBrm.UpdatedAt) { [string]$existingPrintBrm.UpdatedAt } else { $null }
        }
    }
}

function Set-SystemExportProvenance {
    # A failed optional admin retry must never erase the last known-good
    # standard-user provenance.  This writes only after a concrete attempt and
    # uses a replace operation so readers never receive partial JSON.
    param(
        [string]$DestinationBase,
        [ValidateSet('Power', 'PrintBrm')][string]$Artifact,
        [bool]$Attempted,
        [bool]$CapturedWithAdministratorRights,
        [ValidateSet('NotAttempted', 'Succeeded', 'Failed', 'Unavailable', 'Skipped')][string]$Status,
        [string]$Detail
    )

    try {
        $settingsPath = Join-Path $DestinationBase 'Settings'
        if (-not (Test-Path -LiteralPath $settingsPath)) { New-Item -ItemType Directory -Path $settingsPath -Force | Out-Null }
        $manifestPath = Join-Path $settingsPath 'SystemExport.json'
        $provenance = Get-SystemExportProvenance -DestinationBase $DestinationBase
        $provenance.AdminExportRequested = [bool]$Script:Config.Export.RequestAdministratorPrivileges
        $provenance.MainExporterWasAdministrator = [bool]$Script:IsAdmin
        $provenance.UpdatedAt = (Get-Date).ToString('o')
        $provenance.$Artifact = [PSCustomObject]@{
            Attempted = $Attempted
            CapturedWithAdministratorRights = $CapturedWithAdministratorRights
            Status = $Status
            Detail = $Detail
            UpdatedAt = (Get-Date).ToString('o')
        }

        $temporaryPath = Join-Path $settingsPath ("SystemExport.$PID.$([guid]::NewGuid().ToString('N')).tmp")
        try {
            [System.IO.File]::WriteAllText($temporaryPath, ($provenance | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $manifestPath) {
                try { [System.IO.File]::Replace($temporaryPath, $manifestPath, $null) }
                catch {
                    # File.Replace can be unavailable on some redirected
                    # folders. The temporary file still makes this fallback
                    # overwrite a complete JSON document in one operation.
                    [System.IO.File]::Copy($temporaryPath, $manifestPath, $true)
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                }
            }
            else { [System.IO.File]::Move($temporaryPath, $manifestPath) }
        }
        finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
    catch { Write-Log "Could not update system-export provenance for ${Artifact}: $($_.Exception.Message)" -Level Warning }
}

function Get-SystemSettings {
    # Collect power, personalization, network-drive, desktop, taskbar, and
    # default-app state into package files.  Capture failures are recorded as
    # manual tasks because a missing setting should be visible at handoff.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Capturing system settings..." -Level Info
    
    $settingsPath = Join-Path $DestinationBase "Settings"
    if (-not (Test-Path $settingsPath)) {
        New-Item -ItemType Directory -Path $settingsPath -Force | Out-Null
    }
    
    $settings = @{
        CaptureDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        UserName = $Script:OriginalUserName
        ComputerName = $env:COMPUTERNAME
        TransferMode = $Script:Config.TransferMode
        ExportWasAdministrator = [bool]$Script:IsAdmin
    }

    # Verify the operating-system drive without requiring elevation. This is a
    # provisioning check, not an administrative inventory of every volume.
    try {
        $settings.BitLocker = Test-OperatingSystemDriveBitLocker
        Add-Result -Category 'Settings' -Item 'BitLocker OS-drive status' -Status $settings.BitLocker.Status -Details $settings.BitLocker.Details
    }
    catch {
        $settings.BitLocker = [PSCustomObject]@{ MountPoint = if ($env:SystemDrive) { $env:SystemDrive + '\' } else { 'C:\' }; ShellStatus = $null; Status = 'Warning'; Details = $_.Exception.Message }
        Write-Status 'BitLocker OS drive' 'WARN' $settings.BitLocker.Details
        Add-Result -Category 'Settings' -Item 'BitLocker OS-drive status' -Status 'Warning' -Details $settings.BitLocker.Details
    }
    
    # Power Settings
    try {
        Write-Log "Capturing power settings..." -Level Info
        
        $powerScheme = powercfg /getactivescheme
        $settings.PowerScheme = $powerScheme
        $settings.PowerMode = Get-WindowsPowerMode
        # Retain the registry snapshot for older generated import scripts. The
        # PowerMode API result above is the authoritative capture for new ones.
        $overlayPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
        $overlayValues = Get-ItemProperty -LiteralPath $overlayPath -ErrorAction SilentlyContinue
        $settings.PowerModeOverlay = @{
            ActiveOverlayAcPowerScheme = $overlayValues.ActiveOverlayAcPowerScheme
            ActiveOverlayDcPowerScheme = $overlayValues.ActiveOverlayDcPowerScheme
        }
        
        # Extract the GUID from the power scheme output
        $schemeGuid = if ($powerScheme -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $matches[1]
        } else { $null }
        
        # A .pow export is a complete, portable copy of the active plan.  It
        # contains the AC and DC values for every setting exposed in Control
        # Panel and Power & battery (including the hidden advanced settings),
        # rather than just the small lid-close subset parsed below. Always try
        # this once in the current user context: some devices allow it without
        # UAC, and a later opt-in helper can safely retry only this operation.
        $powerExport = Join-Path $settingsPath "PowerScheme.pow"
        if (-not $schemeGuid) {
            throw "Could not determine the active power-scheme GUID."
        }

        # Keep a human-readable, full advanced-settings snapshot with the
        # package.  The .pow file is used for restoration because it is not
        # language-dependent and preserves settings that are not available on
        # the destination hardware.
        $powerDetailsPath = Join-Path $settingsPath "PowerSchemeDetails.txt"
        $powerDetails = & powercfg /qh $schemeGuid 2>&1
        $settings.PowerSettingsSnapshot = "PowerSchemeDetails.txt"
        $settings.PowerSettingsSnapshotExitCode = $LASTEXITCODE
        Set-Content -LiteralPath $powerDetailsPath -Value ($powerDetails | Out-String) -Encoding UTF8

        # Store every individual setting value as well as the .pow file.  The
        # destination normally already has the organisation's STOBG plan, so
        # these values can be applied one at a time to that existing plan even
        # when no plan import is being used.
        $powerSettingValues = New-Object System.Collections.ArrayList
        $currentSubgroupGuid = $null
        $currentPowerSetting = $null
        foreach ($line in $powerDetails) {
            if ($line -match '^\s*Subgroup GUID:\s*([0-9a-fA-F-]{36})') {
                $currentSubgroupGuid = $matches[1]
                $currentPowerSetting = $null
            }
            elseif ($line -match '^\s*Power Setting GUID:\s*([0-9a-fA-F-]{36})') {
                if ($currentSubgroupGuid) {
                    $currentPowerSetting = [ordered]@{
                        SubgroupGuid = $currentSubgroupGuid
                        SettingGuid = $matches[1]
                        ACValue = $null
                        DCValue = $null
                    }
                    [void]$powerSettingValues.Add($currentPowerSetting)
                }
            }
            elseif ($currentPowerSetting -and $line -match '^\s*Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
                $currentPowerSetting.ACValue = $matches[1]
            }
            elseif ($currentPowerSetting -and $line -match '^\s*Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)') {
                $currentPowerSetting.DCValue = $matches[1]
            }
        }
        $settings.PowerSettingValues = @($powerSettingValues | Where-Object { $_.ACValue -or $_.DCValue })
        $settings.PowerSettingValueCount = $settings.PowerSettingValues.Count
        if ($settings.PowerSettingValueCount -eq 0) {
            Write-Log "Could not parse individual power-setting values; the full text snapshot was saved" -Level Warning
        } else {
            Write-Log "Captured $($settings.PowerSettingValueCount) individual AC/DC power-setting value(s)" -Level Success
        }

        if (Test-Path -LiteralPath $powerExport) {
            Remove-Item -LiteralPath $powerExport -Force -ErrorAction Stop
        }

        $powerExportResult = & powercfg /export $powerExport $schemeGuid 2>&1
        $powerExportExitCode = $LASTEXITCODE
        $settings.PowerSchemeExported = ((Test-Path -LiteralPath $powerExport) -and ((Get-Item -LiteralPath $powerExport).Length -gt 0) -and $powerExportExitCode -eq 0)
        $settings.PowerSchemeExportExitCode = $powerExportExitCode
        $settings.PowerSchemeExportWasAdministrator = [bool]$Script:IsAdmin
        $settings.PowerSettingsMirror = "PowerScheme.pow"

        $powerAccessMode = if ($Script:IsAdmin) { 'administrator' } else { 'standard user' }
        if ($settings.PowerSchemeExported) {
            $powerDetail = "Complete power plan captured by $powerAccessMode export (exit $powerExportExitCode)."
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact Power -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Succeeded -Detail $powerDetail
            Write-Log "Complete power scheme exported successfully by $powerAccessMode" -Level Success
        }
        else {
            $exportMessage = ($powerExportResult | Out-String).Trim()
            $powerDetail = "Complete power plan was not created by the $powerAccessMode attempt (exit $powerExportExitCode)."
            if ($exportMessage) { $powerDetail += " $exportMessage" }
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact Power -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail $powerDetail
            if ($Script:IsAdmin) {
                Write-Log $powerDetail -Level Warning
            }
            else {
                # This is an expected capability boundary, not a failed export:
                # individual values remain captured and the admin retry is an
                # explicitly optional recommendation.
                Write-Log "$powerDetail Administrator export is recommended but optional." -Level Info
            }
        }
        
        # Capture lid close settings using powercfg query (works without admin)
        $lidSettingsRaw = powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>&1
        
        $settings.LidClose = @{
            Raw = ($lidSettingsRaw | Out-String)
        }
        
        # Try to parse AC and DC settings from the output
        if ($lidSettingsRaw -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $acValue = [convert]::ToInt32($matches[1], 16)
            $lidActions = @{0="Do Nothing"; 1="Sleep"; 2="Hibernate"; 3="Shut Down"}
            $settings.LidClose.OnAC = $lidActions[$acValue]
        }
        if ($lidSettingsRaw -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') {
            $dcValue = [convert]::ToInt32($matches[1], 16)
            $lidActions = @{0="Do Nothing"; 1="Sleep"; 2="Hibernate"; 3="Shut Down"}
            $settings.LidClose.OnBattery = $lidActions[$dcValue]
        }
        
        Write-Log "Complete power settings captured" -Level Success
        $fullPlanDetail = if ($settings.PowerSchemeExported) { "; full plan exported by $powerAccessMode" } elseif ($Script:IsAdmin) { '; full plan export did not complete' } else { '; full plan standard-user attempt did not complete (administrator export is recommended, optional)' }
        Add-Result -Category "Settings" -Item "Power Configuration" -Status $(if ($settings.PowerSettingValueCount -gt 0) { "Success" } else { "Warning" }) -Details "$($settings.PowerSettingValueCount) individual AC/DC values captured$fullPlanDetail; lid: AC=$($settings.LidClose.OnAC), DC=$($settings.LidClose.OnBattery); Windows power mode: $($settings.PowerMode.DisplayName)"
    }
    catch {
        Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact Power -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail "Power-settings capture did not complete: $($_.Exception.Message)"
        Write-Log "Error capturing power settings: $_" -Level Warning
        Add-Result -Category "Settings" -Item "Power Configuration" -Status "Manual" -Details "Could not capture - verify manually"
        Add-ManualTask -Task "Verify Power Settings" -Reason "Automatic capture failed" -Instructions "Check lid close action and sleep settings manually on both computers"
    }
    
    # Mapped Network Drives
    try {
        Write-Log "Capturing mapped drives..." -Level Info
        
        $mappedDrives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot -like "\\*" } | ForEach-Object {
            @{
                Letter = $_.Name
                Path = $_.DisplayRoot
            }
        }
        
        # Also check registry for persistent mappings
        $regDrives = Get-ItemProperty -Path "HKCU:\Network\*" -ErrorAction SilentlyContinue | ForEach-Object {
            @{
                Letter = $_.PSChildName
                Path = $_.RemotePath
                Persistent = $true
            }
        }
        
        # Keep the letter/path pair intact.  A letter can be reused with a
        # different UNC path, which is precisely the mismatch the importer
        # needs to identify on the replacement device.
        $settings.MappedDrives = @($mappedDrives) + @($regDrives) |
            Where-Object { $_.Letter -and $_.Path } |
            Sort-Object -Property Letter, Path -Unique
        
        $driveCount = ($settings.MappedDrives | Measure-Object).Count
        Write-Log "Found $driveCount mapped drive(s)" -Level Success
        Add-Result -Category "Settings" -Item "Mapped Drives" -Status "Success" -Details "$driveCount drive(s) documented"
    }
    catch {
        Write-Log "Error capturing mapped drives: $_" -Level Warning
        Add-Result -Category "Settings" -Item "Mapped Drives" -Status "Warning" -Details $_.Exception.Message
    }
    
    # Default Browser
    try {
        $defaultBrowser = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -ErrorAction SilentlyContinue).ProgId
        $settings.DefaultBrowser = $defaultBrowser
        Write-Log "Default browser: $defaultBrowser" -Level Info
        Add-Result -Category "Settings" -Item "Default Browser" -Status "Success" -Details $defaultBrowser
    }
    catch {
        Write-Log "Could not determine default browser" -Level Warning
    }
    
    # ========== PERSONALIZATION SETTINGS ==========
    Write-Log "Capturing personalization settings..." -Level Info
    
    try {
        $personalization = @{}
        
        # Dark/Light Mode
        $personalize = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction SilentlyContinue
        if ($personalize) {
            $personalization.AppsUseLightTheme = $personalize.AppsUseLightTheme
            $personalization.SystemUsesLightTheme = $personalize.SystemUsesLightTheme
            $personalization.EnableTransparency = $personalize.EnableTransparency
            $personalization.ColorPrevalence = $personalize.ColorPrevalence
        }
        
        # Accent Colors (DWM)
        $dwm = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -ErrorAction SilentlyContinue
        if ($dwm) {
            $personalization.ColorizationColor = $dwm.ColorizationColor
            $personalization.ColorizationAfterglow = $dwm.ColorizationAfterglow
            $personalization.ColorizationColorBalance = $dwm.ColorizationColorBalance
            $personalization.EnableWindowColorization = $dwm.EnableWindowColorization
            $personalization.AccentColorInactive = $dwm.AccentColorInactive
        }
        
        # Accent palette
        $accent = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent" -ErrorAction SilentlyContinue
        if ($accent) {
            $personalization.AccentPalette = $accent.AccentPalette
            $personalization.StartColorMenu = $accent.StartColorMenu
            $personalization.AccentColorMenu = $accent.AccentColorMenu
        }
        
        # Taskbar Settings
        $taskbar = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -ErrorAction SilentlyContinue
        if ($taskbar) {
            $personalization.TaskbarAl = $taskbar.TaskbarAl  # 0=Left, 1=Center (Win11)
            $personalization.TaskbarSi = $taskbar.TaskbarSi  # Taskbar size
            $personalization.ShowTaskViewButton = $taskbar.ShowTaskViewButton
            $personalization.TaskbarDa = $taskbar.TaskbarDa  # Widgets button
            $personalization.TaskbarMn = $taskbar.TaskbarMn  # Chat button
            $personalization.ShowCopilotButton = $taskbar.ShowCopilotButton
            $personalization.TaskbarSmallIcons = $taskbar.TaskbarSmallIcons
            $personalization.MMTaskbarEnabled = $taskbar.MMTaskbarEnabled  # Multi-monitor taskbar
        }
        
        # Taskbar Search Box mode (separate key from Explorer\Advanced)
        # 0=Hidden, 1=Search icon only, 2=Search box, 3=Search icon and label
        $searchTb = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -ErrorAction SilentlyContinue
        if ($searchTb) {
            $personalization.SearchboxTaskbarMode = $searchTb.SearchboxTaskbarMode
        }
        
        # Mouse pointer style, size, and per-role cursor mappings.
        $cursors = Get-ItemProperty -Path "HKCU:\Control Panel\Cursors" -ErrorAction SilentlyContinue
        if ($cursors) {
            $personalization.CursorScheme = $cursors.'(default)'
            $personalization.CursorBaseSize = $cursors.CursorBaseSize
            $personalization.CursorSettings = @{}
            $cursors.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                $personalization.CursorSettings[$_.Name] = $_.Value
            }
        }

        # Night light uses opaque binary CloudStore values rather than a
        # conventional Settings registry value.  Preserve both entries: the
        # state entry holds whether it is on, while settings holds intensity
        # and schedule.  The .reg export below restores the original bytes.
        $nightLightKeys = @(
            @{ Name = 'State'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\Current' },
            @{ Name = 'Settings'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings\Current' }
        )
        $personalization.NightLight = @{}
        foreach ($nightLightKey in $nightLightKeys) {
            $nightLightData = (Get-ItemProperty -LiteralPath $nightLightKey.Path -Name 'Data' -ErrorAction SilentlyContinue).Data
            if ($null -ne $nightLightData) {
                $personalization.NightLight[$nightLightKey.Name] = @{ Captured = $true; DataLength = @($nightLightData).Count }
            }
        }
        
        # Desktop Icon Settings
        $desktopIcons = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" -ErrorAction SilentlyContinue
        if ($desktopIcons) {
            $personalization.DesktopIcons = @{}
            $desktopIcons.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $personalization.DesktopIcons[$_.Name] = $_.Value
            }
        }
        
        # Visual Effects
        $visualFx = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -ErrorAction SilentlyContinue
        if ($visualFx) {
            $personalization.VisualFXSetting = $visualFx.VisualFXSetting
        }
        
        # Font DPI / Scaling
        $desktop = Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -ErrorAction SilentlyContinue
        if ($desktop) {
            $personalization.LogPixels = $desktop.LogPixels
            $personalization.Win8DpiScaling = $desktop.Win8DpiScaling
        }

        # Windows 10/11 stores display scaling per monitor.  Monitor IDs do
        # not survive a hardware migration, so retain the DPI values in JSON
        # for the importer to apply to the destination monitor entries.
        $perMonitorDpi = @(Get-ChildItem -Path 'HKCU:\Control Panel\Desktop\PerMonitorSettings' -ErrorAction SilentlyContinue | ForEach-Object {
            $dpi = (Get-ItemProperty -LiteralPath $_.PSPath -Name DpiValue -ErrorAction SilentlyContinue).DpiValue
            # DpiValue is an unsigned registry DWORD; 0xffffffff is valid
            # there but cannot be cast to Int32.
            if ($null -ne $dpi) { [uint32]$dpi }
        })
        $personalization.ScreenScale = @{
            LogPixels = $personalization.LogPixels
            Win8DpiScaling = $personalization.Win8DpiScaling
            PerMonitorDpiValues = $perMonitorDpi
        }

        # Accessibility > Text size is a percentage stored per user.
        $accessibility = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Accessibility' -ErrorAction SilentlyContinue
        if ($accessibility -and $null -ne $accessibility.TextScaleFactor) {
            $personalization.TextScaleFactor = [uint32]$accessibility.TextScaleFactor
        }
        
        $settings.Personalization = $personalization
        
        # Export registry keys to .reg file for reliable restore
        $regExportPath = Join-Path $settingsPath "Personalization.reg"
        $regContent = @"
Windows Registry Editor Version 5.00

; Personalization settings exported by STO Laptop Transfer Tool
; Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

"@
        
        # Export each key
        $regKeys = @(
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            "HKCU\Software\Microsoft\Windows\DWM",
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent",
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Search",
            "HKCU\Control Panel\Cursors",
            "HKCU\Control Panel\Desktop",
            "HKCU\Control Panel\Desktop\PerMonitorSettings",
            "HKCU\Software\Microsoft\Accessibility",
            'HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings'
        )
        
        foreach ($key in $regKeys) {
            $tempReg = Join-Path $env:TEMP "temp_export_$(Get-Random).reg"
            $exportResult = reg export $key $tempReg /y 2>&1
            if (Test-Path $tempReg) {
                $keyContent = Get-Content $tempReg -Raw -ErrorAction SilentlyContinue
                # Remove the header from subsequent exports
                $keyContent = $keyContent -replace "Windows Registry Editor Version 5.00\r?\n\r?\n", ""
                $regContent += "`n$keyContent"
                Remove-Item $tempReg -Force -ErrorAction SilentlyContinue
            }
        }
        
        $regContent | Out-File $regExportPath -Encoding Unicode
        
        $nightLightDetail = if ($personalization.NightLight.Count -gt 0) { 'Night light state, strength, and schedule captured' } else { 'Night light was not configured' }
        Write-Log "Personalization settings captured (colors, taskbar, display scale, mouse pointer style, Night light, text size)" -Level Success
        Add-Result -Category "Settings" -Item "Personalization" -Status "Success" -Details "Colors, taskbar, display scale, mouse pointer style, text size, visual effects; $nightLightDetail"
    }
    catch {
        Write-Log "Error capturing personalization: $_" -Level Warning
        Add-Result -Category "Settings" -Item "Personalization" -Status "Warning" -Details $_.Exception.Message
    }
    
    # Wallpaper (separate for clarity)
    try {
        Write-Log "Capturing wallpaper..." -Level Info
        
        $wallpaperPath = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -ErrorAction SilentlyContinue).Wallpaper
        if ($wallpaperPath -and (Test-Path $wallpaperPath)) {
            $wallpaperDest = Join-Path $settingsPath "Wallpaper$([System.IO.Path]::GetExtension($wallpaperPath))"
            Copy-Item $wallpaperPath -Destination $wallpaperDest -Force
            $settings.WallpaperCopied = $true
            Write-Log "Wallpaper copied" -Level Success
            Add-Result -Category "Settings" -Item "Wallpaper" -Status "Success" -Details "Image file saved"
        }
        else {
            $settings.WallpaperCopied = $false
            Write-Log "No custom wallpaper found" -Level Info
            Add-Result -Category "Settings" -Item "Wallpaper" -Status "Skipped" -Details "Using default or no wallpaper"
        }
    }
    catch {
        Write-Log "Error capturing wallpaper: $_" -Level Warning
    }
    
    # Save a dedicated, technician-readable snapshot as well as the complete
    # settings payload consumed by the generated importer.
    if (-not $settings.ContainsKey('MappedDrives')) { $settings.MappedDrives = @() }
    $mappedDriveSnapshotFile = Join-Path $settingsPath "MappedDrivesSnapshot.json"
    [PSCustomObject]@{
        CaptureDate = $settings.CaptureDate
        ComputerName = $settings.ComputerName
        UserName = $settings.UserName
        Drives = @($settings.MappedDrives)
    } | ConvertTo-Json -Depth 4 | Out-File $mappedDriveSnapshotFile -Encoding UTF8

    # Save settings to JSON
    $settingsFile = Join-Path $settingsPath "SystemSettings.json"
    $settings | ConvertTo-Json -Depth 5 | Out-File $settingsFile -Encoding UTF8
    
    Write-Log "Settings saved to SystemSettings.json" -Level Success
    
    return $settings
}
function Get-ShortcutMetadata {
    param([System.IO.FileInfo]$File, [int]$Ordinal = 0)

    $item = [ordered]@{
        Name = $File.Name; Extension = $File.Extension.ToLowerInvariant(); Sha256 = $null
        TargetPath = $null; Arguments = $null; WorkingDirectory = $null; IconLocation = $null; Ordinal = $Ordinal
    }
    try { $item.Sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if ($item.Extension -eq '.lnk') {
        try {
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($File.FullName)
            $item.TargetPath = $shortcut.TargetPath; $item.Arguments = $shortcut.Arguments
            $item.WorkingDirectory = $shortcut.WorkingDirectory; $item.IconLocation = $shortcut.IconLocation
        } catch { Write-Log "Could not inspect shortcut '$($File.Name)': $($_.Exception.Message)" -Level Warning }
    }
    return [PSCustomObject]$item
}

function Backup-TaskbarLayout {
    param([string]$DestinationBase)

    $settingsPath = Join-Path $DestinationBase 'Settings'
    $sourcePath = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $packagePath = Join-Path $settingsPath 'TaskbarLayout'
    try {
        $pins = @()
        $taskbandValues = @{}
        $taskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
        if (Test-Path -LiteralPath $taskbandPath) {
            $taskbandProperties = Get-ItemProperty -LiteralPath $taskbandPath -ErrorAction SilentlyContinue
            foreach ($property in @($taskbandProperties.PSObject.Properties | Where-Object { $_.Name -in @('Favorites', 'FavoritesResolve') -and $_.Value -is [byte[]] })) {
                $taskbandValues[$property.Name] = [Convert]::ToBase64String([byte[]]$property.Value)
            }
        }
        if (Test-Path -LiteralPath $sourcePath) {
            New-Item -ItemType Directory -Path $packagePath -Force | Out-Null
            $ordinal = 0
            # Taskband contains the authoritative pin order. Keep the link
            # inventory independent of alphabetical file-name sorting so it
            # cannot obscure that source ordering during restoration.
            foreach ($file in @(Get-ChildItem -LiteralPath $sourcePath -File -Force | Where-Object { $_.Name -notmatch 'Microsoft Store|WindowsStore' })) {
                $ordinal++; Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $packagePath $file.Name) -Force -ErrorAction Stop
                $pins += Get-ShortcutMetadata -File $file -Ordinal $ordinal
            }
        }
        [PSCustomObject]@{ CaptureDate = (Get-Date).ToString('o'); Pins = @($pins); SourcePath = $sourcePath; TaskbandValues = $taskbandValues; MicrosoftStoreExcluded = $true } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $settingsPath 'TaskbarLayout.json') -Encoding UTF8
        Add-Result -Category 'Settings' -Item 'Taskbar Layout' -Status 'Success' -Details "$($pins.Count) pinned app shortcut(s) captured"
        Write-Log "Taskbar layout captured: $($pins.Count) pin(s)" -Level Success
    } catch {
        Write-Log "Taskbar layout capture failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'Settings' -Item 'Taskbar Layout' -Status 'Warning' -Details $_.Exception.Message
    }
}

function Backup-DefaultApps {
    param([string]$DestinationBase)

    $settingsPath = Join-Path $DestinationBase 'Settings'
    try {
        $associations = @()
        $roots = @(
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'; Type = 'FileExtension' },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations'; Type = 'Protocol' }
        )
        foreach ($root in $roots) {
            foreach ($key in @(Get-ChildItem -Path $root.Path -ErrorAction SilentlyContinue)) {
                $choice = Get-ItemProperty -LiteralPath (Join-Path $key.PSPath 'UserChoice') -ErrorAction SilentlyContinue
                if ($choice -and $choice.ProgId) {
                    $associations += [PSCustomObject]@{ Name = $key.PSChildName; Type = $root.Type; ProgId = $choice.ProgId }
                }
            }
        }
        $associations = @($associations | Sort-Object Type, Name -Unique)
        [PSCustomObject]@{ CaptureDate = (Get-Date).ToString('o'); Associations = $associations } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $settingsPath 'DefaultApps.json') -Encoding UTF8
        Add-Result -Category 'Settings' -Item 'Default Apps' -Status 'Success' -Details "$($associations.Count) explicit association(s) captured"
        Write-Log "Default app inventory captured: $($associations.Count) association(s)" -Level Success
    } catch {
        Write-Log "Default app inventory capture failed: $($_.Exception.Message)" -Level Warning
        Add-Result -Category 'Settings' -Item 'Default Apps' -Status 'Warning' -Details $_.Exception.Message
    }
}
function Get-InstalledPrograms {
    # Read the machine's uninstall inventories from both registry views and
    # normalize them into a deduplicated list for comparison during import.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Documenting installed programs..." -Level Info
    
    $programs = @()
    
    # 64-bit programs
    $programs += Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'Machine64' } }
    
    # 32-bit programs on 64-bit system
    $programs += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'Machine32' } }
    
    # User-installed programs
    $programs += Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate, @{ Name = 'SourceScope'; Expression = { 'CurrentUser' } }
    
    $programs = @($programs | ForEach-Object {
        [PSCustomObject]@{
            DisplayName = $_.DisplayName; DisplayVersion = $_.DisplayVersion; Publisher = $_.Publisher
            InstallDate = $_.InstallDate; SourceScope = $_.SourceScope
            MatchKey = Get-ProgramMatchKey -DisplayName $_.DisplayName -Publisher $_.Publisher
        }
    } | Sort-Object MatchKey, DisplayName -Unique)
    
    $settingsPath = Join-Path $DestinationBase "Settings"
    $programsFile = Join-Path $settingsPath "InstalledPrograms.json"
    $programs | ConvertTo-Json | Out-File $programsFile -Encoding UTF8
    
    # Also create a readable text file
    $programsTxt = Join-Path $settingsPath "InstalledPrograms.txt"
    $programs | Format-Table -AutoSize | Out-String | Out-File $programsTxt -Encoding UTF8
    
    $count = ($programs | Measure-Object).Count
    Write-Log "Documented $count installed programs" -Level Success
    Add-Result -Category "Settings" -Item "Installed Programs" -Status "Success" -Details "$count programs listed"
    
    return $programs
}

function ConvertTo-ProgramMatchPart {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Get-ProgramMatchKey {
    param([string]$DisplayName, [string]$Publisher)
    return "$(ConvertTo-ProgramMatchPart $DisplayName)|$(ConvertTo-ProgramMatchPart $Publisher)"
}

function Get-AppDataCandidates {
    param(
        [string]$DestinationBase,
        [bool]$IncludeSizes = $true
    )

    $excludedNames = @('Microsoft', 'Packages', 'Temp', 'Temporary Internet Files', 'CrashDumps', 'SquirrelTemp', 'D3DSCache', 'ConnectedDevicesPlatform', 'Comms')
    $curated = @($Script:Config.AppDataRoaming.Keys + $Script:Config.AppDataLocal.Keys + 'Bluebeam')
    $candidates = [System.Collections.ArrayList]::new()
    foreach ($root in @(
        @{ Area = 'Roaming'; Path = $Script:OriginalAppDataRoaming },
        @{ Area = 'Local'; Path = $Script:OriginalAppDataLocal }
    )) {
        try {
            foreach ($folder in @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction Stop)) {
                if ($folder.Name -in $excludedNames) { continue }
                $covered = $curated -contains $folder.Name
                $size = 0L
                if ($IncludeSizes) {
                    try { $size = Get-FolderSizeBytes -Path $folder.FullName } catch { Write-Log "Could not size AppData candidate $($folder.FullName): $($_.Exception.Message)" -Level Warning }
                }
                [void]$candidates.Add([PSCustomObject]@{
                    Area = $root.Area; RelativePath = $folder.Name; FullPath = $folder.FullName; SizeBytes = $size
                    CoveredByCuratedBackup = $covered; AssociationHint = ConvertTo-ProgramMatchPart $folder.Name
                })
            }
        }
        catch {
            Write-Log "Could not enumerate $($root.Area) AppData candidates: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'Settings' -Item "AppData candidates ($($root.Area))" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    $settingsPath = Join-Path $DestinationBase 'Settings'
    $path = Join-Path $settingsPath 'AppDataCandidates.json'
    @($candidates | Sort-Object Area, RelativePath) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    $textPath = Join-Path $settingsPath 'AppDataCandidates.txt'
    @($candidates | Sort-Object Area, RelativePath | ForEach-Object { "[$($_.Area)] $($_.RelativePath) | $(Format-FileSize $_.SizeBytes) | $(if ($_.CoveredByCuratedBackup) { 'already curated' } else { 'review candidate' })" }) | Set-Content -LiteralPath $textPath -Encoding UTF8
    $detail = if ($IncludeSizes) { "$($candidates.Count) review candidate(s) listed with sizes" } else { "$($candidates.Count) review candidate(s) listed (sizes skipped for Online speed)" }
    Add-Result -Category 'Settings' -Item 'AppData candidates' -Status 'Success' -Details $detail
    return @($candidates)
}

function Get-AdditionalAppDataCandidates {
    param([bool]$IncludeSizes = $true)
    $excludedNames = @('Microsoft', 'Packages', 'Temp', 'Temporary Internet Files', 'CrashDumps', 'SquirrelTemp', 'D3DSCache', 'ConnectedDevicesPlatform', 'Comms')
    $curated = @($Script:Config.AppDataRoaming.Keys + $Script:Config.AppDataLocal.Keys + 'Bluebeam', 'Bluebeam Software', 'Mozilla', 'Google')
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @(
        @{ Area = 'Roaming'; Path = $Script:OriginalAppDataRoaming },
        @{ Area = 'Local'; Path = $Script:OriginalAppDataLocal }
    )) {
        try {
            foreach ($folder in @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction Stop)) {
                if ($folder.Name -in $excludedNames -or $folder.Name -in $curated) { continue }
                if ($folder.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { continue }
                $sizeBytes = $null
                if ($IncludeSizes) {
                    try { $sizeBytes = Get-FolderSizeBytes -Path $folder.FullName }
                    catch {
                        Write-Log "Could not size additional $($root.Area) AppData folder '$($folder.FullName)': $($_.Exception.Message)" -Level Warning
                        Add-Result -Category 'Additional AppData' -Item "$($root.Area)\$($folder.Name)" -Status 'Warning' -Details 'Size unavailable'
                    }
                }
                [void]$candidates.Add([PSCustomObject]@{
                    Area = $root.Area; RelativePath = $folder.Name; FullPath = $folder.FullName; SizeBytes = $sizeBytes
                })
            }
        }
        catch {
            Write-Log "Could not enumerate $($root.Area) AppData folders for Advanced selection: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'Additional AppData' -Item "$($root.Area) candidates" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    return @($candidates | Sort-Object Area, RelativePath)
}

function Start-AdditionalAppDataSizeJob {
    param([array]$Candidates)
    $paths = @($Candidates | ForEach-Object { $_.FullPath } | Where-Object { $_ } | Sort-Object -Unique)
    return Start-Job -ArgumentList (,$paths) -ScriptBlock {
        param([string[]]$FolderPaths)
        foreach ($path in $FolderPaths) {
            $bytes = 0L
            try {
                if (Test-Path -LiteralPath $path) {
                    # Do not collect every file into an array before adding
                    # its length.  AppData folders can contain hundreds of
                    # thousands of files, and the streaming measure keeps the
                    # selection screen responsive.
                    $measure = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
                        Measure-Object -Property Length -Sum
                    $bytes = [long]$(if ($null -eq $measure.Sum) { 0 } else { $measure.Sum })
                }
            }
            catch { }
            [PSCustomObject]@{ Path = $path; Bytes = $bytes }
        }
    }
}

function Receive-AdditionalAppDataSizeJob {
    param([System.Management.Automation.Job]$Job, [array]$Candidates)
    if (-not $Job) { return $false }
    $updated = $false
    $sizes = @{}
    foreach ($result in @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)) {
        if ($result -and $result.Path) { $sizes[$result.Path] = [long]$result.Bytes; $updated = $true }
    }
    foreach ($candidate in $Candidates) {
        if ($sizes.ContainsKey($candidate.FullPath)) { $candidate.SizeBytes = $sizes[$candidate.FullPath] }
    }
    return $updated
}

function Show-AdditionalAppDataMenu {
    param([array]$Candidates, [bool]$Calculating, [bool]$Skipped, [System.Collections.Generic.HashSet[int]]$Selected = $null)
    Clear-StoScreen
    Write-Banner -Title 'Advanced AppData Selection' -Subtitle 'Select additional folders to include in this transfer'
    Write-Host '  Curated AppData items remain included automatically. Select only extra folders below.' -ForegroundColor DarkGray
    if ($Calculating) { Write-Host '  Calculating folder sizes in the background. Press R to refresh; the menu refreshes automatically when finished.' -ForegroundColor Cyan }
    elseif ($Skipped) { Write-Host '  Folder sizing was not completed; unsized folders display as unknown.' -ForegroundColor Yellow }
    Write-Host ''
    for ($index = 0; $index -lt $Candidates.Count; $index++) {
        $item = $Candidates[$index]
        $sizeText = if ($null -eq $item.SizeBytes) { 'calculating...' } else { Format-FileSize $item.SizeBytes }
        $state = if ($Selected -and $Selected.Contains($index + 1)) { 'ON ' } else { 'OFF' }
        $color = if ($state -eq 'ON ') { 'Green' } else { 'DarkGray' }
        Write-Host "  [$($index + 1)] $state " -ForegroundColor $color -NoNewline
        Write-Host "$($item.Area.PadRight(7)) $($item.RelativePath.PadRight(32)) $sizeText" -ForegroundColor White
    }
    Write-Host ''
}

function Select-AdditionalAppData {
    # Draw the selection screen before recursive sizing starts so the
    # technician immediately sees what is being evaluated.
    $candidates = @(Get-AdditionalAppDataCandidates -IncludeSizes $false)
    if ($candidates.Count -eq 0) {
        Write-Host '  No additional Local or Roaming AppData folders were found.' -ForegroundColor Yellow
        return @()
    }

    $sizeJob = Start-AdditionalAppDataSizeJob -Candidates $candidates
    $Script:AdditionalAppDataSizeJob = $sizeJob
    $Script:AdditionalAppDataMenuCandidates = $candidates
    $Script:AdditionalAppDataSizeAutoRefreshed = $false
    $selectedNumbers = [System.Collections.Generic.HashSet[int]]::new()
    try {
        while ($true) {
            Show-AdditionalAppDataMenu -Candidates $Script:AdditionalAppDataMenuCandidates -Calculating ($Script:AdditionalAppDataSizeJob.State -eq 'Running') -Skipped $false -Selected $selectedNumbers
            Write-Host '  Enter a number to toggle it; [A] all; [N] none; [S] save; [R] refresh' -ForegroundColor Gray
            $answer = Read-MenuInputWithBackgroundRefresh -Prompt '' -Poll {
                $wasRunning = [bool]$Script:AdditionalAppDataSizeJob
                [void](Receive-AdditionalAppDataSizeJob -Job $Script:AdditionalAppDataSizeJob -Candidates $Script:AdditionalAppDataMenuCandidates)
                if ($wasRunning -and $Script:AdditionalAppDataSizeJob.State -ne 'Running' -and -not $Script:AdditionalAppDataSizeAutoRefreshed) {
                    $Script:AdditionalAppDataSizeAutoRefreshed = $true
                    return $true
                }
                return $false
            }
            if ($answer -eq '__MENU_AUTO_REFRESH__' -or $answer -match '^[Rr]$') { continue }
            if ($answer -match '^[Aa]$') { $selectedNumbers.Clear(); 1..$candidates.Count | ForEach-Object { [void]$selectedNumbers.Add($_) }; continue }
            if ($answer -match '^[Nn]$') { $selectedNumbers.Clear(); continue }
            if ($answer -match '^[Ss]$') { break }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
                if ($selectedNumbers.Contains($number)) { [void]$selectedNumbers.Remove($number) } else { [void]$selectedNumbers.Add($number) }
                continue
            }
            Write-Host '  Enter a listed number, A, N, S, or R.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 700
        }
        if ($sizeJob.State -eq 'Running') { Stop-Job -Job $sizeJob -ErrorAction SilentlyContinue }
    }
    finally {
        Remove-Job -Job $sizeJob -Force -ErrorAction SilentlyContinue
    }
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($number in $selectedNumbers) { [void]$selected.Add($candidates[$number - 1]) }
    return @($selected | Sort-Object Area, RelativePath -Unique)
}

function Copy-SelectedAdditionalAppData {
    param([string]$DestinationBase)

    foreach ($item in @($Script:SelectedAdditionalAppData)) {
        $itemName = "$($item.Area)\$($item.RelativePath)"
        if ($item.Area -notin @('Roaming', 'Local') -or [string]::IsNullOrWhiteSpace($item.RelativePath) -or
            $item.RelativePath -match '[\\/]') {
            Write-Log "Skipping invalid additional AppData selection '$itemName'." -Level Warning
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Skipped' -Details 'Invalid selection path'
            continue
        }
        if (-not (Test-Path -LiteralPath $item.FullPath)) {
            Write-Log "Selected additional AppData folder '$itemName' no longer exists." -Level Warning
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Skipped' -Details 'Source folder no longer exists'
            continue
        }
        try {
            $destination = Join-Path $DestinationBase "AppData\Additional\$($item.Area)\$($item.RelativePath)"
            $logPath = Join-Path $DestinationBase "Logs\robocopy_additional_appdata_$($item.Area)_$($item.RelativePath).log"
            $result = Copy-WithProgress -Source $item.FullPath -Destination $destination -FolderName "Additional AppData: $itemName" -LogPath $logPath -RobocopyArgs $Script:Config.RobocopyArgs
            Add-Result -Category 'Additional AppData' -Item $itemName -Status $result.Status -Details "$($result.FilesCopied) files; $(Format-FileSize $item.SizeBytes)"
        }
        catch {
            Write-Log "Could not copy additional AppData folder '$itemName': $($_.Exception.Message)" -Level Error
            Add-Result -Category 'Additional AppData' -Item $itemName -Status 'Error' -Details $_.Exception.Message
        }
    }
}

function Backup-Printers {
    # Capture printers using the least-privileged supported path first.  PrintBRM
    # is an optional elevated fallback because it can include drivers and local
    # queues that ordinary Add-Printer connections cannot recreate.
    param(
        [string]$DestinationBase
    )

    Write-Section "Backing up printers"

    $printerFolder = Join-Path $DestinationBase "Printers"
    $connectionsJson = Join-Path $printerFolder "PrinterConnections.json"
    $exportFile    = Join-Path $printerFolder "Printers.printerExport"
    $brmLog        = Join-Path $DestinationBase "Logs\printbrm_backup.log"

    # A 32-bit PowerShell host is redirected from System32 to SysWOW64.  Use
    # Sysnative first in that case so we always call the native PrintBRM tool.
    $printBrmCandidates = @()
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $printBrmCandidates += (Join-Path $env:WINDIR "Sysnative\spool\tools\PrintBrm.exe")
    }
    $printBrmCandidates += (Join-Path $env:WINDIR "System32\spool\tools\PrintBrm.exe")
    $printBrmPath = $printBrmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    foreach ($p in @($printerFolder, (Split-Path $brmLog))) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }

    # Virtual/built-in printers we never want to carry over
    $virtualPrinters = @(
        "Microsoft Print to PDF", "Microsoft XPS Document Writer",
        "OneNote", "OneNote (Desktop)", "OneNote for Windows 10",
        "Fax", "Send To OneNote 2016", "Adobe PDF"
    )

    # ---- PRIMARY (non-admin): capture the user's network printer connections ----
    # These are \\server\printer connections stored per-user (HKCU\Printers\
    # Connections). Enumerating and re-adding them needs NO admin, as long as the
    # driver is staged or v4 on the new machine.
    $allPrinters = @(Get-Printer -ErrorAction SilentlyContinue)
    $connections = @($allPrinters | Where-Object {
        ($_.Type -eq 'Connection' -or $_.Name -like '\\*') -and
        ($virtualPrinters -notcontains $_.Name)
    })

    # Default printer (best-effort, works non-admin via CIM)
    $defaultPrinter = $null
    try {
        $defaultPrinter = (Get-CimInstance -ClassName Win32_Printer -Filter "Default = True" -ErrorAction SilentlyContinue).Name
    } catch { }

    $connData = @{
        CapturedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DefaultPrinter = $defaultPrinter
        Connections = @($connections | ForEach-Object {
            @{ Name = $_.Name; ConnectionName = $_.Name }
        })
    }
    $connData | ConvertTo-Json -Depth 4 | Out-File $connectionsJson -Encoding UTF8

    if ($connections.Count -gt 0) {
        Write-Log "Captured $($connections.Count) network printer connection(s)" -Level Success
        Write-Status "Network printers" "OK" "$($connections.Count) connection(s), no admin needed"
        Add-Result -Category "Printers" -Item "Network Connections" -Status "Success" -Details "$($connections.Count) connection(s) captured"
    }
    else {
        Write-Log "No network printer connections found" -Level Info
        Write-Status "Network printers" "INFO" "none found"
        Add-Result -Category "Printers" -Item "Network Connections" -Status "Skipped" -Details "None found"
    }
    if ($defaultPrinter) {
        Write-KeyValue "Default printer" $defaultPrinter
    }

    # ---- PrintBRM package ----
    # PrintBRM is the only source of a real .printerExport migration file.  Do
    # not limit it to local printers: a package can also contain network queues,
    # and users expect this artifact even when the JSON connection list is enough
    # for a driverless restore.  Windows may reject the backup from a non-elevated
    # session; we still attempt it and retain the tool output in the log.
    $localPrinters = @($allPrinters | Where-Object {
        $_.Type -eq 'Local' -and $_.Name -notlike '\\*' -and
        ($virtualPrinters -notcontains $_.Name)
    })

    if ($localPrinters.Count -gt 0) {
        Write-Host "    $($Script:Theme.Glyphs.INFO) " -ForegroundColor Cyan -NoNewline
        Write-Host "$($localPrinters.Count) local/direct-IP printer(s) detected" -ForegroundColor White
    }

    if (-not $printBrmPath) {
        Write-Status "Printer migration file" "SKIP" "PrintBRM.exe not present"
        Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Skipped" -Details "PrintBRM.exe not found"
        Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $false -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Unavailable -Detail 'PrintBRM.exe was not found on the export computer.'
        return
    }

    try {
        # Do not let a stale file be mistaken for the result of this run.
        if (Test-Path -LiteralPath $exportFile) {
            Remove-Item -LiteralPath $exportFile -Force -ErrorAction Stop
        }

        $brmArgs = @("-B", "-F", $exportFile)
        if (-not $Script:Config.IncludePrinterDrivers) { $brmArgs += "-NOBIN" }
        $accessMode = if ($Script:IsAdmin) { "elevated" } else { "standard-user attempt" }
        Write-Host "    $($Script:Theme.Glyphs.INFO) Creating printer migration file (PrintBRM, $accessMode)" -ForegroundColor DarkGray
        & $printBrmPath @brmArgs *>&1 | Tee-Object -FilePath $brmLog | Out-Null
        $brmExit = $LASTEXITCODE

        if ((Test-Path $exportFile) -and ((Get-Item $exportFile).Length -gt 0)) {
            $file = Get-Item $exportFile
            Write-Log "Printer migration file created ($(Format-FileSize $file.Length)); PrintBRM exit $brmExit" -Level Success
            Write-Status "Printer migration file" "OK" "$(Format-FileSize $file.Length) (PrintBRM)"
            Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Success" -Details "$(Format-FileSize $file.Length), drivers=$($Script:Config.IncludePrinterDrivers), exit=$brmExit"
            $accessMode = if ($Script:IsAdmin) { 'administrator' } else { 'standard-user' }
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Succeeded -Detail "PrintBRM package created by the $accessMode export (exit $brmExit)."
        }
        else {
            $elevationHint = if ($Script:IsAdmin) { "" } else { "; Windows commonly requires an elevated session" }
            $failureDetail = "PrintBRM did not create Printers.printerExport during the $(if ($Script:IsAdmin) { 'administrator' } else { 'standard-user' }) attempt (exit $brmExit)$elevationHint."
            Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail $failureDetail
            if ($Script:IsAdmin) {
                Write-Log $failureDetail -Level Warning
                Write-Status "Printer migration file" "WARN" "not created (exit $brmExit)"
                Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Warning" -Details "Exit $brmExit; see printbrm_backup.log"
            }
            else {
                # The default path deliberately allows this attempt to fail
                # without turning an optional UAC choice into a handoff error.
                Write-Log "$failureDetail Administrator export is recommended but optional." -Level Info
                Write-Status "Printer migration file" "INFO" "standard-user attempt did not create it; admin is recommended"
                Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Skipped" -Details "Standard-user attempt did not create the package (exit $brmExit). Administrator export is recommended, optional; see printbrm_backup.log"
            }
        }
    }
    catch {
        Set-SystemExportProvenance -DestinationBase $DestinationBase -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights ([bool]$Script:IsAdmin) -Status Failed -Detail "PrintBRM attempt failed: $($_.Exception.Message)"
        if ($Script:IsAdmin) {
            Write-Status "Local printers" "FAIL" $_.Exception.Message
            Add-Result -Category "Printers" -Item "Local Printers" -Status "Error" -Details $_.Exception.Message
        }
        else {
            Write-Status "Local printers" "INFO" "standard-user attempt did not complete; admin is recommended"
            Add-Result -Category "Printers" -Item "Local Printers" -Status "Skipped" -Details "Standard-user PrintBRM attempt did not complete. Administrator export is recommended, optional; see printbrm_backup.log"
            Write-Log "Standard-user PrintBRM attempt did not complete: $($_.Exception.Message)" -Level Info
        }
    }
}

function Test-UacElevationCancelled {
    # ERROR_CANCELLED (1223) is the stable Windows signal even when the UAC
    # dialog's localized text does not contain an English "cancel" message.
    param([System.Exception]$Exception)

    if (-not $Exception) { return $false }
    if ($Exception.Message -match '(?i)cancel|denied|aborted') { return $true }
    try { return (($Exception.HResult -band 0xFFFF) -eq 1223) }
    catch { return $false }
}

function Start-ElevatedSystemExport {
    param([string]$DestinationBase)

    $capturePower = [bool]$Script:Config.Backup.SystemSettings
    $capturePrinters = [bool]$Script:Config.Backup.Printers
    if ($Script:IsAdmin -or -not $Script:Config.Export.RequestAdministratorPrivileges -or (-not $capturePower -and -not $capturePrinters)) { return }

    # UAC receives only a completed package path. The helper has no access to
    # user-data capture routines, so profile-scoped data remains normal-user.
    $logsPath = Join-Path $DestinationBase 'Logs'
    if (-not (Test-Path -LiteralPath $logsPath)) { New-Item -ItemType Directory -Path $logsPath -Force | Out-Null }
    $helperPath = Join-Path $logsPath 'Export-SystemSettings.elevated.ps1'
    $helperScript = @'
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [bool]$CapturePower = $true,
    [bool]$CapturePrinters = $true
)
$ErrorActionPreference = 'Continue'
$logsPath = Join-Path $PackagePath 'Logs'
$settingsPath = Join-Path $PackagePath 'Settings'
$printersPath = Join-Path $PackagePath 'Printers'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$logPath = Join-Path $logsPath 'AdminExportLog.txt'
function Write-Audit([string]$Message) { Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" }
function Save-JsonAtomically([string]$Path, [object]$Data) {
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $temporaryPath = Join-Path $folder (".$([IO.Path]::GetFileName($Path)).$PID.$([guid]::NewGuid().ToString('N')).tmp")
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Data | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($temporaryPath, $Path, $null) }
            catch {
                [IO.File]::Copy($temporaryPath, $Path, $true)
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}
function Publish-Artifact([string]$TemporaryPath, [string]$FinalPath) {
    if (-not (Test-Path -LiteralPath $FinalPath)) {
        [IO.File]::Move($TemporaryPath, $FinalPath)
        return
    }
    $backupPath = "$FinalPath.preElevated.$PID.bak"
    try {
        [IO.File]::Replace($TemporaryPath, $FinalPath, $backupPath, $true)
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Keep the original package until the replacement is ready. If a
        # redirected drive does not support File.Replace, restore it on any
        # move failure rather than leaving no printer/power artifact behind.
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $FinalPath -Destination $backupPath -ErrorAction Stop
        try {
            Move-Item -LiteralPath $TemporaryPath -Destination $FinalPath -ErrorAction Stop
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            if (-not (Test-Path -LiteralPath $FinalPath) -and (Test-Path -LiteralPath $backupPath)) {
                Move-Item -LiteralPath $backupPath -Destination $FinalPath -ErrorAction SilentlyContinue
            }
            throw
        }
    }
}
function New-ProvenanceEntry([bool]$Attempted, [bool]$CapturedWithAdministratorRights, [string]$Status, [string]$Detail) {
    return [PSCustomObject]@{
        Attempted = $Attempted
        CapturedWithAdministratorRights = $CapturedWithAdministratorRights
        Status = $Status
        Detail = $Detail
        UpdatedAt = (Get-Date).ToString('o')
    }
}
function Update-Provenance([ValidateSet('Power', 'PrintBrm')][string]$Artifact, [bool]$Attempted, [string]$Status, [string]$Detail) {
    try {
        $provenancePath = Join-Path $settingsPath 'SystemExport.json'
        $provenance = $null
        if (Test-Path -LiteralPath $provenancePath) {
            try { $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json } catch { Write-Audit "Existing system-export provenance could not be read: $($_.Exception.Message)" }
        }
        if (-not $provenance) {
            $provenance = [PSCustomObject]@{
                SchemaVersion = 1; AdminExportRequested = $true; MainExporterWasAdministrator = $false; UpdatedAt = (Get-Date).ToString('o')
                Power = New-ProvenanceEntry $false $false 'NotAttempted' 'No full power-plan export was attempted.'
                PrintBrm = New-ProvenanceEntry $false $false 'NotAttempted' 'No PrintBRM export was attempted.'
            }
        }
        foreach ($property in @(
            @{ Name = 'SchemaVersion'; Value = 1 },
            @{ Name = 'AdminExportRequested'; Value = $true },
            @{ Name = 'MainExporterWasAdministrator'; Value = $false },
            @{ Name = 'UpdatedAt'; Value = (Get-Date).ToString('o') }
        )) {
            if (-not $provenance.PSObject.Properties[$property.Name]) { $provenance | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
        }
        if (-not $provenance.PSObject.Properties[$Artifact]) {
            $provenance | Add-Member -NotePropertyName $Artifact -NotePropertyValue (New-ProvenanceEntry $false $false 'NotAttempted' "No $Artifact export was attempted.")
        }
        $provenance.AdminExportRequested = $true
        $provenance.UpdatedAt = (Get-Date).ToString('o')
        $provenance.$Artifact = New-ProvenanceEntry $Attempted $true $Status $Detail
        Save-JsonAtomically -Path $provenancePath -Data $provenance
    }
    catch { Write-Audit "Could not update $Artifact provenance: $($_.Exception.Message)" }
}

$resultPath = Join-Path $logsPath 'AdminExportResult.json'
$result = [ordered]@{
    StartedAt = (Get-Date).ToString('o')
    CompletedAt = $null
    Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Power = [ordered]@{ Requested = $CapturePower; Attempted = $false; Status = 'Skipped'; Detail = 'Not selected for elevated export.' }
    PrintBrm = [ordered]@{ Requested = $CapturePrinters; Attempted = $false; Status = 'Skipped'; Detail = 'Not selected for elevated export.' }
}

if (-not $result.Elevated) {
    $result.Power.Status = 'Denied'; $result.PrintBrm.Status = 'Denied'
    $result.Power.Detail = 'Administrator privileges were not available.'; $result.PrintBrm.Detail = 'Administrator privileges were not available.'
    $result.CompletedAt = (Get-Date).ToString('o')
    Save-JsonAtomically -Path $resultPath -Data ([PSCustomObject]$result)
    Write-Audit 'Administrator helper started without elevation; no artifacts were changed.'
    exit 1
}

if ($CapturePower) {
    $result.Power.Attempted = $true
    $temporaryPowerFile = $null
    try {
        $settingsFile = Join-Path $settingsPath 'SystemSettings.json'
        $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        if ($settings.PowerScheme -notmatch '([0-9a-fA-F-]{36})') { throw 'The active power-scheme GUID is missing from SystemSettings.json.' }
        $powerFile = Join-Path $settingsPath 'PowerScheme.pow'
        $temporaryPowerFile = Join-Path $settingsPath "PowerScheme.elevated.$PID.pow"
        Remove-Item -LiteralPath $temporaryPowerFile -Force -ErrorAction SilentlyContinue
        $powerOutput = & powercfg /export $temporaryPowerFile $matches[1] 2>&1
        $powerExitCode = $LASTEXITCODE
        $powerOutput | Add-Content -LiteralPath $logPath
        if ($powerExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPowerFile) -or (Get-Item -LiteralPath $temporaryPowerFile).Length -eq 0) { throw "powercfg /export failed (exit $powerExitCode)." }
        Publish-Artifact -TemporaryPath $temporaryPowerFile -FinalPath $powerFile
        $temporaryPowerFile = $null
        $result.Power.Status = 'Succeeded'; $result.Power.Detail = "Full power plan captured with administrator rights (exit $powerExitCode)."
        Update-Provenance -Artifact Power -Attempted $true -Status Succeeded -Detail $result.Power.Detail
        Write-Audit $result.Power.Detail
    }
    catch {
        $result.Power.Status = 'Failed'; $result.Power.Detail = "Elevated power export failed: $($_.Exception.Message)"
        Update-Provenance -Artifact Power -Attempted $true -Status Failed -Detail $result.Power.Detail
        Write-Audit $result.Power.Detail
    }
    finally { if ($temporaryPowerFile) { Remove-Item -LiteralPath $temporaryPowerFile -Force -ErrorAction SilentlyContinue } }
}

if ($CapturePrinters) {
    $result.PrintBrm.Attempted = $true
    $temporaryPrinterFile = $null
    try {
        $printBrmCandidates = @()
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $printBrmCandidates += (Join-Path $env:WINDIR 'Sysnative\spool\tools\PrintBrm.exe') }
        $printBrmCandidates += (Join-Path $env:WINDIR 'System32\spool\tools\PrintBrm.exe')
        $printBrm = $printBrmCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $printBrm) { throw 'PrintBRM.exe was not found.' }
        if (-not (Test-Path -LiteralPath $printersPath)) { New-Item -ItemType Directory -Path $printersPath -Force | Out-Null }
        $printerExport = Join-Path $printersPath 'Printers.printerExport'
        $temporaryPrinterFile = Join-Path $printersPath "Printers.elevated.$PID.printerExport"
        Remove-Item -LiteralPath $temporaryPrinterFile -Force -ErrorAction SilentlyContinue
        $arguments = @('-B', '-F', $temporaryPrinterFile)
        if (-not [bool]::Parse('{INCLUDE_DRIVERS}')) { $arguments += '-NOBIN' }
        & $printBrm @arguments 2>&1 | Tee-Object -LiteralPath (Join-Path $logsPath 'printbrm_backup_elevated.log') | Out-Null
        $printBrmExitCode = $LASTEXITCODE
        if ($printBrmExitCode -ne 0 -or -not (Test-Path -LiteralPath $temporaryPrinterFile) -or (Get-Item -LiteralPath $temporaryPrinterFile).Length -eq 0) { throw "PrintBRM backup failed (exit $printBrmExitCode)." }
        Publish-Artifact -TemporaryPath $temporaryPrinterFile -FinalPath $printerExport
        $temporaryPrinterFile = $null
        $result.PrintBrm.Status = 'Succeeded'; $result.PrintBrm.Detail = "PrintBRM package captured with administrator rights (exit $printBrmExitCode)."
        Update-Provenance -Artifact PrintBrm -Attempted $true -Status Succeeded -Detail $result.PrintBrm.Detail
        Write-Audit $result.PrintBrm.Detail
    }
    catch {
        $result.PrintBrm.Status = 'Failed'; $result.PrintBrm.Detail = "Elevated PrintBRM export failed: $($_.Exception.Message)"
        Update-Provenance -Artifact PrintBrm -Attempted $true -Status Failed -Detail $result.PrintBrm.Detail
        Write-Audit $result.PrintBrm.Detail
    }
    finally { if ($temporaryPrinterFile) { Remove-Item -LiteralPath $temporaryPrinterFile -Force -ErrorAction SilentlyContinue } }
}

$result.CompletedAt = (Get-Date).ToString('o')
$failed = (($CapturePower -and $result.Power.Status -ne 'Succeeded') -or ($CapturePrinters -and $result.PrintBrm.Status -ne 'Succeeded'))
Save-JsonAtomically -Path $resultPath -Data ([PSCustomObject]$result)
Write-Audit (if ($failed) { 'Scoped administrator export completed with one or more failures.' } else { 'Scoped administrator export completed successfully.' })
exit $(if ($failed) { 1 } else { 0 })
'@
    $helperScript = $helperScript -replace '\{INCLUDE_DRIVERS\}', $Script:Config.IncludePrinterDrivers.ToString().ToLowerInvariant()
    $helperScript | Set-Content -LiteralPath $helperPath -Encoding UTF8
    try {
        $scopeLabel = switch ("$capturePower/$capturePrinters") { 'True/True' { 'PrintBRM and full power-plan capture' }; 'True/False' { 'full power-plan capture' }; default { 'PrintBRM capture' } }
        Write-Host "    Requesting administrator approval for $scopeLabel..." -ForegroundColor Cyan
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -PackagePath `"$DestinationBase`" -CapturePower:$($capturePower.ToString().ToLowerInvariant()) -CapturePrinters:$($capturePrinters.ToString().ToLowerInvariant())"
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $arguments -ErrorAction Stop
        if ($process.ExitCode -ne 0) { throw "Elevated helper exited with code $($process.ExitCode). Review Logs\\AdminExportLog.txt." }
        if ($capturePower) { Add-Result -Category 'Settings' -Item 'Power Scheme (elevated)' -Status 'Success' -Details 'Complete plan captured by scoped elevated helper' }
        if ($capturePrinters) {
            Add-Result -Category 'Printers' -Item 'Printer Migration File (elevated)' -Status 'Success' -Details 'Created by scoped elevated helper; see printbrm_backup_elevated.log'
            Write-Status 'Printer migration file' 'OK' 'created by elevated helper'
        }
        Write-Log "Scoped elevated $scopeLabel completed." -Level Success
    }
    catch {
        if (Test-UacElevationCancelled -Exception $_.Exception) {
            # The requested UAC retry did not run, but the normal user-context
            # export remains valid. Surface a real error without preventing the
            # remaining package artifacts, report, and import helpers from
            # being generated.
            $cancelledMessage = "Administrator printer and power export was enabled, but UAC elevation was cancelled. The export will continue with the standard-user artifacts."
            Write-Log "$cancelledMessage $($_.Exception.Message)" -Level Error
            Add-Result -Category 'System Export' -Item "Elevated $scopeLabel" -Status 'Error' -Details $cancelledMessage
            Write-Error -Message $cancelledMessage -ErrorAction Continue
        }
        else {
            Write-Log "Scoped elevated export did not complete: $($_.Exception.Message)" -Level Warning
            Add-Result -Category 'System Export' -Item "Elevated $scopeLabel" -Status 'Warning' -Details $_.Exception.Message
        }
    }
    finally { Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue }
}
# ============================================================================
# BROWSER DATA
# ============================================================================

# Browser handling separates portable data (bookmarks and an operator-approved
# password CSV) from protected profile state.  Windows user-protection keys are
# tied to the original account, so the module never pretends that copying a raw
# database is equivalent to restoring credentials on another computer.

function Convert-ChromeBookmarksToHtml {
    # Convert Chromium's JSON bookmark tree into Netscape bookmark HTML, which
    # Chrome, Edge, and Firefox can import.  Names and URLs are HTML-escaped.
    param(
        [string]$JsonPath,
        [string]$HtmlPath
    )
    
    try {
        $bookmarksJson = Get-Content $JsonPath -Raw | ConvertFrom-Json
        
        $html = @"
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
"@
        
        function Process-BookmarkFolder {
            param($folder, $indent = "    ")
            
            $result = ""
            
            if ($folder.children) {
                foreach ($child in $folder.children) {
                    if ($child.type -eq "folder") {
                        $result += "$indent<DT><H3>$(Out-HtmlEncoded $child.name)</H3>`n"
                        $result += "$indent<DL><p>`n"
                        $result += (Process-BookmarkFolder -folder $child -indent "$indent    ")
                        $result += "$indent</DL><p>`n"
                    }
                    elseif ($child.type -eq "url") {
                        $result += "$indent<DT><A HREF=`"$(Out-HtmlEncoded $child.url)`">$(Out-HtmlEncoded $child.name)</A>`n"
                    }
                }
            }
            
            return $result
        }
        
        # Chrome can have several root folders (bookmark bar, other/mobile
        # bookmarks, reading list, managed folders, etc.).  Enumerating them
        # instead of hard-coding two roots preserves every bookmark Chrome
        # exposes in the profile file.
        $rootLabels = @{
            bookmark_bar = "Bookmarks Bar"
            other        = "Other Bookmarks"
            synced       = "Mobile Bookmarks"
        }
        foreach ($rootProperty in $bookmarksJson.roots.PSObject.Properties) {
            $folder = $rootProperty.Value
            if (-not $folder -or -not $folder.children) { continue }

            $label = if ($rootLabels.ContainsKey($rootProperty.Name)) {
                $rootLabels[$rootProperty.Name]
            }
            elseif ($folder.name) {
                $folder.name
            }
            else {
                $rootProperty.Name
            }

            $html += "    <DT><H3>$(Out-HtmlEncoded $label)</H3>`n"
            $html += "    <DL><p>`n"
            $html += (Process-BookmarkFolder -folder $folder -indent "        ")
            $html += "    </DL><p>`n"
        }
        
        $html += "</DL><p>"
        
        $html | Out-File $HtmlPath -Encoding UTF8
        return $true
    }
    catch {
        Write-Log "Error converting bookmarks to HTML: $_" -Level Warning
        return $false
    }
}

function Get-ChromeProfileDirectories {
    param([string]$UserDataPath)

    if (-not (Test-Path -LiteralPath $UserDataPath)) { return @() }

    # The profile names Chrome creates on Windows are Default and Profile N.
    # Guest/System profiles are intentionally not exported as personal data.
    return @(Get-ChildItem -LiteralPath $UserDataPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" } |
        Sort-Object Name)
}

function Request-BrowserClose {
    # Browser databases may be locked.  Ask the operator to close the relevant
    # process and give them a chance to retry before falling back to a manual
    # task rather than copying an inconsistent live database.
    param(
        [string]$ProcessName,
        [string]$DisplayName
    )

    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $true }

    Write-Host ""
    Write-Host "  $DisplayName is open. Waiting up to 10 seconds for it to close; copying will continue afterward." -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 750
        $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) { return $true }
    } while ((Get-Date) -lt $deadline)

    Write-Log "$DisplayName is still running; some active database files may be unavailable or inconsistent" -Level Warning
    Add-ManualTask -Task "Verify $DisplayName profile export" -Reason "$DisplayName was open during export" -Instructions "Close $DisplayName and run the export again before the old laptop is wiped if its current browser data is important."
    return $false
}

function Export-ChromeBookmarks {
    param(
        [string]$ChromeUserDataPath,
        [string]$BrowserPath
    )

    $bookmarkPath = Join-Path $BrowserPath "Chrome\Bookmarks"
    # Retain the small native bookmark store as well as the portable HTML.
    # The importer can copy this JSON file into a matching Chrome profile for
    # an automatic restore; the HTML remains the safe fallback when profiles
    # cannot be matched on the destination computer.
    $rawUserDataPath = Join-Path $BrowserPath "Chrome\ProfileBookmarks"
    $profiles = @(Get-ChromeProfileDirectories -UserDataPath $ChromeUserDataPath)
    $exported = 0
    $rawExported = 0

    foreach ($profile in $profiles) {
        $bookmarksJson = Join-Path $profile.FullName "Bookmarks"
        if (-not (Test-Path -LiteralPath $bookmarksJson)) { continue }

        $safeProfileName = $profile.Name -replace '[^a-zA-Z0-9_.-]', '_'
        $chromeHtml = Join-Path $bookmarkPath "Chrome_Bookmarks_$safeProfileName.html"
        if (-not (Test-Path -LiteralPath $bookmarkPath)) {
            New-Item -ItemType Directory -Path $bookmarkPath -Force | Out-Null
        }

        if (Convert-ChromeBookmarksToHtml -JsonPath $bookmarksJson -HtmlPath $chromeHtml) {
            $exported++
            try {
                $rawProfilePath = Join-Path $rawUserDataPath $profile.Name
                New-Item -ItemType Directory -Path $rawProfilePath -Force | Out-Null
                Copy-Item -LiteralPath $bookmarksJson -Destination (Join-Path $rawProfilePath "Bookmarks") -Force -ErrorAction Stop
                $rawExported++
            }
            catch {
                Write-Log "Could not retain native Chrome bookmarks for profile '$($profile.Name)': $_" -Level Warning
            }
            Write-Log "Chrome bookmarks exported for profile '$($profile.Name)'" -Level Success

        }
        else {
            Write-Log "Could not convert Chrome bookmarks for profile '$($profile.Name)'" -Level Warning
        }
    }

    if ($exported -gt 0) {
        $detail = "$exported Chrome profile(s) exported as HTML"
        if ($rawExported -gt 0) { $detail += "; $rawExported profile(s) available for automatic restore" }
        Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Success" -Details $detail
    }
    else {
        Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Skipped" -Details "No Chrome bookmark files found"
    }

    return $exported
}

function Invoke-ChromePasswordExportPrompt {
    param(
        [string]$BrowserPath,
        [bool]$CanLaunchChromeForOriginalUser,
        [bool]$HasProfileArchive
    )

    $passwordExportPath = Join-Path $BrowserPath "Chrome\PasswordExport"
    New-Item -ItemType Directory -Path $passwordExportPath -Force | Out-Null

    Write-Host ""
    Write-Host "  Chrome passwords are protected by Windows and cannot be restored by copying the profile." -ForegroundColor Yellow
    Write-Host "  Chrome's own export is the supported transfer method: it will request Windows authentication." -ForegroundColor Yellow
    Write-Host "  Save the resulting CSV only in: $passwordExportPath" -ForegroundColor Cyan

    $exportNow = Read-UserInput "  Open Chrome Password Manager now to export passwords? (Y/N)"
    if ($exportNow -notmatch '^[Yy]') {
        $reason = if ($HasProfileArchive) { 'Chrome passwords remain encrypted in the raw profile backup' } else { "Chrome passwords require Chrome's native export" }
        Add-ManualTask -Task "Export Chrome Passwords" -Reason $reason -Instructions @"
On the old laptop, while signed in as the original Windows user:
1. Open Chrome > Passwords and autofill > Google Password Manager > Settings.
2. Under Export passwords, select Download file and complete the Windows authentication prompt.
3. Save the CSV only to: $passwordExportPath
4. On the new laptop, import it in Google Password Manager > Settings > Import passwords, then delete the CSV.
"@
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "Native Chrome export declined"
        return
    }

    if (-not $CanLaunchChromeForOriginalUser) {
        Write-Log "Cannot safely launch Chrome for the original profile from an elevated alternate-user session" -Level Warning
        Write-Host "  Run the native Chrome export from the original user's desktop and use the path above." -ForegroundColor Yellow
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "Export is running under a different/elevated Windows user" -Instructions "Sign in as the original user, open Chrome's Google Password Manager > Settings > Export passwords, complete Windows authentication, and save the CSV to: $passwordExportPath"
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "Must be exported in original user's Windows session"
        return
    }

    try {
        Start-Process -FilePath 'chrome.exe' -ArgumentList '--new-window', 'chrome://password-manager/settings' -ErrorAction Stop
        Write-Host "  Complete Chrome's export, choose the folder shown above, then return here." -ForegroundColor Gray
        [void](Read-UserInput "  Press Enter after saving the CSV (S to skip)")
    }
    catch {
        Write-Log "Could not open Chrome Password Manager: $_" -Level Warning
        Write-Host "  Open Chrome manually and use the folder shown above." -ForegroundColor Yellow
    }

    $csvFiles = @(Get-ChildItem -LiteralPath $passwordExportPath -Filter "*.csv" -File -Force -ErrorAction SilentlyContinue)
    if ($csvFiles.Count -gt 0) {
        Write-Log "Chrome password CSV captured: $($csvFiles.Count) file(s)" -Level Success
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Success" -Details "$($csvFiles.Count) CSV file(s) captured; plaintext - protect transfer package"
    }
    else {
        Write-Log "No Chrome password CSV was found in the designated folder" -Level Warning
        Add-ManualTask -Task "Export Chrome Passwords" -Reason "No CSV was saved to the transfer package" -Instructions "Use Chrome's Google Password Manager > Settings > Export passwords, complete Windows authentication, and save the CSV to: $passwordExportPath"
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "No native Chrome password export captured"
    }
}

function Copy-BrowserData {
    # Orchestrate per-browser exports and preserve independent results.  A
    # failure in one browser must not suppress OneDrive processing or the other
    # browser stages.
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Capturing browser data..." -Level Info
    
    $browserPath = Join-Path $DestinationBase "BrowserData"
    if (-not (Test-Path $browserPath)) {
        New-Item -ItemType Directory -Path $browserPath -Force | Out-Null
    }
    
    $localAppData = $Script:OriginalAppDataLocal
    
    # ========== CHROME ==========
    # Chrome data is split across every profile under User Data.  Keep a raw
    # archive with common disposable cache directories excluded, then export each profile's
    # bookmarks into Chrome's portable HTML format for reliable import.
    $chromeUserDataPath = Join-Path $localAppData "Google\Chrome\User Data"
    if ($Script:Config.Backup.Chrome -eq 'Off') {
        Add-DisabledBackupResult -Item "Chrome" -Category "Browser"
    }
    elseif (Test-Path -LiteralPath $chromeUserDataPath) {
        [void](Export-ChromeBookmarks -ChromeUserDataPath $chromeUserDataPath -BrowserPath $browserPath)
        $includeChromeArchive = $Script:Config.Backup.Chrome -eq 'FullProfile'
        if ($includeChromeArchive) {
            # Keep the result: a partial copy while Chrome is open must never be
            # presented as a fully successful profile archive.
            $chromeClosed = Request-BrowserClose -ProcessName "chrome" -DisplayName "Google Chrome"
            $chromeRawDestination = Join-Path $browserPath "Chrome\User Data"
            $chromeRawLog = Join-Path $DestinationBase "Logs\robocopy_chrome_user_data.log"
            $chromeCopyArgs = @($Script:Config.RobocopyArgs) + @(
                "/XD", "Cache", '"Code Cache"', "GPUCache", "GPUPersistentCache", "ShaderCache", "GrShaderCache", "DawnCache", "Crashpad", "Network", '"Safe Browsing Network"', '"Service Worker\\CacheStorage"', '"Service Worker\\ScriptCache"', "optimization_guide_model_store", "hyphen-data", "MEIPreload"
            )
            $result = Copy-WithProgress -Source $chromeUserDataPath -Destination $chromeRawDestination -FolderName "Chrome profile archive (all profiles)" -LogPath $chromeRawLog -RobocopyArgs $chromeCopyArgs
            if ($result.Status -eq "Success" -and $chromeClosed) {
                Write-Log "Chrome profile archive copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Success" -Details "$($result.FilesCopied) files; common caches excluded; credentials remain Windows-protected"
            }
            elseif ($result.Aborted) {
                Write-Log "Chrome profile archive copy stopped by operator" -Level Warning
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Skipped" -Details "Stopped by operator; partial files may remain and can be resumed by rerunning the export"
            }
            else {
                $detail = if (-not $chromeClosed) { "Chrome was open; active profile databases may be incomplete. Close Chrome and rerun before wiping the old laptop." } else { "Check robocopy_chrome_user_data.log" }
                Write-Log "Chrome profile archive copy completed with warnings" -Level Warning
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Warning" -Details $detail
            }
        }
        else {
            Write-Log "Chrome raw profile archive omitted by Online policy; portable bookmarks and password export remain available" -Level Info
            Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Skipped" -Details "Online lean mode: bookmarks and optional native password CSV only"
        }

        if (-not $result -or -not $result.Aborted) {
            $canLaunchChromeForOriginalUser = (-not $Script:IsAdmin) -or ($Script:OriginalUserProfile -eq $env:USERPROFILE)
            $Script:DeferredChromePasswordExport = @{ BrowserPath = $browserPath; CanLaunchChromeForOriginalUser = $canLaunchChromeForOriginalUser; HasProfileArchive = $includeChromeArchive }
        }
    }
    else {
        Write-Log "Chrome not installed or no user data found" -Level Info
        Add-Result -Category "Browser" -Item "Chrome" -Status "Skipped" -Details "Not found"
    }
    
    # ========== FIREFOX PROFILE ==========
    if (-not $Script:Config.Backup.Firefox) {
        Add-DisabledBackupResult -Item "Firefox" -Category "Browser"
    }
    else {
    # Firefox stores the portable profile (bookmarks, history, extensions,
    # saved logins, settings, and open tabs) in Roaming AppData. Local AppData
    # holds companion profile data such as offline storage and cache metadata.
    # Copy both locations so the generated import script can restore Firefox
    # without requiring separate HTML/CSV exports.
    $firefoxRoamingSource = Join-Path $Script:OriginalAppDataRoaming "Mozilla\Firefox"
    $firefoxLocalSource = Join-Path $Script:OriginalAppDataLocal "Mozilla\Firefox"
    $firefoxPackagePath = Join-Path $browserPath "Firefox"
    $firefoxFound = $false

    # Unlike Chromium bookmark files, Firefox's SQLite databases and key
    # material are not safe to capture while the process still owns them.
    # Do not create a package that looks successful but contains a torn or
    # locked Firefox profile; the operator can close Firefox and rerun.
    $firefoxClosed = Request-BrowserClose -ProcessName "firefox" -DisplayName "Firefox"

    if ($firefoxClosed -and (Test-Path $firefoxRoamingSource)) {
        $firefoxFound = $true
        $firefoxRoamingDest = Join-Path $firefoxPackagePath "Roaming"
        $firefoxRoamingLog = Join-Path $DestinationBase "Logs\robocopy_firefox_roaming.log"
        $result = Copy-WithProgress -Source $firefoxRoamingSource `
                                    -Destination $firefoxRoamingDest `
                                    -FolderName "Firefox profile (Roaming)" `
                                    -LogPath $firefoxRoamingLog `
                                    -RobocopyArgs $Script:Config.RobocopyArgs

        if ($result.Status -eq "Success") {
            Write-Log "Firefox roaming profile copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Success" -Details "$($result.FilesCopied) files; bookmarks, history, logins, extensions, and settings"
        }
        elseif ($result.Aborted) {
            Write-Log "Firefox roaming profile copy stopped by operator" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
        }
        else {
            Write-Log "Firefox roaming profile copy completed with warnings" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Warning" -Details "Check robocopy_firefox_roaming.log"
        }
    }

    if ($firefoxClosed -and (Test-Path $firefoxLocalSource)) {
        $firefoxFound = $true
        $firefoxLocalDest = Join-Path $firefoxPackagePath "Local"
        $firefoxLocalLog = Join-Path $DestinationBase "Logs\robocopy_firefox_local.log"
        # Local Firefox data is largely disposable cache. Preserve profile
        # metadata and offline data, but skip the cache trees that otherwise
        # dominate both the export and the later ZIP operation.
        $firefoxLocalArgs = @($Script:Config.RobocopyArgs) + @("/XD", "cache2", "startupCache", "shader-cache", "thumbnails")
        $result = Copy-WithProgress -Source $firefoxLocalSource `
                                    -Destination $firefoxLocalDest `
                                    -FolderName "Firefox data (Local)" `
                                    -LogPath $firefoxLocalLog `
                                    -RobocopyArgs $firefoxLocalArgs

        if ($result.Status -eq "Success") {
            Write-Log "Firefox local data copied: $($result.FilesCopied) files" -Level Success
            Add-Result -Category "Browser" -Item "Firefox Local Data" -Status "Success" -Details "$($result.FilesCopied) files"
        }
        elseif ($result.Aborted) {
            Write-Log "Firefox local data copy stopped by operator" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Local Data" -Status "Skipped" -Details "Stopped by operator; partial files may remain"
        }
        else {
            Write-Log "Firefox local data copy completed with warnings" -Level Warning
            Add-Result -Category "Browser" -Item "Firefox Local Data" -Status "Warning" -Details "Check robocopy_firefox_local.log"
        }
    }

    if ($firefoxClosed -and -not $firefoxFound) {
        Write-Log "Firefox not installed or no profile data found" -Level Info
        Add-Result -Category "Browser" -Item "Firefox" -Status "Skipped" -Details "Not found"
    }
    elseif (-not $firefoxClosed) {
        Write-Log "Firefox export skipped because Firefox is still running" -Level Warning
        Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Skipped" -Details "Firefox must be closed; rerun the export to capture a consistent profile"
    }

    }

    # ========== MICROSOFT EDGE ==========
    # Edge uses the same Chromium profile layout as Chrome.  The previous
    # implementation looked only in Default and exported only HTML, leaving
    # Profile N favorites with nothing the import script could restore.  Keep
    # the portable HTML copies and also preserve each raw Bookmarks file so
    # the generated importer can restore matching Edge profiles automatically.
    if (-not $Script:Config.Backup.Edge) {
        Add-DisabledBackupResult -Item "Microsoft Edge" -Category "Browser"
        return
    }

    $edgeUserDataPath = Join-Path $localAppData "Microsoft\Edge\User Data"
    if (Test-Path -LiteralPath $edgeUserDataPath) {
        [void](Request-BrowserClose -ProcessName "msedge" -DisplayName "Microsoft Edge")
        $edgeProfiles = @(Get-ChromeProfileDirectories -UserDataPath $edgeUserDataPath)
        $edgeBookmarkPath = Join-Path $browserPath "Edge\Bookmarks"
        $exportedEdgeProfiles = 0

        foreach ($profile in $edgeProfiles) {
            $bookmarksJson = Join-Path $profile.FullName "Bookmarks"
            if (-not (Test-Path -LiteralPath $bookmarksJson)) { continue }

            $safeProfileName = $profile.Name -replace '[^a-zA-Z0-9_.-]', '_'
            if (-not (Test-Path -LiteralPath $edgeBookmarkPath)) {
                New-Item -ItemType Directory -Path $edgeBookmarkPath -Force | Out-Null
            }

            $edgeHtml = Join-Path $edgeBookmarkPath "Edge_Bookmarks_$safeProfileName.html"
            if (Convert-ChromeBookmarksToHtml -JsonPath $bookmarksJson -HtmlPath $edgeHtml) {
                $rawProfileDestination = Join-Path $browserPath "Edge\User Data\$($profile.Name)"
                New-Item -ItemType Directory -Path $rawProfileDestination -Force | Out-Null
                Copy-Item -LiteralPath $bookmarksJson -Destination (Join-Path $rawProfileDestination "Bookmarks") -Force
                $exportedEdgeProfiles++
                Write-Log "Edge bookmarks exported for profile '$($profile.Name)'" -Level Success

                # Preserve the legacy filename for older import packages and
                # technicians who expect a single Default-profile HTML file.
                if ($profile.Name -eq "Default") {
                    Copy-Item -LiteralPath $edgeHtml -Destination (Join-Path $browserPath "Edge_Bookmarks.html") -Force
                }
            }
            else {
                Write-Log "Could not convert Edge bookmarks for profile '$($profile.Name)'" -Level Warning
            }
        }

        if ($exportedEdgeProfiles -gt 0) {
            Add-Result -Category "Browser" -Item "Edge Bookmarks" -Status "Success" -Details "$exportedEdgeProfiles Edge profile(s) exported; matching profiles can be restored automatically"
        }
        else {
            Add-Result -Category "Browser" -Item "Edge Bookmarks" -Status "Skipped" -Details "No Edge bookmark files found"
        }
    }
    else {
        Write-Log "Edge not installed or no user data found" -Level Info
        Add-Result -Category "Browser" -Item "Edge" -Status "Skipped" -Details "Not found"
    }
    
    # Edge syncs via Microsoft account
    Add-ManualTask -Task "Sign into Microsoft Edge" -Reason "Edge syncs via Microsoft account" -Instructions "Sign into Edge with Microsoft account to sync passwords and settings"
}

# ============================================================================
# ONEDRIVE
# ============================================================================

# OneDrive work is performed through filesystem state and documented shell
# commands.  Online mode deliberately avoids force-hydrating every cloud file;
# local mode may request hydration when the operator has chosen it.

function Set-OneDriveLocalSync {
    # Apply the selected hydration policy to the user's synchronized folders.
    # Errors are warnings because sign-in and tenant policy can legitimately
    # prevent a command from changing cloud-file availability.
    Write-Log "Checking OneDrive status..." -Level Info

    # Online mode: don't force-hydrate OneDrive. Pinning every file would
    # re-download the whole drive over the same constrained link we're trying
    # to spare. OneDrive re-syncs on the new machine after sign-in anyway.
    if ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.SkipOneDriveHydration) {
        Write-Log "Skipping OneDrive offline hydration (online mode)" -Level Info
        Write-Status "OneDrive Hydration" "SKIP" "online mode - re-syncs on new machine"
        Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Skipped" -Details "Skipped in online mode (re-syncs after sign-in)"
        Add-ManualTask -Task "Verify OneDrive after sign-in" -Reason "Offline hydration skipped in online transfer" -Instructions "On the new machine, sign into OneDrive and confirm files sync. No action needed on the old machine."
        return
    }

    # Find OneDrive folder
    $oneDrivePath = $env:OneDrive
    $oneDriveCommercial = $env:OneDriveCommercial
    
    $targetPath = if ($oneDriveCommercial) { $oneDriveCommercial } else { $oneDrivePath }
    
    if ($targetPath -and (Test-Path $targetPath)) {
        Write-Log "OneDrive path: $targetPath" -Level Info
        
        # Try to set files as "Always available on this device" using attrib
        # -U removes the "online-only" attribute, +P sets "pinned" (always available)
        Write-Log "Attempting to mark OneDrive files for offline availability..." -Level Info
        Write-Host "  This may take several minutes depending on the number of files..." -ForegroundColor Yellow
        
        $success = $false
        $errorMessage = ""
        
        try {
            # Count files first to give user an idea of scope
            $fileCount = (Get-ChildItem $targetPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-Log "Found approximately $fileCount files in OneDrive" -Level Info
            
            # Use attrib to remove cloud-only and set pinned
            # /S = process subfolders, /D = process directories too
            # attrib requires the file specification before /S and /D.  The
            # former order silently skipped hydration on some Windows builds.
            $attribResult = Start-Process -FilePath "attrib.exe" -ArgumentList "+P", "-U", "`"$targetPath\*`"", "/S", "/D" -Wait -PassThru -NoNewWindow -ErrorAction Stop
            
            if ($attribResult.ExitCode -eq 0) {
                $success = $true
                Write-Log "OneDrive files marked for offline availability" -Level Success
                Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Success" -Details "Files marked for download (~$fileCount files)"
                
                # Add note that download may still be in progress
                Add-ManualTask -Task "Verify OneDrive Download Complete" -Reason "Files are downloading in background" -Instructions @"
Files have been marked for offline availability but may still be downloading.
1. Check the OneDrive icon in system tray for sync status
2. Wait for sync to complete before disconnecting from network
3. Verify important files are available by checking for green checkmarks
"@
            }
            else {
                $errorMessage = "attrib command returned exit code $($attribResult.ExitCode)"
            }
        }
        catch {
            $errorMessage = $_.Exception.Message
        }
        
        if (-not $success) {
            Write-Log "Could not automatically set OneDrive offline: $errorMessage" -Level Warning
            Add-Result -Category "OneDrive" -Item "Offline Sync" -Status "Manual" -Details "Automatic method failed"
            
            Add-ManualTask -Task "OneDrive - Make Files Available Offline" -Reason "Automatic method failed: $errorMessage" -Instructions @"
1. Open File Explorer and navigate to: $targetPath
2. Press Ctrl+A to select all files/folders
3. Right-click and select 'Always keep on this device'
4. Wait for sync to complete (check OneDrive tray icon)
5. Verify files show green checkmarks before proceeding
"@
        }
    }
    else {
        Write-Log "OneDrive not configured" -Level Warning
        Add-Result -Category "OneDrive" -Item "Sync Status" -Status "Skipped" -Details "OneDrive not found"
    }
}

# ============================================================================
# IMPORT SCRIPT GENERATOR
# ============================================================================

# This module has two execution layers.  New-ImportScript emits the normal
# user-context importer as a here-string, while New-AdminImportScript emits a
# separate elevated helper.  Code inside those strings executes later on the
# replacement computer and therefore cannot depend on the export process's
# variables or functions.
#
# The generated importer restores user data first, then settings and browsers,
# updates the handoff report, and invokes the helper last.  That ordering keeps
# privileged work narrowly limited to operations Windows requires to elevate.

function New-ImportScript {
    # Materialize the import script by expanding export-time settings into a
    # self-contained template.  Runtime checks still verify source paths before
    # copying because the package may be moved between computers.
    param(
        [string]$DestinationBase,
        [hashtable]$Settings
    )
    
    Write-Log "Generating import script..." -Level Info
    
    $importScript = @'
<#
.SYNOPSIS
    STO Building Group Laptop Transfer - Import Script
    Generated automatically by Export-LaptopData.ps1

.DESCRIPTION
    This script restores user data and settings to the new laptop.
    Run this script after initial Windows setup is complete.
    
    What this script restores:
    - User folders (Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites)
    - Additional custom folders from user profile
    - OCS Documents (if present)
    - Bluebeam settings and preferences
    - Lotus Notes data (if present)
    - Outlook email signatures
    - Quick Access pins
    - Personalization settings (colors, dark mode, taskbar)
    - Power scheme settings (with admin rights)
    - Lid close actions (AC and DC)
    - Mapped network drives
    - Desktop wallpaper
    - Chrome/Edge bookmarks (HTML files for manual import)
    - Chrome password-export CSV files (manual native Chrome import)
    - Chrome profile archive retained for recovery/reference (not auto-restored)
    - Firefox profile data (bookmarks, logins, extensions, settings, and history)

.PARAMETER TestMode
    Runs in test mode - shows what would be restored without making changes

.NOTES
    Generated: {TIMESTAMP}
    Original User: {USERNAME}
    Original Computer: {COMPUTERNAME}
    
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File ".\Import-LaptopData.ps1"
#>

#Requires -Version 5.1

param(
    [switch]$TestMode
)

$ErrorActionPreference = "Continue"

# This JSON is embedded from Import.PostImportLaunch in the development
# configuration.  Keep the launch inventory there so future app changes do
# not require editing this generated-script template.
$postImportLaunchConfig = $null
try {
    $postImportLaunchConfig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{POST_IMPORT_LAUNCH_CONFIG_BASE64}')) | ConvertFrom-Json
}
catch {
    Write-Host "  Post-import launch configuration could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
}
$appComparisonExcludePatterns = @()
try {
    # Materialize before wrapping so Windows PowerShell does not retain the
    # JSON array as one System.Object[] "pattern". Casting that aggregate to a
    # regex matches ordinary app names and suppresses every missing-app warning.
    $appComparisonExcludePatternInventory = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{APP_COMPARISON_EXCLUDE_PATTERNS_BASE64}')) | ConvertFrom-Json
    $appComparisonExcludePatterns = @($appComparisonExcludePatternInventory)
}
catch { }

# ============================================================================
# CONSOLE ENCODING & THEME
# ============================================================================
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$Script:AnsiEnabled = $false
try { if ($Host.UI.SupportsVirtualTerminal) { $Script:AnsiEnabled = $true } } catch { }

$Script:Theme = @{
    Esc        = [char]27
    AccentFrom = @(0, 212, 255)
    AccentTo   = @(124, 58, 237)
    Width      = 60
    Glyphs     = @{ OK = [char]0x2713; WARN = [char]0x26A0; FAIL = [char]0x2717; INFO = [char]0x2139; SKIP = [char]0x2022; ARROW = [char]0x25B8 }
    Box        = @{ TL=[char]0x2554; TR=[char]0x2557; BL=[char]0x255A; BR=[char]0x255D; H=[char]0x2550; V=[char]0x2551 }
    Bar        = @{ Full=[char]0x2588; Light=[char]0x2591 }
    Spinner    = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)
}

function Convert-ToGradient {
    param([string]$Text, [int[]]$From = $Script:Theme.AccentFrom, [int[]]$To = $Script:Theme.AccentTo)
    if (-not $Script:AnsiEnabled) { return $Text }
    $e = $Script:Theme.Esc; $len = $Text.Length
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $len; $i++) {
        $t = if ($len -le 1) { 0 } else { $i / ($len - 1) }
        $r = [int]($From[0] + ($To[0]-$From[0])*$t); $g = [int]($From[1] + ($To[1]-$From[1])*$t); $b = [int]($From[2] + ($To[2]-$From[2])*$t)
        [void]$sb.Append("$e[38;2;$r;$g;${b}m$($Text[$i])")
    }
    [void]$sb.Append("$e[0m"); return $sb.ToString()
}

function Write-Banner {
    param([string]$Title, [string]$Subtitle = "", [int]$Width = $Script:Theme.Width)
    $bx = $Script:Theme.Box; $inner = $Width - 2
    Write-Host ""
    Write-Host (Convert-ToGradient "$($bx.TL)$([string]$bx.H * $inner)$($bx.TR)")
    $pad = [math]::Max(0, $inner - $Title.Length); $l = [math]::Floor($pad/2); $r = $pad - $l
    Write-Host "$($bx.V)$(' ' * $l)$(Convert-ToGradient $Title)$(' ' * $r)$($bx.V)"
    if ($Subtitle) {
        $sp = [math]::Max(0, $inner - $Subtitle.Length); $sl = [math]::Floor($sp/2); $sr = $sp - $sl
        Write-Host "$($bx.V)$(' ' * $sl)" -NoNewline
        Write-Host $Subtitle -ForegroundColor DarkGray -NoNewline
        Write-Host "$(' ' * $sr)$($bx.V)"
    }
    Write-Host (Convert-ToGradient "$($bx.BL)$([string]$bx.H * $inner)$($bx.BR)")
    Write-Host ""
}

function Write-Section {
    param([string]$Title, [int]$Width = $Script:Theme.Width)
    $rule = [string]$Script:Theme.Box.H * [math]::Max(4, ($Width - $Title.Length - 4))
    Write-Host ""
    Write-Host "$($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White -NoNewline
    Write-Host "  $(Convert-ToGradient $rule)"
}

function Write-Status {
    param([string]$Label, [ValidateSet("OK","WARN","FAIL","INFO","SKIP")][string]$Status, [string]$Detail = "", [int]$LabelWidth = 34)
    $glyph = $Script:Theme.Glyphs[$Status]
    $color = @{ OK="Green"; WARN="Yellow"; FAIL="Red"; INFO="Cyan"; SKIP="DarkGray" }[$Status]
    $padded = if ($Label.Length -gt $LabelWidth) { $Label.Substring(0,$LabelWidth) } else { $Label.PadRight($LabelWidth) }
    Write-Host "  $glyph " -ForegroundColor $color -NoNewline
    Write-Host $padded -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host " $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
}

function Write-KeyValue {
    param([string]$Key, [string]$Value, [int]$KeyWidth = 18)
    Write-Host "    $($Key.PadRight($KeyWidth))" -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor White
}

function Write-SummaryCard {
    param([int]$Success, [int]$Warning, [int]$Errors, [int]$Skipped, [string]$Duration, [int]$Width = $Script:Theme.Width)
    $bx = $Script:Theme.Box; $inner = $Width - 2
    Write-Host ""
    Write-Host (Convert-ToGradient "$($bx.TL)$([string]$bx.H * $inner)$($bx.TR)")
    $rows = @(@{L="Successful";V=$Success;C="Green"},@{L="Warnings";V=$Warning;C="Yellow"},@{L="Errors";V=$Errors;C="Red"},@{L="Skipped";V=$Skipped;C="DarkGray"})
    foreach ($row in $rows) {
        $line = "  $($Script:Theme.Glyphs.ARROW) $($row.L)"; $val = "$($row.V)"
        $pad = $inner - $line.Length - $val.Length - 2
        Write-Host "$($bx.V)" -NoNewline
        Write-Host $line -ForegroundColor $row.C -NoNewline
        Write-Host "$(' ' * [math]::Max(1,$pad))$val  " -ForegroundColor $row.C -NoNewline
        Write-Host "$($bx.V)"
    }
    $durLine = "  Duration: $Duration"
    Write-Host "$($bx.V)$(' ' * $inner)$($bx.V)"
    Write-Host "$($bx.V)" -NoNewline
    Write-Host $durLine -ForegroundColor DarkGray -NoNewline
    Write-Host "$(' ' * [math]::Max(0,$inner - $durLine.Length))$($bx.V)"
    Write-Host (Convert-ToGradient "$($bx.BL)$([string]$bx.H * $inner)$($bx.BR)")
    Write-Host ""
}

function Write-StoLogo {
    $l = @("  ___ _____ ___    "," / __|_   _/ _ \   "," \__ \ | || (_) |  "," |___/ |_| \___/   ")
    Write-Host ""
    foreach ($line in $l) { Write-Host (Convert-ToGradient $line) }
    Write-Host "  BUILDING GROUP" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================================
# INITIALIZATION
# ============================================================================

$Script:Results = @{
    StartTime = Get-Date
    Actions = @()
    Warnings = @()
    Errors = @()
    ManualTasks = @()
    OriginalUser = "{USERNAME}"
    OriginalComputer = "{COMPUTERNAME}"
}

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$userProfile = $env:USERPROFILE
$logFile = Join-Path $scriptPath "ImportLog.txt"
$importLotusNotes = [bool]::Parse('{IMPORT_LOTUS_NOTES}')
$compareInstalledApps = [bool]::Parse('{IMPORT_APP_COMPARISON}')
$reviewAppDataCandidates = [bool]::Parse('{IMPORT_APPDATA_REVIEW}')
# Firefox is restored whenever its independently-selected backup payload is
# present. There is no separate import toggle to keep in sync.
$importFirefox = $true
$deletePrintBrmAfterImport = [bool]::Parse('{DELETE_PRINTBRM_AFTER_IMPORT}')
$enableAdminHelper = [bool]::Parse('{ENABLE_ADMIN_HELPER}')
$isOnlineTransfer = [bool]::Parse('{IS_ONLINE_TRANSFER}')
$browserDataPath = Join-Path $scriptPath 'BrowserData'

function Read-UserInput {
    param([string]$Prompt)
    Write-Host $Prompt
    return Read-Host '  > '
}

function Invoke-OnlineChromePasswordImport {
    # Guide the operator through Chrome's supported CSV import flow.  The CSV is
    # sensitive plaintext, so this code never attempts to decrypt browser data.
    $passwordExportPath = Join-Path $browserDataPath 'Chrome\PasswordExport'
    $csvs = @(Get-ChildItem -LiteralPath $passwordExportPath -Filter '*.csv' -File -Force -ErrorAction SilentlyContinue)
    if (-not $csvs.Count) { return }
    Write-Host '  Chrome password export detected - this CSV is plaintext. Keep the transfer package secure.' -ForegroundColor Yellow
    foreach ($csv in $csvs) { Write-Host "    File: $($csv.FullName)" -ForegroundColor Gray }
    if ($TestMode) { Add-Result -Category 'Browser' -Item 'Chrome Passwords' -Status 'TestMode' -Details "$($csvs.Count) CSV file(s); native import required"; return }
    if ((Read-UserInput '  Open Chrome Password Manager now? (Y/N)') -match '^[Yy]') {
        try { Start-Process 'chrome.exe' 'chrome://password-manager/settings' -ErrorAction Stop } catch { Write-Log "Could not open Chrome Password Manager automatically: $_" -Level Warning }
    }
    if ((Read-UserInput '  After importing and verifying passwords, type DELETE to permanently remove the plaintext CSV (or press Enter to keep it)') -ceq 'DELETE') {
        try { foreach ($csv in $csvs) { Remove-Item -LiteralPath $csv.FullName -Force -ErrorAction Stop }; Add-Result -Category 'Browser' -Item 'Chrome Passwords' -Status 'Success' -Details 'Imported through Chrome and deleted from transfer package' }
        catch { Add-Result -Category 'Browser' -Item 'Chrome Passwords' -Status 'Warning' -Details 'CSV may still be present; remove it securely after import' }
    }
    else { Add-Result -Category 'Browser' -Item 'Chrome Passwords' -Status 'Manual' -Details 'Import in Chrome, verify, then securely delete plaintext CSV' }
    $Script:ChromePasswordImportHandled = $true
}

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logFile -Value $logEntry
    
    switch ($Level) {
        "Success" { Write-Host "  [OK] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "  [!] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "  [X] $Message" -ForegroundColor Red }
        default   { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

function Add-Result {
    param([string]$Category, [string]$Item, [string]$Status, [string]$Details = "")
    # Keep the importer ledger on the same four status groups used by its
    # terminal receipt and the final handoff report.
    if ($Status -eq 'Empty') { $Status = 'Skipped' }
    $Script:Results.Actions += [PSCustomObject]@{
        Category = $Category
        Item = $Item
        Status = $Status
        Details = $Details
    }
}

function Test-RobocopySuccess {
    # Robocopy codes below 8 represent success or acceptable differences; 8+
    # indicates that one or more files failed to copy.
    param([int]$ExitCode, [string]$LogPath)
    
    # Robocopy exit codes: 0-7 = success levels, 8+ = errors
    # Code 8 = some files failed (often junction points)
    # Code 9 = 8 + 1 (errors but also files copied)
    
    if ($ExitCode -lt 8) { return "Success" }
    
    if ($ExitCode -in @(8, 9)) {
        if ($LogPath -and (Test-Path $LogPath)) {
            $logContent = Get-Content $LogPath -Raw
            if ($logContent -match "Files :\s+(\d+)") {
                $filesCopied = [int]$Matches[1]
                if ($filesCopied -gt 0) { return "Success" }
            }
        }
        return "Warning"
    }
    
    return "Error"
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Add-ManualTask {
    param([string]$Task, [string]$Reason, [string]$Instructions = "")
    $Script:Results.ManualTasks += [PSCustomObject]@{
        Task = $Task
        Reason = $Reason
        Instructions = $Instructions
    }
}

function Format-RemainingTime {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) {
        return "calculating..."
    }

    $remaining = [int][math]::Ceiling($Seconds)
    if ($remaining -lt 60) { return "$remaining sec" }
    if ($remaining -lt 3600) { return "$([math]::Floor($remaining / 60)) min $($remaining % 60) sec" }
    return "$([math]::Floor($remaining / 3600)) hr $([math]::Floor(($remaining % 3600) / 60)) min"
}

function Copy-WithProgress {
    # Import-side copy wrapper that converts robocopy output into the same
    # structured result vocabulary used by the export phase.
    param(
        [string]$Source,
        [string]$Destination,
        [string]$FolderName,
        [string]$LogPath
    )
    
    # Get source size and file count
    $sourceMeasure = Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
        Measure-Object -Property Length -Sum
    $totalFiles = $sourceMeasure.Count
    $totalSize = [long]$(if ($null -eq $sourceMeasure.Sum) { 0 } else { $sourceMeasure.Sum })
    
    if ($totalFiles -eq 0) {
        return @{ ExitCode = 0; FilesCopied = 0; Status = "Empty" }
    }
    
    # Create destination if needed
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    
    Write-Host ""
    Write-Host "  $($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $FolderName -ForegroundColor White -NoNewline
    Write-Host "  $(Format-FileSize $totalSize) / $totalFiles files" -ForegroundColor DarkGray
    
    $startTime = Get-Date
    $spinIndex = 0
    
    # Do not attach PowerShell script blocks to Robocopy's asynchronous output
    # events. Windows PowerShell 5.1 invokes those callbacks on worker threads
    # without a runspace and can terminate the import host immediately.
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "robocopy.exe"
    $pinfo.Arguments = "`"$Source`" `"$Destination`" /E /XJ /Z /R:2 /W:3 /MT:8 /BYTES"
    $pinfo.RedirectStandardOutput = $false
    $pinfo.RedirectStandardError = $false
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    if (-not $process.Start()) { return @{ ExitCode = -1; FilesCopied = 0; BytesCopied = 0; Status = "Warning" } }
    # Render only from the owning runspace. This keeps the display responsive
    # without destination rescans or unsafe background callbacks.
    # Reserve room for the size and duration fields in an 80-column console.
    # A 34-character completion bar wraps onto a second line.
    $progressBarWidth = 16
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 750
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]; $spinIndex++
        $elapsed = (Get-Date) - $startTime
        Write-Host "`r    $spin Copying $totalFiles files ($(Format-FileSize $totalSize))  elapsed $([math]::Round($elapsed.TotalSeconds, 0)) sec   " -NoNewline
    }
    
    $exitCode = $process.ExitCode
    $logLines = @("Source: $Source", "Destination: $Destination", "Robocopy exit code: $exitCode")
    $logLines | Set-Content -LiteralPath $LogPath -Encoding UTF8
    
    # A missing exit code means the worker failed or Robocopy did not start;
    # never convert that failure into a successful import.
    if ($null -eq $exitCode) { $exitCode = 16 }
    
    # Final stats
    $copiedSize = $totalSize
    $copiedFiles = $totalFiles
    
    $elapsed = (Get-Date) - $startTime
    $progressBar = [string]$Script:Theme.Bar.Full * $progressBarWidth
    Write-Host "`r$(' ' * 140)" -NoNewline
    Write-Host "`r    " -NoNewline
    Write-Host "$($Script:Theme.Glyphs.OK) " -ForegroundColor Green -NoNewline
    Write-Host $progressBar -ForegroundColor Green -NoNewline
    Write-Host " 100%  $(Format-FileSize $copiedSize)  in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    
    $copySucceeded = $exitCode -lt 8
    if (-not $copySucceeded) {
        # The destination may contain files from an earlier attempt. Do not
        # report those pre-existing files as part of a failed copy.
        $copiedFiles = 0
        $copiedSize = [long]0
    }
    $status = if ($copySucceeded) { "Success" } else { "Warning" }
    
    return @{
        ExitCode = $exitCode
        FilesCopied = $copiedFiles
        BytesCopied = $copiedSize
        Status = $status
    }
}

# ============================================================================
# HEADER
# ============================================================================

# A log-capturing or remoted host may not expose RawUI. Do not let the
# cosmetic screen clear prevent an import.
try { Clear-Host -ErrorAction Stop } catch { }
Write-StoLogo
Write-Banner -Title "Laptop Transfer  -  Import Tool"
Write-Host "  From (source)" -ForegroundColor DarkGray
Write-KeyValue "User" "{USERNAME}"
Write-KeyValue "Computer" "{COMPUTERNAME}"
Write-Host ""
Write-Host "  To (this machine)" -ForegroundColor DarkGray
Write-KeyValue "User" "$env:USERNAME"
Write-KeyValue "Computer" "$env:COMPUTERNAME"
Write-Host ""

if ($TestMode) {
    Write-Host "  ** TEST MODE - No changes will be made **" -ForegroundColor Magenta
    Write-Host ""
}

# Same computer warning
if (-not $TestMode -and $env:COMPUTERNAME -eq "{COMPUTERNAME}") {
    Write-Host "  WARNING: Running on the SAME computer as export!" -ForegroundColor Yellow
    Write-Host "  This may overwrite existing files." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-UserInput "  Continue anyway? (Y/N)"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "`n  Import cancelled." -ForegroundColor Gray
        exit
    }
    Write-Host ""
}

# ============================================================================
# USER-CONTEXT SAFETY CHECK
# ============================================================================

$isActuallyAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isActuallyAdmin -and -not $TestMode) {
    Write-Host "  Import-LaptopData.ps1 must run as the signed-in standard user." -ForegroundColor Yellow
    Write-Host "  Close this window and run QuickImport.bat normally." -ForegroundColor Gray
    exit 1
}
$isAdmin = $false # This script intentionally never performs elevated work.
Write-Host "  Running in signed-in user context; user data and connections restore here." -ForegroundColor DarkGray

if ($isOnlineTransfer) { Invoke-OnlineChromePasswordImport }

Write-Host ""
Write-Host "  Starting import..." -ForegroundColor Cyan
Write-Host "  ----------------------------------------" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# RESTORE USER FOLDERS
# ============================================================================

Write-Section "Restoring user folders"
Write-Host ""

$folders = @("Documents", "Desktop", "Downloads", "Pictures", "Videos", "Music", "Favorites", "Start Menu")
$logsPath = Join-Path $scriptPath "Logs"
if (-not (Test-Path $logsPath)) { New-Item -ItemType Directory -Path $logsPath -Force | Out-Null }

foreach ($folder in $folders) {
    $sourcePath = Join-Path $scriptPath "UserData\$folder"
    # Start Menu is a Roaming AppData location. Do not target the legacy
    # profile-root junction, which Windows may reject or redirect.
    $destPath = if ($folder -eq 'Start Menu') { Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu' } else { Join-Path $userProfile $folder }
    
    if (Test-Path $sourcePath) {
        $fileCount = (Get-ChildItem $sourcePath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        
        if ($fileCount -eq 0) {
            Write-Log "$folder - Empty (skipped)" -Level "Info"
            Add-Result -Category "User Folders" -Item $folder -Status "Skipped" -Details "No files to restore"
            continue
        }
        
        if ($TestMode) {
            Write-Log "$folder - Would restore $fileCount files" -Level "Info"
            Add-Result -Category "User Folders" -Item $folder -Status "TestMode" -Details "$fileCount files"
            continue
        }
        
        $logPath = Join-Path $logsPath "import_$folder.log"
        
        # Use progress copy
        $result = Copy-WithProgress -Source $sourcePath `
                                   -Destination $destPath `
                                   -FolderName $folder `
                                   -LogPath $logPath
        
        if ($result.Status -eq "Success") {
            Write-Log "$folder restored: $($result.FilesCopied) files, $(Format-FileSize $result.BytesCopied)" -Level "Success"
        }
        elseif ($result.Status -eq "Warning") {
            Write-Log "$folder - Completed with warnings" -Level "Warning"
        }
        else {
            Write-Log "$folder - $($result.Status)" -Level "Info"
        }
        Add-Result -Category "User Folders" -Item $folder -Status $result.Status -Details "$($result.FilesCopied) files"
        Write-Host ""
    }
    else {
        Write-Log "$folder - Not in transfer package" -Level "Info"
    }
}

# ============================================================================
# TASKBAR PINS AND DEFAULT-APP GUIDANCE
# ============================================================================


function Get-OneDriveDesktopPaths {
    # Return redirected, local, and Public Desktop roots used to find duplicate
    # shortcuts after restoring a profile into OneDrive.
    $paths = @()
    foreach ($root in @($env:OneDriveCommercial, $env:OneDrive)) {
        if ($root) {
            $candidate = Join-Path $root 'Desktop'
            if (Test-Path -LiteralPath $candidate) { $paths += $candidate }
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Get-ShortcutHash { param([string]$Path) try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return $null } }

function Send-ShortcutToRecycleBin {
    # Recycle only a confirmed duplicate shortcut, preserving a recovery path
    # and avoiding permanent deletion of user content.
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
}

function Remove-MicrosoftStoreTaskbarPin {
    param([string]$TaskbarPath)
    foreach ($file in @(Get-ChildItem -LiteralPath $TaskbarPath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Microsoft Store|WindowsStore' })) {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    }
    try {
        $appsFolder = (New-Object -ComObject Shell.Application).Namespace('shell:AppsFolder')
        $storeApp = $appsFolder.ParseName('Microsoft.WindowsStore_8wekyb3d8bbwe!App')
        $unpinVerb = @($storeApp.Verbs() | Where-Object { ($_.Name -replace '&', '') -match 'Unpin from taskbar|taskbarunpin' }) | Select-Object -First 1
        if ($unpinVerb) { $unpinVerb.DoIt() }
    } catch { }
}

function Initialize-DesktopRestoreInterop {
    # Load the COM interop used for shell/taskbar operations once; repeated
    # initialization is safe when the generated script is rerun.
    # Use Explorer's supported IFolderView positioning API. Registry ItemPos
    # values are retained only as a legacy-package fallback.
    if ('StoDesktopRestoreInterop' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class StoDesktopRestoreResult { public int Positioned { get; set; } public string[] Missing { get; set; } }
public static class StoDesktopRestoreInterop {
    const int SWC_DESKTOP = 8, SWFO_NEEDDISPATCH = 1;
    static object GetView() {
        dynamic app = Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")); dynamic windows = app.Windows;
        int hwnd = 0; object disp = windows.FindWindowSW(Type.Missing, Type.Missing, SWC_DESKTOP, ref hwnd, SWFO_NEEDDISPATCH);
        var provider = (IServiceProvider)disp; var service = new Guid("4c96be40-915c-11cf-99d3-00aa004ae837");
        var browser = (IShellBrowser)provider.QueryService(service, typeof(IShellBrowser).GUID); return browser.QueryActiveShellView();
    }
    public static StoDesktopRestoreResult Restore(string[] names, int[] xs, int[] ys, double scaleX, double scaleY, int sourceX, int sourceY, int destinationX, int destinationY) {
        var view = (IFolderView)GetView(); var view2 = (IFolderView2)view;
        var current = new Dictionary<string, IntPtr>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < view.ItemCount(); i++) { var item = view2.GetItem(i, typeof(IShellItem).GUID); var name = item.GetDisplayName(SIGDN.SIGDN_NORMALDISPLAY); if (!String.IsNullOrEmpty(name) && !current.ContainsKey(name)) current.Add(name, view.Item(i)); }
        var missing = new List<string>(); var positioned = 0;
        for (int i = 0; i < names.Length; i++) {
            IntPtr pidl; if (String.IsNullOrEmpty(names[i]) || !current.TryGetValue(names[i], out pidl)) { missing.Add(names[i] ?? "(unnamed)"); continue; }
            var point = new POINT { x = (int)Math.Round((xs[i] - sourceX) * scaleX + destinationX), y = (int)Math.Round((ys[i] - sourceY) * scaleY + destinationY) };
            view.SelectAndPositionItems(1, new IntPtr[] { pidl }, new POINT[] { point }, SVSIF.SVSI_POSITIONITEM); positioned++;
        }
        return new StoDesktopRestoreResult { Positioned = positioned, Missing = missing.ToArray() };
    }
    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IServiceProvider { [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService([MarshalAs(UnmanagedType.LPStruct)] Guid service, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); }
    [ComImport, Guid("000214E2-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IShellBrowser { void _VtblGap1_12(); [return: MarshalAs(UnmanagedType.IUnknown)] object QueryActiveShellView(); }
    [ComImport, Guid("cde725b0-ccc9-4519-917e-325d72fab4ce"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IFolderView { void _VtblGap1_3(); IntPtr Item(int index); int ItemCount(uint flags = 0); void _VtblGap2_3(); void GetItemPosition(IntPtr pidl, out POINT point); void _VtblGap1_4(); void SelectAndPositionItems(int count, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] IntPtr[] pidls, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex=0)] POINT[] points, SVSIF flags); }
    [ComImport, Guid("1af3a467-214f-4298-908e-06b03e0b39f9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IFolderView2 { void _VtblGap1_26(); IShellItem GetItem(int index, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); }
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IShellItem { [return: MarshalAs(UnmanagedType.IUnknown)] object BindToHandler(System.Runtime.InteropServices.ComTypes.IBindCtx context, [MarshalAs(UnmanagedType.LPStruct)] Guid bhid, [MarshalAs(UnmanagedType.LPStruct)] Guid riid); IShellItem GetParent(); [return: MarshalAs(UnmanagedType.LPWStr)] string GetDisplayName(SIGDN sigdn); }
    struct POINT { public int x; public int y; } enum SIGDN { SIGDN_NORMALDISPLAY } [Flags] enum SVSIF { SVSI_POSITIONITEM = 0x80 }
}
"@ -ErrorAction Stop
}

function Get-TaskbarUnpinVerb {
    param([object]$ShellItem)
    try {
        return @($ShellItem.Verbs() | Where-Object {
            ($_.Name -replace '&', '').Trim() -match 'Unpin from taskbar|taskbarunpin'
        }) | Select-Object -First 1
    }
    catch { return $null }
}

function Test-SourceTaskbarPin {
    param([object]$ShellItem, [object[]]$SourcePins)
    $itemName = [IO.Path]::GetFileNameWithoutExtension([string]$ShellItem.Name)
    $itemPath = [string]$ShellItem.Path
    $itemTarget = if ($itemPath) { [IO.Path]::GetFileName($itemPath) } else { '' }
    foreach ($pin in @($SourcePins)) {
        if ($pin.Name -match 'Microsoft Store|WindowsStore') { continue }
        $pinName = [IO.Path]::GetFileNameWithoutExtension([string]$pin.Name)
        $pinTarget = [string]$pin.TargetPath
        if ($itemName -and $pinName -and $itemName -ieq $pinName) { return $true }
        if ($itemPath -and $pinTarget -and $itemPath -ieq $pinTarget) { return $true }
        if ($itemTarget -and $pinTarget -and $itemTarget -ieq [IO.Path]::GetFileName($pinTarget)) { return $true }
    }
    return $false
}

function Remove-NonSourceTaskbarPins {
    param([object[]]$SourcePins)
    $removed = 0
    try {
        $appsFolder = (New-Object -ComObject Shell.Application).Namespace('shell:AppsFolder')
        $shellItems = $appsFolder.Items()
        for ($index = 0; $index -lt $shellItems.Count; $index++) {
            $shellItem = $shellItems.Item($index)
            if (Test-SourceTaskbarPin -ShellItem $shellItem -SourcePins $SourcePins) { continue }
            $unpinVerb = Get-TaskbarUnpinVerb -ShellItem $shellItem
            if ($unpinVerb) {
                try { $unpinVerb.DoIt(); $removed++ }
                catch { Write-Log "Could not remove unmatched taskbar app '$($shellItem.Name)': $($_.Exception.Message)" -Level 'Warning' }
            }
        }
    }
    catch { Write-Log "Could not enumerate shell taskbar pins for exact reconciliation: $($_.Exception.Message)" -Level 'Warning' }
    return $removed
}

# Desktop layout import was retired. Keep the taskbar and default-app routines
# below independent from packages created by earlier deployment versions.
if ($false) {
    try {
        $desktopLayout = Get-Content -LiteralPath $desktopLayoutFile -Raw | ConvertFrom-Json
        $count = @($desktopLayout.Shortcuts).Count
        if ($TestMode) {
            $shellCoordinateState = 'legacy shell-position fallback'
            if ($desktopLayout.DesktopItems -and @($desktopLayout.DesktopItems).Count) {
                try { Initialize-DesktopRestoreInterop; $shellCoordinateState = 'Explorer shell-coordinate restore' }
                catch { $shellCoordinateState = "Explorer shell-coordinate restore unavailable: $($_.Exception.Message)" }
            }
            Write-Log "Desktop layout - Would retain $count transferred shortcut(s) and use $shellCoordinateState" -Level 'Info'
            Add-Result -Category 'Desktop Layout' -Item 'Shortcut layout' -Status 'TestMode' -Details "$count shortcut(s); $shellCoordinateState; no changes made"
        }
        else {
            # Desktop files have already been restored with the Desktop folder.
            # Position matching visible shell items through Explorer itself so
            # the saved coordinates work across display resolutions.
            $positionValues = $desktopLayout.ShellPositionValues
            $positionRestored = 0
            $missingDesktopItems = @()
            $usedShellCoordinates = $false
            if ($desktopLayout.DesktopItems -and $desktopLayout.SourceWorkArea -and @($desktopLayout.DesktopItems).Count) {
                try {
                    Initialize-DesktopRestoreInterop
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                    $sourceArea = $desktopLayout.SourceWorkArea
                    $destinationArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                    if ([int]$sourceArea.Width -le 0 -or [int]$sourceArea.Height -le 0) { throw 'Source work-area dimensions are invalid.' }
                    $items = @($desktopLayout.DesktopItems)
                    $restoreResult = [StoDesktopRestoreInterop]::Restore(
                        [string[]]@($items | ForEach-Object { [string]$_.Name }),
                        [int[]]@($items | ForEach-Object { [int]$_.X }),
                        [int[]]@($items | ForEach-Object { [int]$_.Y }),
                        ([double]$destinationArea.Width / [double]$sourceArea.Width),
                        ([double]$destinationArea.Height / [double]$sourceArea.Height),
                        [int]$sourceArea.X, [int]$sourceArea.Y, [int]$destinationArea.X, [int]$destinationArea.Y
                    )
                    $positionRestored = [int]$restoreResult.Positioned
                    $missingDesktopItems = @($restoreResult.Missing)
                    $usedShellCoordinates = $true
                }
                catch { Write-Log "Desktop shell-coordinate restore unavailable: $($_.Exception.Message)" -Level 'Warning' }
            }
            if (-not $usedShellCoordinates -and $positionValues) {
                $desktopBagPath = 'HKCU:\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
                New-Item -Path $desktopBagPath -Force | Out-Null
                foreach ($property in $positionValues.PSObject.Properties) {
                    try { Set-ItemProperty -LiteralPath $desktopBagPath -Name $property.Name -Value ([Convert]::FromBase64String([string]$property.Value)) -Type Binary -ErrorAction Stop; $positionRestored++ }
                    catch { Write-Log "Desktop position value '$($property.Name)' could not be restored: $($_.Exception.Message)" -Level 'Warning' }
                }
                if ($positionRestored) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer.exe }
            }
            $layoutStatus = if ($positionRestored) { 'Success' } else { 'Skipped' }
            $layoutDetail = if ($positionRestored -and $usedShellCoordinates) { "$positionRestored desktop item(s) positioned through Explorer with destination-display scaling" } elseif ($positionRestored) { "$count desktop shortcut(s) restored; $positionRestored legacy shell position value(s) applied" } else { "$count shortcut(s) restored; source package has no usable desktop position state" }
            Add-Result -Category 'Desktop Layout' -Item 'Shortcut layout' -Status $layoutStatus -Details $layoutDetail
            if ($missingDesktopItems.Count) { Add-Result -Category 'Desktop Layout' -Item 'Unmatched desktop items' -Status 'Skipped' -Details "$($missingDesktopItems.Count) source item(s) were not present after restore: $(@($missingDesktopItems | Select-Object -First 5) -join ', ')" }
            # DesktopDirectory can itself be the OneDrive Desktop. Compare only
            # distinct roots; otherwise a shortcut compares equal to itself and
            # is incorrectly offered for recycling as a "duplicate".
            $localDesktops = @(
                [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory),
                (Join-Path $env:USERPROFILE 'Desktop')
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
            $candidates = @()
            foreach ($cloudDesktop in @(Get-OneDriveDesktopPaths)) {
                $cloudRoot = [IO.Path]::GetFullPath($cloudDesktop).TrimEnd([char]92)
                foreach ($localDesktop in $localDesktops) {
                    if ($cloudRoot -eq [IO.Path]::GetFullPath($localDesktop).TrimEnd([char]92)) { continue }
                foreach ($cloudShortcut in @(Get-ChildItem -LiteralPath $cloudDesktop -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.lnk', '.url') })) {
                    $localShortcut = Join-Path $localDesktop $cloudShortcut.Name
                    if (-not (Test-Path -LiteralPath $localShortcut)) { continue }
                    $cloudHash = Get-ShortcutHash $cloudShortcut.FullName; $localHash = Get-ShortcutHash $localShortcut
                    if ($cloudHash -and $cloudHash -eq $localHash) { $candidates += $cloudShortcut }
                }
                }
            }
            $candidates = @($candidates | Sort-Object FullName -Unique)
            if ($candidates.Count) {
                Write-Host '  Exact duplicate OneDrive Desktop shortcuts:' -ForegroundColor Yellow
                $candidates | ForEach-Object { Write-Host "    $($_.FullName)" -ForegroundColor Gray }
                $answer = Read-UserInput '  Send ALL listed duplicate shortcuts to the Recycle Bin? (Y/N)'
                if ($answer -match '^[Yy]') {
                    foreach ($candidate in $candidates) {
                        try { Send-ShortcutToRecycleBin -Path $candidate.FullName; Write-Log "OneDrive duplicate shortcut recycled: $($candidate.Name)" -Level 'Success' }
                        catch { Write-Log "Could not recycle OneDrive shortcut '$($candidate.Name)': $($_.Exception.Message)" -Level 'Warning' }
                    }
                    Add-Result -Category 'Desktop Layout' -Item 'OneDrive duplicate shortcuts' -Status 'Success' -Details "$($candidates.Count) selected exact duplicate(s) sent to Recycle Bin"
                } else { Add-Result -Category 'Desktop Layout' -Item 'OneDrive duplicate shortcuts' -Status 'Skipped' -Details "$($candidates.Count) candidate(s) retained by technician" }
            }
        }
    } catch { Write-Log "Desktop layout restore failed: $($_.Exception.Message)" -Level 'Warning'; Add-Result -Category 'Desktop Layout' -Item 'Shortcut layout' -Status 'Warning' -Details $_.Exception.Message }
}

# ============================================================================
# TASKBAR PINS AND DEFAULT-APP GUIDANCE
# ============================================================================

$taskbarLayoutFile = Join-Path $scriptPath 'Settings\TaskbarLayout.json'
$taskbarPackagePath = Join-Path $scriptPath 'Settings\TaskbarLayout'
if (Test-Path -LiteralPath $taskbarLayoutFile) {
    try {
        $taskbarLayout = Get-Content -LiteralPath $taskbarLayoutFile -Raw | ConvertFrom-Json
        $pinCount = @($taskbarLayout.Pins).Count
        if ($TestMode) { Write-Log "Taskbar layout - Would replace destination pins with $pinCount source pin(s), excluding Microsoft Store" -Level 'Info'; Add-Result -Category 'Taskbar Layout' -Item 'Pinned apps' -Status 'TestMode' -Details "$pinCount source pin(s); exact replacement" }
        elseif (Test-Path -LiteralPath $taskbarPackagePath) {
            $destinationPins = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
            New-Item -ItemType Directory -Path $destinationPins -Force | Out-Null
            $copied = 0; $skipped = 0; $removed = 0
            foreach ($destinationPin in @(Get-ChildItem -LiteralPath $destinationPins -File -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $destinationPin.FullName -Force -ErrorAction Stop; $removed++
            }
            foreach ($pin in @($taskbarLayout.Pins | Sort-Object Ordinal)) {
                if ($pin.Name -match 'Microsoft Store|WindowsStore') { continue }
                $sourcePin = Join-Path $taskbarPackagePath $pin.Name
                if (-not (Test-Path -LiteralPath $sourcePin)) {
                    $skipped++
                    Write-Log "Taskbar source pin payload missing: $($pin.Name)" -Level 'Warning'
                    Add-Result -Category 'Taskbar Layout' -Item $pin.Name -Status 'Skipped' -Details 'Source pin payload is missing from the transfer package'
                    continue
                }
                if ($pin.TargetPath -and -not (Test-Path -LiteralPath $pin.TargetPath) -and $pin.TargetPath -notmatch '^(shell:|explorer\.exe)') {
                    Write-Log "Taskbar app unavailable: $($pin.Name) -> $($pin.TargetPath)" -Level 'Warning'
                    Add-Result -Category 'Taskbar Layout' -Item $pin.Name -Status 'Skipped' -Details "Source app unavailable on destination: $($pin.TargetPath)"
                    $skipped++; continue
                }
                Copy-Item -LiteralPath $sourcePin -Destination (Join-Path $destinationPins $pin.Name) -ErrorAction Stop; $copied++
            }
            $taskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
            if ($taskbarLayout.TaskbandValues) {
                New-Item -Path $taskbandPath -Force | Out-Null
                foreach ($property in $taskbarLayout.TaskbandValues.PSObject.Properties) {
                    try { Set-ItemProperty -LiteralPath $taskbandPath -Name $property.Name -Value ([Convert]::FromBase64String([string]$property.Value)) -Type Binary -ErrorAction Stop }
                    catch { Write-Log "Taskbar order value '$($property.Name)' could not be restored: $($_.Exception.Message)" -Level 'Warning'; $skipped++ }
                }
            }
            Remove-MicrosoftStoreTaskbarPin -TaskbarPath $destinationPins
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Process explorer.exe
            Start-Sleep -Seconds 2
            $unmatchedPinsRemoved = Remove-NonSourceTaskbarPins -SourcePins @($taskbarLayout.Pins)
            Remove-MicrosoftStoreTaskbarPin -TaskbarPath $destinationPins
            Start-Sleep -Seconds 1
            $unmatchedPinsRemoved += Remove-NonSourceTaskbarPins -SourcePins @($taskbarLayout.Pins)
            Remove-MicrosoftStoreTaskbarPin -TaskbarPath $destinationPins
            $storeReintroduced = @(Get-ChildItem -LiteralPath $destinationPins -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Microsoft Store|WindowsStore' })
            if ($storeReintroduced.Count) {
                Write-Log 'Microsoft Store taskbar pin was reintroduced after removal; policy or imaging may be enforcing it.' -Level 'Warning'
                Add-Result -Category 'Taskbar Layout' -Item 'Microsoft Store' -Status 'Warning' -Details 'Pin was reintroduced after removal; policy or imaging may be enforcing it'
            }
            Add-Result -Category 'Taskbar Layout' -Item 'Pinned apps' -Status $(if ($skipped) { 'Warning' } else { 'Success' }) -Details "$copied restored in source order; $removed destination pin(s) removed; $unmatchedPinsRemoved reintroduced/default pin(s) unpinned; Microsoft Store unpinned; $skipped unavailable/order issue(s)"
        }
    } catch { Write-Log "Taskbar layout restore failed: $($_.Exception.Message)" -Level 'Warning'; Add-Result -Category 'Taskbar Layout' -Item 'Pinned apps' -Status 'Warning' -Details $_.Exception.Message }
}

$defaultAppsFile = Join-Path $scriptPath 'Settings\DefaultApps.json'
if (Test-Path -LiteralPath $defaultAppsFile) {
    try {
        $defaultApps = Get-Content -LiteralPath $defaultAppsFile -Raw | ConvertFrom-Json
        $guidePath = Join-Path $logsPath 'DefaultAppsRestoreGuide.txt'
        $guide = @('Default apps captured on the source computer', 'Windows protects per-user defaults; set these through Settings > Apps > Default apps.', '')
        $guide += @($defaultApps.Associations | Sort-Object Type, Name | ForEach-Object { "$($_.Type): $($_.Name) -> $($_.ProgId)" })
        $guide | Set-Content -LiteralPath $guidePath -Encoding UTF8
        if ($TestMode) { Add-Result -Category 'Default Apps' -Item 'Restore guide' -Status 'TestMode' -Details 'No Settings page opened' }
        else { $Script:OpenDefaultAppsAtCompletion = $true; Add-Result -Category 'Default Apps' -Item 'Restore guide' -Status 'Manual' -Details 'See the restore guide; Default apps will open at completion' }
    } catch { Write-Log "Default-app guidance failed: $($_.Exception.Message)" -Level 'Warning'; Add-Result -Category 'Default Apps' -Item 'Restore guide' -Status 'Warning' -Details $_.Exception.Message }
}

# Remaining folders from the optional entire-profile export. Standard user
# folders and AppData are intentionally absent here because their dedicated
# import stages already restored them.
$fullProfilePath = Join-Path $scriptPath 'UserData\FullProfile'
if (Test-Path -LiteralPath $fullProfilePath) {
    Write-Host ''
    Write-Host '  Restoring remaining user-profile content:' -ForegroundColor Gray
    foreach ($item in @(Get-ChildItem -LiteralPath $fullProfilePath -Force -ErrorAction SilentlyContinue)) {
        $destination = Join-Path $userProfile $item.Name
        if ($TestMode) {
            Add-Result -Category 'Entire User Profile' -Item $item.Name -Status 'TestMode' -Details 'Would restore'
        }
        elseif ($item.PSIsContainer) {
            $result = Copy-WithProgress -Source $item.FullName -Destination $destination -FolderName "Profile: $($item.Name)" -LogPath (Join-Path $logsPath "import_profile_$($item.Name).log")
            Add-Result -Category 'Entire User Profile' -Item $item.Name -Status $result.Status -Details "$($result.FilesCopied) files"
        }
        else {
            try { Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop; Add-Result -Category 'Entire User Profile' -Item $item.Name -Status 'Success' -Details 'Profile-root file restored' }
            catch { Add-Result -Category 'Entire User Profile' -Item $item.Name -Status 'Warning' -Details $_.Exception.Message }
        }
    }
}

# Additional folders
$additionalPath = Join-Path $scriptPath "UserData\Additional"
if (Test-Path $additionalPath) {
    Write-Host ""
    Get-ChildItem $additionalPath -Directory | ForEach-Object {
        $destPath = Join-Path $userProfile $_.Name
        $fileCount = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        
        if ($TestMode) {
            Write-Log "$($_.Name) - Would restore $fileCount files" -Level "Info"
            Add-Result -Category "Additional Folders" -Item $_.Name -Status "TestMode" -Details "$fileCount files"
        }
        else {
            $logPath = Join-Path $logsPath "import_$($_.Name).log"
            
            $result = Copy-WithProgress -Source $_.FullName `
                                       -Destination $destPath `
                                       -FolderName "Additional: $($_.Name)" `
                                       -LogPath $logPath
            
            if ($result.Status -eq "Success") {
                Write-Log "$($_.Name) restored: $($result.FilesCopied) files" -Level "Success"
            }
            else {
                Write-Log "$($_.Name) - $($result.Status)" -Level "Info"
            }
            Add-Result -Category "Additional Folders" -Item $_.Name -Status $result.Status -Details "$($result.FilesCopied) files"
            Write-Host ""
        }
    }
}

# Loose files from profile root
$profileRootPath = Join-Path $scriptPath "UserData\ProfileRoot"
if (Test-Path $profileRootPath) {
    $looseFiles = Get-ChildItem $profileRootPath -File -ErrorAction SilentlyContinue
    if ($looseFiles -and $looseFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "  Loose files from profile root:" -ForegroundColor Gray
        
        $copiedCount = 0
        foreach ($file in $looseFiles) {
            $destFile = Join-Path $userProfile $file.Name
            
            if ($TestMode) {
                Write-Log "  $($file.Name) - Would restore to profile root" -Level "Info"
                $copiedCount++

            }
            else {
                try {
                    # Check if file already exists
                    if (Test-Path $destFile) {
                        $backupName = "$($file.BaseName)_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')$($file.Extension)"
                        $backupPath = Join-Path $userProfile $backupName
                        Move-Item $destFile -Destination $backupPath -Force
                        Write-Log "  Backed up existing: $($file.Name)" -Level "Info"
                    }
                    Copy-Item $file.FullName -Destination $destFile -Force
                    Write-Log "  $($file.Name) - Restored" -Level "Success"
                    $copiedCount++
                }
                catch {
                    Write-Log "  $($file.Name) - Failed: $_" -Level "Warning"
                }
            }
        }
        Add-Result -Category "Loose Files" -Item "Profile Root" -Status "Success" -Details "$copiedCount file(s)"
    }
}

# OCS Documents (from C: drive)
$ocsPath = Join-Path $scriptPath "UserData\OCS Documents"
if (Test-Path $ocsPath) {
    Write-Host ""
    Write-Host "  OCS Documents folder found in transfer package" -ForegroundColor Gray
    
    $ocsDest = "C:\OCS Documents"
    
    if ($TestMode) {
        Write-Log "OCS Documents - Would restore to C:\OCS Documents" -Level "Info"
        Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "TestMode" -Details "Would restore to C:\OCS Documents"
    }
    else {
        $logPath = Join-Path $logsPath "import_ocs_documents.log"
        $result = Copy-WithProgress -Source $ocsPath `
                                   -Destination $ocsDest `
                                   -FolderName "OCS Documents (C:\)" `
                                   -LogPath $logPath
        if ($result.Status -eq "Success") {
            Write-Log "OCS Documents restored: $($result.FilesCopied) files" -Level "Success"
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status "Success" -Details "$($result.FilesCopied) files to C:\OCS Documents"
        }
        else {
            Write-Log "OCS Documents - $($result.Status)" -Level "Warning"
            Add-Result -Category "Special Folders" -Item "OCS Documents" -Status $result.Status -Details "Check log for details"
        }
        Write-Host ""
    }
}

Write-Host ""

# ============================================================================
# RESTORE APPDATA
# ============================================================================

Write-Section "Restoring application data"
Write-Host ""

# Bluebeam Software - Roaming AppData
$bluebeamSource = Join-Path $scriptPath "AppData\Bluebeam"
if (Test-Path $bluebeamSource) {
    $bluebeamDest = Join-Path $env:APPDATA "Bluebeam Software"
    if ($TestMode) {
        Write-Log "Bluebeam Software - Would restore" -Level "Info"
        Add-Result -Category "AppData" -Item "Bluebeam Software" -Status "TestMode"
    }
    else {
        $logPath = Join-Path $logsPath "import_bluebeam.log"
        $result = Copy-WithProgress -Source $bluebeamSource `
                                   -Destination $bluebeamDest `
                                   -FolderName "Bluebeam Software (Roaming)" `
                                   -LogPath $logPath
        if ($result.Status -eq "Success") {
            Write-Log "Bluebeam Software restored: $($result.FilesCopied) files" -Level "Success"
            Add-Result -Category "AppData" -Item "Bluebeam Software" -Status "Success" -Details "$($result.FilesCopied) files"
        }
        else {
            Write-Log "Bluebeam Software - $($result.Status)" -Level "Warning"
            Add-Result -Category "AppData" -Item "Bluebeam Software" -Status $result.Status
        }
        Write-Host ""
    }
}

# Lotus Notes - Local AppData
$lotusSource = Join-Path $scriptPath "AppData\Lotus_Local"
if ((Test-Path $lotusSource) -and -not $importLotusNotes) {
    Write-Log "Lotus Notes import disabled by configuration" -Level "Info"
    Add-Result -Category "AppData" -Item "Lotus Notes" -Status "Skipped" -Details "Disabled by configuration"
}
elseif (Test-Path $lotusSource) {
    $lotusDest = Join-Path $env:LOCALAPPDATA "Lotus"
    if ($TestMode) {
        Write-Log "Lotus Notes - Would restore" -Level "Info"
        Add-Result -Category "AppData" -Item "Lotus Notes" -Status "TestMode"
    }
    else {
        $logPath = Join-Path $logsPath "import_lotus.log"
        $result = Copy-WithProgress -Source $lotusSource `
                                   -Destination $lotusDest `
                                   -FolderName "Lotus Notes (Local AppData)" `
                                   -LogPath $logPath
        if ($result.Status -eq "Success") {
            Write-Log "Lotus Notes restored: $($result.FilesCopied) files" -Level "Success"
            Add-Result -Category "AppData" -Item "Lotus Notes" -Status "Success" -Details "$($result.FilesCopied) files"
        }
        else {
            Write-Log "Lotus Notes - $($result.Status)" -Level "Warning"
            Add-Result -Category "AppData" -Item "Lotus Notes" -Status $result.Status
        }
        Write-Host ""
    }
}

# On-Screen Takeoff - Roaming and Local AppData
# These are intentionally restored only when present in the package.  The
# application itself should be installed before opening it on the new PC.
$ostAppDataCopies = @(
    @{ Source = (Join-Path $scriptPath 'AppData\OnScreenTakeoff'); Destination = (Join-Path $env:APPDATA 'On Center Software\On-Screen Takeoff'); Name = 'On-Screen Takeoff (Roaming)' },
    @{ Source = (Join-Path $scriptPath 'AppData\OnScreenTakeoff_Local'); Destination = (Join-Path $env:LOCALAPPDATA 'On Center Software\On-Screen Takeoff'); Name = 'On-Screen Takeoff (Local)' }
)
foreach ($ostCopy in $ostAppDataCopies) {
    if (-not (Test-Path -LiteralPath $ostCopy.Source)) { continue }
    if ($TestMode) {
        Write-Log "$($ostCopy.Name) - Would restore" -Level 'Info'
        Add-Result -Category 'AppData' -Item $ostCopy.Name -Status 'TestMode'
        continue
    }

    $ostLogName = if ($ostCopy.Name -match 'Local') { 'import_onscreen_takeoff_local.log' } else { 'import_onscreen_takeoff_roaming.log' }
    $result = Copy-WithProgress -Source $ostCopy.Source -Destination $ostCopy.Destination -FolderName $ostCopy.Name -LogPath (Join-Path $logsPath $ostLogName)
    if ($result.Status -eq 'Success') {
        Write-Log "$($ostCopy.Name) restored: $($result.FilesCopied) files" -Level 'Success'
        Add-Result -Category 'AppData' -Item $ostCopy.Name -Status 'Success' -Details "$($result.FilesCopied) files"
    }
    else {
        Write-Log "$($ostCopy.Name) - $($result.Status)" -Level 'Warning'
        Add-Result -Category 'AppData' -Item $ostCopy.Name -Status $result.Status -Details 'Check log for details'
    }
    Write-Host ''
}

# Signatures
$sigSource = Join-Path $scriptPath "AppData\Signatures"
if (Test-Path $sigSource) {
    $sigDest = Join-Path $env:APPDATA "Microsoft\Signatures"
    if ($TestMode) {
        Write-Log "Outlook signatures - Would restore" -Level "Info"
        Add-Result -Category "AppData" -Item "Signatures" -Status "TestMode"
    }
    else {
        if (-not (Test-Path $sigDest)) { New-Item -ItemType Directory -Path $sigDest -Force | Out-Null }
        $robocopyResult = robocopy $sigSource $sigDest /E /Z /R:2 /W:3 /NP /NDL /NFL
        $exitCode = $LASTEXITCODE
        if ($exitCode -lt 8) {
            Write-Log "Outlook signatures restored" -Level "Success"
            Add-Result -Category "AppData" -Item "Signatures" -Status "Success"
        }
        else {
            Write-Log "Outlook signatures - Copy had issues (exit code: $exitCode)" -Level "Warning"
            Add-Result -Category "AppData" -Item "Signatures" -Status "Warning" -Details "Exit code: $exitCode"
        }
    }
}

# Quick Access - Restore by copying the database file back
$qaSource = Join-Path $scriptPath "AppData\QuickAccess"
if (Test-Path $qaSource) {
    $qaFile = Join-Path $qaSource "f01b4d95cf55d32a.automaticDestinations-ms"
    
    if ($TestMode) {
        Write-Log "Quick Access - Would restore database file" -Level "Info"
        if (Test-Path $qaFile) {
            Write-Log "  File found, would copy to AutomaticDestinations" -Level "Info"
        }
        Add-Result -Category "AppData" -Item "Quick Access" -Status "TestMode"
    }
    else {
        if (Test-Path $qaFile) {
            Write-Log "Restoring Quick Access database..." -Level "Info"
            
            $qaDest = Join-Path $env:APPDATA "Microsoft\Windows\Recent\AutomaticDestinations"
            $destFile = Join-Path $qaDest "f01b4d95cf55d32a.automaticDestinations-ms"
            
            try {
                # Ensure destination folder exists
                if (-not (Test-Path $qaDest)) {
                    New-Item -ItemType Directory -Path $qaDest -Force | Out-Null
                }
                
                # Check if Explorer is using the file - close Explorer windows
                Write-Host "    Closing File Explorer to unlock Quick Access database..." -ForegroundColor Yellow
                
                # Close all Explorer windows (but not the shell itself)
                $explorerWindows = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" }
                foreach ($explorerWindow in @($explorerWindows)) {
                    try { [void]$explorerWindow.CloseMainWindow() } catch { }
                }
                Start-Sleep -Milliseconds 750
                # Do not kill explorer.exe before the copy: it owns the shell.
                
                # Try to copy the file
                $copySuccess = $false
                $attempts = 0
                $maxAttempts = 3
                
                while (-not $copySuccess -and $attempts -lt $maxAttempts) {
                    $attempts++
                    try {
                        # Backup existing file if present
                        if (Test-Path $destFile) {
                            $backupFile = "$destFile.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                            Move-Item $destFile -Destination $backupFile -Force -ErrorAction SilentlyContinue
                        }
                        
                        Copy-Item $qaFile -Destination $destFile -Force -ErrorAction Stop
                        $copySuccess = $true
                    }
                    catch {
                        if ($attempts -lt $maxAttempts) {
                            Write-Host "    File locked, waiting and retrying..." -ForegroundColor Gray
                            Start-Sleep -Seconds 2
                        }
                    }
                }
                
                if ($copySuccess) {
                    Write-Log "Quick Access database restored" -Level "Success"
                    
                    # Restart Explorer to reload Quick Access
                    Write-Host "    Restarting Explorer to apply changes..." -ForegroundColor Yellow
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                    # Explorer restarts automatically, but just in case:
                    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
                        Start-Process explorer
                    }
                    Start-Sleep -Seconds 1
                    
                    Write-Log "Explorer restarted - Quick Access should be restored" -Level "Success"
                    Add-Result -Category "AppData" -Item "Quick Access" -Status "Success" -Details "Database restored, Explorer restarted"
                    
                    Write-Host ""
                    Write-Host "    NOTE: If some pinned folders don't appear, they may reference" -ForegroundColor Yellow
                    Write-Host "    paths that don't exist on this computer (different username, etc.)" -ForegroundColor Yellow
                    Write-Host "    You can manually re-pin those folders." -ForegroundColor Yellow
                }
                else {
                    Write-Log "Quick Access: Could not copy file (locked by system)" -Level "Warning"
                    Add-Result -Category "AppData" -Item "Quick Access" -Status "Warning" -Details "File locked - manual restore needed"
                    
                    Write-Host ""
                    Write-Host "  [!] Could not restore automatically. Manual steps:" -ForegroundColor Yellow
                    Write-Host "      1. Close ALL File Explorer windows" -ForegroundColor Gray
                    Write-Host "      2. Copy file from: $qaFile" -ForegroundColor Gray
                    Write-Host "      3. To: $qaDest" -ForegroundColor Gray
                    Write-Host "      4. Restart Explorer (Task Manager > Windows Explorer > Restart)" -ForegroundColor Gray
                }
            }
            catch {
                Write-Log "Quick Access restore failed: $_" -Level "Error"
                Add-Result -Category "AppData" -Item "Quick Access" -Status "Error" -Details $_.Exception.Message
                
                Write-Host ""
                Write-Host "  [!] Quick Access restore failed. See RESTORE_INSTRUCTIONS.txt" -ForegroundColor Yellow
                $instructionFile = Join-Path $qaSource "RESTORE_INSTRUCTIONS.txt"
                if (Test-Path $instructionFile) {
                    Write-Host "      Instructions: $instructionFile" -ForegroundColor Gray
                }
            }
        }
        else {
            Write-Log "Quick Access: Database file not found in backup" -Level "Warning"
            Add-Result -Category "AppData" -Item "Quick Access" -Status "Skipped" -Details "No backup file found"
        }
    }
}

Write-Host ""

# Additional AppData selected in Advanced mode during export.
$additionalAppDataPath = Join-Path $scriptPath 'AppData\Additional'
if (Test-Path -LiteralPath $additionalAppDataPath) {
    foreach ($area in @('Roaming', 'Local')) {
        $areaPath = Join-Path $additionalAppDataPath $area
        $destinationRoot = if ($area -eq 'Roaming') { $env:APPDATA } else { $env:LOCALAPPDATA }
        foreach ($folder in @(Get-ChildItem -LiteralPath $areaPath -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($TestMode) {
                Add-Result -Category 'Additional AppData' -Item "$area\$($folder.Name)" -Status 'TestMode' -Details 'Would restore'
                continue
            }
            $result = Copy-WithProgress -Source $folder.FullName -Destination (Join-Path $destinationRoot $folder.Name) -FolderName "Additional AppData: $area\$($folder.Name)" -LogPath (Join-Path $logsPath "import_additional_appdata_$area`_$($folder.Name).log")
            Add-Result -Category 'Additional AppData' -Item "$area\$($folder.Name)" -Status $result.Status -Details "$($result.FilesCopied) files"
        }
    }
}

# ============================================================================
# RESTORE SYSTEM SETTINGS
# ============================================================================

Write-Section "Applying system settings"
Write-Host ""

$settingsFile = Join-Path $scriptPath "Settings\SystemSettings.json"
$settingsData = $null

if (Test-Path $settingsFile) {
    try {
        $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Could not read settings file" -Level "Warning"
    }
}

# Power scheme import is retained as a legacy fallback for packages made
# before individual values were captured.  New packages deliberately keep the
# organisation's existing STOBG plan and update its values one by one below.
$powerPlanRestored = $false
$hasIndividualPowerSettings = ($settingsData -and $settingsData.PowerSettingValues -and @($settingsData.PowerSettingValues).Count -gt 0)
$powerScheme = Join-Path $scriptPath "Settings\PowerScheme.pow"
if ($false -and (Test-Path $powerScheme) -and -not $hasIndividualPowerSettings) {
    if (-not $isAdmin) {
        Write-Log "Power scheme - Skipped (requires admin)" -Level "Warning"
        Add-Result -Category "Settings" -Item "Power Scheme" -Status "Skipped" -Details "Requires admin"
        $Script:Results.Warnings += "Power scheme import requires admin rights. Run: powercfg /import `"$powerScheme`""
    }
    elseif ($TestMode) {
        Write-Log "Power scheme - Would import" -Level "Info"
        Add-Result -Category "Settings" -Item "Power Scheme" -Status "TestMode"
    }
    else {
        try {
            $guid = [guid]::NewGuid().ToString()
            $importResult = & powercfg /import $powerScheme $guid 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "powercfg /import failed (exit $LASTEXITCODE): $(($importResult | Out-String).Trim())"
            }

            # Querying the new GUID verifies that Windows actually registered
            # the imported plan before it is made active.
            $verifyResult = & powercfg /query $guid 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Imported power plan could not be queried (exit $LASTEXITCODE): $(($verifyResult | Out-String).Trim())"
            }

            $activateResult = & powercfg /setactive $guid 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "powercfg /setactive failed (exit $LASTEXITCODE): $(($activateResult | Out-String).Trim())"
            }

            $powerPlanRestored = $true
            Write-Log "Complete power scheme imported, verified, and activated" -Level "Success"
            Add-Result -Category "Settings" -Item "Power Configuration" -Status "Success" -Details "All available AC/DC power-plan settings restored"
        }
        catch {
            Write-Log "Power scheme import failed: $_" -Level "Error"
            Add-Result -Category "Settings" -Item "Power Scheme" -Status "Error"
        }
    }
}
elseif ((Test-Path $powerScheme) -and $hasIndividualPowerSettings) {
    Write-Log "Power scheme file retained as an elevated backup; applying individual values to the current STOBG plan" -Level "Info"
    Add-Result -Category "Settings" -Item "Power Scheme" -Status "Skipped" -Details "Individual values preserve the existing managed plan"
}

# Apply the captured values to the plan already present on the new computer.
# This is the normal route for the organisation's managed STOBG plan; it is
# intentionally attempted even without elevation.  Settings rejected by a
# policy or unsupported by the new hardware are reported individually.

function Set-ImportedPowerOverlay {
    # PowerSetActiveOverlayScheme accepts the overlay GUID by value.  The old
    # declaration passed an extra user-root pointer, which made the Windows
    # Settings Power mode restore fail even when a valid overlay was captured.
    param([string]$OverlayGuid)
    if ([string]::IsNullOrWhiteSpace($OverlayGuid) -or $OverlayGuid -notmatch '^[0-9a-fA-F-]{36}$') {
        return [PSCustomObject]@{ Applied = $false; EffectiveOverlayGuid = $null; Detail = 'Captured overlay identifier is invalid' }
    }
    try {
        if (-not ('StoPowerOverlay' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StoPowerOverlay {
    [DllImport("PowrProf.dll", EntryPoint="PowerSetActiveOverlayScheme", SetLastError=true)]
    public static extern uint PowerSetActiveOverlayScheme(Guid overlaySchemeGuid);
    [DllImport("PowrProf.dll", EntryPoint="PowerGetEffectiveOverlayScheme")]
    public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlaySchemeGuid);
}
"@ -ErrorAction Stop
        }
        $guid = [Guid]$OverlayGuid
        $setResult = [StoPowerOverlay]::PowerSetActiveOverlayScheme($guid)
        if ($setResult -ne 0) {
            return [PSCustomObject]@{ Applied = $false; EffectiveOverlayGuid = $null; Detail = "PowerSetActiveOverlayScheme returned $setResult" }
        }
        $effective = [guid]::Empty
        $effectiveResult = [StoPowerOverlay]::PowerGetEffectiveOverlayScheme([ref]$effective)
        return [PSCustomObject]@{
            Applied = $true
            EffectiveOverlayGuid = if ($effectiveResult -eq 0) { $effective.ToString() } else { $null }
            Detail = if ($effectiveResult -eq 0 -and $effective.ToString() -ne $guid.ToString()) { "Applied, but Windows reports effective overlay $effective (policy or hardware may override it)" } else { 'Applied and verified' }
        }
    } catch {
        return [PSCustomObject]@{ Applied = $false; EffectiveOverlayGuid = $null; Detail = $_.Exception.Message }
    }
}

function Get-ImportResultCounts {
    # This is deliberately the only classifier for import outcomes. The
    # terminal summary and the report update both consume these values.
    $actions = @($Script:Results.Actions)
    return [PSCustomObject]@{
        Success = @($actions | Where-Object { $_.Status -eq 'Success' }).Count
        Warning = @($actions | Where-Object { $_.Status -in @('Warning', 'Manual', 'Pending') }).Count
        Errors = @($actions | Where-Object { $_.Status -eq 'Error' }).Count
        Skipped = @($actions | Where-Object { $_.Status -eq 'Skipped' }).Count
    }
}

function Get-ImportAttentionActions {
    # Keep the report's post-transfer list and the terminal attention section
    # one-for-one with the non-success outcomes in the import ledger.
    return @($Script:Results.Actions | Where-Object {
        $_.Status -in @('Warning', 'Error', 'Skipped', 'Manual', 'Pending')
    })
}

if ($hasIndividualPowerSettings) {
    $individualPowerSettings = @($settingsData.PowerSettingValues)
    if ($TestMode) {
        Write-Log "Individual power settings - Would apply $($individualPowerSettings.Count) AC/DC value set(s) to the current plan" -Level "Info"
        Add-Result -Category "Settings" -Item "Individual Power Settings" -Status "TestMode" -Details "$($individualPowerSettings.Count) captured setting(s)"
    }
    else {
        $powerValuesApplied = 0
        $powerValueFailures = New-Object System.Collections.ArrayList
        foreach ($powerSetting in $individualPowerSettings) {
            $subgroupGuid = [string]$powerSetting.SubgroupGuid
            $settingGuid = [string]$powerSetting.SettingGuid
            if ($subgroupGuid -notmatch '^[0-9a-fA-F-]{36}$' -or $settingGuid -notmatch '^[0-9a-fA-F-]{36}$') {
                [void]$powerValueFailures.Add("Invalid setting identifier: $subgroupGuid / $settingGuid")
                continue
            }

            foreach ($powerType in @(@{ Name = "AC"; Value = [string]$powerSetting.ACValue }, @{ Name = "DC"; Value = [string]$powerSetting.DCValue })) {
                if (-not $powerType.Value) { continue }
                $powerCommand = if ($powerType.Name -eq "AC") { "/setacvalueindex" } else { "/setdcvalueindex" }
                $powerOutput = & powercfg $powerCommand SCHEME_CURRENT $subgroupGuid $settingGuid $powerType.Value 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $powerValuesApplied++
                } else {
                    $failureDetail = "$settingGuid ($($powerType.Name)): $(($powerOutput | Out-String).Trim())"
                    [void]$powerValueFailures.Add($failureDetail)
                    # Individual failures are summarized below so the handoff
                    # report remains useful instead of repeating every GUID.
                }
            }
        }

        $activateCurrentResult = & powercfg /setactive SCHEME_CURRENT 2>&1
        if ($LASTEXITCODE -ne 0) {
            [void]$powerValueFailures.Add("Could not activate the current plan: $(($activateCurrentResult | Out-String).Trim())")
        }

        if ($powerValueFailures.Count -eq 0) {
            Write-Log "Individual power settings applied: $powerValuesApplied AC/DC value(s)" -Level "Success"
            Add-Result -Category "Settings" -Item "Individual Power Settings" -Status "Success" -Details "$powerValuesApplied AC/DC values applied to the current plan"
        } else {
            Write-Log "Individual power settings applied: $powerValuesApplied; $($powerValueFailures.Count) value(s) could not be applied" -Level "Warning"
            Add-Result -Category "Settings" -Item "Individual Power Settings" -Status "Warning" -Details "$powerValuesApplied applied; $($powerValueFailures.Count) settings rejected or unsupported. See Logs\\AdminImportLog.txt for details."
            $Script:Results.Warnings += "Some individual power settings were rejected by the current plan, policy, or hardware. See ImportLog.txt."
        }
    }
}

# The Windows Settings Power mode control is represented by distinct AC/DC
# overlay schemes. Attempt this in the signed-in context; policy or hardware
# rejection is reported as skipped rather than escalating the import.
if ($settingsData -and ($settingsData.PowerMode -or $settingsData.PowerModeOverlay)) {
    # New packages capture the actual requested overlay through PowrProf. Keep
    # the registry fallback only for packages created by older exporters.
    $capturedOverlay = if ($settingsData.PowerMode -and $settingsData.PowerMode.RequestedOverlayGuid) {
        [string]$settingsData.PowerMode.RequestedOverlayGuid
    }
    elseif ($settingsData.PowerMode -and $settingsData.PowerMode.EffectiveOverlayGuid) {
        [string]$settingsData.PowerMode.EffectiveOverlayGuid
    }
    elseif ($settingsData.PowerModeOverlay.ActiveOverlayAcPowerScheme) {
        [string]$settingsData.PowerModeOverlay.ActiveOverlayAcPowerScheme
    }
    else { [string]$settingsData.PowerModeOverlay.ActiveOverlayDcPowerScheme }
    if ($TestMode) {
        Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'TestMode' -Details "Would apply captured overlay $capturedOverlay"
    }
    else {
        $overlayResult = Set-ImportedPowerOverlay -OverlayGuid $capturedOverlay
        if ($overlayResult.Applied -and ($null -eq $overlayResult.EffectiveOverlayGuid -or $overlayResult.EffectiveOverlayGuid -eq $capturedOverlay)) {
            Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Success' -Details $overlayResult.Detail
        }
        elseif ($overlayResult.Applied) {
            Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Warning' -Details $overlayResult.Detail
        }
        else {
            Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Skipped' -Details "Overlay could not be applied: $($overlayResult.Detail)"
        }
    }
}
else { Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Skipped' -Details 'No source power-mode overlay captured' }

# Lid actions must be attempted in the ordinary import path. Verify the
# actual AC/DC values afterward so an accepted command is not misreported.
if ($settingsData -and $settingsData.LidClose -and $settingsData.LidClose.OnAC) {
    $lidActionMap = @{ 'Do Nothing' = 0; Sleep = 1; Hibernate = 2; 'Shut Down' = 3 }
    if ($TestMode) {
        Add-Result -Category 'Settings' -Item 'Lid actions' -Status 'TestMode' -Details "AC: $($settingsData.LidClose.OnAC); DC: $($settingsData.LidClose.OnBattery)"
    }
    else {
        $lidFailed = $false
        foreach ($powerKind in @(@{ Command='/setacvalueindex'; Value=$lidActionMap[$settingsData.LidClose.OnAC] }, @{ Command='/setdcvalueindex'; Value=$lidActionMap[$settingsData.LidClose.OnBattery] })) {
            if ($null -eq $powerKind.Value) { $lidFailed = $true; continue }
            & powercfg $powerKind.Command SCHEME_CURRENT SUB_BUTTONS LIDACTION $powerKind.Value 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $lidFailed = $true }
        }
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
        $lidVerify = & powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>&1 | Out-String
        $expectedAc = ('0x{0:x}' -f $lidActionMap[$settingsData.LidClose.OnAC])
        $expectedDc = ('0x{0:x}' -f $lidActionMap[$settingsData.LidClose.OnBattery])
        if (-not $lidFailed -and $lidVerify -match [regex]::Escape($expectedAc) -and $lidVerify -match [regex]::Escape($expectedDc)) {
            Add-Result -Category 'Settings' -Item 'Lid actions' -Status 'Success' -Details "Verified AC: $($settingsData.LidClose.OnAC); DC: $($settingsData.LidClose.OnBattery)"
        }
        else { Add-Result -Category 'Settings' -Item 'Lid actions' -Status 'Skipped' -Details 'Windows, policy, or hardware rejected the non-elevated lid setting' }
    }
}

# Lid close actions are already included in a successful full plan import.
# Keep this narrowly-scoped fallback for older transfer packages that do not
# have PowerScheme.pow, or if a new computer rejects that plan.
if ($false -and -not $powerPlanRestored -and $settingsData -and $settingsData.LidClose -and $settingsData.LidClose.OnAC) {
    if (-not $isAdmin) {
        Write-Log "Lid close actions - Skipped (requires admin)" -Level "Warning"
        Add-Result -Category "Settings" -Item "Lid Actions" -Status "Skipped" -Details "Requires admin"
    }
    elseif ($TestMode) {
        Write-Log "Lid close actions - Would apply (AC: $($settingsData.LidClose.OnAC), DC: $($settingsData.LidClose.OnBattery))" -Level "Info"
        Add-Result -Category "Settings" -Item "Lid Actions" -Status "TestMode" -Details "AC: $($settingsData.LidClose.OnAC), DC: $($settingsData.LidClose.OnBattery)"
    }
    else {
        try {
            # Map text values back to codes
            $lidActionMap = @{
                "Do Nothing" = 0
                "Sleep" = 1
                "Hibernate" = 2
                "Shut Down" = 3
            }
            
            $acCode = $lidActionMap[$settingsData.LidClose.OnAC]
            $dcCode = $lidActionMap[$settingsData.LidClose.OnBattery]
            
            if ($null -ne $acCode) {
                powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $acCode 2>&1 | Out-Null
            }
            if ($null -ne $dcCode) {
                powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $dcCode 2>&1 | Out-Null
            }
            powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
            
            Write-Log "Lid close: AC=$($settingsData.LidClose.OnAC), DC=$($settingsData.LidClose.OnBattery)" -Level "Success"
            Add-Result -Category "Settings" -Item "Lid Actions" -Status "Success"
        }
        catch {
            Write-Log "Lid close action setting failed: $_" -Level "Warning"
            Add-Result -Category "Settings" -Item "Lid Actions" -Status "Warning" -Details $_.Exception.Message
        }
    }
}

# Mapped network drives

function Get-CurrentNetworkDriveMappings {
    # Snapshot current drive mappings for comparison without attempting to
    # recreate credentials or connections that require user approval.
    $mappings = @()
    try {
        $mappings += @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop |
            Where-Object { $_.DisplayRoot -like "\\*" } |
            ForEach-Object { [PSCustomObject]@{ Letter = $_.Name.ToUpperInvariant(); Path = $_.DisplayRoot } })
    }
    catch { Write-Log "Could not query active network drives: $($_.Exception.Message)" -Level "Warning" }

    try {
        $mappings += @(Get-ItemProperty -Path "HKCU:\Network\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -and $_.RemotePath } |
            ForEach-Object { [PSCustomObject]@{ Letter = $_.PSChildName.ToUpperInvariant(); Path = $_.RemotePath } })
    }
    catch { Write-Log "Could not query persistent network drives: $($_.Exception.Message)" -Level "Warning" }

    return @($mappings | Sort-Object Letter, Path -Unique)
}

function Write-NetworkDriveComparison {
    # Render the captured/current mapping difference as an import handoff item.
    param([object[]]$ExpectedDrives)

    $currentDrives = @(Get-CurrentNetworkDriveMappings)
    $missing = @()
    $conflicts = @()
    foreach ($expected in $ExpectedDrives) {
        $matchingLetter = @($currentDrives | Where-Object { $_.Letter -eq $expected.Letter })
        if (@($matchingLetter | Where-Object { $_.Path -eq $expected.Path }).Count -eq 0) {
            if ($matchingLetter.Count -gt 0) {
                $conflicts += "$($expected.Letter): expected $($expected.Path); found $($matchingLetter[0].Path)"
            }
            else { $missing += "$($expected.Letter): $($expected.Path)" }
        }
    }

    $reportPath = Join-Path $scriptPath "Logs\NetworkDriveComparison.txt"
    $lines = @(
        "Network drive comparison - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Expected: $($ExpectedDrives.Count); detected: $($currentDrives.Count)",
        "",
        "Missing expected mappings:"
    )
    $lines += if ($missing.Count) { $missing } else { "None" }
    $lines += ""; $lines += "Conflicting drive letters:"
    $lines += if ($conflicts.Count) { $conflicts } else { "None" }
    $lines += ""; $lines += "Detected mappings:"
    $lines += if ($currentDrives.Count) { @($currentDrives | ForEach-Object { "$($_.Letter): $($_.Path)" }) } else { "None" }
    $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8

    if ($missing.Count -or $conflicts.Count) {
        $detail = "$($missing.Count) missing, $($conflicts.Count) conflicting. See Logs\\NetworkDriveComparison.txt"
        Write-Log "NETWORK DRIVE REVIEW REQUIRED: $detail" -Level "Warning"
        Write-Host "  Technician notification: $detail" -ForegroundColor Yellow
        Add-Result -Category "Network Drives" -Item "Comparison" -Status "Warning" -Details $detail
        Add-ManualTask -Task "Resolve missing network drives" -Reason $detail -Instructions "Review Logs\\NetworkDriveComparison.txt. Connect to the required network/VPN, resolve credentials, and ensure every expected letter points to its recorded UNC path."
    }
    else {
        Write-Log "Network drive comparison passed: all expected mappings match" -Level "Success"
        Add-Result -Category "Network Drives" -Item "Comparison" -Status "Success" -Details "All $($ExpectedDrives.Count) expected mappings match"
    }
}

if ($settingsData -and $settingsData.MappedDrives -and (@($settingsData.MappedDrives).Count -gt 0)) {
    Write-Host ""
    Write-Host "  Network Drives:" -ForegroundColor Gray
    
    foreach ($drive in $settingsData.MappedDrives) {
        if ($drive.Letter -and $drive.Path) {
            $driveLetter = $drive.Letter.ToString().TrimEnd(':').ToUpperInvariant()
            $drivePath = $drive.Path.ToString().Trim()
            
            if ($TestMode) {
                Write-Log "  ${driveLetter}: -> $drivePath (would map)" -Level "Info"
                Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "TestMode" -Details $drivePath
            }
            else {
                # Check if drive letter already in use
                $existing = @(Get-CurrentNetworkDriveMappings | Where-Object { $_.Letter -eq $driveLetter })
                if ($existing.Count -gt 0) {
                    $existingPath = $existing[0].Path
                    $status = if ($existingPath -eq $drivePath) { "Skipped" } else { "Warning" }
                    $detail = if ($existingPath -eq $drivePath) { "Already mapped to expected path" } else { "Already mapped to different path: $existingPath" }
                    Write-Log "  ${driveLetter}: $detail" -Level $(if ($status -eq "Warning") { "Warning" } else { "Info" })
                    Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status $status -Details $detail
                }
                else {
                    try {
                        $netUseOutput = @(net use "${driveLetter}:" $drivePath /persistent:yes 2>&1)
                        $netUseExitCode = $LASTEXITCODE
                        if ($netUseExitCode -eq 0) {
                            Write-Log "  ${driveLetter}: -> $drivePath" -Level "Success"
                            Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Success" -Details $drivePath
                        }
                        else {
                            $netUseDetail = ($netUseOutput -join ' ').Trim()
                            if ([string]::IsNullOrWhiteSpace($netUseDetail)) { $netUseDetail = "net use exit code $netUseExitCode" }
                            Write-Log "  ${driveLetter}: -> $drivePath failed: $netUseDetail" -Level "Warning"
                            Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Warning" -Details $netUseDetail
                        }
                    }
                    catch {
                        Write-Log "  ${driveLetter}: -> $drivePath (failed - may need credentials)" -Level "Warning"
                        Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Warning" -Details "May need manual setup"
                    }
                }
            }
        }
    }
    $expectedDrives = @($settingsData.MappedDrives | Where-Object { $_.Letter -and $_.Path } | ForEach-Object {
        [PSCustomObject]@{ Letter = $_.Letter.ToString().TrimEnd(':').ToUpperInvariant(); Path = $_.Path.ToString().Trim() }
    } | Sort-Object Letter, Path -Unique)
    Write-NetworkDriveComparison -ExpectedDrives $expectedDrives
}

# ========== RESTORE PRINTERS ==========

Write-Section "Restoring printers"

$printBrmPath = "$env:WINDIR\System32\spool\tools\PrintBrm.exe"
$printerExportFile = Join-Path $scriptPath "Printers\Printers.printerExport"
$printBrmLog = Join-Path $scriptPath "Logs\printbrm_restore.log"
$connectionsJson = Join-Path $scriptPath "Printers\PrinterConnections.json"

# ---- PRIMARY (non-admin): re-add network printer connections ----
# Add-Printer -ConnectionName recreates the user's connection to an already-
# shared server queue. No admin needed when the driver is staged or v4.
if (Test-Path $connectionsJson) {
    try {
        $connData = Get-Content $connectionsJson -Raw | ConvertFrom-Json
        $conns = @($connData.Connections)

        if ($conns.Count -eq 0) {
            Write-Log "No network printer connections to restore" -Level "Info"
            Write-Status "Network printers" "SKIP" "none in package"
        }
        elseif ($TestMode) {
            Write-Log "Would restore $($conns.Count) network printer connection(s)" -Level "Info"
            Add-Result -Category "Printers" -Item "Network Connections" -Status "TestMode" -Details "$($conns.Count) connection(s)"
        }
        else {
            $added = 0; $failed = 0
            foreach ($c in $conns) {
                $name = $c.ConnectionName
                if (-not $name) { continue }
                try {
                    Add-Printer -ConnectionName $name -ErrorAction Stop
                    $added++
                    Write-Log "  Added printer connection: $name" -Level "Success"
                }
                catch {
                    # Usually means the driver isn't staged / server unreachable
                    $failed++
                    Write-Log "  Could not add $name : $($_.Exception.Message)" -Level "Warning"
                }
            }

            if ($added -gt 0) {
                Write-Status "Network printers" "OK" "$added connection(s) re-added (no admin)"
                Add-Result -Category "Printers" -Item "Network Connections" -Status "Success" -Details "$added re-added$(if($failed){", $failed failed"})"
            }
            if ($failed -gt 0) {
                Add-Result -Category "Printers" -Item "Network Connections (failed)" -Status "Warning" -Details "$failed could not be added (driver not staged or server unreachable)"
                Add-ManualTask -Task "Re-add failed network printers" -Reason "$failed printer connection(s) failed (driver not staged or print server unreachable)" -Instructions "Connect to the print server (\\server) in File Explorer and double-click the printer(s) to install, or check VPN/network access."
            }

            # Restore default printer (non-admin, via CIM)
            if ($connData.DefaultPrinter) {
                try {
                    $defP = Get-CimInstance -ClassName Win32_Printer -Filter "Name = '$($connData.DefaultPrinter -replace "'","''")'" -ErrorAction SilentlyContinue
                    if ($defP) {
                        Invoke-CimMethod -InputObject $defP -MethodName SetDefaultPrinter -ErrorAction SilentlyContinue | Out-Null
                        Write-Log "Default printer set to $($connData.DefaultPrinter)" -Level "Success"
                        Write-Status "Default printer" "OK" $connData.DefaultPrinter
                    }
                }
                catch {
                    Write-Log "Could not set default printer: $_" -Level "Warning"
                }
            }
        }
    }
    catch {
        Write-Log "Error restoring printer connections: $_" -Level "Warning"
        Add-Result -Category "Printers" -Item "Network Connections" -Status "Warning" -Details $_.Exception.Message
    }
}
else {
    Write-Log "No printer connections file in package" -Level "Info"
    Write-Status "Network printers" "SKIP" "none in package"
}

# ---- FALLBACK (admin only): local/direct-IP printers from PrintBRM package ----
if ($false -and (Test-Path $printerExportFile)) {
    if (-not $isAdmin) {
        Write-Log "Local printer package present but restore needs admin" -Level "Warning"
        Write-Status "Local printers" "SKIP" "admin needed for local drivers"
        Add-Result -Category "Printers" -Item "Local Printers" -Status "Manual" -Details "Re-run elevated (or re-add via Settings) for local printers"
        Add-ManualTask -Task "Restore local/direct-IP printers" -Reason "Local printers carry their own drivers and need admin" -Instructions "Run Import-LaptopData.ps1 as Administrator to install local printers. QuickImport.bat intentionally runs without elevation."
    }
    elseif (-not (Test-Path $printBrmPath)) {
        Write-Status "Local printers" "SKIP" "PrintBRM.exe not present"
        Add-Result -Category "Printers" -Item "Local Printers" -Status "Skipped"
    }
    elseif ($TestMode) {
        Write-Log "Would restore local printers from PrintBRM package" -Level "Info"
        Add-Result -Category "Printers" -Item "Local Printers" -Status "TestMode"
    }
    else {
        try {
            Write-Host "    $([char]0x25B8) Restoring local printers + drivers (PrintBRM)..." -ForegroundColor Cyan
            & $printBrmPath -R -F "$printerExportFile" -O FORCE *>&1 | Tee-Object -FilePath $printBrmLog | Out-Null
            $printBrmExitCode = $LASTEXITCODE

            if ($printBrmExitCode -eq 0) {
                Write-Status "Local printers" "OK" "restore command completed"
                Add-Result -Category "Printers" -Item "Local Printers" -Status "Success"
                Write-Host "    $([char]0x2139) A zero exit code doesn't guarantee every driver installed." -ForegroundColor DarkGray
                $printBrmRestoreSucceeded = $true
            }
            else {
                Write-Status "Local printers" "WARN" "exit $printBrmExitCode, backup retained"
                Add-Result -Category "Printers" -Item "Local Printers" -Status "Warning" -Details "Exit code: $printBrmExitCode, see printbrm_restore.log"
            }
        }
        catch {
            Write-Status "Local printers" "FAIL" $_.Exception.Message
            Add-Result -Category "Printers" -Item "Local Printers" -Status "Error"
        }
    }
}

# ========== PERSONALIZATION SETTINGS (Colors, Taskbar, etc.) ==========
$personalizationReg = Join-Path $scriptPath "Settings\Personalization.reg"
if (Test-Path $personalizationReg) {
    Write-Host ""
    Write-Host "  Personalization Settings:" -ForegroundColor Gray
    
    if ($TestMode) {
        Write-Log "Personalization - Would import registry settings" -Level "Info"
        Add-Result -Category "Settings" -Item "Personalization" -Status "TestMode"
    }
    else {
        try {
            # Import the registry file silently
            $regImportResult = Start-Process -FilePath "reg.exe" -ArgumentList "import `"$personalizationReg`"" -Wait -PassThru -WindowStyle Hidden
            
            if ($regImportResult.ExitCode -eq 0) {
                Write-Log "Personalization settings restored (colors, taskbar, mouse pointer style, Night light, visual effects)" -Level "Success"
                Add-Result -Category "Settings" -Item "Personalization" -Status "Success" -Details "Registry imported"
                
                # Notify user to restart Explorer for full effect
                Write-Host "    Note: Some settings may require sign-out/sign-in to take full effect" -ForegroundColor Yellow
            }
            else {
                Write-Log "Personalization import completed with warnings" -Level "Warning"
                Add-Result -Category "Settings" -Item "Personalization" -Status "Warning" -Details "Some settings may not have imported"
            }
        }
        catch {
            Write-Log "Personalization restore failed: $_" -Level "Warning"
            Add-Result -Category "Settings" -Item "Personalization" -Status "Warning" -Details $_.Exception.Message
            
            # Offer manual alternative
            Write-Host "    Manual: Double-click Settings\Personalization.reg to import" -ForegroundColor Yellow
        }
    }
}

# Also try to apply key settings directly for immediate effect
if (-not $TestMode -and (Test-Path $settingsFile)) {
    try {
        $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
        
        if ($settingsData.Personalization) {
            $p = $settingsData.Personalization
            
            # Dark/Light mode
            if ($null -ne $p.AppsUseLightTheme) {
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -Value $p.AppsUseLightTheme -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "SystemUsesLightTheme" -Value $p.SystemUsesLightTheme -ErrorAction SilentlyContinue
            }
            
            # Accent color
            if ($null -ne $p.ColorizationColor) {
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "ColorizationColor" -Value $p.ColorizationColor -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "ColorizationAfterglow" -Value $p.ColorizationAfterglow -ErrorAction SilentlyContinue
            }
            
            # Taskbar alignment (Win11)
            if ($null -ne $p.TaskbarAl) {
                Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAl" -Value $p.TaskbarAl -ErrorAction SilentlyContinue
            }

            # Taskbar Search Box mode (0=Hidden, 1=Icon only, 2=Search box, 3=Icon+label)
            # Stored under ...\Search, not Explorer\Advanced. Requires the companion
            # Cache value or a fresh profile can reset it, and an Explorer restart to apply.
            if ($null -ne $p.SearchboxTaskbarMode) {
                # Skip if an org policy locks the search mode (per-user set would be ignored)
                $searchPolicy = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "SearchOnTaskbarMode" -ErrorAction SilentlyContinue
                if ($searchPolicy) {
                    Write-Log "Taskbar search mode is managed by policy - skipping (policy wins)" -Level "Info"
                    Add-Result -Category "Settings" -Item "Taskbar Search Mode" -Status "Skipped" -Details "Managed by organization policy"
                }
                else {
                    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
                    if (-not (Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
                    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value $p.SearchboxTaskbarMode -Type DWord -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarModeCache" -Value 1 -Type DWord -ErrorAction SilentlyContinue
                    $Script:RestartExplorerForTaskbar = $true
                    Write-Log "Taskbar search mode restored (value $($p.SearchboxTaskbarMode))" -Level "Success"
                    Add-Result -Category "Settings" -Item "Taskbar Search Mode" -Status "Success" -Details "Mode $($p.SearchboxTaskbarMode)"
                }
            }

            # Restore display scaling to the current destination display(s),
            # rather than importing source monitor IDs that cannot exist on
            # the replacement computer.  Windows applies this at next sign-in.
            $scaleApplied = $false
            if ($p.ScreenScale) {
                $desktopKey = 'HKCU:\Control Panel\Desktop'
                if ($null -ne $p.ScreenScale.LogPixels) {
                    Set-ItemProperty -Path $desktopKey -Name 'LogPixels' -Value $p.ScreenScale.LogPixels -Type DWord -ErrorAction Stop
                    $scaleApplied = $true
                }
                if ($null -ne $p.ScreenScale.Win8DpiScaling) {
                    Set-ItemProperty -Path $desktopKey -Name 'Win8DpiScaling' -Value $p.ScreenScale.Win8DpiScaling -Type DWord -ErrorAction Stop
                    $scaleApplied = $true
                }
                $sourceDpiValues = @($p.ScreenScale.PerMonitorDpiValues | Where-Object { $null -ne $_ })
                if ($sourceDpiValues.Count -gt 0) {
                    $targetMonitorKeys = @(Get-ChildItem -Path 'HKCU:\Control Panel\Desktop\PerMonitorSettings' -ErrorAction SilentlyContinue)
                    foreach ($monitorKey in $targetMonitorKeys) {
                        Set-ItemProperty -LiteralPath $monitorKey.PSPath -Name 'DpiValue' -Value ([int]$sourceDpiValues[0]) -Type DWord -ErrorAction Stop
                        $scaleApplied = $true
                    }
                }
            }
            if ($scaleApplied) {
                $Script:DisplayAccessibilitySettingsChanged = $true
                Write-Log 'Screen scale restored; Windows will apply it after sign-out/sign-in.' -Level 'Success'
                Add-Result -Category 'Settings' -Item 'Screen scale' -Status 'Success' -Details 'Applied to destination display settings; sign out/in required'
            }

            # The registry import preserves all cursor role mappings.  Set the
            # scheme and size explicitly as well, so the current user receives
            # them even if the registry file was partially imported.
            $cursorApplied = $false
            $cursorKey = 'HKCU:\Control Panel\Cursors'
            if ($null -ne $p.CursorScheme) {
                Set-ItemProperty -Path $cursorKey -Name '(default)' -Value $p.CursorScheme -ErrorAction Stop
                $cursorApplied = $true
            }
            if ($null -ne $p.CursorBaseSize) {
                Set-ItemProperty -Path $cursorKey -Name 'CursorBaseSize' -Value $p.CursorBaseSize -Type DWord -ErrorAction Stop
                $cursorApplied = $true
            }
            if ($cursorApplied) {
                $Script:DisplayAccessibilitySettingsChanged = $true
                Add-Result -Category 'Settings' -Item 'Mouse pointer style' -Status 'Success' -Details 'Scheme, size, and cursor mappings restored; sign out/in may be required'
            }

            if ($p.NightLight -and $p.NightLight.Count -gt 0) {
                Add-Result -Category 'Settings' -Item 'Night light' -Status 'Success' -Details 'Enabled state, strength, and schedule restored; sign out/in may be required'
                $Script:DisplayAccessibilitySettingsChanged = $true
            }

            if ($null -ne $p.TextScaleFactor) {
                $accessibilityKey = 'HKCU:\Software\Microsoft\Accessibility'
                if (-not (Test-Path -LiteralPath $accessibilityKey)) { New-Item -Path $accessibilityKey -Force | Out-Null }
                Set-ItemProperty -Path $accessibilityKey -Name 'TextScaleFactor' -Value $p.TextScaleFactor -Type DWord -ErrorAction Stop
                $Script:DisplayAccessibilitySettingsChanged = $true
                Add-Result -Category 'Settings' -Item 'Text size' -Status 'Success' -Details "$($p.TextScaleFactor)% restored; sign out/in required"
            }
        }
    }
    catch {
        # Silent fail - registry import already handled main settings
    }

    # Restart Explorer so taskbar changes (search mode, alignment) take effect now
    if ($Script:RestartExplorerForTaskbar -and -not $TestMode) {
        try {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            # Explorer auto-relaunches; give it a moment
            Start-Sleep -Seconds 2
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Write-Log "Explorer restarted to apply taskbar settings" -Level "Info"
        }
        catch {
            Write-Log "Could not restart Explorer automatically - sign out/in to apply taskbar settings" -Level "Warning"
        }
    }
    if ($Script:DisplayAccessibilitySettingsChanged) {
        Write-Host '    Display scale, mouse pointer style, Night light, and text size will take full effect after sign-out/sign-in.' -ForegroundColor Yellow
    }
}

# Wallpaper
$wallpaperFiles = Get-ChildItem (Join-Path $scriptPath "Settings") -Filter "Wallpaper.*" -ErrorAction SilentlyContinue
if ($wallpaperFiles) {
    $wallpaper = $wallpaperFiles | Select-Object -First 1
    if ($TestMode) {
        Write-Log "Wallpaper - Would restore" -Level "Info"
        Add-Result -Category "Settings" -Item "Wallpaper" -Status "TestMode"
    }
    else {
        try {
            $themesDir = Join-Path $env:APPDATA "Microsoft\Windows\Themes"
            if (-not (Test-Path $themesDir)) { New-Item -ItemType Directory -Path $themesDir -Force | Out-Null }
            
            $wallpaperDest = Join-Path $themesDir "TransferredWallpaper$($wallpaper.Extension)"
            Copy-Item $wallpaper.FullName -Destination $wallpaperDest -Force
            Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -Value $wallpaperDest
            rundll32.exe user32.dll, UpdatePerUserSystemParameters
            Write-Log "Wallpaper restored" -Level "Success"
            Add-Result -Category "Settings" -Item "Wallpaper" -Status "Success"
        }
        catch {
            Write-Log "Wallpaper restore failed: $_" -Level "Warning"
            Add-Result -Category "Settings" -Item "Wallpaper" -Status "Warning" -Details $_.Exception.Message
        }
    }
}

Write-Host ""

# ============================================================================
# RESTORE BROWSER DATA
# ============================================================================

Write-Section "Browser data"
Write-Host ""

# Browser bookmarks are exported as HTML files for manual import. Chrome
# profile archives and password CSVs are handled deliberately below; copying a
# Chrome profile onto a different Windows installation cannot restore the
# Windows-protected credential material safely.
$browserDataPath = Join-Path $scriptPath "BrowserData"


function Restore-ChromiumProfileBookmarks {
    # Restore portable bookmark HTML into the active profile discovered at
    # runtime; usernames and profile directories may differ on the new machine.
    param(
        [string]$BrowserName,
        [string]$ProcessName,
        [string]$PackageUserDataPath,
        [string]$TargetUserDataPath
    )

    if (-not (Test-Path -LiteralPath $PackageUserDataPath)) { return }

    $sourceProfiles = @(Get-ChildItem -LiteralPath $PackageUserDataPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" } |
        Sort-Object Name)
    if ($sourceProfiles.Count -eq 0) { return }

    if ($TestMode) {
        $bookmarkCount = @($sourceProfiles | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "Bookmarks") }).Count
        Add-Result -Category "Browser" -Item "$BrowserName Bookmarks" -Status "TestMode" -Details "$bookmarkCount profile(s) would be restored when matching target profiles are available"
        return
    }

    $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host "  $BrowserName must be closed before bookmarks can be restored." -ForegroundColor Yellow
        [void](Read-UserInput "  Close $BrowserName, then press Enter to continue (S to skip)")
        $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    }
    if ($running.Count -gt 0) {
        Write-Log "$BrowserName bookmark restore skipped because the browser is still running" -Level "Warning"
        Add-Result -Category "Browser" -Item "$BrowserName Bookmarks" -Status "Skipped" -Details "Close $BrowserName and re-run the import script"
        return
    }

    $backupRoot = Join-Path $env:LOCALAPPDATA "LaptopTransferBrowserBackups\$BrowserName\$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $restored = 0
    $manual = 0
    foreach ($sourceProfile in $sourceProfiles) {
        $sourceBookmarks = Join-Path $sourceProfile.FullName "Bookmarks"
        if (-not (Test-Path -LiteralPath $sourceBookmarks)) { continue }

        $targetProfile = Join-Path $TargetUserDataPath $sourceProfile.Name
        # A Default profile can be safely created for a newly installed browser.
        # Additional profiles require an existing matching target profile, since
        # Chromium maps their display names in Local State.
        if ($sourceProfile.Name -ne "Default" -and -not (Test-Path -LiteralPath $targetProfile)) {
            $manual++
            Write-Log "$BrowserName profile '$($sourceProfile.Name)' has no matching target profile; its HTML export remains available for import" -Level "Warning"
            continue
        }

        try {
            if (-not (Test-Path -LiteralPath $targetProfile)) {
                New-Item -ItemType Directory -Path $targetProfile -Force | Out-Null
            }

            $targetBookmarks = Join-Path $targetProfile "Bookmarks"
            if (Test-Path -LiteralPath $targetBookmarks) {
                $backupProfile = Join-Path $backupRoot $sourceProfile.Name
                New-Item -ItemType Directory -Path $backupProfile -Force | Out-Null
                Copy-Item -LiteralPath $targetBookmarks -Destination (Join-Path $backupProfile "Bookmarks") -Force -ErrorAction Stop
            }

            Copy-Item -LiteralPath $sourceBookmarks -Destination $targetBookmarks -Force -ErrorAction Stop
            $restored++
        }
        catch {
            Write-Log "$BrowserName bookmark restore failed for profile '$($sourceProfile.Name)': $_" -Level "Warning"
            Add-Result -Category "Browser" -Item "$BrowserName $($sourceProfile.Name) Bookmarks" -Status "Warning" -Details $_.Exception.Message
        }
    }

    if ($restored -gt 0) {
        Write-Log "$BrowserName bookmarks restored for $restored profile(s)" -Level "Success"
        Add-Result -Category "Browser" -Item "$BrowserName Bookmarks" -Status "Success" -Details "$restored profile(s) restored; any replaced target bookmarks are backed up under $backupRoot"
    }
    if ($manual -gt 0) {
        Add-Result -Category "Browser" -Item "$BrowserName Additional Profiles" -Status "Manual" -Details "$manual profile(s) have no matching target profile; import the supplied HTML files"
    }
}

function Restore-ChromeProfileArchive {
    # Restore an optional raw archive for reference/recovery, separate from
    # bookmark import because protected credentials remain account-bound.
    param([string]$PackageUserDataPath, [string]$TargetUserDataPath)
    if (-not (Test-Path -LiteralPath $PackageUserDataPath)) { return }
    if ($TestMode) {
        $count = @(Get-ChildItem -LiteralPath $PackageUserDataPath -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'TestMode' -Details "$count files would be restored"
        return
    }
    $running = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
    if ($running.Count) {
        $closeChrome = Read-UserInput '  Google Chrome must be closed. Close it, then press Enter to continue (S to skip)'
        $running = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
        if ($closeChrome -match '^[Ss]') { $running = @('skipped') }
    }
    if ($running.Count) {
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'Skipped' -Details 'Close Chrome and rerun the import script'
        return
    }
    $backup = Join-Path $env:LOCALAPPDATA "LaptopTransferBrowserBackups\Chrome\$(Get-Date -Format 'yyyyMMdd_HHmmss')\User Data"
    $backupCreated = $false
    try {
        $targetParent = Split-Path -Parent $TargetUserDataPath
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        if (Test-Path -LiteralPath $TargetUserDataPath) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Move-Item -LiteralPath $TargetUserDataPath -Destination $backup -ErrorAction Stop
            $backupCreated = $true
        }
        $result = Copy-WithProgress -Source $PackageUserDataPath -Destination $TargetUserDataPath -FolderName 'Chrome profile (all profiles)' -LogPath (Join-Path $logsPath 'import_chrome_profile.log')
        if ($result.Status -ne 'Success') { throw "Profile copy did not complete successfully (robocopy exit $($result.ExitCode))" }
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'Success' -Details "$($result.FilesCopied) files; prior data backed up when present"
        Write-Host '    Chrome extensions, settings, history, and bookmarks were restored. Passwords and cookies may require Chrome sign-in.' -ForegroundColor Gray
    }
    catch {
        $failureDetail = $_.Exception.Message
        if ($backupCreated -and (Test-Path -LiteralPath $backup)) {
            try {
                if (Test-Path -LiteralPath $TargetUserDataPath) {
                    $failedTarget = "$TargetUserDataPath.failed_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    Move-Item -LiteralPath $TargetUserDataPath -Destination $failedTarget -ErrorAction Stop
                }
                Move-Item -LiteralPath $backup -Destination $TargetUserDataPath -ErrorAction Stop
                $failureDetail = "$failureDetail. Original Chrome profile restored from backup."
            }
            catch {
                $failureDetail = "$failureDetail. Automatic rollback failed: $($_.Exception.Message). Backup retained at $backup."
            }
        }
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'Warning' -Details $failureDetail
        Write-Log "Chrome profile restore failed: $failureDetail" -Level Warning
    }
}

if (Test-Path $printerExportFile) {
    Write-Log "Local/direct-IP printer package retained for optional administrator helper" -Level "Info"
    Write-Status "Local printers" "INFO" "optional administrator helper"
    Add-Result -Category "Printers" -Item "Local Printers" -Status "Pending" -Details "Run Import-SystemSettings.ps1 through the optional helper"
}

# Chrome bookmarks HTML (one file per old Chrome profile)
$chromeBookmarksPath = Join-Path $browserDataPath "Chrome\Bookmarks"
$chromeBookmarkFiles = @(Get-ChildItem -LiteralPath $chromeBookmarksPath -Filter "*.html" -File -Force -ErrorAction SilentlyContinue)
if ($chromeBookmarkFiles.Count -eq 0) {
    # Compatibility with transfer packages generated before multi-profile
    # Chrome bookmark export was introduced.
    $legacyChromeHtml = Join-Path $browserDataPath "Chrome_Bookmarks.html"
    if (Test-Path -LiteralPath $legacyChromeHtml) { $chromeBookmarkFiles = @(Get-Item -LiteralPath $legacyChromeHtml) }
}
if ($chromeBookmarkFiles.Count -gt 0) {
    Write-Log "Chrome bookmark HTML files available for $($chromeBookmarkFiles.Count) profile(s)" -Level "Success"
    foreach ($chromeBookmarkFile in $chromeBookmarkFiles) {
        Write-Host "    File: $($chromeBookmarkFile.FullName)" -ForegroundColor Gray
    }
    Write-Host "    HTML files are retained for manual import if a Chrome profile cannot be matched automatically." -ForegroundColor Gray
    Write-Host "    Manual fallback: Chrome > Bookmarks and lists > Import bookmarks and settings > HTML file" -ForegroundColor Gray
    Add-Result -Category "Browser" -Item "Chrome Bookmark HTML" -Status "Ready" -Details "$($chromeBookmarkFiles.Count) fallback HTML file(s) available"
}

# A FullProfile archive restores the complete Chrome User Data tree. Passwords
# and cookies remain Windows-protected and may still require Chrome sign-in.
$chromeProfileArchive = Join-Path $browserDataPath "Chrome\User Data"
if (Test-Path -LiteralPath $chromeProfileArchive) {
    $chromeArchiveFiles = (Get-ChildItem -LiteralPath $chromeProfileArchive -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Log "Chrome profile archive detected ($chromeArchiveFiles files)" -Level "Info"
    Write-Host "    Chrome profile archive: $chromeProfileArchive" -ForegroundColor Gray
    Restore-ChromeProfileArchive -PackageUserDataPath $chromeProfileArchive -TargetUserDataPath (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data")
}
else {
    # The standard, lean Chrome export contains only profile bookmark stores.
    # Restore those automatically where the source and destination profile
    # directories match; HTML files above remain available for every other
    # profile.
    $chromeProfileBookmarks = Join-Path $browserDataPath "Chrome\ProfileBookmarks"
    Restore-ChromiumProfileBookmarks -BrowserName "Google Chrome" -ProcessName "chrome" -PackageUserDataPath $chromeProfileBookmarks -TargetUserDataPath (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data")
}

# Chrome's native Password Manager export produces a plaintext CSV after the
# user completes the Windows authentication prompt on the old computer. Do
# not attempt to decrypt the raw Chrome profile here; the browser/Windows
# protections are intentional. Instead, guide the user through Chrome's own
# CSV import and offer to remove the sensitive export after confirmation.
function Invoke-ChromePasswordImport {
    # Execute the operator-mediated password CSV workflow and record its outcome
    # instead of silently treating a skipped import as success.
if ($Script:ChromePasswordImportHandled) { return }
$chromePasswordExportPath = Join-Path $browserDataPath "Chrome\PasswordExport"
$chromePasswordCsvs = @(Get-ChildItem -LiteralPath $chromePasswordExportPath -Filter "*.csv" -File -Force -ErrorAction SilentlyContinue)
if ($chromePasswordCsvs.Count -gt 0) {
    Write-Host ""
    Write-Host "  Chrome password export detected - this CSV is plaintext. Keep the transfer package secure." -ForegroundColor Yellow
    foreach ($chromePasswordCsv in $chromePasswordCsvs) {
        Write-Host "    File: $($chromePasswordCsv.FullName)" -ForegroundColor Gray
    }
    Write-Host "    In Chrome: Passwords and autofill > Google Password Manager > Settings > Import passwords." -ForegroundColor Gray

    if ($TestMode) {
        Write-Log "Chrome passwords - Would make $($chromePasswordCsvs.Count) CSV file(s) available for native import" -Level "Info"
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "TestMode" -Details "$($chromePasswordCsvs.Count) plaintext CSV file(s); manual native Chrome import required"
    }
    else {
        $openChrome = Read-UserInput "  Open Chrome Password Manager now? (Y/N)"
        if ($openChrome -match '^[Yy]') {
            try { Start-Process "chrome.exe" "chrome://password-manager/settings" -ErrorAction Stop }
            catch { Write-Log "Could not open Chrome Password Manager automatically: $_" -Level Warning }
        }

        $deleteCsv = Read-UserInput "  After importing and verifying passwords, type DELETE to permanently remove the plaintext CSV (or press Enter to keep it)"
        if ($deleteCsv -ceq "DELETE") {
            try {
                foreach ($chromePasswordCsv in $chromePasswordCsvs) {
                    Remove-Item -LiteralPath $chromePasswordCsv.FullName -Force -ErrorAction Stop
                }
                Write-Log "Chrome password CSV removed after user-confirmed import" -Level Success
                Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Success" -Details "Imported through Chrome and deleted from transfer package"
            }
            catch {
                Write-Log "Could not remove Chrome password CSV: $_" -Level Warning
                Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Warning" -Details "CSV may still be present; remove it securely after import"
            }
        }
        else {
            Write-Log "Chrome password CSV retained; delete it after native Chrome import" -Level Warning
            Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details "Import in Chrome, verify, then securely delete plaintext CSV"
        }
    }
}
}

# OneDrive Files On-Demand: after the user has signed in, pin every synced
# folder so Windows keeps the content available on this replacement device.
function Enable-OneDriveAlwaysOnDevice {
    # Request local availability for synced files after sign-in.  Tenant policy
    # can reject this request, so failures remain visible but non-fatal.
    $oneDriveFolders = @($env:OneDriveCommercial, $env:OneDrive) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
    if ($TestMode) {
        Write-Log "OneDrive - Would enable 'Always keep on this device' after sign-in" -Level "Info"
        Add-Result -Category "OneDrive" -Item "Always on this device" -Status "TestMode" -Details "No changes made"
        return
    }
    if ($oneDriveFolders.Count -eq 0) {
        Write-Log "OneDrive is not signed in or its sync folder is unavailable" -Level "Warning"
        Add-Result -Category "OneDrive" -Item "Always on this device" -Status "Manual" -Details "Sign in to OneDrive, then rerun the import"
        Add-ManualTask -Task "Enable OneDrive always-on-device sync" -Reason "No signed-in OneDrive folder was found" -Instructions "Sign in to OneDrive, wait for its folder to appear, then rerun Import-LaptopData.ps1. The rerun pins the synced files for offline availability."
        return
    }
    foreach ($oneDriveFolder in $oneDriveFolders) {
        try {
            $process = Start-Process -FilePath "attrib.exe" -ArgumentList "+P", "-U", "`"$oneDriveFolder\*`"", "/S", "/D" -Wait -PassThru -NoNewWindow -ErrorAction Stop
            if ($process.ExitCode -ne 0) { throw "attrib.exe exited with code $($process.ExitCode)" }
            Write-Log "OneDrive files pinned for this device: $oneDriveFolder" -Level "Success"
            Add-Result -Category "OneDrive" -Item "Always on this device" -Status "Success" -Details $oneDriveFolder
        }
        catch {
            Write-Log "Could not pin OneDrive files at ${oneDriveFolder}: $($_.Exception.Message)" -Level "Warning"
            Add-Result -Category "OneDrive" -Item "Always on this device" -Status "Manual" -Details $_.Exception.Message
            Add-ManualTask -Task "Enable OneDrive always-on-device sync" -Reason "Automatic pinning failed" -Instructions "In File Explorer, open $oneDriveFolder, select all content, then choose 'Always keep on this device'."
        }
    }
}

Enable-OneDriveAlwaysOnDevice

# Edge bookmarks HTML (one file per old Edge profile)
$edgeBookmarksPath = Join-Path $browserDataPath "Edge\Bookmarks"
$edgeBookmarkFiles = @(Get-ChildItem -LiteralPath $edgeBookmarksPath -Filter "*.html" -File -Force -ErrorAction SilentlyContinue)
if ($edgeBookmarkFiles.Count -eq 0) {
    $legacyEdgeHtml = Join-Path $browserDataPath "Edge_Bookmarks.html"
    if (Test-Path -LiteralPath $legacyEdgeHtml) { $edgeBookmarkFiles = @(Get-Item -LiteralPath $legacyEdgeHtml) }
}
if ($edgeBookmarkFiles.Count -gt 0) {
    Write-Log "Edge bookmark HTML files available for $($edgeBookmarkFiles.Count) profile(s)" -Level "Success"
    foreach ($edgeBookmarkFile in $edgeBookmarkFiles) {
        Write-Host "    File: $($edgeBookmarkFile.FullName)" -ForegroundColor Gray
    }
    Write-Host "    Additional profiles: Edge > Favorites > Import favorites > HTML file" -ForegroundColor Gray
    Add-Result -Category "Browser" -Item "Edge Bookmark HTML" -Status "Ready" -Details "$($edgeBookmarkFiles.Count) HTML file(s) available for manual import"
}

$edgeProfileArchive = Join-Path $browserDataPath "Edge\User Data"
if (Test-Path -LiteralPath $edgeProfileArchive) {
    Restore-ChromiumProfileBookmarks -BrowserName "Microsoft Edge" -ProcessName "msedge" -PackageUserDataPath $edgeProfileArchive -TargetUserDataPath (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data")
}

# Firefox profile data

function Remove-FirefoxProfileLocks {
    # Remove only transient Firefox lock files before copying a profile, after
    # the caller has ensured Firefox is not actively changing its databases.
    param([string]$FirefoxRoot)

    # A lock copied from an interrupted/forced-close session can make Firefox
    # report that the profile is already in use on the new computer.  These
    # are transient lock markers only; never remove profile databases or user
    # preferences here.
    $profilesRoot = Join-Path $FirefoxRoot "Profiles"
    $lockFiles = @(Get-ChildItem -LiteralPath $profilesRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @("parent.lock", ".parentlock") })
    foreach ($lockFile in $lockFiles) {
        try {
            Remove-Item -LiteralPath $lockFile.FullName -Force -ErrorAction Stop
            Write-Log "Removed stale Firefox profile lock: $($lockFile.FullName)" -Level "Info"
        }
        catch {
            Write-Log "Could not remove Firefox profile lock '$($lockFile.FullName)': $_" -Level "Warning"
        }
    }
}

$firefoxRoamingSource = Join-Path $browserDataPath "Firefox\Roaming"
$firefoxLocalSource = Join-Path $browserDataPath "Firefox\Local"
if (-not $importFirefox) {
    if ((Test-Path -LiteralPath $firefoxRoamingSource) -or (Test-Path -LiteralPath $firefoxLocalSource)) {
        Write-Log "Firefox import disabled by configuration" -Level "Info"
        Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Skipped" -Details "Disabled by configuration"
    }
}
else {
    $firefoxProfilesRoot = Join-Path $firefoxRoamingSource "Profiles"
    $firefoxProfileFolders = @(Get-ChildItem -LiteralPath $firefoxProfilesRoot -Directory -Force -ErrorAction SilentlyContinue)

    # A valid standard Firefox backup always includes one or more profile folders
    # beneath Roaming\Profiles.  Refuse to move aside an existing new-machine
    # profile when this essential payload is missing or incomplete.
    if ((Test-Path -LiteralPath $firefoxRoamingSource) -and $firefoxProfileFolders.Count -eq 0) {
        Write-Log "Firefox package has no Roaming\Profiles payload; existing Firefox data was left untouched" -Level "Warning"
        Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Warning" -Details "Package is missing Roaming\Profiles; existing Firefox data was not replaced"
        $firefoxRoamingSource = $null
        $firefoxLocalSource = $null
    }

    if (($firefoxRoamingSource -and (Test-Path -LiteralPath $firefoxRoamingSource)) -or
        ($firefoxLocalSource -and (Test-Path -LiteralPath $firefoxLocalSource))) {
    if ($TestMode) {
        $firefoxFileCount = ((Get-ChildItem -LiteralPath $firefoxRoamingSource -Recurse -File -Force -ErrorAction SilentlyContinue) + (Get-ChildItem -LiteralPath $firefoxLocalSource -Recurse -File -Force -ErrorAction SilentlyContinue) | Measure-Object).Count
        Write-Log "Firefox profile - Would restore $firefoxFileCount files" -Level "Info"
        Add-Result -Category "Browser" -Item "Firefox Profile" -Status "TestMode" -Details "$firefoxFileCount files"
    }
    else {
        $firefoxProcesses = @(Get-Process -Name "firefox" -ErrorAction SilentlyContinue)
        if ($firefoxProcesses.Count -gt 0) {
            Write-Host "  Firefox must be closed before its profile can be restored." -ForegroundColor Yellow
            $closeFirefox = Read-UserInput "  Close Firefox, then press Enter to continue (S to skip)"
            $firefoxProcesses = @(Get-Process -Name "firefox" -ErrorAction SilentlyContinue)
        }

        if ($firefoxProcesses.Count -gt 0 -or $closeFirefox -match "^[Ss]") {
            Write-Log "Firefox profile restore skipped because Firefox is still running or was skipped" -Level "Warning"
            Add-Result -Category "Browser" -Item "Firefox Profile" -Status "Skipped" -Details "Close Firefox and re-run the import script"
        }
        else {
            $backupStamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $firefoxRestoreTargets = @(
                @{ Source = $firefoxRoamingSource; Parent = (Join-Path $env:APPDATA "Mozilla"); Name = "Roaming" },
                @{ Source = $firefoxLocalSource; Parent = (Join-Path $env:LOCALAPPDATA "Mozilla"); Name = "Local" }
            )

            foreach ($target in $firefoxRestoreTargets) {
                if (-not $target.Source -or -not (Test-Path -LiteralPath $target.Source)) { continue }

                $destination = Join-Path $target.Parent "Firefox"
                $backup = Join-Path $target.Parent "Firefox_Backup_$backupStamp"
                $backupCreated = $false
                try {
                    if (-not (Test-Path $target.Parent)) { New-Item -ItemType Directory -Path $target.Parent -Force | Out-Null }
                    if (Test-Path $destination) {
                        Move-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
                        $backupCreated = $true
                        Write-Log "Existing Firefox $($target.Name) data backed up to $backup" -Level "Info"
                    }

                    $logPath = Join-Path $logsPath "import_firefox_$($target.Name.ToLower()).log"
                    $result = Copy-WithProgress -Source $target.Source `
                                               -Destination $destination `
                                               -FolderName "Firefox $($target.Name) data" `
                                               -LogPath $logPath
                    if ($result.Status -ne "Success") { throw "Firefox $($target.Name) copy did not complete successfully (robocopy exit $($result.ExitCode))" }
                    if ($target.Name -eq "Roaming" -and $result.FilesCopied -gt 0) {
                        Remove-FirefoxProfileLocks -FirefoxRoot $destination
                    }
                    if ($result.Status -eq "Success") {
                        Write-Log "Firefox $($target.Name) data restored: $($result.FilesCopied) files" -Level "Success"
                        Add-Result -Category "Browser" -Item "Firefox $($target.Name) Data" -Status "Success" -Details "$($result.FilesCopied) files"
                    }
                    else {
                        Write-Log "Firefox $($target.Name) data restore completed with warnings" -Level "Warning"
                        Add-Result -Category "Browser" -Item "Firefox $($target.Name) Data" -Status $result.Status -Details "Check $logPath"
                    }
                }
                catch {
                    $failureDetail = $_.Exception.Message
                    if ($backupCreated -and (Test-Path -LiteralPath $backup)) {
                        try {
                            if (Test-Path -LiteralPath $destination) {
                                $failedTarget = "$destination.failed_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                                Move-Item -LiteralPath $destination -Destination $failedTarget -ErrorAction Stop
                            }
                            Move-Item -LiteralPath $backup -Destination $destination -ErrorAction Stop
                            $failureDetail = "$failureDetail. Original Firefox $($target.Name) data restored from backup."
                        }
                        catch {
                            $failureDetail = "$failureDetail. Automatic rollback failed: $($_.Exception.Message). Backup retained at $backup."
                        }
                    }
                    Write-Log "Firefox $($target.Name) data restore failed: $failureDetail" -Level "Warning"
                    Add-Result -Category "Browser" -Item "Firefox $($target.Name) Data" -Status "Warning" -Details $failureDetail
                }
            }

            Write-Host "    Firefox profile restored. Start Firefox after this import completes." -ForegroundColor Gray
        }
    }
}
}

Write-Host ""

# ============================================================================
# VERIFY INSTALLED PROGRAMS AND APPDATA REVIEW
# ============================================================================

Write-Section "Installed programs reference"
Write-Host ""

function ConvertTo-ProgramMatchPart {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Test-UserFacingProgram {
    param([object]$Program)
    $name = [string]$Program.DisplayName
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $publisher = [string]$Program.Publisher

    # These app families are supplied through the normal image or standard
    # post-transfer configuration. Keep this safeguard independent of the
    # serialized configuration so they never appear in a handoff app list.
    if ("$name`n$publisher" -match '\b(?:Adobe|ClickShare|Lenovo|Microsoft|Windows)\b') { return $false }

    foreach ($pattern in @($appComparisonExcludePatterns)) {
        # A legacy Windows PowerShell JSON import can leave the configured
        # patterns nested in an Object[] value. Never cast that aggregate to a
        # regex: "System.Object[]" is a character class that matches most app
        # names and would hide every missing-application warning.
        foreach ($individualPattern in @($pattern)) {
            if ($individualPattern -is [string] -and $individualPattern -and ($name -match $individualPattern -or $publisher -match $individualPattern)) { return $false }
        }
    }
    return $true
}

function Get-ProgramMatchKey {
    param([string]$DisplayName, [string]$Publisher)
    return "$(ConvertTo-ProgramMatchPart $DisplayName)|$(ConvertTo-ProgramMatchPart $Publisher)"
}

function Get-ProgramNameKey {
    param([string]$DisplayName)
    return (ConvertTo-ProgramMatchPart $DisplayName)
}

function Get-CurrentInstalledPrograms {
    $items = @()
    $locations = @(
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine64' },
        @{ Path = 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine32' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'CurrentUser' }
    )
    foreach ($location in $locations) {
        try {
            $items += Get-ItemProperty $location.Path -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -and -not $_.SystemComponent -and -not $_.ReleaseType
            } | ForEach-Object {
                [PSCustomObject]@{
                    DisplayName = $_.DisplayName; DisplayVersion = $_.DisplayVersion; Publisher = $_.Publisher
                    InstallDate = $_.InstallDate; SourceScope = $location.Scope
                    MatchKey = Get-ProgramMatchKey $_.DisplayName $_.Publisher
                }
            }
        } catch { Write-Log "Could not read installed-program inventory location $($location.Scope): $($_.Exception.Message)" -Level 'Warning' }
    }
    return @($items | Sort-Object MatchKey, DisplayName -Unique)
}

function ConvertTo-ReviewHtml {
    param([object[]]$Missing, [object[]]$Candidates)
    $encode = { param($Value) [Security.SecurityElement]::Escape([string]$Value) }
    $rows = @($Missing | ForEach-Object { "<tr><td>$(& $encode $_.DisplayName)</td><td>$(& $encode $_.Publisher)</td><td>$(& $encode $_.DisplayVersion)</td></tr>" }) -join "`n"
    if (-not $rows) { $rows = '<tr><td colspan="3">No missing apps detected.</td></tr>' }
    $candidateRows = @($Candidates | ForEach-Object { "<tr><td>$(& $encode $_.Area)</td><td>$(& $encode $_.RelativePath)</td><td>$(& $encode $_.Association)</td></tr>" }) -join "`n"
    if (-not $candidateRows) { $candidateRows = '<tr><td colspan="3">No AppData candidates available.</td></tr>' }
    return "<html><head><meta charset='utf-8'><title>Application Migration Review</title><style>body{font-family:Segoe UI;margin:32px;color:#202020}table{border-collapse:collapse;width:100%;margin-bottom:25px}td,th{padding:8px;border:1px solid #ccc;text-align:left}th{background:#17365d;color:#fff}h1{color:#17365d}</style></head><body><h1>Application Migration Review</h1><p>Review missing applications and AppData candidates before handoff. Candidate folders are review-only and were not copied automatically. Adobe, ClickShare, Lenovo, Microsoft, and Windows-related AppData folders are excluded from this review.</p><h2>Missing applications</h2><table><tr><th>Application</th><th>Publisher</th><th>Old version</th></tr>$rows</table><h2>AppData candidates</h2><table><tr><th>Area</th><th>Folder</th><th>Association</th></tr>$candidateRows</table></body></html>"
}

function Set-TransferReportMarkedContent {
    param([string]$Html, [string]$Marker, [string]$Content)
    $openMarker = "<!-- $Marker -->"
    $closeMarker = "<!-- /$Marker -->"
    $start = $Html.IndexOf($openMarker, [StringComparison]::Ordinal)
    if ($start -lt 0) { return $Html }
    $end = $Html.IndexOf($closeMarker, $start + $openMarker.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) { return $Html }
    return $Html.Substring(0, $start + $openMarker.Length) + $Content + $Html.Substring($end)
}

function Update-TransferReportFromImport {
    # Merge import outcomes into the export report through stable HTML markers,
    # keeping a partial import auditable instead of overwriting its history.
    param(
        [object[]]$MissingPrograms = @(),
        [object[]]$AppDataCandidates = @(),
        [ValidateSet('Complete', 'Disabled', 'Unavailable', 'Failed')][string]$State = 'Complete',
        [string]$Detail = ''
    )
    $reportPath = Join-Path $scriptPath 'TransferReport.html'
    if (-not (Test-Path -LiteralPath $reportPath)) {
        Write-Log 'Transfer report update skipped: TransferReport.html is missing.' -Level 'Warning'
        return
    }
    try {
        $encode = { param($Value) [Security.SecurityElement]::Escape([string]$Value) }
        if ($State -eq 'Complete') {
            $appItems = @(@($MissingPrograms) | ForEach-Object {
                $name = & $encode ([string]$_.DisplayName)
                $publisher = & $encode ([string]$_.Publisher)
                $version = & $encode ([string]$_.DisplayVersion)
                "<li><strong>$name</strong><small>$publisher · old version: $version</small></li>"
            }) -join "`n"
            # Use one explicit table row per candidate. This avoids serializing
            # an array into a single card in the handoff report.
            $candidateRows = @($AppDataCandidates | ForEach-Object { "<tr><td>$(& $encode ([string]$_.Area))</td><td>$(& $encode ([string]$_.RelativePath))</td><td>$(& $encode ([string]$_.Association))</td></tr>" }) -join "`n"
            $candidatePanel = if ($candidateRows) { "<details class='section'><summary>AppData migration review<span>$($AppDataCandidates.Count) folder(s) to review; excluded app families are omitted</span></summary><div class='section-content'><p>Adobe, ClickShare, Lenovo, Microsoft, and Windows-related AppData folders are excluded from this review; none of the remaining folders are copied automatically.</p><table><thead><tr><th>Area</th><th>Folder</th><th>Association</th></tr></thead><tbody>$candidateRows</tbody></table></div></details>" } else { '' }
            if ($MissingPrograms.Count -gt 0) {
                $appSection = "<div class='app-summary ready'><h3>$($MissingPrograms.Count) app(s) need installation</h3><p>Please confirm which apps you would like to install on the new device.</p><details><summary>Post-transfer apps list<span>$($MissingPrograms.Count) app(s) to install or replace</span></summary><ul class='missing-app-list'>$appItems</ul></details></div>$candidatePanel"
            }
            else {
                $appSection = "<div class='app-summary ok'><h3>Application comparison complete</h3><p>No applications from the old computer are missing on this new computer.</p></div>$candidatePanel"
            }
        }
        else {
            $heading = switch ($State) {
                'Disabled' { 'Application comparison disabled' }
                'Unavailable' { 'Application comparison unavailable' }
                default { 'Application comparison could not be completed' }
            }
            $reason = if ($Detail) { & $encode $Detail } else { 'No additional detail was recorded.' }
            $appSection = "<div class='app-summary ready'><h3>$heading</h3><p>$reason See Logs\ImportLog.txt for details.</p></div>"
        }
        $reportHtml = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'DESTINATION_COMPUTER' -Content (& $encode $env:COMPUTERNAME)
        $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'APP_MIGRATION_SECTION' -Content $appSection
        Set-Content -LiteralPath $reportPath -Value $reportHtml -Encoding UTF8
        Write-Log 'Transfer report updated with destination computer and application comparison.' -Level 'Success'
    }
    catch {
        Write-Log "Transfer report update failed: $($_.Exception.Message)" -Level 'Warning'
    }
}

function Update-TransferReportImportOutcomes {
    # Replace pending application and AppData review sections with final
    # comparison results collected on the replacement computer.
    # The export report remains the handoff document. Surface only import
    # outcomes that require a technician's attention, ahead of its export log.
    $reportPath = Join-Path $scriptPath 'TransferReport.html'
    if (-not (Test-Path -LiteralPath $reportPath)) { return }
    try {
        $resultCounts = Get-ImportResultCounts
        $attention = Get-ImportAttentionActions
        $encode = { param($Value) [Security.SecurityElement]::Escape([string]$Value) }
        $summary = "<section class='stats'><div class='stat success'><div class='number'>$($resultCounts.Success)</div><div class='label'>Successful import steps</div></div><div class='stat warning'><div class='number'>$($resultCounts.Warning)</div><div class='label'>Import warnings</div></div><div class='stat error'><div class='number'>$($resultCounts.Errors)</div><div class='label'>Import errors</div></div><div class='stat skipped'><div class='number'>$($resultCounts.Skipped)</div><div class='label'>Import skipped</div></div></section>"
        $content = if ($attention.Count) {
            $items = @($attention | ForEach-Object {
                "<li><strong>$(& $encode ([string]$_.Item))</strong><small>$(& $encode ([string]$_.Status)) · $(& $encode ([string]$_.Details))</small></li>"
            }) -join "`n"
            "<details class='section' open><summary>Post-transfer items needing attention<span>$($resultCounts.Warning) warning(s) · $($resultCounts.Errors) error(s) · $($resultCounts.Skipped) skipped item(s)</span></summary><div class='section-content'><div class='app-summary ready'><ul class='app-list'>$items</ul></div></div></details>"
        }
        else { "<section class='admin-success'>No import items need attention.</section>" }
        $reportHtml = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'TRANSFER_SUMMARY' -Content $summary
        $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'IMPORT_RESULTS' -Content $content
        $importDuration = (Get-Date) - $Script:Results.StartTime
        $importMinutes = [math]::Round($importDuration.TotalMinutes, 1)
        if ($reportHtml -match '<!-- TRANSFER_DURATION -->(.*?)<!-- /TRANSFER_DURATION -->') {
            $exportDuration = $Matches[1]
            $exportMinutes = 0.0
            [void][double]::TryParse(($exportDuration -replace '[^0-9.]', ''), [ref]$exportMinutes)
            $totalMinutes = [math]::Round(($exportMinutes + $importMinutes), 1)
            $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'TRANSFER_DURATION' -Content "$totalMinutes min total"
            $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'TRANSFER_DURATION_COPY' -Content "($exportDuration export + $importMinutes min import)"
        }
        Set-Content -LiteralPath $reportPath -Value $reportHtml -Encoding UTF8
        Write-Log "Transfer report updated with $($attention.Count) import item(s) needing attention." -Level 'Info'
    }
    catch { Write-Log "Transfer report import-outcome update failed: $($_.Exception.Message)" -Level 'Warning' }
}

$programsFile = Join-Path $scriptPath "Settings\InstalledPrograms.txt"
$sourceProgramsPath = Join-Path $scriptPath 'Settings\InstalledPrograms.json'
if (-not $compareInstalledApps) {
    Add-Result -Category 'Reference' -Item 'Application comparison' -Status 'Skipped' -Details 'Disabled by package configuration'
    if (-not $TestMode) { Update-TransferReportFromImport -State Disabled -Detail 'This transfer package was configured not to compare installed applications.' }
}
elseif (-not (Test-Path -LiteralPath $sourceProgramsPath)) {
    Write-Log 'Application comparison skipped: source InstalledPrograms.json is missing.' -Level 'Warning'
    Add-Result -Category 'Reference' -Item 'Application comparison' -Status 'Warning' -Details 'Source installed-program inventory is missing'
    if (-not $TestMode) { Update-TransferReportFromImport -State Unavailable -Detail 'The source InstalledPrograms.json inventory is missing from this transfer package.' }
}
else {
    try {
        # ConvertFrom-Json in Windows PowerShell can emit a JSON array as one
        # pipeline object.  Materialize it first, then enumerate it explicitly:
        # otherwise every source program is collapsed into one pseudo-record and
        # a leading excluded name can hide all missing applications.
        # Accept inventories from earlier package versions that predate MatchKey.
        $sourceProgramInventory = Get-Content -LiteralPath $sourceProgramsPath -Raw | ConvertFrom-Json
        $sourcePrograms = @(foreach ($sourceProgram in @($sourceProgramInventory)) {
            [PSCustomObject]@{
                DisplayName = $sourceProgram.DisplayName; DisplayVersion = $sourceProgram.DisplayVersion; Publisher = $sourceProgram.Publisher
                InstallDate = $sourceProgram.InstallDate; SourceScope = $sourceProgram.SourceScope
                MatchKey = if ($sourceProgram.MatchKey) { $sourceProgram.MatchKey } else { Get-ProgramMatchKey $sourceProgram.DisplayName $sourceProgram.Publisher }
            }
        })
        $newPrograms = @(Get-CurrentInstalledPrograms)
        $newProgramsPath = Join-Path $logsPath 'NewInstalledPrograms.json'
        $newPrograms | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $newProgramsPath -Encoding UTF8
        $newByKey = @{}; foreach ($program in $newPrograms) { if ($program.MatchKey) { $newByKey[$program.MatchKey] = $program } }
        $newByName = @{}; foreach ($program in $newPrograms) { $nameKey = Get-ProgramNameKey $program.DisplayName; if ($nameKey) { if (-not $newByName.ContainsKey($nameKey)) { $newByName[$nameKey] = @() }; $newByName[$nameKey] += $program } }
        # Publisher strings can differ between MSI, Store, and winget builds.
        # An unambiguous normalized display-name match is still installed.
        $allMissingPrograms = @($sourcePrograms | Where-Object {
            $nameKey = Get-ProgramNameKey $_.DisplayName
            -not $_.MatchKey -or (-not $newByKey.ContainsKey($_.MatchKey) -and (-not $nameKey -or -not $newByName.ContainsKey($nameKey) -or $newByName[$nameKey].Count -ne 1))
        })
        $filteredPrograms = @($allMissingPrograms | Where-Object { -not (Test-UserFacingProgram $_) })
        $missingPrograms = @($allMissingPrograms | Where-Object { Test-UserFacingProgram $_ })
        $matchedPrograms = @($sourcePrograms | Where-Object { $_.MatchKey -and $newByKey.ContainsKey($_.MatchKey) } | ForEach-Object {
            [PSCustomObject]@{ DisplayName = $_.DisplayName; Publisher = $_.Publisher; OldVersion = $_.DisplayVersion; NewVersion = $newByKey[$_.MatchKey].DisplayVersion; VersionDifferent = ($_.DisplayVersion -ne $newByKey[$_.MatchKey].DisplayVersion) }
        })
        $candidateItems = @()
        $filteredAppDataCandidates = @()
        $candidatePath = Join-Path $scriptPath 'Settings\AppDataCandidates.json'
        if ($reviewAppDataCandidates -and (Test-Path -LiteralPath $candidatePath)) {
            $missingWords = @($missingPrograms | ForEach-Object { ConvertTo-ProgramMatchPart $_.DisplayName })
            # Apply the same explicit enumeration for Windows PowerShell 5.1.
            # It also ensures one row is rendered for each AppData candidate.
            $candidateInventory = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
            $candidateItems = @(foreach ($candidate in @($candidateInventory)) {
                # Apply the installed-app exclusions to AppData review too.
                # These folders are provisioned or configured separately and
                # should not create a migration-review action.
                if (-not (Test-UserFacingProgram ([PSCustomObject]@{ DisplayName = $candidate.RelativePath; Publisher = '' }))) {
                    $filteredAppDataCandidates += $candidate
                    continue
                }
                $associationHint = ConvertTo-ProgramMatchPart $candidate.AssociationHint
                $association = if ($associationHint -and ($missingWords | Where-Object { $_ -like "*$associationHint*" })) { 'Potentially associated with missing app' } elseif ($candidate.CoveredByCuratedBackup) { 'Already covered by curated backup' } else { 'Review candidate' }
                [PSCustomObject]@{ Area = $candidate.Area; RelativePath = $candidate.RelativePath; SizeBytes = $candidate.SizeBytes; Association = $association }
            })
        }
        elseif ($reviewAppDataCandidates) { Write-Log 'AppData candidate review skipped: source inventory is missing.' -Level 'Warning' }
        $comparison = [PSCustomObject]@{ GeneratedAt = (Get-Date).ToString('o'); Missing = $missingPrograms; Filtered = $filteredPrograms; Matched = $matchedPrograms; AppDataCandidates = $candidateItems; FilteredAppDataCandidates = $filteredAppDataCandidates }
        $comparison | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logsPath 'AppMigrationComparison.json') -Encoding UTF8
        @('Application migration review', '', "Missing user-facing applications: $($missingPrograms.Count)", "Filtered technical entries: $($filteredPrograms.Count)", "Filtered managed AppData candidates: $($filteredAppDataCandidates.Count)", '') + @($missingPrograms | ForEach-Object { "MISSING | $($_.DisplayName) | $($_.Publisher) | old version: $($_.DisplayVersion)" }) + @('', 'Filtered technical entries:') + @($filteredPrograms | ForEach-Object { "FILTERED | $($_.DisplayName) | $($_.Publisher)" }) + @('', 'Filtered managed AppData candidates:') + @($filteredAppDataCandidates | ForEach-Object { "FILTERED | [$($_.Area)] $($_.RelativePath)" }) + @('', 'AppData candidates:') + @($candidateItems | ForEach-Object { "[$($_.Area)] $($_.RelativePath) | $($_.Association)" }) | Set-Content -LiteralPath (Join-Path $logsPath 'AppMigrationReview.txt') -Encoding UTF8
        (ConvertTo-ReviewHtml -Missing $missingPrograms -Candidates $candidateItems) | Set-Content -LiteralPath (Join-Path $logsPath 'AppMigrationReview.html') -Encoding UTF8
        if (-not $TestMode) { Update-TransferReportFromImport -MissingPrograms $missingPrograms -AppDataCandidates $candidateItems }
        $detail = "$($missingPrograms.Count) missing app(s); $($candidateItems.Count) AppData candidate(s)"
        Write-Log "Application migration review created: $detail" -Level $(if ($missingPrograms.Count -gt 0) { 'Warning' } else { 'Success' })
        Add-Result -Category 'Reference' -Item 'Application migration review' -Status $(if ($missingPrograms.Count -gt 0) { 'Manual' } else { 'Success' }) -Details $detail
        if ($missingPrograms.Count -gt 0 -or $candidateItems.Count -gt 0) {
            Add-ManualTask -Task 'Review applications and AppData' -Reason $detail -Instructions 'Review Logs\AppMigrationReview.html, install/configure required apps, and decide whether any AppData candidate needs manual migration.'
            # The handoff report now contains the interactive application
            # review; do not open a competing standalone browser page.
        }
    } catch {
        Write-Log "Application comparison failed: $($_.Exception.Message)" -Level 'Warning'
        Add-Result -Category 'Reference' -Item 'Application comparison' -Status 'Warning' -Details $_.Exception.Message
        if (-not $TestMode) { Update-TransferReportFromImport -State Failed -Detail $_.Exception.Message }
    }
}

if (Test-Path $programsFile) {
    $programCount = (Get-Content $programsFile | Measure-Object -Line).Lines
    Write-Log "Program list available ($programCount programs documented)" -Level "Info"
    Write-Host "    See: $programsFile" -ForegroundColor Gray
    Add-Result -Category "Reference" -Item "Installed Programs" -Status "Info" -Details "$programCount programs"
}

Write-Host ""

# ============================================================================
# SUMMARY
# ============================================================================

if (-not $isOnlineTransfer) { Invoke-ChromePasswordImport }

Write-Section "Import summary"
Write-Host ""

$Script:Results.EndTime = Get-Date
$duration = $Script:Results.EndTime - $Script:Results.StartTime

$resultCounts = Get-ImportResultCounts
$successCount = $resultCounts.Success
$warningCount = $resultCounts.Warning
$errorCount = $resultCounts.Errors
$skippedCount = $resultCounts.Skipped

Write-Host "  Import complete" -ForegroundColor Green
Write-SummaryCard -Success $successCount -Warning $warningCount -Errors $errorCount -Skipped $skippedCount -Duration "$([math]::Round($duration.TotalMinutes, 1)) min"

$attention = Get-ImportAttentionActions
if ($attention.Count -gt 0) {
    Write-Section "Items needing attention"
    foreach ($action in $attention) {
        $status = switch ($action.Status) {
            'Error' { 'FAIL' }
            'Skipped' { 'SKIP' }
            default { 'WARN' }
        }
        Write-Status "$($action.Category): $($action.Item)" $status $action.Details
    }
    Write-Host ""
}

if ($Script:Results.ManualTasks.Count -gt 0) {
    Write-Section "Manual follow-up instructions"
    foreach ($task in $Script:Results.ManualTasks) {
        Write-Host "  $([char]0x26A0) " -ForegroundColor Yellow -NoNewline
        Write-Host $task.Task -ForegroundColor Yellow
        Write-Host "    $($task.Reason)" -ForegroundColor DarkGray
        if ($task.Instructions) { Write-Host "    $($task.Instructions -replace '[\r\n]+', ' ')" -ForegroundColor Gray }
    }
    Write-Host ""
}

Write-Section "Manual Configuration"
$manualConfigurationSteps = @(
    "Set default apps",
    "Log into all auto-opened apps and verify they work",
    "Log into M365 apps (Teams, Onedrive, Outlook)",
    "Configure Adobe/Bluebeam Revu",
    "Configure Bluebeam Stapler (If installed, sign in/out of Bluebeam)",
    "Connect to STOBG WiFi"
)
foreach ($step in $manualConfigurationSteps) {
    Write-Host "  $([char]0x25A1) " -ForegroundColor DarkGray -NoNewline
    Write-Host $step -ForegroundColor White
}

Write-Section "Verification/Checks"
$verificationSteps = @(
    "Perform a Teams test call",
    "Verify/Resolve Imaging Errors",
    "Verify/Run Lenovo System Update",
    "Verify/Run Windows Updates",
    "Verify Bitlocker is Enabled",
    "Verify Lotus Notes (If still used)",
    "Verify taskbar has no MS Store",
    "Verify data is successfully transferred over",
    "Verify power settings match",
    "Verify printers match",
    "Verify manual drive mappings"
)
foreach ($step in $verificationSteps) {
    Write-Host "  $([char]0x25A1) " -ForegroundColor DarkGray -NoNewline
    Write-Host $step -ForegroundColor White
}
Write-Host ""
Write-Host "  See TransferReport.html for full export details." -ForegroundColor DarkGray
Write-Host ""

# The only elevation path is the narrowly-scoped system helper. It starts only
# after all user-profile work has completed and restores power plus PrintBRM.
# TestMode must never show UAC or launch the helper.
$adminAuditPath = Join-Path $logsPath "AdminImportResult.json"

function Get-SystemExportArtifactProvenance {
    # Packages created before SystemExport.json still receive a useful, clear
    # status based on their legacy settings and files. New packages report the
    # exact attempt that produced each full-system artifact.
    param([ValidateSet('Power', 'PrintBrm')][string]$Artifact)

    $manifestPath = Join-Path $scriptPath 'Settings\SystemExport.json'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $entry = $manifest.$Artifact
            if ($entry) {
                return [PSCustomObject]@{
                    Attempted = [bool]$entry.Attempted
                    CapturedWithAdministratorRights = [bool]$entry.CapturedWithAdministratorRights
                    Status = if ($entry.Status) { [string]$entry.Status } else { 'Unknown' }
                    Detail = if ($entry.Detail) { [string]$entry.Detail } else { '' }
                }
            }
        }
        catch { Write-Log "Could not read system-export provenance: $($_.Exception.Message)" -Level Info }
    }

    $legacySettings = $null
    try { $legacySettings = Get-Content -LiteralPath (Join-Path $scriptPath 'Settings\SystemSettings.json') -Raw | ConvertFrom-Json } catch { }
    $legacyElevated = if ($legacySettings) { [bool]$legacySettings.ExportWasAdministrator } else { $false }
    $legacyArtifactPath = if ($Artifact -eq 'Power') { Join-Path $scriptPath 'Settings\PowerScheme.pow' } else { Join-Path $scriptPath 'Printers\Printers.printerExport' }
    return [PSCustomObject]@{
        Attempted = Test-Path -LiteralPath $legacyArtifactPath
        CapturedWithAdministratorRights = $legacyElevated
        Status = if (Test-Path -LiteralPath $legacyArtifactPath) { 'LegacyPackage' } else { 'Unknown' }
        Detail = 'Legacy package: precise per-artifact elevation provenance is not available.'
    }
}

function Write-SystemExportProvenanceSummary {
    Write-Section 'Printer and power export status'
    foreach ($entry in @(
        @{ Label = 'Full power plan'; Artifact = 'Power' },
        @{ Label = 'PrintBRM printer package'; Artifact = 'PrintBrm' }
    )) {
        $provenance = Get-SystemExportArtifactProvenance -Artifact $entry.Artifact
        $captureContext = if ($provenance.Attempted -and $provenance.Status -in @('Succeeded', 'LegacyPackage')) {
            if ($provenance.CapturedWithAdministratorRights) { 'captured with administrator rights' } else { 'captured without administrator rights' }
        }
        elseif ($provenance.Attempted) { 'attempted without a completed capture' }
        else { 'not available in this package' }
        $detail = if ($provenance.Detail) { " - $($provenance.Detail)" } else { '' }
        Write-Host "  $($entry.Label): $captureContext$detail" -ForegroundColor DarkCyan
    }
    Write-Host '  Administrator export is recommended for the most complete printer and power capture; it remains optional.' -ForegroundColor Yellow
    Write-Host ''
}

function Write-AdminHelperAudit {
    param([string]$Status, [string]$Detail)
    $audit = [PSCustomObject]@{ Timestamp = (Get-Date).ToString("o"); Status = $Status; Detail = $Detail; Source = "Import-LaptopData.ps1" }
    $audit | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $adminAuditPath -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $logsPath "AdminImportLog.txt") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Status] $Detail"
}

function Test-AdminHelperElevationCancelled {
    # ERROR_CANCELLED (1223) is stable across localized UAC dialog text.
    param([System.Exception]$Exception)

    if (-not $Exception) { return $false }
    if ($Exception.Message -match '(?i)cancel|denied|aborted') { return $true }
    try { return (($Exception.HResult -band 0xFFFF) -eq 1223) }
    catch { return $false }
}

function Invoke-StandardSystemRestoreFallback {
    # PrintBRM is the only standard-user fallback. Power settings must remain
    # deferred until the administrator helper is explicitly approved.
    param([string]$HelperPath, [ValidateSet('Both', 'Printers', 'Power')][string]$Scope)

    # If UAC is unavailable, attempt only the printer migration package. Do
    # not let a declined elevation attempt modify any power configuration.
    if ($isAdmin -or $Scope -eq 'Power') { return }
    $printerExport = Join-Path $scriptPath 'Printers\Printers.printerExport'
    if (-not (Test-Path -LiteralPath $printerExport)) { return }

    try {
        Write-Host '  Trying non-administrator fallback for PrintBRM only; power settings remain deferred...' -ForegroundColor Cyan
        $fallbackProcess = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" -AllowStandardUser -Scope Printers"
        if ($fallbackProcess.ExitCode -eq 0) {
            Write-Host '  Non-administrator fallback completed. See Logs\AdminImportLog.txt.' -ForegroundColor Green
            Write-AdminHelperAudit -Status 'FallbackCompleted' -Detail 'UAC was unavailable; standard-user PrintBRM-only fallback completed. Power settings remain deferred.'
        }
        else {
            Write-Host '  Non-administrator PrintBRM fallback could not complete; printer package was retained and power settings remain deferred.' -ForegroundColor Yellow
            Write-AdminHelperAudit -Status 'FallbackPartial' -Detail "UAC was unavailable; PrintBRM-only fallback exited with code $($fallbackProcess.ExitCode). Power settings remain deferred. See AdminImportLog.txt."
        }
    }
    catch {
        Write-Host '  Non-administrator fallback could not start; system packages were retained.' -ForegroundColor Yellow
        Write-AdminHelperAudit -Status 'FallbackFailed' -Detail "Could not start standard-user fallback: $($_.Exception.Message)"
    }
}

Write-SystemExportProvenanceSummary

if ($TestMode) {
    Write-AdminHelperAudit -Status "Skipped" -Detail "TestMode never launches the administrator helper."
}
elseif (-not $enableAdminHelper) {
    Write-AdminHelperAudit -Status "Skipped" -Detail "Optional administrator helper is disabled by package configuration."
}
else {
    Write-Host '  [1] Retry printers and power settings with administrator rights' -ForegroundColor Cyan
    Write-Host '  [2] Retry printers only with administrator rights' -ForegroundColor Cyan
    Write-Host '  [3] Retry power settings only with administrator rights' -ForegroundColor Cyan
    $adminChoice = Read-UserInput '  Select 1-3 (or press Enter to skip)'
    $adminScope = switch ($adminChoice) { '1' { 'Both' }; '2' { 'Printers' }; '3' { 'Power' }; default { $null } }
    if (-not $adminScope) { $enableAdminHelper = $false }
    if (-not $enableAdminHelper) {
        Write-AdminHelperAudit -Status 'Skipped' -Detail 'Technician chose not to run the optional administrator helper.'
        Write-Host '  Elevated power and PrintBRM restore skipped by technician.' -ForegroundColor Yellow
    }
    else {
    $helperPath = Join-Path $scriptPath "Import-SystemSettings.ps1"
    if (-not (Test-Path -LiteralPath $helperPath)) {
        Write-Host "  Administrator helper is missing; system tasks are deferred." -ForegroundColor Yellow
        Write-AdminHelperAudit -Status "Deferred" -Detail "Import-SystemSettings.ps1 is missing."
    }
    else {
        try {
            $scopeLabel = switch ($adminScope) { 'Both' { 'power settings and PrintBRM' }; 'Printers' { 'PrintBRM' }; 'Power' { 'power settings' } }
            Write-Host "  Requesting administrator approval for $scopeLabel..." -ForegroundColor Cyan
            $helperProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -Scope $adminScope"
            if ($helperProcess.ExitCode -eq 0) {
                Write-Host "  Elevated $scopeLabel restore completed. See Logs\\AdminImportLog.txt." -ForegroundColor Green
            }
            else {
                Write-Host "  Administrator helper reported an error; system tasks are deferred." -ForegroundColor Yellow
                Write-AdminHelperAudit -Status "Deferred" -Detail "Helper exited with code $($helperProcess.ExitCode)."
                Invoke-StandardSystemRestoreFallback -HelperPath $helperPath -Scope $adminScope
            }
        }
        catch {
            if (Test-AdminHelperElevationCancelled -Exception $_.Exception) {
                $cancelledMessage = "Administrator $scopeLabel import was requested, but UAC elevation was cancelled. The import will continue with user-level results."
                Write-Host "  $cancelledMessage" -ForegroundColor Red
                Write-Log $cancelledMessage -Level Error
                Add-Result -Category 'System Restore' -Item "Elevated $scopeLabel" -Status 'Error' -Details $cancelledMessage
                Write-AdminHelperAudit -Status 'Cancelled' -Detail "$cancelledMessage $($_.Exception.Message)"
                # Keep this non-terminating: user data and the report still
                # need to finish, and the printer-only fallback can still help.
                Write-Error -Message $cancelledMessage -ErrorAction Continue
            }
            else {
                Write-Host "  Administrator approval could not start; system tasks are deferred." -ForegroundColor Yellow
                Write-AdminHelperAudit -Status "Deferred" -Detail "Could not start UAC elevation: $($_.Exception.Message)"
            }
            Invoke-StandardSystemRestoreFallback -HelperPath $helperPath -Scope $adminScope
        }
    }
    }
}

if (-not $TestMode) { Update-TransferReportImportOutcomes }

function Resolve-PostImportLaunchTarget {
    # Resolve configured alternatives by checking desktop shortcuts first and
    # executable lookup second, keeping launch behavior data-driven.
    param([object]$Alternative, [object]$LaunchConfig)
    foreach ($folder in @($LaunchConfig.DesktopFolders)) {
        if ([string]::IsNullOrWhiteSpace([string]$folder)) { continue }
        $desktopPath = if ([IO.Path]::IsPathRooted([string]$folder)) { [string]$folder } else { Join-Path $env:USERPROFILE ([string]$folder) }
        foreach ($shortcutName in @($Alternative.DesktopShortcuts)) {
            $shortcutPath = Join-Path $desktopPath ([string]$shortcutName)
            if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                return [PSCustomObject]@{ Path = $shortcutPath; Source = 'desktop shortcut'; Name = $Alternative.Name }
            }
        }
    }
    foreach ($commandName in @($Alternative.Commands)) {
        if ([string]::IsNullOrWhiteSpace([string]$commandName)) { continue }
        $command = Get-Command -Name ([string]$commandName) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Path) {
            return [PSCustomObject]@{ Path = $command.Path; Source = 'installed command'; Name = $Alternative.Name }
        }
    }
    return $null
}

function Start-PostImportHandoff {
    # Open the final report and configured handoff applications only after all
    # restoration work is complete; launch failures remain non-fatal.
    $reportPath = Join-Path $scriptPath 'TransferReport.html'
    try {
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'TransferReport.html is missing from this package.' }
        Start-Process -FilePath $reportPath -ErrorAction Stop
        Write-Log 'Opened transfer report at import completion.' -Level 'Success'
    }
    catch {
        Write-Log "Could not open transfer report: $($_.Exception.Message)" -Level 'Warning'
        Write-Host "  Could not open TransferReport.html: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not $postImportLaunchConfig -or -not $postImportLaunchConfig.Enabled) { return }
    $launchApps = Read-UserInput '  Open the standard handoff applications too? (Y/N) [N]'
    if ($launchApps -notmatch '^[Yy]') {
        Write-Log 'Technician chose report-only completion view.' -Level 'Info'
        return
    }

    Write-Host '  Opening configured handoff applications...' -ForegroundColor Cyan
    foreach ($target in @($postImportLaunchConfig.Targets)) {
        $resolved = $null
        foreach ($alternative in @($target.Alternatives)) {
            $resolved = Resolve-PostImportLaunchTarget -Alternative $alternative -LaunchConfig $postImportLaunchConfig
            if ($resolved) { break }
        }
        if (-not $resolved) {
            Write-Log "Post-import app not found: $($target.Name)" -Level 'Warning'
            Write-Host "  Skipped: $($target.Name) (not found)" -ForegroundColor Yellow
            continue
        }
        try {
            Start-Process -FilePath $resolved.Path -ErrorAction Stop
            Write-Log "Opened post-import app: $($target.Name) using $($resolved.Name) ($($resolved.Source))" -Level 'Success'
            Write-Host "  Opened: $($target.Name)" -ForegroundColor Green
        }
        catch {
            Write-Log "Could not open post-import app $($target.Name): $($_.Exception.Message)" -Level 'Warning'
            Write-Host "  Could not open: $($target.Name)" -ForegroundColor Yellow
        }
    }
}

if (-not $TestMode) {
    Start-PostImportHandoff
}

if (-not $TestMode -and $Script:OpenDefaultAppsAtCompletion) {
    try { Start-Process 'ms-settings:defaultapps' -ErrorAction Stop; Write-Log 'Opened Default apps at import completion.' -Level Success }
    catch { Write-Log "Could not open Default apps: $($_.Exception.Message)" -Level Warning }
}

if (-not $TestMode) {
    Read-UserInput "  Press Enter to exit" | Out-Null
}
'@

    # Replace placeholders
    $importScript = $importScript -replace '\{TIMESTAMP\}', (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $importScript = $importScript -replace '\{USERNAME\}', $Script:OriginalUserName
    $importScript = $importScript -replace '\{COMPUTERNAME\}', $env:COMPUTERNAME
    $importScript = $importScript -replace '\{IMPORT_LOTUS_NOTES\}', $Script:Config.Import.LotusNotes.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{IMPORT_APP_COMPARISON\}', $Script:Config.Import.AppComparison.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{IMPORT_APPDATA_REVIEW\}', $Script:Config.Import.AppDataReview.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{DELETE_PRINTBRM_AFTER_IMPORT\}', $Script:Config.Import.DeletePrintBrmAfterImport.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{ENABLE_ADMIN_HELPER\}', $Script:Config.Import.EnableAdminHelper.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{IS_ONLINE_TRANSFER\}', ($Script:Config.TransferMode -eq 'Online').ToString().ToLowerInvariant()
    # Preserve compatibility with callers that construct a minimal Import
    # hashtable instead of loading the full development configuration.
    $postImportLaunchProfile = $Script:Config.Import.PostImportLaunch
    if (-not $postImportLaunchProfile -and $Script:DevelopmentConfig) { $postImportLaunchProfile = $Script:DevelopmentConfig.Import.PostImportLaunch }
    if (-not $postImportLaunchProfile) { $postImportLaunchProfile = @{ Enabled = $false; DesktopFolders = @(); Targets = @() } }
    $postImportLaunchJson = $postImportLaunchProfile | ConvertTo-Json -Depth 8 -Compress
    $postImportLaunchConfigBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($postImportLaunchJson))
    $importScript = $importScript -replace '\{POST_IMPORT_LAUNCH_CONFIG_BASE64\}', $postImportLaunchConfigBase64
    $appComparisonPatterns = @($Script:Config.Import.AppComparisonExcludePatterns)
    if (-not $appComparisonPatterns.Count -and $Script:DevelopmentConfig) { $appComparisonPatterns = @($Script:DevelopmentConfig.Import.AppComparisonExcludePatterns) }
    # ConvertTo-Json emits no pipeline output for an empty collection in some
    # Windows PowerShell versions.  Always serialize an array so generated
    # packages have a valid, decodable filter configuration.
    $appComparisonPatternsJson = ConvertTo-Json -InputObject @($appComparisonPatterns) -Compress
    if ($null -eq $appComparisonPatternsJson) { $appComparisonPatternsJson = '[]' }
    $appComparisonPatternsBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($appComparisonPatternsJson))
    $importScript = $importScript -replace '\{APP_COMPARISON_EXCLUDE_PATTERNS_BASE64\}', $appComparisonPatternsBase64
    
    $importScriptPath = Join-Path $DestinationBase "Import-LaptopData.ps1"
    $importScript | Out-File $importScriptPath -Encoding UTF8
    
    Write-Log "Import script generated" -Level Success
    Add-Result -Category "Scripts" -Item "Import-LaptopData.ps1" -Status "Success" -Details "Ready for new machine"
}


function New-AdminImportScript {
    # Emit the isolated administrator helper with a narrow input surface and
    # audit log.  User-profile restoration intentionally stays outside it.
    param([string]$DestinationBase)

    # This helper deliberately has no user-profile, HKCU, drive-mapping, or
    # shared-printer work.  It can safely run under an administrator account.
    $helperScript = @'
<#
.SYNOPSIS
    STO Building Group Laptop Transfer - Optional Administrator Helper
.DESCRIPTION
    Applies only system power settings and local/direct-IP printers from the
    transfer package. It normally runs elevated; -AllowStandardUser is used
    only as a logged fallback when destination UAC is unavailable.
#>
#Requires -Version 5.1
param(
    [switch]$AllowStandardUser,
    # PrintBrmOnly is retained for packages that were generated before Scope
    # was introduced. New callers explicitly choose Both, Printers, or Power.
    [switch]$PrintBrmOnly,
    [ValidateSet('Both', 'Printers', 'Power')][string]$Scope = 'Both'
)
if ($PrintBrmOnly) { $Scope = 'Printers' }
$restorePower = $Scope -in @('Both', 'Power')
$restorePrinters = $Scope -in @('Both', 'Printers')
$ErrorActionPreference = 'Continue'
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsPath = Join-Path $scriptPath 'Logs'
New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
$logPath = Join-Path $logsPath 'AdminImportLog.txt'
$resultPath = Join-Path $logsPath 'AdminImportResult.json'
$result = [ordered]@{
    StartTime = (Get-Date).ToString('o'); EndTime = $null; Status = 'Running'
    Elevated = $false; Power = @(); PrintBrm = [ordered]@{ PackagePresent = $false; ToolPresent = $false; ExitCode = $null; Status = 'Skipped' }
    PrinterStatus = @(); Errors = @()
}
function Write-Audit([string]$Message, [string]$Level = 'Info') {
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $logPath -Value $line
    Write-Host "  $Message" -ForegroundColor $(if($Level -eq 'Error'){'Red'}elseif($Level -eq 'Warning'){'Yellow'}else{'Gray'})
}
function Save-Result {
    $result.EndTime = (Get-Date).ToString('o')
    [PSCustomObject]$result | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}
$result.Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $result.Elevated -and -not $AllowStandardUser) {
    $result.Status = 'Denied'
    $result.Errors += 'Administrator privileges are required.'
    Write-Audit 'Administrator privileges are required; no changes were made.' 'Error'
    Save-Result
    exit 1
}
if (-not $result.Elevated -and $AllowStandardUser) {
    if ($Scope -ne 'Printers') {
        $result.Status = 'Denied'
        $result.Errors += 'The standard-user fallback is limited to printers.'
        Write-Audit 'Standard-user fallback was asked to restore power; no changes were made.' 'Error'
        Save-Result
        exit 1
    }
    Write-Audit 'Running explicit non-administrator PrintBRM-only fallback; power settings will not be attempted.' 'Warning'
}

$settingsFile = Join-Path $scriptPath 'Settings\SystemSettings.json'
$powerScheme = Join-Path $scriptPath 'Settings\PowerScheme.pow'
$settingsData = $null
if (Test-Path -LiteralPath $settingsFile) {
    try { $settingsData = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { $result.Errors += "Could not read SystemSettings.json: $($_.Exception.Message)" }
}

# Legacy packages have only a .pow file. New packages keep the managed plan
# and receive their captured AC/DC values one by one.
if (-not $restorePower) {
    $result.Power += [PSCustomObject]@{ Item = 'Power settings'; Status = 'Skipped'; Detail = 'Deferred: non-administrator fallback is PrintBRM-only' }
    Write-Audit 'Power settings deferred because this is a PrintBRM-only fallback.' 'Info'
}
elseif (Test-Path -LiteralPath $powerScheme) {
    try {
        $guid = [guid]::NewGuid().ToString()
        $output = & powercfg /import $powerScheme $guid 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg /import exit ${LASTEXITCODE}: $(($output | Out-String).Trim())" }
        $output = & powercfg /setactive $guid 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive exit ${LASTEXITCODE}: $(($output | Out-String).Trim())" }
        $result.Power += [PSCustomObject]@{ Item = 'Full power scheme'; Status = 'Success'; Detail = "Imported and activated $guid" }
        Write-Audit 'Full power scheme imported and activated.' 'Success'
    } catch { $result.Power += [PSCustomObject]@{ Item = 'Full power scheme'; Status = 'Failed'; Detail = $_.Exception.Message }; $result.Errors += $_.Exception.Message; Write-Audit "Power scheme failed: $_" 'Error' }
}
if ($restorePower -and $settingsData.PowerSettingValues -and @($settingsData.PowerSettingValues).Count) {
    foreach ($setting in @($settingsData.PowerSettingValues)) {
        foreach ($kind in @(@{ Name='AC'; Command='/setacvalueindex'; Value=[string]$setting.ACValue }, @{ Name='DC'; Command='/setdcvalueindex'; Value=[string]$setting.DCValue })) {
            if (-not $kind.Value) { continue }
            $output = & powercfg $kind.Command SCHEME_CURRENT $setting.SubgroupGuid $setting.SettingGuid $kind.Value 2>&1
            $status = if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Failed' }
            $detail = if ($LASTEXITCODE -eq 0) { "$($setting.SettingGuid) $($kind.Name)" } else { "$(($output | Out-String).Trim())" }
            $result.Power += [PSCustomObject]@{ Item = 'Individual power setting'; Status = $status; Detail = $detail }
            if ($status -eq 'Failed') { $result.Errors += "Power setting $detail"; Write-Audit "Power setting failed: $detail" 'Warning' }
        }
    }
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
}
if ($restorePower -and $settingsData.LidClose -and $settingsData.LidClose.OnAC) {
    $map = @{ 'Do Nothing'=0; Sleep=1; Hibernate=2; 'Shut Down'=3 }
    foreach ($kind in @(@{ Command='/setacvalueindex'; Value=$map[$settingsData.LidClose.OnAC] }, @{ Command='/setdcvalueindex'; Value=$map[$settingsData.LidClose.OnBattery] })) {
        if ($null -ne $kind.Value) { & powercfg $kind.Command SCHEME_CURRENT SUB_BUTTONS LIDACTION $kind.Value 2>&1 | Out-Null }
    }
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    $result.Power += [PSCustomObject]@{ Item = 'Lid actions'; Status = 'Attempted'; Detail = "AC: $($settingsData.LidClose.OnAC); DC: $($settingsData.LidClose.OnBattery)" }
}
if ($restorePower -and $settingsData) {
    $capturedOverlay = if ($settingsData.PowerMode -and $settingsData.PowerMode.RequestedOverlayGuid) { [string]$settingsData.PowerMode.RequestedOverlayGuid }
        elseif ($settingsData.PowerMode -and $settingsData.PowerMode.EffectiveOverlayGuid) { [string]$settingsData.PowerMode.EffectiveOverlayGuid }
        elseif ($settingsData.PowerModeOverlay -and $settingsData.PowerModeOverlay.ActiveOverlayAcPowerScheme) { [string]$settingsData.PowerModeOverlay.ActiveOverlayAcPowerScheme }
        elseif ($settingsData.PowerModeOverlay) { [string]$settingsData.PowerModeOverlay.ActiveOverlayDcPowerScheme }
    if ($capturedOverlay -match '^[0-9a-fA-F-]{36}$') {
        try {
            if (-not ('StoAdminPowerOverlay' -as [type])) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StoAdminPowerOverlay {
    [DllImport("PowrProf.dll", EntryPoint="PowerSetActiveOverlayScheme", SetLastError=true)]
    public static extern uint PowerSetActiveOverlayScheme(Guid overlaySchemeGuid);
    [DllImport("PowrProf.dll", EntryPoint="PowerGetEffectiveOverlayScheme")]
    public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlaySchemeGuid);
}
"@ -ErrorAction Stop
            }
            $overlayGuid = [guid]$capturedOverlay
            $setResult = [StoAdminPowerOverlay]::PowerSetActiveOverlayScheme($overlayGuid)
            if ($setResult -ne 0) { throw "PowerSetActiveOverlayScheme returned $setResult." }
            $effectiveGuid = [guid]::Empty
            $effectiveResult = [StoAdminPowerOverlay]::PowerGetEffectiveOverlayScheme([ref]$effectiveGuid)
            $detail = if ($effectiveResult -eq 0 -and $effectiveGuid.ToString() -ne $capturedOverlay) { "Applied $capturedOverlay; effective overlay is $effectiveGuid (policy or hardware override)." } else { "Applied and verified $capturedOverlay." }
            $status = if ($effectiveResult -eq 0 -and $effectiveGuid.ToString() -ne $capturedOverlay) { 'Warning' } else { 'Success' }
            $result.Power += [PSCustomObject]@{ Item = 'Windows power mode'; Status = $status; Detail = $detail }
            Write-Audit "Windows power mode: $detail" $(if($status -eq 'Success'){'Success'}else{'Warning'})
        }
        catch {
            $result.Power += [PSCustomObject]@{ Item = 'Windows power mode'; Status = 'Failed'; Detail = $_.Exception.Message }
            $result.Errors += "Windows power mode: $($_.Exception.Message)"
            Write-Audit "Windows power mode failed: $($_.Exception.Message)" 'Warning'
        }
    }
}

$printerExport = Join-Path $scriptPath 'Printers\Printers.printerExport'
$printBrm = Join-Path $env:WINDIR 'System32\spool\tools\PrintBrm.exe'
$result.PrintBrm.PackagePresent = Test-Path -LiteralPath $printerExport
$result.PrintBrm.ToolPresent = Test-Path -LiteralPath $printBrm
if ($restorePrinters -and $result.PrintBrm.PackagePresent -and $result.PrintBrm.ToolPresent) {
    try {
        $brmLog = Join-Path $logsPath 'printbrm_restore.log'
        & $printBrm -R -F $printerExport -O FORCE *>&1 | Tee-Object -LiteralPath $brmLog | Out-Null
        $result.PrintBrm.ExitCode = $LASTEXITCODE
        $result.PrintBrm.Status = if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Failed' }
        $result.PrinterStatus += [PSCustomObject]@{ Item='Local/direct-IP printers'; Status=$result.PrintBrm.Status; Detail="PrintBRM exit $LASTEXITCODE" }
        if ($LASTEXITCODE -eq 0 -and [bool]::Parse('{DELETE_PRINTBRM_AFTER_IMPORT}')) { Remove-Item -LiteralPath $printerExport -Force; Write-Audit 'PrintBRM succeeded; migration package deleted.' 'Success' }
        elseif ($LASTEXITCODE -ne 0) { Write-Audit "PrintBRM failed with exit $LASTEXITCODE; package retained." 'Warning' }
    } catch { $result.PrintBrm.Status='Failed'; $result.Errors += "PrintBRM error: $($_.Exception.Message)"; Write-Audit "PrintBRM error: $_; package retained." 'Error' }
} elseif ($restorePrinters -and $result.PrintBrm.PackagePresent) { $result.PrintBrm.Status='Skipped'; $result.PrinterStatus += [PSCustomObject]@{ Item='Local/direct-IP printers'; Status='Skipped'; Detail='PrintBRM.exe not found' } }
elseif (-not $restorePrinters) { $result.PrintBrm.Status='Skipped'; $result.PrinterStatus += [PSCustomObject]@{ Item='Local/direct-IP printers'; Status='Skipped'; Detail='Not selected for this administrator retry' } }

$result.Status = if ($result.Errors.Count) { 'CompletedWithErrors' } else { 'Completed' }
Save-Result
Write-Audit "Administrator helper $($result.Status)." $(if($result.Errors.Count){'Warning'}else{'Success'})
exit $(if($result.Errors.Count){1}else{0})
'@
    $helperScript = $helperScript -replace '\{DELETE_PRINTBRM_AFTER_IMPORT\}', $Script:Config.Import.DeletePrintBrmAfterImport.ToString().ToLowerInvariant()
    $helperPath = Join-Path $DestinationBase 'Import-SystemSettings.ps1'
    $helperScript | Out-File -LiteralPath $helperPath -Encoding UTF8
    Write-Log 'Administrator helper generated' -Level Success
    Add-Result -Category 'Scripts' -Item 'Import-SystemSettings.ps1' -Status 'Success' -Details 'Optional elevated system settings helper'
}

# ============================================================================
# HTML REPORT GENERATOR
# ============================================================================
# Report generation is deliberately last-mile: it reads the structured result
# ledger and substitutes escaped values into a static HTML template.  It does
# not infer success from console text or filesystem guesses.

function Get-TransferReportTemplate {
    # Cache the template after the first read because report generation may be
    # retried and the template is immutable for the lifetime of this process.
    if ($Script:TransferReportTemplate) { return $Script:TransferReportTemplate }
    $templatePath = Join-Path $PSScriptRoot 'TransferReport.template.html'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Transfer report template is missing: $templatePath" }
    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function New-TransferReport {
    # Freeze timing, classify actions, render manual handoff tasks, and write a
    # self-contained report.  HTML encoding is applied at every dynamic field
    # boundary so paths and user-controlled names cannot alter the markup.
    param([string]$DestinationBase)

    $Script:Results.EndTime = Get-Date
    $duration = $Script:Results.EndTime - $Script:Results.StartTime
    $resultCounts = Get-TransferResultCounts
    $successCount = $resultCounts.Success
    $warningCount = $resultCounts.Warning
    $errorCount = $resultCounts.Errors
    $skippedCount = $resultCounts.Skipped

    # Keep the handoff blockers visible: an otherwise successful item must not
    # bury a skipped, manual, warning, or failed action lower in the report.
    $actionPriority = {
        param($Action)
        switch -Regex ([string]$Action.Status) {
            'Error|NOT EXPORTED|Admin Required' { return 0 }
            'Warning' { return 1 }
            'Skipped|Manual|Pending' { return 2 }
            'Success' { return 4 }
            default { return 3 }
        }
    }
    $orderedActions = @($Script:Results.Actions | Sort-Object @{ Expression = { & $actionPriority $_ } }, @{ Expression = { $_.Timestamp } })
    $actionRows = foreach ($action in $orderedActions) {
        $statusClass = switch -Regex ($action.Status) {
            'Success' { 'status-success'; break }; 'Warning' { 'status-warning'; break }
            'Error|NOT EXPORTED|Admin Required' { 'status-error'; break }; 'Skipped' { 'status-skipped'; break }
            default { 'status-warning' }
        }
        "<tr><td>$(Out-HtmlEncoded $action.Category)</td><td>$(Out-HtmlEncoded $action.Item)</td><td><span class='status $statusClass'>$(Out-HtmlEncoded $action.Status)</span></td><td>$(Out-HtmlEncoded $action.Details)</td></tr>"
    }
    if (-not $actionRows) { $actionRows = '<tr><td colspan="4">No export actions were recorded.</td></tr>' }

    # Warnings emitted to the console are frequently contextual rather than a
    # single copy-stage result. Preserve them in the handoff report even when
    # the originating code did not also call Add-Result.
    $runtimeAlerts = @($Script:Results.RuntimeAlerts | Where-Object { $_.Level -in @('Warning', 'Error') })
    $runtimeAlertSection = if ($runtimeAlerts.Count) {
        $alertRows = foreach ($alert in $runtimeAlerts) {
            $class = if ($alert.Level -eq 'Error') { 'status-error' } else { 'status-warning' }
            "<tr><td>$(Out-HtmlEncoded $alert.Timestamp)</td><td><span class='status $class'>$(Out-HtmlEncoded $alert.Level)</span></td><td>$(Out-HtmlEncoded $alert.Message)</td></tr>"
        }
        "<details class='section' open><summary>Console warnings and errors<span>$($runtimeAlerts.Count) message(s), including warnings without an export-action row</span></summary><div class='section-content'><table><thead><tr><th>Time</th><th>Level</th><th>Message</th></tr></thead><tbody>$($alertRows -join "`n")</tbody></table></div></details>"
    }
    else { '' }

    $adminTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match 'admin|Administrator|privileges' })
    $adminBanner = ''
    if (-not $Script:IsAdmin -and $adminTasks.Count) {
        $adminRows = foreach ($task in $adminTasks) {
            "<div class='manual-task critical'><h4>$(Out-HtmlEncoded $task.Task)</h4><p><strong>Why not captured:</strong> $(Out-HtmlEncoded $task.Reason)</p><pre>$(Out-HtmlEncoded $task.Instructions)</pre></div>"
        }
        $adminBanner = "<section class='critical-warning'><h2>INCOMPLETE EXPORT - ADMIN RIGHTS REQUIRED</h2><p>$($adminTasks.Count) item(s) require manual capture before wiping the old laptop.</p></section><section class='section'><div class='section-header'>Not captured - manual action required</div><div class='section-content'>$($adminRows -join "`n")</div></section>"
    }
    elseif ($Script:IsAdmin) { $adminBanner = "<section class='admin-success'>Full export completed with administrator rights.</section>" }

    $otherTasks = if ($Script:IsAdmin) { @($Script:Results.ManualTasks) } else { @($Script:Results.ManualTasks | Where-Object { $_.Reason -notmatch 'admin|Administrator|privileges' }) }
    $manualTasks = if ($otherTasks.Count) {
        ($otherTasks | ForEach-Object { "<div class='manual-task'><h4>$(Out-HtmlEncoded $_.Task)</h4><p>$(Out-HtmlEncoded $_.Reason)</p><pre>$(Out-HtmlEncoded $_.Instructions)</pre></div>" }) -join "`n"
    } else { '<p class="success-text">No additional manual tasks required.</p>' }

    $html = Get-TransferReportTemplate
    $replacements = @{
        '{{USER}}' = Out-HtmlEncoded $Script:Results.UserName; '{{COMPUTER}}' = Out-HtmlEncoded $Script:Results.ComputerName
        '{{SOURCE_COMPUTER}}' = Out-HtmlEncoded $Script:Results.ComputerName; '{{DESTINATION_COMPUTER}}' = 'Pending import on new computer'
        '{{MODE}}' = Out-HtmlEncoded $Script:Config.TransferMode; '{{DATE}}' = (Get-Date -Format "MMMM dd, yyyy 'at' h:mm tt")
        '{{DURATION}}' = "$([math]::Round($duration.TotalMinutes, 1)) minutes"; '{{SUCCESS_COUNT}}' = $successCount
        '{{WARNING_COUNT}}' = $warningCount; '{{ERROR_COUNT}}' = $errorCount; '{{SKIPPED_COUNT}}' = $skippedCount
        '{{ADMIN_BANNER}}' = $adminBanner; '{{ACTION_ROWS}}' = ($actionRows -join "`n"); '{{RUNTIME_ALERTS}}' = $runtimeAlertSection; '{{MANUAL_TASKS}}' = $manualTasks
        '{{APP_MIGRATION_SECTION}}' = '<div class="app-summary"><h3>Comparison pending</h3><p>Run the import on the new computer to identify applications that still need installation.</p></div>'
        '{{VERSION}}' = $Script:Config.Version; '{{YEAR}}' = (Get-Date -Format 'yyyy')
    }
    foreach ($token in $replacements.Keys) { $html = $html.Replace($token, [string]$replacements[$token]) }
    $reportPath = Join-Path $DestinationBase 'TransferReport.html'
    # Use an explicit UTF-8 BOM. Windows PowerShell and PowerShell 7 otherwise
    # differ here, and some file associations decode a BOM-less local report as
    # the ANSI code page (shown as "Â·" / "âˆ’" in the supplied report).
    [System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($true))
    Write-Log 'Transfer report generated' -Level Success
    return $reportPath
}
# Main coordinates the ordered export lifecycle.  The numbered build order
# supplies its dependencies; this file should mostly orchestrate and should
# not duplicate copy, logging, or formatting implementations.

function New-QuickImportBatch {
    # Emit a tiny operator-facing launcher.  It intentionally invokes the
    # user-context import first; that generated script owns any narrowly scoped
    # administrator helper needed after user-scoped restoration.
    param(
        [string]$DestinationBase
    )

    $batPath = Join-Path $DestinationBase "QuickImport.bat"

    # The user-context import owns any optional elevation after it finishes.
    $batContent = @"
@echo off
title STO Laptop Transfer - Quick Import

echo.
echo ============================================
echo    STO Laptop Transfer - Quick Import
echo ============================================
echo.
echo Running import script as the current signed-in user...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-LaptopData.ps1"

:Complete
set IMPORT_EXIT=%errorlevel%

echo.
echo ============================================
if %IMPORT_EXIT% neq 0 (
    echo Import finished with exit code %IMPORT_EXIT%. Review messages above.
) else (
    echo Import complete.
)
"@

    $batContent | Out-File $batPath -Encoding ASCII

    Write-Log "QuickImport.bat created" -Level Success
    Add-Result -Category "Scripts" -Item "QuickImport.bat" -Status "Success"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Start-LaptopExport {
    # Drive the complete state machine: resolve mode and settings, choose a
    # destination, execute enabled stages, generate the import/report artifacts,
    # and optionally create the online ZIP.  Each stage records its own result,
    # allowing the final report to distinguish success, omission, and failure.
    Clear-StoScreen
    Write-StoLogo
    Write-Banner -Title 'Laptop Transfer  -  Export Tool' -Subtitle "v$($Script:Config.Version)"

    # Resolve transfer mode: honor -TransferMode param, else prompt.
    if ($TransferMode -in @("Local", "Online")) {
        $Script:Config.TransferMode = $TransferMode
    }
    else {
        Resolve-TransferMode
    }

    Apply-OnlineTransferDefaults
    if (-not $ElevatedFromSettings) {
        # Each newly selected transfer begins from the safe, lean preset.
        Set-SettingsPreset -Name Basic
    }
    elseif ($Script:Config.Backup.EntireUserProfile -and $Script:Config.Backup.AdditionalAppData) {
        $Script:SettingsPreset = 'Advanced'
    }
    elseif (-not $Script:Config.Backup.EntireUserProfile -and -not $Script:Config.Backup.AdditionalAppData) {
        $Script:SettingsPreset = 'Basic'
    }
    else {
        $Script:SettingsPreset = 'Custom'
    }
    if ($ElevatedFromSettings) {
        Write-Log "Transfer Settings restored after administrator approval" -Level Info
    }
    elseif ($NonInteractive) {
        # Browsers can require a close/password-export prompt. Leave them out
        # of unattended validation runs rather than hanging partway through.
        $Script:Config.Backup.Chrome = 'Off'
        $Script:Config.Backup.Firefox = $false
        $Script:Config.Backup.Edge = $false
        # PrintBRM and ZIP compression can outlive automation time limits; the
        # package and all generated artifacts are still exercised by validation
        # runs. Normal technician exports retain both stages.
        $Script:Config.Backup.Printers = $false
        $Script:Config.Transfer.CreateZipArchive = $false
        Write-Log "Non-interactive mode: browser collection, PrintBRM, and ZIP creation disabled" -Level Info
    }
    if (-not $ElevatedFromSettings -and -not $NonInteractive) { $Script:TransferSizeEstimateJob = Start-TransferSizeEstimateJob }
    if (-not $NonInteractive -and -not (Show-BackupOverview)) {
        Write-Host "`n  Transfer cancelled." -ForegroundColor Yellow
        return
    }

    # The reported export time starts at the technician's final Start choice,
    # not while they are reviewing settings. Preserve it through optional UAC.
    if (-not $ElevatedFromSettings) {
        $Script:TransferStartedAt = Get-Date
        $Script:Results.StartTime = $Script:TransferStartedAt
        Write-Log "Transfer clock started after settings confirmation." -Level Info
    }

    if (-not (Start-ElevatedExport)) { return }

    # Non-interactive runs must receive an explicit destination. Never fall
    # back to a drive selector or Windows folder picker in automation.
    if ($NonInteractive) {
        if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
            throw "Non-interactive export requires -DestinationPath. No files were copied."
        }
        $destinationFolder = $DestinationPath
        if (Test-DestinationIsWithinSourceProfile -Path $destinationFolder) {
            throw "Non-interactive export destination is inside the source profile. No files were copied."
        }
    }
    elseif ($Script:Config.TransferMode -eq "Local") {
        # Local interactive mode retains the external/secondary-drive selector.
        $destinationFolder = Select-TargetDrive
    }
    else {
        # Online interactive mode uses the Windows folder picker.
        $destinationFolder = Select-TargetDestination
    }
    if (-not $destinationFolder) {
        Write-Host "`n  Export cancelled: no usable destination was selected. No files were copied." -ForegroundColor Yellow
        if (-not $NonInteractive) { Read-UserInput "  Press Enter to exit" | Out-Null }
        return
    }

    $createsZipArchive = [bool]$Script:Config.Transfer.CreateZipArchive
    $isNetworkDestination = $Script:Config.TransferMode -eq "Online" -and (Test-NetworkDestination -Path $destinationFolder)
    $useLocalStaging = $isNetworkDestination -and $createsZipArchive -and $Script:Config.Online.StageNetworkTransfersLocally
    $stagingAppData = if ($Script:OriginalAppDataLocal) { $Script:OriginalAppDataLocal } else { $env:LOCALAPPDATA }
    $stagingRoot = Join-Path $stagingAppData "STO Building Group\LaptopTransferStaging"
    $workingFolder = $destinationFolder
    if ($useLocalStaging) {
        try {
            New-Item -ItemType Directory -Path $stagingRoot -Force -ErrorAction Stop | Out-Null
            $workingFolder = $stagingRoot
            Write-Section "Network transfer staging"
            Write-KeyValue "Network destination" $destinationFolder
            Write-KeyValue "Local staging" $stagingRoot
            Write-Host "  Files will be collected and zipped locally before one ZIP is uploaded." -ForegroundColor DarkGray
        }
        catch {
            Write-Host "Could not create local staging folder '$stagingRoot': $_" -ForegroundColor Red
            return
        }
    }

    # ---- Pre-scan + free-space check ----
    # Estimate what we're about to copy so we can (a) warn on insufficient space
    # and (b) show the operator the size up front. In online mode this reflects
    # the selected transfer set.
    Write-Section "Estimating transfer size"
    # The background estimate is for responsive UI only. Recalculate the
    # authoritative preflight estimate here so changed toggles, additional
    # folders, loose profile files, and OCS Documents are included.
    Write-Host '  Calculating final payload estimate...' -ForegroundColor Cyan
    $payloadEstimate = Get-TransferPayloadEstimate
    $estBytes = $payloadEstimate.TotalBytes
    Write-KeyValue "Estimated size" (Format-FileSize $estBytes)
    if ($Script:Config.TransferMode -eq "Online") {
        Write-KeyValue "Online payload limit" "$($Script:Config.Online.MaxTransferGB) GB"
        if ($estBytes -gt ($Script:Config.Online.MaxTransferGB * 1GB)) {
            $message = "Selected Online payload ($(Format-FileSize $estBytes)) exceeds the $($Script:Config.Online.MaxTransferGB) GB limit."
            Write-Host ""; Write-Host "  $($Script:Theme.Glyphs.WARN) $message" -ForegroundColor Yellow
            if ($NonInteractive) { throw "Non-interactive export stopped because: $message" }
            $continueLargePayload = Read-UserInput "    Export anyway? (Y/N)"
            if ($continueLargePayload -notmatch "^[Yy]") { Write-Host "  Cancelled. No files were copied." -ForegroundColor Yellow; return }
        }
    }

    try {
        $freeBytes = Get-DestinationFreeSpaceBytes -Path $workingFolder
        $networkFreeBytes = if ($useLocalStaging) { Get-DestinationFreeSpaceBytes -Path $destinationFolder } else { $null }
    }
    catch {
        # A provider that cannot report capacity (some cloud folders, for
        # example) must not prevent an export. Only the query itself is
        # best-effort; warnings calculated below still control the flow.
        Write-Log "Could not read free space at $destinationFolder (continuing)" -Level Info
        $freeBytes = $null
        $networkFreeBytes = $null
    }

    if ($null -ne $freeBytes) {
        $freeLabel = if ($useLocalStaging) { "Free in local staging" } else { "Free at destination" }
        Write-KeyValue $freeLabel (Format-FileSize $freeBytes)
    }
    # Online mode needs extra space only when it will also create a ZIP.
    $spaceMultiplier = if ($createsZipArchive) { 2.15 } else { 1.15 }
    $requiredFreeBytes = [math]::Ceiling($estBytes * $spaceMultiplier)
    $spaceWarnings = @()
    if ($freeBytes -gt 0 -and $freeBytes -lt $requiredFreeBytes) {
        $spaceLocation = if ($useLocalStaging) { "local staging location" } else { "destination" }
        $spaceDetail = if ($createsZipArchive) { "the package and ZIP archive" } else { "the transfer package" }
        $spaceWarnings += "The $spaceLocation may not have enough space for $spaceDetail."
    }
    if ($useLocalStaging) {
        if ($null -ne $networkFreeBytes) {
            Write-KeyValue "Free at network destination" (Format-FileSize $networkFreeBytes)
        }
        if ($networkFreeBytes -gt 0 -and $networkFreeBytes -lt [math]::Ceiling($estBytes * 1.15)) {
            $spaceWarnings += "The network destination may not have enough space for the ZIP archive."
        }
    }
    if ($spaceWarnings.Count -gt 0) {
        if ($NonInteractive) {
            throw "Non-interactive export stopped because: $($spaceWarnings -join ' ')"
        }
        Write-Host ""
        Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
        Write-Host ($spaceWarnings -join " ") -ForegroundColor White
        $go = Read-UserInput "    Continue anyway? (Y/N)"
        if ($go -notmatch "^[Yy]") { Write-Host "  Cancelled." -ForegroundColor Yellow; return }
    }

    # Create transfer folder structure
    $transferBase = Join-Path $workingFolder $Script:Config.TransferFolderName
    
    Write-KeyValue "Transfer folder" $transferBase
    
    $folders = @("UserData", "AppData", "Settings", "BrowserData", "Printers", "Logs")
    foreach ($folder in $folders) {
        $path = Join-Path $transferBase $folder
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    
    Write-Log "Transfer folder created at $transferBase" -Level Success
    
    # Execute export tasks
    Write-Banner -Title "Starting Export Process ($($Script:Config.TransferMode))"
    
    # 1. Copy standard user folders and, when selected, the remainder of the
    # profile. The latter excludes content captured by other stages.
    if ($Script:Config.Backup.UserData -or $Script:Config.Backup.Downloads -or $Script:Config.Backup.EntireUserProfile) {
        Copy-UserFolders -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "User data" -Category "User Folders"; Add-DisabledBackupResult -Item "Entire user profile" -Category "User Folders" }
    
    # 2. Copy AppData
    if ($Script:Config.Backup.AppData) {
        Copy-AppData -DestinationBase $transferBase
        if ($Script:Config.Backup.AdditionalAppData) { Copy-SelectedAdditionalAppData -DestinationBase $transferBase }
    }
    else { Add-DisabledBackupResult -Item "AppData" }
    
    # 3. Capture system settings
    $settings = @{}
    if ($Script:Config.Backup.SystemSettings) {
        $settings = Get-SystemSettings -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "System settings" -Category "Settings" }
    
    # 4. Document installed programs
    if ($Script:Config.Backup.InstalledPrograms) {
        $programs = Get-InstalledPrograms -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "Installed programs" }

    if ($Script:Config.Backup.AppDataCandidateInventory) {
        $includeCandidateSizes = $Script:Config.TransferMode -ne 'Online' -or $Script:Config.Online.DetailedAppDataCandidateInventory
        Get-AppDataCandidates -DestinationBase $transferBase -IncludeSizes $includeCandidateSizes
    }
    else { Add-DisabledBackupResult -Item "AppData candidate inventory" -Category "Settings" }
    
    # 5. Back up printers
    if ($Script:Config.Backup.Printers) {
        Backup-Printers -DestinationBase $transferBase
    }
    else { Add-DisabledBackupResult -Item "Printers" }

    # 6. Copy the independently selected browser data.
    Copy-BrowserData -DestinationBase $transferBase
    
    # 7. Check OneDrive
    if ($Script:Config.Backup.OneDrive) {
        Set-OneDriveLocalSync
    }
    else { Add-DisabledBackupResult -Item "OneDrive" }

    if ($Script:DeferredChromePasswordExport) {
        Write-Section 'Chrome password export'
        Invoke-ChromePasswordExportPrompt -BrowserPath $Script:DeferredChromePasswordExport.BrowserPath -CanLaunchChromeForOriginalUser $Script:DeferredChromePasswordExport.CanLaunchChromeForOriginalUser -HasProfileArchive $Script:DeferredChromePasswordExport.HasProfileArchive
        $Script:DeferredChromePasswordExport = $null
    }

    # 8. Capture optional taskbar-layout and default-app inventories.
    if ($Script:Config.Backup.TaskbarLayout) { Backup-TaskbarLayout -DestinationBase $transferBase }
    else { Add-DisabledBackupResult -Item "Taskbar layout" -Category "Settings" }
    if ($Script:Config.Backup.DefaultApps) { Backup-DefaultApps -DestinationBase $transferBase }
    else { Add-DisabledBackupResult -Item "Default apps" -Category "Settings" }

    # The preceding export stays in the signed-in user's context. This is the
    # only UAC prompt, limited to PrintBRM and the complete power-plan file.
    Start-ElevatedSystemExport -DestinationBase $transferBase

    # 9. Generate import script
    New-ImportScript -DestinationBase $transferBase -Settings $settings
    # Do not ship an elevated power/printer helper when neither stage was
    # selected. This keeps an intentionally settings-free package from trying
    # to process PowerShell/power artifacts that do not exist.
    if ($Script:Config.Backup.SystemSettings -or $Script:Config.Backup.Printers) {
        New-AdminImportScript -DestinationBase $transferBase
    }

    # 9. Generate quick import batch file
    New-QuickImportBatch -DestinationBase $transferBase

    if (-not $Script:Config.Transfer.CreateZipArchive) {
        Write-Log "ZIP archive creation disabled by configuration" -Level Info
        Add-Result -Category "Package" -Item "ZIP Archive" -Status "Skipped" -Details "Disabled by configuration"
    }

    # ZIP creation is selectable for either transfer mode.
    $archivePath = $null
    $publishedArchivePath = $null
    if ($Script:Config.Transfer.CreateZipArchive) {
        $archivePath = New-TransferArchive -TransferBase $transferBase
        if ($archivePath -and $useLocalStaging) {
            $uploadLog = Join-Path $transferBase "Logs\robocopy_network_zip_upload.log"
            $publishedArchivePath = Publish-TransferArchive -ArchivePath $archivePath -DestinationFolder $destinationFolder -LogPath $uploadLog
        }
    }

    # Generate the report only after every package action has been recorded so
    # its four counters exactly match the terminal summary.
    $reportPath = New-TransferReport -DestinationBase $transferBase
    
    # Summary
    $Script:Results.EndTime = Get-Date
    $dur = $Script:Results.EndTime - $Script:Results.StartTime
    $resultCounts = Get-TransferResultCounts
    $sc = $resultCounts.Success
    $wc = $resultCounts.Warning
    $ec = $resultCounts.Errors
    $kc = $resultCounts.Skipped

    Write-Banner -Title "Export Complete"
    Write-SummaryCard -Success $sc -Warning $wc -Errors $ec -Skipped $kc -Duration "$([math]::Round($dur.TotalMinutes, 1)) min"

    $adminRequiredTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match "admin|Administrator|privileges" })
    if (-not $Script:IsAdmin -and $adminRequiredTasks.Count -gt 0) {
        Write-Host ""
        Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "  ! INCOMPLETE EXPORT: ADMIN-ONLY ITEMS WERE NOT CAPTURED !" -ForegroundColor Red
        Write-Host "  ! Re-run elevated before wiping the old laptop.          !" -ForegroundColor Red
        Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        foreach ($task in $adminRequiredTasks) {
            Write-Host "  $($Script:Theme.Glyphs.WARN) $($task.Task)" -ForegroundColor Yellow
        }
    }

    $packageLabel = if ($useLocalStaging) { "Local staging package" } else { "Package" }
    Write-KeyValue $packageLabel $transferBase
    if ($publishedArchivePath) { Write-KeyValue "Network ZIP" $publishedArchivePath }
    elseif ($archivePath) { Write-KeyValue "ZIP archive" $archivePath }
    Write-Section "Package contents"
    Write-Status "UserData"               "INFO" "Documents, Desktop, loose files"
    Write-Status "AppData"                "INFO" "Bluebeam, signatures, Quick Access"
    Write-Status "Settings"               "INFO" "power, drives, personalization"
    if ($Script:Config.Backup.Printers) {
        Write-Status "Printers" "INFO" "PrintBRM package"
    }
    else {
        Write-Status "Printers" "SKIP" "disabled by configuration"
    }
    if ($Script:Config.Backup.Chrome -ne 'Off') { Write-Status "Chrome" "INFO" $Script:Config.Backup.Chrome } else { Write-Status "Chrome" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Firefox) { Write-Status "Firefox" "INFO" "selected" } else { Write-Status "Firefox" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Edge) { Write-Status "Edge" "INFO" "selected" } else { Write-Status "Edge" "SKIP" "disabled by configuration" }
    Write-Status "Import-LaptopData.ps1"  "OK"   "run on new machine"
    Write-Status "QuickImport.bat"        "OK"   "double-click (runs as signed-in user)"
    Write-Status "TransferReport.html"    "OK"   "full report"
    if ($publishedArchivePath) {
        Write-Status "$(Split-Path -Path $publishedArchivePath -Leaf)" "OK" "uploaded ZIP archive"
    }
    elseif ($archivePath) {
        Write-Status "$(Split-Path -Path $archivePath -Leaf)" "OK" "portable compressed package"
    }

    # Persist every event, including ZIP creation and any network upload.
    $logPath = Join-Path $transferBase "Logs\ExportLog.txt"
    $Script:Log | Out-File $logPath -Encoding UTF8

    # Open report only for an interactive technician run.
    Write-Host ""
    if ($NonInteractive) {
        Write-Host "  Report saved: $reportPath" -ForegroundColor DarkGray
    }
    elseif ($reportPath -and (Test-Path $reportPath)) {
        Write-Host "  Opening transfer report..." -ForegroundColor DarkGray
        Start-Process $reportPath
    }
    
    Write-Host ""
    if (-not $NonInteractive) { Read-UserInput "  Press Enter to exit" | Out-Null }
}

# Run the export
Start-LaptopExport