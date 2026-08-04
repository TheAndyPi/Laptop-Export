# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY
# Source modules: src\\01-bootstrap.ps1 through src\\10-main.ps1
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
    Version: 0.6
    Author: STO IT
    Run as: The user being transferred (IT admin logged in as user)
#>

#Requires -Version 5.1

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
    # Development-time defaults. Edit these values, then run
    # Build-Deployment.ps1 to embed the configuration in Export-LaptopData.ps1.
    Backup = @{
        UserData          = $true
        Downloads         = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        # Off, BookmarksAndPasswords, or FullProfile. The lightweight option
        # exports bookmarks and prompts for Chrome's native password CSV export.
        Chrome            = "BookmarksAndPasswords"
        Firefox           = $true
        Edge              = $false  # Microsoft account already syncs Edge settings
        OneDrive          = $true
    }

    Import = @{
        # Restores AppData\Lotus_Local when it is present in a transfer package.
        LotusNotes = $true

        # Deletes Printers\Printers.printerExport only after a successful
        # PrintBRM restore and completion of the generated import script.
        DeletePrintBrmAfterImport = $true
    }

    # These values override the regular Import defaults when the technician
    # selects an Online transfer. They can still be changed for one transfer
    # in the runtime settings menu.
    Online = @{
        # Online transfers warn before starting when selected payload exceeds this size.
        MaxTransferGB = 5
        # Downloads is excluded from Online transfers by default. The technician
        # can enable its standalone toggle for an individual transfer.
        Downloads = $true
        # Online transfers create a ZIP beside the transfer folder by default.
        CreateZipArchive = $true

        # Build network-bound packages in the transferring user's Local AppData,
        # then upload one ZIP instead of thousands of small network writes.
        StageNetworkTransfersLocally = $true

        Import = @{
            LotusNotes                  = $true
            DeletePrintBrmAfterImport   = $true
        }
    }
}

function Get-VisibleLength {
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

# ============================================================================
# ADMIN ELEVATION
# ============================================================================

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

function Restart-AsAdministrator {
    if ($Script:IsAdmin) {
        Write-Host "  Already running as Administrator." -ForegroundColor Green
        Start-Sleep -Seconds 1
        return
    }

    Write-Host "  Requesting administrator privileges..." -ForegroundColor Yellow
    $scriptPath = $PSCommandPath
    $elevatedArgs = "-ExecutionPolicy Bypass -File `"$scriptPath`" -TargetUserProfile `"$env:USERPROFILE`" -TargetUserName `"$env:USERNAME`" -TargetAppDataRoaming `"$env:APPDATA`" -TargetAppDataLocal `"$env:LOCALAPPDATA`""
    if ($DestinationPath) { $elevatedArgs += " -DestinationPath `"$DestinationPath`"" }
    if ($OnlineMaxTransferGB -gt 0) { $elevatedArgs += " -OnlineMaxTransferGB $OnlineMaxTransferGB" }

    try {
        Start-Process PowerShell -Verb RunAs -ArgumentList $elevatedArgs -ErrorAction Stop
        exit
    }
    catch {
        Write-Host "  Could not elevate. Continuing without administrator rights." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
    }
}

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version = "0.7"
    TransferFolderName = "LaptopTransfer_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

    # Printer driver binaries in the PrintBRM package. Network printers also
    # have a driverless, non-admin connection restore. TRUE bundles drivers
    # when PrintBRM is permitted to create the package; FALSE (-NOBIN) makes a
    # smaller package.
    IncludePrinterDrivers = $true
    
    # User profile folders to copy (relative to user profile)
    UserFolders = @(
        "Documents",
        "Desktop",
        "Downloads",
        "Pictures",
        "Videos",
        "Music",
        "Favorites"
    )
    
    # AppData paths to check/copy (relative to AppData\Roaming)
    AppDataRoaming = @{
        "Signatures" = "Microsoft\Signatures"
        "QuickAccess" = "Microsoft\Windows\Recent\AutomaticDestinations"
    }
    
    # AppData\Local paths to check/copy
    AppDataLocal = @{
        "Lotus" = "Lotus"
    }
    
    # Bluebeam can be in different locations - check these paths
    BluebeamPaths = @(
        "Bluebeam Software",
        "Bluebeam"
    )
    
    # Robocopy settings
    RobocopyArgs = @("/E", "/Z", "/R:2", "/W:3", "/MT:8", "/NP", "/NDL", "/NFL")

    # ---- Transfer mode ----
    # "Local"  = full copy (USB/on-site).  "Online" = trimmed for slow/remote links.
    # Resolved at runtime from the -TransferMode param or an interactive prompt.
    TransferMode = "Local"

    # Online-mode defaults (only applied when TransferMode = "Online")
    Online = @{
        MaxTransferGB    = 5
        # Downloads is a standalone backup toggle and is disabled by default
        # for Online transfers.
        Downloads = $false
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
        # Import defaults used only when the selected transfer mode is Online.
        Import = @{
            LotusNotes = $true
            DeletePrintBrmAfterImport = $true
        }
    }

    # These switches are supplied by src\00-development-config.psd1 at build
    # time and remain embedded in the single deployment script.
    Backup = @{
        UserData          = $true
        Downloads         = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        # Off, BookmarksAndPasswords, or FullProfile.
        Chrome            = "Off"
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
    }
    Import = @{
        LotusNotes = $true
        DeletePrintBrmAfterImport = $true
    }
}

# Apply only known Boolean development switches so invalid additions cannot
# unexpectedly change the behavior of a technician deployment.
foreach ($sectionName in @("Backup", "Import")) {
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

# Chrome has three choices rather than a simple on/off switch. Keep its
# allowlist explicit so only supported modes can be compiled into deployments.
if ($Script:DevelopmentConfig -is [hashtable] -and
    $Script:DevelopmentConfig.ContainsKey("Backup") -and
    $Script:DevelopmentConfig.Backup -is [hashtable] -and
    $Script:DevelopmentConfig.Backup.ContainsKey("Chrome") -and
    $Script:DevelopmentConfig.Backup.Chrome -in @("Off", "BookmarksAndPasswords", "FullProfile")) {
    $Script:Config.Backup.Chrome = $Script:DevelopmentConfig.Backup.Chrome
}

# Online transfer behavior has a nested import-default section. Keep its
# allowlist separate so config-file additions cannot alter unrelated settings.
if ($Script:DevelopmentConfig -is [hashtable] -and
    $Script:DevelopmentConfig.ContainsKey("Online") -and
    $Script:DevelopmentConfig.Online -is [hashtable]) {
    $developmentOnline = $Script:DevelopmentConfig.Online
    foreach ($switchName in @("CreateZipArchive", "StageNetworkTransfersLocally", "Downloads")) {
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
}

if ($OnlineMaxTransferGB -gt 0) {
    $Script:Config.Online.MaxTransferGB = $OnlineMaxTransferGB
}

function Apply-OnlineTransferDefaults {
    if ($Script:Config.TransferMode -ne "Online") { return }

    $Script:Config.Backup.Downloads = $Script:Config.Online.Downloads
    foreach ($switchName in $Script:Config.Online.Import.Keys) {
        $Script:Config.Import[$switchName] = $Script:Config.Online.Import[$switchName]
    }
}

function Add-DisabledBackupResult {
    param(
        [string]$Item,
        [string]$Category = "Backup"
    )

    Write-Log "$Item backup disabled by configuration" -Level Info
    Write-Status $Item "SKIP" "disabled by config"
    Add-Result -Category $Category -Item $Item -Status "Skipped" -Details "Disabled by configuration"
}

function Show-TransferSettingsMenu {
    # These are the runtime counterparts of the switches in
    # src\00-development-config.psd1.  Values start with the compiled
    # defaults, but any changes made here apply only to the current transfer.
    $settings = @(
        @{ Section = "Backup"; Key = "UserData";          Label = "User data";          Detail = "Documents, Desktop, and other user folders" }
        @{ Section = "Backup"; Key = "Downloads";         Label = "Downloads";          Detail = "Downloads folder" }
        @{ Section = "Backup"; Key = "AppData";           Label = "AppData";            Detail = "Bluebeam, signatures, and Quick Access" }
        @{ Section = "Backup"; Key = "LotusNotes";        Label = "Lotus Notes";        Detail = "Local Lotus Notes data from AppData\\Local" }
        @{ Section = "Backup"; Key = "SystemSettings";    Label = "System settings";    Detail = "Power, drives, personalization, and related settings" }
        @{ Section = "Backup"; Key = "InstalledPrograms"; Label = "Installed programs"; Detail = "Installed-program inventory" }
        @{ Section = "Backup"; Key = "Printers";          Label = "Printers";           Detail = "PrintBRM package and printer connections" }
        @{ Section = "Backup"; Key = "Chrome"; Type = "ChromeMode"; Label = "Google Chrome"; Detail = "Choose Off, bookmarks + passwords, or full profile" }
        @{ Section = "Backup"; Key = "Firefox";           Label = "Firefox";            Detail = "Firefox profile, bookmarks, logins, extensions, and settings" }
        @{ Section = "Backup"; Key = "Edge";              Label = "Microsoft Edge";     Detail = "Edge bookmarks and profile-specific favorites" }
        @{ Section = "Backup"; Key = "OneDrive";          Label = "OneDrive";           Detail = "Offline file availability check" }
        @{ Section = "Import"; Key = "LotusNotes";        Label = "Import Lotus Notes"; Detail = "Restore exported Lotus local data on the new laptop" }
        @{ Section = "Import"; Key = "DeletePrintBrmAfterImport"; Label = "Delete PrintBRM after import"; Detail = "Remove the printer package after a successful restore" }
        @{ Section = "Online"; Key = "MaxTransferGB"; Type = "Number"; Label = "Online payload limit"; Detail = "Warn before export when selected payload exceeds this many GB" }
        @{ Section = "Online"; Key = "CreateZipArchive";  Label = "Create ZIP archive"; Detail = "Create a ZIP beside the package (Online transfers only)" }
        @{ Section = "Online"; Key = "StageNetworkTransfersLocally"; Label = "Stage network transfers locally"; Detail = "Build locally, then upload one ZIP to a network destination" }
    )

    while ($true) {
        Clear-StoScreen
        Write-Banner -Title "Transfer Settings" -Subtitle "$($Script:Config.TransferMode) transfer - changes apply to this transfer only"
        Write-Section "Backup settings"
        $estimate = Get-TransferPayloadEstimate

        for ($index = 0; $index -lt $settings.Count; $index++) {
            $setting = $settings[$index]
            if ($index -eq 11) {
                Write-Section "Generated import settings"
            }
            if ($index -eq 13) {
                Write-Section "Online transfer settings"
            }

            $number = ($index + 1).ToString().PadLeft(2)
            $isNumber = $setting.Type -eq "Number"
            $isChromeMode = $setting.Type -eq "ChromeMode"
            $isEnabled = if ($isNumber -or $isChromeMode) { $false } else { [bool]$Script:Config[$setting.Section][$setting.Key] }
            $state = if ($isNumber) { "$($Script:Config.Online.MaxTransferGB)GB" } elseif ($isChromeMode) {
                switch ($Script:Config.Backup.Chrome) {
                    "BookmarksAndPasswords" { "BOOKMARKS + PASSWORDS" }
                    "FullProfile" { "FULL PROFILE" }
                    default { "OFF" }
                }
            } elseif ($isEnabled) { "ON " } else { "OFF" }
            $color = if ($isNumber) { "Yellow" } elseif ($isChromeMode) { if ($Script:Config.Backup.Chrome -eq "Off") { "DarkGray" } else { "Green" } } elseif ($isEnabled) { "Green" } else { "DarkGray" }
            $sizeText = if ($setting.Section -eq "Backup") { "$(Format-FileSize ([long]$estimate.ItemBytes[$setting.Key]))" } else { "" }

            Write-Host "  [$number] " -ForegroundColor Cyan -NoNewline
            Write-Host "$state " -ForegroundColor $color -NoNewline
            Write-Host $setting.Label.PadRight(30) -ForegroundColor White -NoNewline
            if ($sizeText) { Write-Host "$($sizeText.PadLeft(10)) " -ForegroundColor DarkCyan -NoNewline }
            Write-Host $setting.Detail -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  Select a number to toggle it; select Chrome to cycle its backup mode." -ForegroundColor Gray
        Write-Host "  Chrome can export bookmarks and passwords without copying its full profile." -ForegroundColor DarkGray
        Write-Host "  ZIP archive is ignored for Local transfers." -ForegroundColor DarkGray
        Write-Host "  Import settings are written into the transfer package's generated import script." -ForegroundColor DarkGray
        $selection = (Read-Host "  [S] Start transfer  [Q] Cancel").Trim()

        if ($selection -match "^[Ss]$") { return $true }
        if ($selection -match "^[Qq]$") { return $false }

        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and
            $selectedIndex -ge 1 -and $selectedIndex -le $settings.Count) {
            $setting = $settings[$selectedIndex - 1]
            if ($setting.Type -eq "Number") {
                $value = 0.0
                $entered = Read-Host "  Enter Online payload limit in GB (current: $($Script:Config.Online.MaxTransferGB))"
                if ([double]::TryParse($entered, [ref]$value) -and $value -gt 0) { $Script:Config.Online.MaxTransferGB = $value }
                else { Write-Host "  Enter a positive number of GB." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
            elseif ($setting.Type -eq "ChromeMode") {
                $Script:Config.Backup.Chrome = switch ($Script:Config.Backup.Chrome) {
                    "Off" { "BookmarksAndPasswords" }
                    "BookmarksAndPasswords" { "FullProfile" }
                    default { "Off" }
                }
            }
            else { $Script:Config[$setting.Section][$setting.Key] = -not [bool]$Script:Config[$setting.Section][$setting.Key] }
        }
        else {
            Write-Host "  Enter a setting number, S, or Q." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

function Show-BackupOverview {
    while ($true) {
        Clear-StoScreen
        Write-Section "OVERVIEW OF BACKUP INCLUDING ESTIMATED SIZE"
        $estimate = Get-TransferPayloadEstimate
        Write-KeyValue "Transfer mode" $Script:Config.TransferMode
        Write-KeyValue "Estimated size" (Format-FileSize $estimate.TotalBytes)
        Write-Host ""
        $choice = (Read-Host "  [S] Start transfer [C] Change Settings [Q] Cancel").Trim()

        if ($choice -match "^[Ss]$") { return $true }
        if ($choice -match "^[Qq]$") { return $false }
        if ($choice -match "^[Cc]$") {
            if (-not (Show-TransferSettingsMenu)) { return $false }
            continue
        }
        Write-Host "  Enter S, C, or Q." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
}

# ============================================================================
# LOGGING & REPORTING
# ============================================================================

$Script:Log = [System.Collections.ArrayList]::new()
$Script:Results = @{
    StartTime = Get-Date
    EndTime = $null
    UserName = $Script:OriginalUserName
    ComputerName = $env:COMPUTERNAME
    Actions = [System.Collections.ArrayList]::new()
    Errors = [System.Collections.ArrayList]::new()
    Warnings = [System.Collections.ArrayList]::new()
    ManualTasks = [System.Collections.ArrayList]::new()
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = "[$timestamp][$Level] $Message"
    [void]$Script:Log.Add($logEntry)
    
    $color = switch ($Level) {
        "Info"    { "White" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    Write-Host $logEntry -ForegroundColor $color
}

function Add-Result {
    param(
        [string]$Category,
        [string]$Item,
        [string]$Status,
        [string]$Details = ""
    )
    
    $result = @{
        Category = $Category
        Item = $Item
        Status = $Status
        Details = $Details
        Timestamp = Get-Date -Format "HH:mm:ss"
    }
    
    [void]$Script:Results.Actions.Add($result)
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

    # Get source size and file count
    $sourceFiles = Get-ChildItem $Source -Recurse -File -Force -ErrorAction SilentlyContinue
    $totalFiles = ($sourceFiles | Measure-Object).Count
    $totalSize = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
    
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
    $progressBarWidth = 34
    $lastPercent = -1
    $spinIndex = 0
    
    # Build full argument string for robocopy
    $robocopyArgString = ($RobocopyArgs -join " ")
    
    # Keep a direct handle to the Robocopy process.  This lets the technician
    # stop only the current copy instead of terminating the whole export.
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "robocopy.exe"
    $pinfo.Arguments = "`"$Source`" `"$Destination`" $robocopyArgString /LOG:`"$LogPath`""
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $pinfo
    if (-not $process.Start()) {
        return @{ ExitCode = -1; FilesCopied = 0; BytesCopied = 0; Status = "Warning"; Duration = [TimeSpan]::Zero }
    }

    $abortedByOperator = $false
    Write-Host "    Press S to stop this copy and continue with the next step." -ForegroundColor DarkGray
    
    # Monitor progress while robocopy runs.
    # Poll less aggressively than before (recursive sizing of a large USB dest
    # every 500ms competes with the copy itself); spinner keeps it feeling live.
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
        
        # Get current destination size
        $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
        $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        $copiedFiles = ($destFiles | Measure-Object).Count
        
        if ($null -eq $copiedSize) { $copiedSize = 0 }
        
        # Calculate percentage
        $percent = if ($totalSize -gt 0) { [math]::Min(100, [math]::Round(($copiedSize / $totalSize) * 100)) } else { 0 }
        
        # Advance spinner + redraw every tick (spinner animates even when % is static)
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]
        $spinIndex++
        $lastPercent = $percent
        
        # Build block-character progress bar
        $filledWidth = [math]::Round(($percent / 100) * $progressBarWidth)
        $emptyWidth = $progressBarWidth - $filledWidth
        $progressBar = ([string]$Script:Theme.Bar.Full * $filledWidth) + ([string]$Script:Theme.Bar.Light * $emptyWidth)
        
        # Calculate speed
        $elapsed = (Get-Date) - $startTime
        $speed = if ($elapsed.TotalSeconds -gt 0) { $copiedSize / $elapsed.TotalSeconds } else { 0 }
        # Force the Int64 overload. The untyped literal 0 selects Int32 and
        # overflows once the copied bytes exceed 2 GB.
        $remainingBytes = [math]::Max([long]0, [long]($totalSize - $copiedSize))
        $eta = if ($speed -gt 0 -and $copiedSize -gt 0) {
            Format-RemainingTime ($remainingBytes / $speed)
        }
        else { "calculating..." }
        
        # Build + write status line (carriage return to overwrite)
        $statusLine = "    $spin $progressBar $($percent.ToString().PadLeft(3))%  $(Format-FileSize $copiedSize) / $(Format-FileSize $totalSize)  $(Format-FileSize $speed)/s  ETA $eta   "
        Write-Host "`r$statusLine" -NoNewline
    }
    
    $exitCode = $process.ExitCode
    
    # Final update
    $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
    $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    $copiedFiles = ($destFiles | Measure-Object).Count
    if ($null -eq $copiedSize) { $copiedSize = 0 }
    
    $elapsed = (Get-Date) - $startTime
    $avgSpeed = if ($elapsed.TotalSeconds -gt 0) { $copiedSize / $elapsed.TotalSeconds } else { 0 }
    
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

    $progressBar = [string]$Script:Theme.Bar.Full * $progressBarWidth
    Write-Host "`r$(' ' * 140)" -NoNewline
    Write-Host "`r    " -NoNewline
    Write-Host "$($Script:Theme.Glyphs.OK) " -ForegroundColor Green -NoNewline
    Write-Host $progressBar -ForegroundColor Green -NoNewline
    Write-Host " 100%  $(Format-FileSize $copiedSize)  in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    
    # Determine status based on exit code and files copied
    $status = if ($exitCode -lt 8) { 
        "Success" 
    } elseif ($exitCode -in @(8, 9) -and $copiedFiles -gt 0) { 
        "Success" 
    } elseif ($exitCode -in @(8, 9)) { 
        "Skipped" 
    } else { 
        "Warning" 
    }
    
    return @{
        ExitCode = $exitCode
        FilesCopied = $copiedFiles
        BytesCopied = $copiedSize
        Status = $status
        Duration = $elapsed
    }
}

function Add-ManualTask {
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

function Test-PathIsSameOrChild {
    param(
        [string]$Path,
        [string]$ParentPath
    )

    try {
        $destination = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92)
        $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([char]92)
        $parentPrefix = $parent + [System.IO.Path]::DirectorySeparatorChar
        return $destination.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
               $destination.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Test-DestinationIsWithinSourceProfile {
    param([string]$Path)

    return Test-PathIsSameOrChild -Path $Path -ParentPath $Script:OriginalUserProfile
}

function Show-NativeWindowsFolderPicker {
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
    Write-StoLogo
    Write-Banner -Title "Laptop Transfer  -  Export Tool" -Subtitle "v$($Script:Config.Version)"
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
        $selection = Read-Host "Select target drive (1-$($drives.Count))"
        if ($selection -eq "0") { return $null }

        $index = 0
        if ([int]::TryParse($selection, [ref]$index)) {
            $index--
            if ($index -ge 0 -and $index -lt $drives.Count) {
                $selectedDrive = $drives[$index]
                $confirm = Read-Host "Proceed with $($selectedDrive.Display)? (Y/N)"
                if ($confirm -match "^[Yy]") { return $selectedDrive.Letter }
            }
        }
        Write-Host "Invalid selection. Please try again." -ForegroundColor Red
    } while ($true)
}

function Select-TargetDestination {
    Write-StoLogo
    Write-Banner -Title "Laptop Transfer  -  Export Tool" -Subtitle "v$($Script:Config.Version)"
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
            $selectedPath = Read-Host "Enter destination folder path (blank to cancel)"
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

function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Get-TransferPayloadEstimate {
    $sizes = @{}
    foreach ($key in @("UserData","Downloads","AppData","LotusNotes","SystemSettings","InstalledPrograms","Printers","Chrome","Firefox","Edge","OneDrive")) {
        $sizes[$key] = [long]0
    }

    if ($Script:Config.Backup.UserData) {
        foreach ($folder in $Script:Config.UserFolders) {
            if ($folder -eq "Downloads") { continue }
            $bytes = Get-FolderSizeBytes (Join-Path $Script:OriginalUserProfile $folder)
            $sizes.UserData += $bytes
        }
    }
    if ($Script:Config.Backup.Downloads) {
        $sizes.Downloads = Get-FolderSizeBytes (Join-Path $Script:OriginalUserProfile "Downloads")
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
    if ($Script:Config.Backup.Chrome -eq "FullProfile") {
        $sizes.Chrome = Get-FolderSizeBytes (Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data")
    }
    elseif ($Script:Config.Backup.Chrome -eq "BookmarksAndPasswords") {
        $chromeRoot = Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data"
        $sizes.Chrome = [long]((Get-ChildItem -LiteralPath $chromeRoot -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
    }
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
    param([string]$TransferBase)

    if ($Script:Config.TransferMode -ne "Online") {
        Write-Log "Skipping ZIP archive for Local transfer" -Level Info
        return $null
    }

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
        $files = @(Get-ChildItem -LiteralPath $TransferBase -Recurse -File -Force -ErrorAction Stop)
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
                $entry = $archive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
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
    Write-StoLogo
    Write-Section "Transfer mode"
    Write-Host "  [1] Local  " -ForegroundColor Cyan -NoNewline
    Write-Host "- full copy (USB / on-site)" -ForegroundColor DarkGray
    Write-Host "  [2] Online " -ForegroundColor Cyan -NoNewline
    Write-Host "- trimmed for slow/remote links (Downloads disabled by default, skips Lotus)" -ForegroundColor DarkGray
    Write-Host "  [0] Administrator" -ForegroundColor Cyan -NoNewline
    Write-Host "- restart with administrator privileges" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $m = Read-Host "  Select transfer mode (0-2)"
        if ($m -eq "1") { $Script:Config.TransferMode = "Local"; break }
        if ($m -eq "2") { $Script:Config.TransferMode = "Online"; break }
        if ($m -eq "0") { Restart-AsAdministrator; continue }
        Write-Host "  Invalid selection." -ForegroundColor Red
    } while ($true)
}

function Copy-UserFolders {
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
        if ($folder -ne "Downloads" -and -not $Script:Config.Backup.UserData) {
            continue
        }
        if ($folder -eq "Downloads" -and -not $Script:Config.Backup.Downloads) {
            Add-DisabledBackupResult -Item "Downloads" -Category "User Folders"
            continue
        }

        $sourcePath = Join-Path $userProfile $folder
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

                    # Any other large folder: ask the tech (skip / copy anyway).
                    if ($folderGB -gt $Script:Config.Online.LargeFolderPromptGB) {
                        Write-Host ""
                        Write-Host "  $($Script:Theme.Glyphs.WARN) " -ForegroundColor Yellow -NoNewline
                        Write-Host "$folder is $folderGB GB (over the $($Script:Config.Online.LargeFolderPromptGB) GB online threshold)." -ForegroundColor White
                        $ans = Read-Host "    Copy it anyway? (Y = copy / N = skip)"
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
    
    $additionalFolders = Get-ChildItem $userProfile -Directory -Force -ErrorAction SilentlyContinue | 
        Where-Object { 
            $folderName = $_.Name
            # Exclude if in explicit list
            $folderName -notin $excludeFolders -and 
            # Exclude hidden folders
            -not $folderName.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            # Exclude any folder starting with "OneDrive"
            -not $folderName.StartsWith("OneDrive")
        }
    
    foreach ($folder in $additionalFolders) {
        $items = Get-ChildItem $folder.FullName -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) }
        if ($items) {
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
    
    # Check for loose files directly in user profile root (not in any subfolder)
    Write-Log "Checking for loose files in user profile root..." -Level Info
    
    $looseFiles = Get-ChildItem $userProfile -File -Force -ErrorAction SilentlyContinue | 
        Where-Object { 
            -not $_.Name.StartsWith(".") -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) -and
            -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) -and
            $_.Extension -notin @(".ini", ".dat", ".log") # Skip system files
        }
    
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

function Get-SystemSettings {
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
    }
    
    # Power Settings
    try {
        Write-Log "Capturing power settings..." -Level Info
        
        $powerScheme = powercfg /getactivescheme
        $settings.PowerScheme = $powerScheme
        
        # Extract the GUID from the power scheme output
        $schemeGuid = if ($powerScheme -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $matches[1]
        } else { $null }
        
        # Try to export current power scheme (requires admin)
        $powerExport = Join-Path $settingsPath "PowerScheme.pow"
        
        if ($Script:IsAdmin) {
            $powerExportResult = powercfg /export $powerExport $schemeGuid 2>&1
            
            if (Test-Path $powerExport) {
                $settings.PowerSchemeExported = $true
                Write-Log "Power scheme exported successfully" -Level Success
            } else {
                $settings.PowerSchemeExported = $false
                Add-ManualTask -Task "Export Power Scheme" -Reason "Export failed even with admin rights" -Instructions "Run as admin: powercfg /export PowerScheme.pow $schemeGuid"
            }
        } else {
            $settings.PowerSchemeExported = $false
            Write-Log "Skipping power scheme export (requires admin)" -Level Info
            Add-ManualTask -Task "Export Power Scheme" -Reason "Requires administrator privileges (skipped)" -Instructions @"
Run these commands as Administrator on the OLD computer:
  powercfg /export "D:\LaptopTransfer\PowerScheme.pow" $schemeGuid

Then on the NEW computer:
  powercfg /import "D:\LaptopTransfer\PowerScheme.pow"
"@
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
        
        Write-Log "Power settings captured" -Level Success
        Add-Result -Category "Settings" -Item "Power Configuration" -Status $(if ($settings.PowerSchemeExported) { "Success" } else { "NOT EXPORTED - Admin Required" }) -Details "Lid: AC=$($settings.LidClose.OnAC), DC=$($settings.LidClose.OnBattery)"
    }
    catch {
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
        
        $settings.MappedDrives = @($mappedDrives) + @($regDrives) | Sort-Object -Property Letter -Unique
        
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
        
        # Mouse Cursor Settings
        $cursors = Get-ItemProperty -Path "HKCU:\Control Panel\Cursors" -ErrorAction SilentlyContinue
        if ($cursors) {
            $personalization.CursorScheme = $cursors.'(default)'
            $personalization.CursorBaseSize = $cursors.CursorBaseSize
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
            "HKCU\Control Panel\Desktop"
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
        
        Write-Log "Personalization settings captured (colors, taskbar, cursors)" -Level Success
        Add-Result -Category "Settings" -Item "Personalization" -Status "Success" -Details "Colors, taskbar, visual effects captured"
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
    
    # Save settings to JSON
    $settingsFile = Join-Path $settingsPath "SystemSettings.json"
    $settings | ConvertTo-Json -Depth 5 | Out-File $settingsFile -Encoding UTF8
    
    Write-Log "Settings saved to SystemSettings.json" -Level Success
    
    return $settings
}

function Get-InstalledPrograms {
    param(
        [string]$DestinationBase
    )
    
    Write-Log "Documenting installed programs..." -Level Info
    
    $programs = @()
    
    # 64-bit programs
    $programs += Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    
    # 32-bit programs on 64-bit system
    $programs += Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    
    # User-installed programs
    $programs += Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    
    $programs = $programs | Sort-Object DisplayName -Unique
    
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

function Backup-Printers {
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
        }
        else {
            $elevationHint = if ($Script:IsAdmin) { "" } else { "; Windows commonly requires an elevated session" }
            Write-Log "PrintBRM did not create Printers.printerExport (exit $brmExit)$elevationHint" -Level Warning
            Write-Status "Printer migration file" "WARN" "not created (exit $brmExit)"
            Add-Result -Category "Printers" -Item "Printer Migration File" -Status "Warning" -Details "Exit $brmExit$elevationHint; see printbrm_backup.log"
            if (-not $Script:IsAdmin) {
                Add-ManualTask -Task "Create PrintBRM printer migration file" -Reason "PrintBRM did not allow the standard-user export" -Instructions "Re-run Export-LaptopData.ps1 and select Y at the administrator prompt. The failed PrintBRM output is in Logs\\printbrm_backup.log."
            }
        }
    }
    catch {
        Write-Status "Local printers" "FAIL" $_.Exception.Message
        Add-Result -Category "Printers" -Item "Local Printers" -Status "Error" -Details $_.Exception.Message
    }
}

# ============================================================================
# BROWSER DATA
# ============================================================================

function Convert-ChromeBookmarksToHtml {
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
    param(
        [string]$ProcessName,
        [string]$DisplayName
    )

    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $true }

    Write-Host ""
    Write-Host "  $DisplayName is open. Close it to capture its profile databases consistently." -ForegroundColor Yellow
    $response = Read-Host "  Close $DisplayName, then press Enter to continue (S to copy while it is open)"
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return $true }

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
    $profiles = @(Get-ChromeProfileDirectories -UserDataPath $ChromeUserDataPath)
    $exported = 0

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
            Write-Log "Chrome bookmarks exported for profile '$($profile.Name)'" -Level Success

            # Keep the old Default filename as a convenience for technicians
            # who are accustomed to the original single-profile layout.
            if ($profile.Name -eq "Default") {
                Copy-Item -LiteralPath $chromeHtml -Destination (Join-Path $BrowserPath "Chrome_Bookmarks.html") -Force
            }
        }
        else {
            Write-Log "Could not convert Chrome bookmarks for profile '$($profile.Name)'" -Level Warning
        }
    }

    if ($exported -gt 0) {
        Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Success" -Details "$exported Chrome profile(s) exported as HTML"
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

    $exportNow = Read-Host "  Open Chrome Password Manager now to export passwords? (Y/N)"
    if ($exportNow -notmatch '^[Yy]') {
        $reason = if ($HasProfileArchive) { "Chrome passwords remain encrypted in the raw profile backup" } else { "Chrome passwords require Chrome's native export" }
        $detail = if ($HasProfileArchive) { "Native Chrome export declined; raw encrypted profile backup is included" } else { "Native Chrome export declined; no Chrome profile archive was selected" }
        Add-ManualTask -Task "Export Chrome Passwords" -Reason $reason -Instructions @"
On the old laptop, while signed in as the original Windows user:
1. Open Chrome > Passwords and autofill > Google Password Manager > Settings.
2. Under Export passwords, select Download file and complete the Windows authentication prompt.
3. Save the CSV only to: $passwordExportPath
4. On the new laptop, import it in Google Password Manager > Settings > Import passwords, then delete the CSV.
"@
        Add-Result -Category "Browser" -Item "Chrome Passwords" -Status "Manual" -Details $detail
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
        Start-Process "chrome.exe" "chrome://password-manager/settings" -ErrorAction Stop
        Write-Host "  Complete Chrome's export, choose the folder shown above, then return here." -ForegroundColor Gray
        [void](Read-Host "  Press Enter after saving the CSV (S to skip)")
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
    # Chrome can either export bookmarks and the native password CSV only, or
    # also retain a raw profile archive for recovery/reference.
    $chromeUserDataPath = Join-Path $localAppData "Google\Chrome\User Data"
    if ($Script:Config.Backup.Chrome -eq "Off") {
        Add-DisabledBackupResult -Item "Chrome" -Category "Browser"
    }
    elseif (Test-Path -LiteralPath $chromeUserDataPath) {
        [void](Export-ChromeBookmarks -ChromeUserDataPath $chromeUserDataPath -BrowserPath $browserPath)

        if ($Script:Config.Backup.Chrome -eq "FullProfile") {
            # Keep the result: a partial copy while Chrome is open must never be
            # presented as a fully successful profile archive.
            $chromeClosed = Request-BrowserClose -ProcessName "chrome" -DisplayName "Google Chrome"
            $chromeRawDestination = Join-Path $browserPath "Chrome\User Data"
            $chromeRawLog = Join-Path $DestinationBase "Logs\robocopy_chrome_user_data.log"
            $chromeCopyArgs = @($Script:Config.RobocopyArgs) + @(
                # These folders hold disposable cache data or Windows-encrypted
                # network cookies. They add substantial size, are often locked
                # while Chrome runs, and cannot be meaningfully moved to another
                # Windows profile.
                "/XD", "Cache", '"Code Cache"', "GPUCache", "GPUPersistentCache", "ShaderCache", "GrShaderCache", "DawnCache", "Crashpad", "Network", '"Safe Browsing Network"'
            )
            $result = Copy-WithProgress -Source $chromeUserDataPath `
                                        -Destination $chromeRawDestination `
                                        -FolderName "Chrome profile archive (all profiles)" `
                                        -LogPath $chromeRawLog `
                                        -RobocopyArgs $chromeCopyArgs
            if ($result.Status -eq "Success" -and $chromeClosed) {
                Write-Log "Chrome profile archive copied: $($result.FilesCopied) files" -Level Success
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Success" -Details "$($result.FilesCopied) files; common caches excluded; credentials remain Windows-protected"
            }
            elseif ($result.Aborted) {
                Write-Log "Chrome profile archive copy stopped by operator" -Level Warning
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Skipped" -Details "Stopped by operator; partial files may remain and can be resumed by rerunning the export"
            }
            else {
                $detail = if (-not $chromeClosed) {
                    "Chrome was open; active profile databases may be incomplete. Close Chrome and rerun before wiping the old laptop."
                }
                else {
                    "Check robocopy_chrome_user_data.log"
                }
                Write-Log "Chrome profile archive copy completed with warnings" -Level Warning
                Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Warning" -Details $detail
            }
        }

        if ($Script:Config.Backup.Chrome -ne "FullProfile" -or -not $result.Aborted) {
            $canLaunchChromeForOriginalUser = (-not $Script:IsAdmin) -or ($Script:OriginalUserProfile -eq $env:USERPROFILE)
            Invoke-ChromePasswordExportPrompt -BrowserPath $browserPath -CanLaunchChromeForOriginalUser $canLaunchChromeForOriginalUser -HasProfileArchive ($Script:Config.Backup.Chrome -eq "FullProfile")
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
        $result = Copy-WithProgress -Source $firefoxLocalSource `
                                    -Destination $firefoxLocalDest `
                                    -FolderName "Firefox data (Local)" `
                                    -LogPath $firefoxLocalLog `
                                    -RobocopyArgs $Script:Config.RobocopyArgs

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

function Set-OneDriveLocalSync {
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
            $attribResult = Start-Process -FilePath "attrib.exe" -ArgumentList "+P", "-U", "/S", "/D", "`"$targetPath\*`"" -Wait -PassThru -NoNewWindow -ErrorAction Stop
            
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

function New-ImportScript {
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
    [switch]$TestMode,
    # Used by QuickImport.bat so a double-click restore stays in the current
    # user's context and does not show a UAC elevation prompt.
    [switch]$NoElevationPrompt
)

$ErrorActionPreference = "Continue"

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
    OriginalUser = "{USERNAME}"
    OriginalComputer = "{COMPUTERNAME}"
}

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$userProfile = $env:USERPROFILE
$logFile = Join-Path $scriptPath "ImportLog.txt"
$importLotusNotes = [bool]::Parse('{IMPORT_LOTUS_NOTES}')
# Firefox is restored whenever its independently-selected backup payload is
# present. There is no separate import toggle to keep in sync.
$importFirefox = $true
$deletePrintBrmAfterImport = [bool]::Parse('{DELETE_PRINTBRM_AFTER_IMPORT}')
$printBrmRestoreSucceeded = $false

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
    $Script:Results.Actions += [PSCustomObject]@{
        Category = $Category
        Item = $Item
        Status = $Status
        Details = $Details
    }
}

function Test-RobocopySuccess {
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
    param(
        [string]$Source,
        [string]$Destination,
        [string]$FolderName,
        [string]$LogPath
    )
    
    # Get source size and file count
    $sourceFiles = Get-ChildItem $Source -Recurse -File -Force -ErrorAction SilentlyContinue
    $totalFiles = ($sourceFiles | Measure-Object).Count
    $totalSize = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
    
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
    $progressBarWidth = 34
    $lastPercent = -1
    $spinIndex = 0
    
    # Run robocopy as a background job using ProcessStartInfo for proper argument handling
    $robocopyScript = {
        param($src, $dst, $log)
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "robocopy.exe"
        $pinfo.Arguments = "`"$src`" `"$dst`" /E /Z /R:2 /W:3 /MT:8 /NP /LOG:`"$log`""
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $pinfo
        $process.Start() | Out-Null
        $process.WaitForExit()
        return $process.ExitCode
    }
    
    $job = Start-Job -ScriptBlock $robocopyScript -ArgumentList $Source, $Destination, $LogPath
    
    # Monitor progress
    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 750
        
        $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
        $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $copiedSize) { $copiedSize = 0 }
        
        $percent = if ($totalSize -gt 0) { [math]::Min(100, [math]::Round(($copiedSize / $totalSize) * 100)) } else { 0 }
        
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]; $spinIndex++
        $lastPercent = $percent
        $filledWidth = [math]::Round(($percent / 100) * $progressBarWidth)
        $emptyWidth = $progressBarWidth - $filledWidth
        $progressBar = ([string]$Script:Theme.Bar.Full * $filledWidth) + ([string]$Script:Theme.Bar.Light * $emptyWidth)
        
        $elapsed = (Get-Date) - $startTime
        $speed = if ($elapsed.TotalSeconds -gt 0) { $copiedSize / $elapsed.TotalSeconds } else { 0 }
        # Force the Int64 overload. The untyped literal 0 selects Int32 and
        # overflows for folders larger than 2 GB.
        $remainingBytes = [math]::Max([long]0, [long]($totalSize - $copiedSize))
        $eta = if ($speed -gt 0 -and $copiedSize -gt 0) {
            Format-RemainingTime ($remainingBytes / $speed)
        }
        else { "calculating..." }
        
        Write-Host "`r    $spin $progressBar $($percent.ToString().PadLeft(3))%  $(Format-FileSize $copiedSize) / $(Format-FileSize $totalSize)  $(Format-FileSize $speed)/s  ETA $eta   " -NoNewline
    }
    
    # Get the exit code from the job
    $exitCode = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    
    # If exit code is null, assume success
    if ($null -eq $exitCode) { $exitCode = 0 }
    
    # Final stats
    $destFiles = Get-ChildItem $Destination -Recurse -File -Force -ErrorAction SilentlyContinue
    $copiedSize = ($destFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    $copiedFiles = ($destFiles | Measure-Object).Count
    if ($null -eq $copiedSize) { $copiedSize = 0 }
    
    $elapsed = (Get-Date) - $startTime
    $progressBar = [string]$Script:Theme.Bar.Full * $progressBarWidth
    Write-Host "`r$(' ' * 140)" -NoNewline
    Write-Host "`r    " -NoNewline
    Write-Host "$($Script:Theme.Glyphs.OK) " -ForegroundColor Green -NoNewline
    Write-Host $progressBar -ForegroundColor Green -NoNewline
    Write-Host " 100%  $(Format-FileSize $copiedSize)  in $([math]::Round($elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
    
    $status = if ($exitCode -lt 8) { "Success" } 
              elseif ($exitCode -in @(8, 9) -and $copiedFiles -gt 0) { "Success" }
              elseif ($exitCode -in @(8, 9)) { "Skipped" }
              else { "Warning" }
    
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
if ($env:COMPUTERNAME -eq "{COMPUTERNAME}") {
    Write-Host "  WARNING: Running on the SAME computer as export!" -ForegroundColor Yellow
    Write-Host "  This may overwrite existing files." -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Continue anyway? (Y/N)"
    if ($confirm -notmatch "^[Yy]") {
        Write-Host "`n  Import cancelled." -ForegroundColor Gray
        exit
    }
    Write-Host ""
}

# ============================================================================
# ADMIN ELEVATION CHECK
# ============================================================================

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    if ($NoElevationPrompt) {
        Write-Host "  Running as the current user; admin-only restore steps will be skipped." -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Some features require Administrator rights:" -ForegroundColor Yellow
        Write-Host "    - Power scheme import" -ForegroundColor Gray
        Write-Host "    - Lid close action settings" -ForegroundColor Gray
        Write-Host ""
        $elevate = Read-Host "  Run as Administrator? (Y/N, or S to skip)"

        if ($elevate -match "^[Yy]") {
            Write-Host "`n  Requesting elevation..." -ForegroundColor Cyan
            try {
                $scriptFullPath = $MyInvocation.MyCommand.Path
                Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptFullPath`""
                exit
            }
            catch {
                Write-Host "  Could not elevate. Continuing without admin rights." -ForegroundColor Yellow
                $isAdmin = $false
            }
        }
        else {
            Write-Host "  Continuing without admin rights..." -ForegroundColor Gray
        }
    }
}
else {
    Write-Host "  Running with Administrator rights" -ForegroundColor Green
}

Write-Host ""
Write-Host "  Starting import..." -ForegroundColor Cyan
Write-Host "  ----------------------------------------" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# RESTORE USER FOLDERS
# ============================================================================

Write-Section "Restoring user folders"
Write-Host ""

$folders = @("Documents", "Desktop", "Downloads", "Pictures", "Videos", "Music", "Favorites")
$logsPath = Join-Path $scriptPath "Logs"
if (-not (Test-Path $logsPath)) { New-Item -ItemType Directory -Path $logsPath -Force | Out-Null }

foreach ($folder in $folders) {
    $sourcePath = Join-Path $scriptPath "UserData\$folder"
    $destPath = Join-Path $userProfile $folder
    
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
                # Note: We don't want to kill explorer.exe completely as that's the shell
                
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

# Power scheme (requires admin)
$powerScheme = Join-Path $scriptPath "Settings\PowerScheme.pow"
if (Test-Path $powerScheme) {
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
            $importResult = powercfg /import $powerScheme $guid 2>&1
            powercfg /setactive $guid 2>&1 | Out-Null
            Write-Log "Power scheme imported and activated" -Level "Success"
            Add-Result -Category "Settings" -Item "Power Scheme" -Status "Success"
        }
        catch {
            Write-Log "Power scheme import failed: $_" -Level "Error"
            Add-Result -Category "Settings" -Item "Power Scheme" -Status "Error"
        }
    }
}

# Lid close actions (requires admin)
if ($settingsData -and $settingsData.LidClose -and $settingsData.LidClose.OnAC) {
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
if ($settingsData -and $settingsData.MappedDrives -and $settingsData.MappedDrives.Count -gt 0) {
    Write-Host ""
    Write-Host "  Network Drives:" -ForegroundColor Gray
    
    foreach ($drive in $settingsData.MappedDrives) {
        if ($drive.Letter -and $drive.Path) {
            $driveLetter = $drive.Letter
            $drivePath = $drive.Path
            
            if ($TestMode) {
                Write-Log "  ${driveLetter}: -> $drivePath (would map)" -Level "Info"
                Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "TestMode" -Details $drivePath
            }
            else {
                # Check if drive letter already in use
                if (Test-Path "${driveLetter}:") {
                    Write-Log "  ${driveLetter}: already mapped" -Level "Warning"
                    Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Skipped" -Details "Already mapped"
                }
                else {
                    try {
                        net use "${driveLetter}:" $drivePath /persistent:yes 2>&1 | Out-Null
                        Write-Log "  ${driveLetter}: -> $drivePath" -Level "Success"
                        Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Success" -Details $drivePath
                    }
                    catch {
                        Write-Log "  ${driveLetter}: -> $drivePath (failed - may need credentials)" -Level "Warning"
                        Add-Result -Category "Network Drives" -Item "${driveLetter}:" -Status "Warning" -Details "May need manual setup"
                    }
                }
            }
        }
    }
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
if (Test-Path $printerExportFile) {
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
                Write-Log "Personalization settings restored (colors, taskbar, visual effects)" -Level "Success"
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
        [void](Read-Host "  Close $BrowserName, then press Enter to continue (S to skip)")
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

function Add-ManualTask {
    param([string]$Task, [string]$Reason, [string]$Instructions = "")

    # The generated importer records items that need manual follow-up, such
    # as local printers that require elevation.
    $Script:Results.ManualTasks += [PSCustomObject]@{
        Task = $Task
        Reason = $Reason
        Instructions = $Instructions
    }
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
    Write-Host "    To import: Chrome > Bookmarks and lists > Import bookmarks and settings > HTML file" -ForegroundColor Gray
    Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Ready" -Details "$($chromeBookmarkFiles.Count) HTML file(s) for manual import"
}

# Chrome profile archive. Credentials and cookies remain encrypted to the old
# Windows installation, so they are deliberately not restored.  Bookmarks are
# portable, however, and are restored below without replacing the rest of the
# Chrome profile.
$chromeProfileArchive = Join-Path $browserDataPath "Chrome\User Data"
if (Test-Path -LiteralPath $chromeProfileArchive) {
    $chromeArchiveFiles = (Get-ChildItem -LiteralPath $chromeProfileArchive -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Log "Chrome profile archive retained ($chromeArchiveFiles files; only portable bookmarks are restored)" -Level "Info"
    Write-Host "    Chrome profile archive: $chromeProfileArchive" -ForegroundColor Gray
    Write-Host "    Bookmarks are restored automatically when Chrome is closed; credentials remain protected." -ForegroundColor Gray
    Add-Result -Category "Browser" -Item "Chrome Profile Archive" -Status "Info" -Details "$chromeArchiveFiles files retained; credentials and cookies are not restored"
    Restore-ChromiumProfileBookmarks -BrowserName "Chrome" -ProcessName "chrome" -PackageUserDataPath $chromeProfileArchive -TargetUserDataPath (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data")
}

# Chrome's native Password Manager export produces a plaintext CSV after the
# user completes the Windows authentication prompt on the old computer. Do
# not attempt to decrypt the raw Chrome profile here; the browser/Windows
# protections are intentional. Instead, guide the user through Chrome's own
# CSV import and offer to remove the sensitive export after confirmation.
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
        $openChrome = Read-Host "  Open Chrome Password Manager now? (Y/N)"
        if ($openChrome -match '^[Yy]') {
            try { Start-Process "chrome.exe" "chrome://password-manager/settings" -ErrorAction Stop }
            catch { Write-Log "Could not open Chrome Password Manager automatically: $_" -Level Warning }
        }

        $deleteCsv = Read-Host "  After importing and verifying passwords, type DELETE to permanently remove the plaintext CSV (or press Enter to keep it)"
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
            $closeFirefox = Read-Host "  Close Firefox, then press Enter to continue (S to skip)"
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
                try {
                    if (-not (Test-Path $target.Parent)) { New-Item -ItemType Directory -Path $target.Parent -Force | Out-Null }
                    if (Test-Path $destination) {
                        Move-Item -LiteralPath $destination -Destination $backup -ErrorAction Stop
                        Write-Log "Existing Firefox $($target.Name) data backed up to $backup" -Level "Info"
                    }

                    $logPath = Join-Path $logsPath "import_firefox_$($target.Name.ToLower()).log"
                    $result = Copy-WithProgress -Source $target.Source `
                                               -Destination $destination `
                                               -FolderName "Firefox $($target.Name) data" `
                                               -LogPath $logPath
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
                    Write-Log "Firefox $($target.Name) data restore failed: $_" -Level "Warning"
                    Add-Result -Category "Browser" -Item "Firefox $($target.Name) Data" -Status "Warning" -Details $_.Exception.Message
                }
            }

            Write-Host "    Firefox profile restored. Start Firefox after this import completes." -ForegroundColor Gray
        }
    }
}

Write-Host ""

# ============================================================================
# VERIFY INSTALLED PROGRAMS
# ============================================================================

Write-Section "Installed programs reference"
Write-Host ""

$programsFile = Join-Path $scriptPath "Settings\InstalledPrograms.txt"
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

Write-Section "Import summary"
Write-Host ""

$Script:Results.EndTime = Get-Date
$duration = $Script:Results.EndTime - $Script:Results.StartTime

$successCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
$warningCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Warning" -or $_.Status -eq "Manual" -or $_.Status -eq "Pending" }).Count
$errorCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Error" }).Count
$skippedCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count

Write-Host "  Import complete" -ForegroundColor Green
Write-SummaryCard -Success $successCount -Warning $warningCount -Errors $errorCount -Skipped $skippedCount -Duration "$([math]::Round($duration.TotalMinutes, 1)) min"

if ($deletePrintBrmAfterImport -and $printBrmRestoreSucceeded) {
    try {
        Remove-Item -LiteralPath $printerExportFile -Force -ErrorAction Stop
        Write-Log "Deleted PrintBRM package after successful import" -Level "Success"
        Add-Result -Category "Printers" -Item "PrintBRM Package Cleanup" -Status "Success" -Details "Deleted after successful import"
    }
    catch {
        Write-Log "Could not delete PrintBRM package: $_" -Level "Warning"
        Add-Result -Category "Printers" -Item "PrintBRM Package Cleanup" -Status "Warning" -Details $_.Exception.Message
    }
    }
}

if ($Script:Results.Warnings.Count -gt 0) {
    Write-Section "Items needing attention"
    foreach ($warning in $Script:Results.Warnings) {
        Write-Status $warning "WARN"
    }
}

if ($Script:Results.ManualTasks.Count -gt 0) {
    Write-Section "Items needing attention"
    foreach ($task in $Script:Results.ManualTasks) {
        Write-Host "  $([char]0x26A0) " -ForegroundColor Yellow -NoNewline
        Write-Host $task.Task -ForegroundColor Yellow
        Write-Host "    $($task.Reason)" -ForegroundColor DarkGray
        if ($task.Instructions) {
            Write-Host "    $($task.Instructions -replace '[\r\n]+', ' ')" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

Write-Section "Remaining manual steps"
$manualSteps = @(
    "Sign into Microsoft 365 / Teams / Outlook",
    "Sign into OneDrive and verify sync",
    "Configure Lotus Notes (if applicable)",
    "Sign into Chrome (enables password sync)",
    "Activate Adobe / Bluebeam licenses",
    "Verify restored printers print a test page",
    "Connect to STOBG Network Wi-Fi",
    "Test all critical applications",
    "Verify BitLocker status"
)
foreach ($step in $manualSteps) {
    Write-Host "  $([char]0x25A1) " -ForegroundColor DarkGray -NoNewline
    Write-Host $step -ForegroundColor White
}
Write-Host ""
Write-Host "  See TransferReport.html for full export details." -ForegroundColor DarkGray
Write-Host ""

$reportPath = Join-Path $scriptPath "TransferReport.html"
if (Test-Path $reportPath) {
    Write-Host "  Opening transfer report..." -ForegroundColor DarkGray
    Start-Process -FilePath $reportPath
}

Read-Host "  Press Enter to exit"
'@

    # Replace placeholders
    $importScript = $importScript -replace '\{TIMESTAMP\}', (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $importScript = $importScript -replace '\{USERNAME\}', $Script:OriginalUserName
    $importScript = $importScript -replace '\{COMPUTERNAME\}', $env:COMPUTERNAME
    $importScript = $importScript -replace '\{IMPORT_LOTUS_NOTES\}', $Script:Config.Import.LotusNotes.ToString().ToLowerInvariant()
    $importScript = $importScript -replace '\{DELETE_PRINTBRM_AFTER_IMPORT\}', $Script:Config.Import.DeletePrintBrmAfterImport.ToString().ToLowerInvariant()
    
    $importScriptPath = Join-Path $DestinationBase "Import-LaptopData.ps1"
    $importScript | Out-File $importScriptPath -Encoding UTF8
    
    Write-Log "Import script generated" -Level Success
    Add-Result -Category "Scripts" -Item "Import-LaptopData.ps1" -Status "Success" -Details "Ready for new machine"
}

# ============================================================================
# HTML REPORT GENERATOR
# ============================================================================

function New-TransferReport {
    param(
        [string]$DestinationBase
    )
    
    $Script:Results.EndTime = Get-Date
    $duration = $Script:Results.EndTime - $Script:Results.StartTime
    
    $successCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
    $warningCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Warning" }).Count
    $errorCount = @($Script:Results.Actions | Where-Object {
        $_.Status -eq "Error" -or $_.Status -like "NOT EXPORTED*"
    }).Count
    $skippedCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Laptop Transfer Report - $($Script:Results.UserName)</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #e0e0e0;
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1000px; margin: 0 auto; }
        
        header {
            background: linear-gradient(135deg, #0f3460 0%, #16213e 100%);
            border-radius: 16px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            border: 1px solid #0f3460;
        }
        header h1 { 
            font-size: 28px; 
            margin-bottom: 10px;
            background: linear-gradient(90deg, #00d4ff, #7c3aed);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .meta { color: #888; font-size: 14px; }
        .meta span { margin-right: 20px; }
        
        .stats {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 15px;
            margin-bottom: 20px;
        }
        .stat-card {
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 20px;
            text-align: center;
            border: 1px solid rgba(255,255,255,0.1);
        }
        .stat-card .number {
            font-size: 36px;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .stat-card .label { color: #888; font-size: 12px; text-transform: uppercase; }
        .stat-success .number { color: #10b981; }
        .stat-warning .number { color: #f59e0b; }
        .stat-error .number { color: #ef4444; }
        .stat-skipped .number { color: #6b7280; }
        
        .section {
            background: rgba(255,255,255,0.03);
            border-radius: 12px;
            margin-bottom: 20px;
            border: 1px solid rgba(255,255,255,0.1);
            overflow: hidden;
        }
        .section-header {
            background: rgba(255,255,255,0.05);
            padding: 15px 20px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .section-header .icon { font-size: 20px; }
        .section-content { padding: 20px; }
        
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.1); }
        th { color: #888; font-weight: 500; font-size: 12px; text-transform: uppercase; }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: rgba(255,255,255,0.02); }
        
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 500;
        }
        .status-success { background: rgba(16, 185, 129, 0.2); color: #10b981; }
        .status-warning { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
        .status-error { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
        .status-skipped { background: rgba(107, 114, 128, 0.2); color: #9ca3af; }
        .status-manual { background: rgba(139, 92, 246, 0.2); color: #a78bfa; }
        .status-partial { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
        
        .critical-warning {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.15) 0%, rgba(220, 38, 38, 0.1) 100%);
            border: 2px solid #ef4444;
            border-radius: 12px;
            padding: 25px;
            margin-bottom: 25px;
            text-align: center;
        }
        .critical-warning h2 {
            color: #ef4444;
            font-size: 22px;
            margin-bottom: 15px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }
        .critical-warning p {
            color: #fca5a5;
            margin-bottom: 10px;
            font-size: 15px;
        }
        .critical-warning .reason {
            color: #888;
            font-size: 13px;
        }
        
        .not-captured-section {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.1) 0%, rgba(220, 38, 38, 0.05) 100%);
            border: 1px solid rgba(239, 68, 68, 0.3);
        }
        .not-captured-section .section-header {
            background: rgba(239, 68, 68, 0.15);
            color: #fca5a5;
        }
        .not-captured-item {
            background: rgba(239, 68, 68, 0.1);
            border-left: 4px solid #ef4444;
            padding: 20px;
            margin-bottom: 15px;
            border-radius: 0 8px 8px 0;
        }
        .not-captured-item h4 { 
            color: #fca5a5; 
            margin-bottom: 8px;
            font-size: 16px;
        }
        .not-captured-item .why { 
            color: #f87171; 
            font-size: 13px; 
            margin-bottom: 10px;
            font-style: italic;
        }
        .not-captured-item .instructions { 
            color: #e0e0e0; 
            font-size: 14px;
            line-height: 1.6;
        }
        .not-captured-item pre { 
            background: rgba(0,0,0,0.4); 
            padding: 15px; 
            margin-top: 12px; 
            border-radius: 6px;
            font-size: 13px;
            white-space: pre-wrap;
            color: #fca5a5;
            border: 1px solid rgba(239, 68, 68, 0.2);
        }
        
        .manual-task {
            background: rgba(139, 92, 246, 0.1);
            border-left: 3px solid #7c3aed;
            padding: 15px;
            margin-bottom: 10px;
            border-radius: 0 8px 8px 0;
        }
        .manual-task h4 { color: #a78bfa; margin-bottom: 5px; }
        .manual-task p { color: #888; font-size: 14px; }
        .manual-task pre { 
            background: rgba(0,0,0,0.3); 
            padding: 10px; 
            margin-top: 10px; 
            border-radius: 6px;
            font-size: 13px;
            white-space: pre-wrap;
        }
        
        .checklist {
            list-style: none;
        }
        .checklist li {
            padding: 10px 15px;
            border-bottom: 1px solid rgba(255,255,255,0.05);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .checklist li:last-child { border-bottom: none; }
        .checkbox {
            width: 20px;
            height: 20px;
            border: 2px solid #444;
            border-radius: 4px;
            display: inline-block;
        }
        
        footer {
            text-align: center;
            padding: 20px;
            color: #666;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>STO Laptop Transfer Report</h1>
            <div class="meta">
                <span>User: $($Script:Results.UserName)</span>
                <span>Computer: $($Script:Results.ComputerName)</span>
                <span>Mode: $(Out-HtmlEncoded $Script:Config.TransferMode)</span>
                <span>Date: $(Get-Date -Format "MMMM dd, yyyy 'at' h:mm tt")</span>
                <span>Duration: $([math]::Round($duration.TotalMinutes, 1)) minutes</span>
            </div>
        </header>
"@

    # Only mark the export incomplete when a recorded task actually needs
    # elevation. A standard-user export can otherwise be complete.
    $adminRequiredTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match "admin|Administrator|privileges" })
    $adminTaskCount = $adminRequiredTasks.Count
    if (-not $Script:IsAdmin -and $adminTaskCount -gt 0) {
        
        $html += @"
        
        <div style="background: linear-gradient(135deg, rgba(220, 38, 38, 0.2) 0%, rgba(185, 28, 28, 0.15) 100%); border: 3px solid #dc2626; border-radius: 16px; padding: 30px; margin-bottom: 25px; text-align: center;">
            <h2 style="color: #fca5a5; font-size: 26px; margin-bottom: 15px;">&#9888; INCOMPLETE EXPORT - ADMIN RIGHTS REQUIRED &#9888;</h2>
            <p style="color: #fecaca; font-size: 18px; margin-bottom: 15px;"><strong>This export was run WITHOUT administrator privileges.</strong></p>
            <p style="color: #fca5a5; font-size: 16px; margin-bottom: 20px;">$adminTaskCount item(s) could <strong>NOT</strong> be automatically captured and <strong>MUST be manually copied BEFORE wiping the old laptop!</strong></p>
            <p style="color: #f87171; font-size: 14px;">To capture everything automatically, re-run Export-LaptopData.ps1 and select <strong>"Y"</strong> when prompted for administrator rights.</p>
        </div>
        
        <div style="background: rgba(220, 38, 38, 0.1); border: 2px solid #dc2626; border-radius: 12px; margin-bottom: 25px; overflow: hidden;">
            <div style="background: rgba(220, 38, 38, 0.2); padding: 18px 25px; font-weight: 700; font-size: 18px; color: #fca5a5; display: flex; align-items: center; gap: 12px;">
                <span style="font-size: 24px;">&#10060;</span>
                NOT CAPTURED - MUST MANUALLY COPY BEFORE WIPING OLD LAPTOP
            </div>
            <div style="padding: 25px;">
"@
        foreach ($task in $adminRequiredTasks) {
            $html += @"
                <div style="background: rgba(220, 38, 38, 0.1); border-left: 5px solid #dc2626; padding: 20px; margin-bottom: 18px; border-radius: 0 10px 10px 0;">
                    <h4 style="color: #fca5a5; font-size: 17px; margin-bottom: 10px; font-weight: 600;">$(Out-HtmlEncoded $task.Task)</h4>
                    <p style="color: #f87171; font-size: 13px; margin-bottom: 12px; font-style: italic;"><strong>Why not captured:</strong> $(Out-HtmlEncoded $task.Reason)</p>
                    <p style="color: #e0e0e0; font-size: 14px; margin-bottom: 8px;"><strong>What you MUST do:</strong></p>
                    $(if ($task.Instructions) { "<pre style='background: rgba(0,0,0,0.5); padding: 15px; border-radius: 8px; font-size: 13px; white-space: pre-wrap; color: #fecaca; border: 1px solid rgba(220, 38, 38, 0.3); margin-top: 8px;'>$(Out-HtmlEncoded $task.Instructions)</pre>" })
                </div>
"@
        }
        $html += @"
            </div>
        </div>
"@
    }
    elseif ($Script:IsAdmin) {
        # Admin mode - show green success banner
        $html += @"
        
        <div style="background: linear-gradient(135deg, rgba(16, 185, 129, 0.15) 0%, rgba(5, 150, 105, 0.1) 100%); border: 2px solid #10b981; border-radius: 12px; padding: 20px; margin-bottom: 25px; text-align: center;">
            <h3 style="color: #6ee7b7; font-size: 18px; margin-bottom: 8px;">&#10003; Full Export Completed with Administrator Rights</h3>
            <p style="color: #a7f3d0; font-size: 14px;">All settings including power schemes were successfully captured.</p>
        </div>
"@
    }

    $html += @"
        
        <div class="stats">
            <div class="stat-card stat-success">
                <div class="number">$successCount</div>
                <div class="label">Successful</div>
            </div>
            <div class="stat-card stat-warning">
                <div class="number">$warningCount</div>
                <div class="label">Warnings</div>
            </div>
            <div class="stat-card stat-error">
                <div class="number">$errorCount</div>
                <div class="label">Errors</div>
            </div>
            <div class="stat-card stat-skipped">
                <div class="number">$skippedCount</div>
                <div class="label">Skipped</div>
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#10003;</span>
                Export Actions
            </div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th>Category</th>
                            <th>Item</th>
                            <th>Status</th>
                            <th>Details</th>
                        </tr>
                    </thead>
                    <tbody>
"@

    foreach ($action in $Script:Results.Actions) {
        $statusClass = switch -Regex ($action.Status) {
            "Success" { "status-success" }
            "Warning" { "status-warning" }
            "Error" { "status-error" }
            "Skipped" { "status-skipped" }
            "NOT EXPORTED|Admin Required" { "status-error" }
            default { "status-warning" }
        }
        $html += @"
                        <tr>
                            <td>$(Out-HtmlEncoded $action.Category)</td>
                            <td>$(Out-HtmlEncoded $action.Item)</td>
                            <td><span class="status $statusClass">$($action.Status)</span></td>
                            <td>$(Out-HtmlEncoded $action.Details)</td>
                        </tr>
"@
    }

    # Get non-admin related manual tasks (admin ones are shown in the big red box above)
    $otherManualTasks = if (-not $Script:IsAdmin) {
        $Script:Results.ManualTasks | Where-Object { $_.Reason -notmatch "admin|Administrator|privileges" }
    } else {
        $Script:Results.ManualTasks
    }

    $html += @"
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#128203;</span>
                Other Manual Tasks
            </div>
            <div class="section-content">
"@

    if ($otherManualTasks -and ($otherManualTasks | Measure-Object).Count -gt 0) {
        foreach ($task in $otherManualTasks) {
            $html += @"
                <div class="manual-task">
                    <h4>$(Out-HtmlEncoded $task.Task)</h4>
                    <p>$(Out-HtmlEncoded $task.Reason)</p>
                    $(if ($task.Instructions) { "<pre>$(Out-HtmlEncoded $task.Instructions)</pre>" })
                </div>
"@
        }
    }
    else {
        $html += @"
                <p style="color: #10b981; padding: 15px;">&#10003; No additional manual tasks required.</p>
"@
    }

    $html += @"
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#9776;</span>
                New Machine Checklist
            </div>
            <div class="section-content">
                <ul class="checklist">
                    <li><span class="checkbox"></span> Run Import-LaptopData.ps1</li>
                    <li><span class="checkbox"></span> Verify/Resolve Imaging Errors</li>
                    <li><span class="checkbox"></span> Run Lenovo System Update</li>
                    <li><span class="checkbox"></span> Uninstall Lenovo System Update</li>
                    <li><span class="checkbox"></span> Check for Windows Updates</li>
                    <li><span class="checkbox"></span> Verify BitLocker is enabled</li>
                    <li><span class="checkbox"></span> Restart Computer</li>
                    <li><span class="checkbox"></span> Login as User</li>
                    <li><span class="checkbox"></span> Configure & Test Lotus Notes</li>
                    <li><span class="checkbox"></span> Configure Office 365</li>
                    <li><span class="checkbox"></span> Sign in to OneDrive and Teams</li>
                    <li><span class="checkbox"></span> Test Teams incl. Camera</li>
                    <li><span class="checkbox"></span> Configure Adobe / Bluebeam Revu</li>
                    <li><span class="checkbox"></span> Test run all other Applications</li>
                    <li><span class="checkbox"></span> Verify printers restored (test page) - add any missing local printers</li>
                    <li><span class="checkbox"></span> Unpin Store from taskbar</li>
                    <li><span class="checkbox"></span> Verify printers and shared drives match</li>
                    <li><span class="checkbox"></span> Verify Power Settings match</li>
                    <li><span class="checkbox"></span> Verify Default Browser</li>
                    <li><span class="checkbox"></span> Outlook Signature and Plug-Ins</li>
                    <li><span class="checkbox"></span> Check for manual drive mappings</li>
                    <li><span class="checkbox"></span> Connect to STOBG Network Wi-Fi</li>
                </ul>
            </div>
        </div>
        
        <footer>
            Generated by STO Laptop Transfer Tool v$($Script:Config.Version) | $(Get-Date -Format "yyyy")
        </footer>
    </div>
</body>
</html>
"@

    $reportPath = Join-Path $DestinationBase "TransferReport.html"
    $html | Out-File $reportPath -Encoding UTF8
    
    Write-Log "Transfer report generated" -Level Success
    
    return $reportPath
}
function New-QuickImportBatch {
    param(
        [string]$DestinationBase
    )

    $batPath = Join-Path $DestinationBase "QuickImport.bat"

    # Let the technician choose once: run normally for user-scoped data, or
    # request elevation when power settings and local printer drivers matter.
    $batContent = @"
@echo off
title STO Laptop Transfer - Quick Import

echo.
echo ============================================
echo    STO Laptop Transfer - Quick Import
echo ============================================
echo.
if /I "%~1"=="--elevated" goto :Elevated

set /p RUN_AS_ADMIN="Run with administrator rights? (Y/N) [N]: "
echo.

if /I "%RUN_AS_ADMIN%"=="Y" (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '--elevated'"
    exit /b
) else (
    echo Running import script as the current user...
    echo Admin-only restore steps will be skipped and listed in the report.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Import-LaptopData.ps1" -NoElevationPrompt
)
goto :Complete

:Elevated
echo Running import script with administrator rights...
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
echo Press any key to exit...
pause >nul
"@

    $batContent | Out-File $batPath -Encoding ASCII

    Write-Log "QuickImport.bat created" -Level Success
    Add-Result -Category "Scripts" -Item "QuickImport.bat" -Status "Success"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Start-LaptopExport {
    Clear-StoScreen

    # Resolve transfer mode: honor -TransferMode param, else prompt.
    if ($TransferMode -in @("Local", "Online")) {
        $Script:Config.TransferMode = $TransferMode
    }
    else {
        Resolve-TransferMode
    }

    Apply-OnlineTransferDefaults
    if ($NonInteractive) {
        # Browsers can require a close/password-export prompt. Leave them out
        # of unattended validation runs rather than hanging partway through.
        $Script:Config.Backup.Chrome = "Off"
        $Script:Config.Backup.Firefox = $false
        $Script:Config.Backup.Edge = $false
        # PrintBRM and ZIP compression can outlive automation time limits; the
        # package and all generated artifacts are still exercised by validation
        # runs. Normal technician exports retain both stages.
        $Script:Config.Backup.Printers = $false
        $Script:Config.Online.CreateZipArchive = $false
        Write-Log "Non-interactive mode: browser collection, PrintBRM, and ZIP creation disabled" -Level Info
    }
    elseif (-not (Show-BackupOverview)) {
        Write-Host "`n  Transfer cancelled." -ForegroundColor Yellow
        return
    }

    # Online exports use the Windows folder picker. Local exports retain the
    # external/secondary-drive selector and do not open the picker.
    if ($Script:Config.TransferMode -eq "Local") {
        $destinationFolder = Select-TargetDrive
    }
    else {
        $destinationFolder = Select-TargetDestination
    }
    if (-not $destinationFolder) {
        Write-Host "`n  Export cancelled: no usable destination was selected. No files were copied." -ForegroundColor Yellow
        if (-not $NonInteractive) { Read-Host "  Press Enter to exit" }
        return
    }

    $createsZipArchive = $Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.CreateZipArchive
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
    # the trimmed set (Downloads over cap and Lotus are excluded from the estimate).
    Write-Section "Estimating transfer size"
    $payloadEstimate = Get-TransferPayloadEstimate
    $estBytes = $payloadEstimate.TotalBytes
    Write-KeyValue "Estimated size" (Format-FileSize $estBytes)
    if ($Script:Config.TransferMode -eq "Online") {
        Write-KeyValue "Online payload limit" "$($Script:Config.Online.MaxTransferGB) GB"
        if ($estBytes -gt ($Script:Config.Online.MaxTransferGB * 1GB)) {
            $message = "Selected Online payload ($(Format-FileSize $estBytes)) exceeds the $($Script:Config.Online.MaxTransferGB) GB limit."
            Write-Host ""; Write-Host "  $($Script:Theme.Glyphs.WARN) $message" -ForegroundColor Yellow
            if ($NonInteractive) { throw "Non-interactive export stopped because: $message" }
            $continueLargePayload = Read-Host "    Export anyway? (Y/N)"
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
        $go = Read-Host "    Continue anyway? (Y/N)"
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
    
    # 1. Copy user folders
    if ($Script:Config.Backup.UserData -or $Script:Config.Backup.Downloads) {
        Copy-UserFolders -DestinationBase $transferBase
    }
    else {
        Add-DisabledBackupResult -Item "User data" -Category "User Folders"
        Add-DisabledBackupResult -Item "Downloads" -Category "User Folders"
    }
    
    # 2. Copy AppData
    if ($Script:Config.Backup.AppData) {
        Copy-AppData -DestinationBase $transferBase
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
    
    # 8. Generate import script
    New-ImportScript -DestinationBase $transferBase -Settings $settings

    # 9. Generate HTML report
    $reportPath = New-TransferReport -DestinationBase $transferBase
    
    # 10. Generate quick import batch file
    New-QuickImportBatch -DestinationBase $transferBase

    if ($Script:Config.TransferMode -eq "Online" -and -not $Script:Config.Online.CreateZipArchive) {
        Write-Log "ZIP archive creation disabled by configuration" -Level Info
        Add-Result -Category "Package" -Item "ZIP Archive" -Status "Skipped" -Details "Disabled by configuration"
    }

    # Local transfers stay as folders for a removable drive. Online transfers
    # also produce a portable ZIP beside the package.
    $archivePath = $null
    $publishedArchivePath = $null
    if ($Script:Config.TransferMode -eq "Online" -and $Script:Config.Online.CreateZipArchive) {
        $archivePath = New-TransferArchive -TransferBase $transferBase
        if ($archivePath -and $useLocalStaging) {
            $uploadLog = Join-Path $transferBase "Logs\robocopy_network_zip_upload.log"
            $publishedArchivePath = Publish-TransferArchive -ArchivePath $archivePath -DestinationFolder $destinationFolder -LogPath $uploadLog
        }
    }
    
    # Summary
    $Script:Results.EndTime = Get-Date
    $dur = $Script:Results.EndTime - $Script:Results.StartTime
    $sc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
    $wc = ($Script:Results.Actions | Where-Object { $_.Status -match "Warning|Manual" }).Count
    $ec = @($Script:Results.Actions | Where-Object {
        $_.Status -eq "Error" -or $_.Status -like "NOT EXPORTED*"
    }).Count
    $kc = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count

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
    if ($Script:Config.Backup.Chrome -ne "Off") { Write-Status "Chrome" "INFO" $Script:Config.Backup.Chrome } else { Write-Status "Chrome" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Firefox) { Write-Status "Firefox" "INFO" "selected" } else { Write-Status "Firefox" "SKIP" "disabled by configuration" }
    if ($Script:Config.Backup.Edge) { Write-Status "Edge" "INFO" "selected" } else { Write-Status "Edge" "SKIP" "disabled by configuration" }
    Write-Status "Import-LaptopData.ps1"  "OK"   "run on new machine"
    Write-Status "QuickImport.bat"        "OK"   "double-click (choose admin or standard)"
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
    if (-not $NonInteractive) { Read-Host "  Press Enter to exit" }
}

# Run the export
Start-LaptopExport
