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
    $appComparisonExcludePatterns = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{APP_COMPARISON_EXCLUDE_PATTERNS_BASE64}')) | ConvertFrom-Json)
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
# DESKTOP LAYOUT AND ONEDRIVE SHORTCUT DUPLICATES
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

$desktopLayoutFile = Join-Path $scriptPath 'Settings\DesktopLayout.json'
if (Test-Path -LiteralPath $desktopLayoutFile) {
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
            $localDesktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
            $candidates = @()
            foreach ($cloudDesktop in @(Get-OneDriveDesktopPaths)) {
                foreach ($cloudShortcut in @(Get-ChildItem -LiteralPath $cloudDesktop -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.lnk', '.url') })) {
                    $localShortcut = Join-Path $localDesktop $cloudShortcut.Name
                    if (-not (Test-Path -LiteralPath $localShortcut)) { continue }
                    $cloudHash = Get-ShortcutHash $cloudShortcut.FullName; $localHash = Get-ShortcutHash $localShortcut
                    if ($cloudHash -and $cloudHash -eq $localHash) { $candidates += $cloudShortcut }
                }
            }
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
        else { Start-Process 'ms-settings:defaultapps' -ErrorAction SilentlyContinue; Add-Result -Category 'Default Apps' -Item 'Restore guide' -Status 'Manual' -Details 'See Logs\DefaultAppsRestoreGuide.txt and the opened Settings page' }
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
    # Apply captured AC/DC values independently to the existing managed plan so
    # a policy rejection of one setting does not hide the others.
    param([string]$OverlayGuid)
    if ([string]::IsNullOrWhiteSpace($OverlayGuid) -or $OverlayGuid -notmatch '^[0-9a-fA-F-]{36}$') { return $false }
    try {
        if (-not ('StoPowerOverlay' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StoPowerOverlay {
    [DllImport("PowrProf.dll", SetLastError=true)]
    public static extern uint PowerSetActiveOverlayScheme(IntPtr UserRootPowerKey, ref Guid OverlaySchemeGuid);
}
"@ -ErrorAction Stop
        }
        $guid = [Guid]$OverlayGuid
        return ([StoPowerOverlay]::PowerSetActiveOverlayScheme([IntPtr]::Zero, [ref]$guid) -eq 0)
    } catch { return $false }
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
if ($settingsData -and $settingsData.PowerModeOverlay) {
    if ($TestMode) {
        Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'TestMode' -Details 'Would apply captured AC/DC power-mode overlay'
    }
    else {
        $overlayResults = @()
        foreach ($overlay in @($settingsData.PowerModeOverlay.ActiveOverlayAcPowerScheme, $settingsData.PowerModeOverlay.ActiveOverlayDcPowerScheme) | Select-Object -Unique) {
            if (-not $overlay) { continue }
            $overlayResults += [bool](Set-ImportedPowerOverlay -OverlayGuid ([string]$overlay))
        }
        if ($overlayResults.Count -gt 0 -and ($overlayResults -notcontains $false)) {
            Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Success' -Details 'Captured power-mode overlay applied'
        }
        else {
            Add-Result -Category 'Settings' -Item 'Windows power mode' -Status 'Skipped' -Details 'Overlay could not be applied without elevation, policy, or supported hardware'
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
                Add-Result -Category 'Settings' -Item 'Cursor settings' -Status 'Success' -Details 'Scheme and size restored; sign out/in may be required'
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
        Write-Host '    Display scale, cursor settings, and text size will take full effect after sign-out/sign-in.' -ForegroundColor Yellow
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
    try {
        $targetParent = Split-Path -Parent $TargetUserDataPath
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        if (Test-Path -LiteralPath $TargetUserDataPath) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Move-Item -LiteralPath $TargetUserDataPath -Destination $backup -ErrorAction Stop
        }
        $result = Copy-WithProgress -Source $PackageUserDataPath -Destination $TargetUserDataPath -FolderName 'Chrome profile (all profiles)' -LogPath (Join-Path $logsPath 'import_chrome_profile.log')
        if ($result.Status -ne 'Success') { throw "Profile copy did not complete successfully (robocopy exit $($result.ExitCode))" }
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'Success' -Details "$($result.FilesCopied) files; prior data backed up when present"
        Write-Host '    Chrome extensions, settings, history, and bookmarks were restored. Passwords and cookies may require Chrome sign-in.' -ForegroundColor Gray
    }
    catch {
        Add-Result -Category 'Browser' -Item 'Chrome Profile' -Status 'Warning' -Details $_.Exception.Message
        Write-Log "Chrome profile restore failed: $($_.Exception.Message)" -Level Warning
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
    Write-Host "    To import: Chrome > Bookmarks and lists > Import bookmarks and settings > HTML file" -ForegroundColor Gray
    Add-Result -Category "Browser" -Item "Chrome Bookmarks" -Status "Ready" -Details "$($chromeBookmarkFiles.Count) HTML file(s) for manual import"
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
            $process = Start-Process -FilePath "attrib.exe" -ArgumentList "+P", "-U", "/S", "/D", "`"$oneDriveFolder\*`"" -Wait -PassThru -NoNewWindow -ErrorAction Stop
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
    foreach ($pattern in @($appComparisonExcludePatterns)) {
        if ($name -match [string]$pattern) { return $false }
    }
    return $true
}

function Get-ProgramMatchKey {
    param([string]$DisplayName, [string]$Publisher)
    return "$(ConvertTo-ProgramMatchPart $DisplayName)|$(ConvertTo-ProgramMatchPart $Publisher)"
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
    return "<html><head><meta charset='utf-8'><title>Application Migration Review</title><style>body{font-family:Segoe UI;margin:32px;color:#202020}table{border-collapse:collapse;width:100%;margin-bottom:25px}td,th{padding:8px;border:1px solid #ccc;text-align:left}th{background:#17365d;color:#fff}h1{color:#17365d}</style></head><body><h1>Application Migration Review</h1><p>Review missing applications and AppData candidates before handoff. Candidate folders are review-only and were not copied automatically.</p><h2>Missing applications</h2><table><tr><th>Application</th><th>Publisher</th><th>Old version</th></tr>$rows</table><h2>AppData candidates</h2><table><tr><th>Area</th><th>Folder</th><th>Association</th></tr>$candidateRows</table></body></html>"
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
            $candidateItems = @($AppDataCandidates | ForEach-Object { "<li><strong>$(& $encode ([string]$_.RelativePath))</strong><small>$(& $encode ([string]$_.Area)) - $(& $encode ([string]$_.Association))</small></li>" }) -join "`n"
            $candidatePanel = if ($candidateItems) { "<details class='section'><summary>AppData migration review<span>$($AppDataCandidates.Count) folder(s) to review; none are copied automatically</span></summary><div class='section-content'><ul class='app-list'>$candidateItems</ul></div></details>" } else { '' }
            if ($MissingPrograms.Count -gt 0) {
                $appSection = "<div class='app-summary ready'><h3>$($MissingPrograms.Count) app(s) still need installation</h3><p>These applications were found on the old computer but not on this new computer. Install or approve replacements before handoff.</p><ul class='app-list'>$appItems</ul></div>$candidatePanel"
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
        $attention = @($Script:Results.Actions | Where-Object {
            $_.Category -in @('Settings', 'Taskbar Layout', 'Desktop Layout') -and
            $_.Status -in @('Warning', 'Error', 'Skipped', 'Manual', 'Pending')
        })
        $encode = { param($Value) [Security.SecurityElement]::Escape([string]$Value) }
        $content = if ($attention.Count) {
            $items = @($attention | ForEach-Object {
                "<li><strong>$(& $encode ([string]$_.Item))</strong><small>$(& $encode ([string]$_.Status)) · $(& $encode ([string]$_.Details))</small></li>"
            }) -join "`n"
            "<section class='section'><div class='section-header'>Import actions needing attention<span class='section-subtitle'>Settings or layout items Windows could not apply</span></div><div class='section-content'><div class='app-summary ready'><ul class='app-list'>$items</ul></div></div></section>"
        }
        else { '' }
        $reportHtml = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        $reportHtml = Set-TransferReportMarkedContent -Html $reportHtml -Marker 'IMPORT_RESULTS' -Content $content
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
        # Accept inventories from earlier package versions that predate MatchKey.
        $sourcePrograms = @(Get-Content -LiteralPath $sourceProgramsPath -Raw | ConvertFrom-Json | ForEach-Object {
            [PSCustomObject]@{
                DisplayName = $_.DisplayName; DisplayVersion = $_.DisplayVersion; Publisher = $_.Publisher
                InstallDate = $_.InstallDate; SourceScope = $_.SourceScope
                MatchKey = if ($_.MatchKey) { $_.MatchKey } else { Get-ProgramMatchKey $_.DisplayName $_.Publisher }
            }
        })
        $newPrograms = @(Get-CurrentInstalledPrograms)
        $newProgramsPath = Join-Path $logsPath 'NewInstalledPrograms.json'
        $newPrograms | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $newProgramsPath -Encoding UTF8
        $newByKey = @{}; foreach ($program in $newPrograms) { if ($program.MatchKey) { $newByKey[$program.MatchKey] = $program } }
        $allMissingPrograms = @($sourcePrograms | Where-Object { -not $_.MatchKey -or -not $newByKey.ContainsKey($_.MatchKey) })
        $filteredPrograms = @($allMissingPrograms | Where-Object { -not (Test-UserFacingProgram $_) })
        $missingPrograms = @($allMissingPrograms | Where-Object { Test-UserFacingProgram $_ })
        $matchedPrograms = @($sourcePrograms | Where-Object { $_.MatchKey -and $newByKey.ContainsKey($_.MatchKey) } | ForEach-Object {
            [PSCustomObject]@{ DisplayName = $_.DisplayName; Publisher = $_.Publisher; OldVersion = $_.DisplayVersion; NewVersion = $newByKey[$_.MatchKey].DisplayVersion; VersionDifferent = ($_.DisplayVersion -ne $newByKey[$_.MatchKey].DisplayVersion) }
        })
        $candidateItems = @()
        $candidatePath = Join-Path $scriptPath 'Settings\AppDataCandidates.json'
        if ($reviewAppDataCandidates -and (Test-Path -LiteralPath $candidatePath)) {
            $missingWords = @($missingPrograms | ForEach-Object { ConvertTo-ProgramMatchPart $_.DisplayName })
            $candidateItems = @(Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json | ForEach-Object {
                $association = if ($_.AssociationHint -and ($missingWords | Where-Object { $_ -like "*$($_.AssociationHint)*" })) { 'Potentially associated with missing app' } elseif ($_.CoveredByCuratedBackup) { 'Already covered by curated backup' } else { 'Review candidate' }
                [PSCustomObject]@{ Area = $_.Area; RelativePath = $_.RelativePath; SizeBytes = $_.SizeBytes; Association = $association }
            })
        }
        elseif ($reviewAppDataCandidates) { Write-Log 'AppData candidate review skipped: source inventory is missing.' -Level 'Warning' }
        $comparison = [PSCustomObject]@{ GeneratedAt = (Get-Date).ToString('o'); Missing = $missingPrograms; Filtered = $filteredPrograms; Matched = $matchedPrograms; AppDataCandidates = $candidateItems }
        $comparison | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logsPath 'AppMigrationComparison.json') -Encoding UTF8
        @('Application migration review', '', "Missing user-facing applications: $($missingPrograms.Count)", "Filtered technical entries: $($filteredPrograms.Count)", '') + @($missingPrograms | ForEach-Object { "MISSING | $($_.DisplayName) | $($_.Publisher) | old version: $($_.DisplayVersion)" }) + @('', 'Filtered technical entries:') + @($filteredPrograms | ForEach-Object { "FILTERED | $($_.DisplayName) | $($_.Publisher)" }) + @('', 'AppData candidates:') + @($candidateItems | ForEach-Object { "[$($_.Area)] $($_.RelativePath) | $($_.Association)" }) | Set-Content -LiteralPath (Join-Path $logsPath 'AppMigrationReview.txt') -Encoding UTF8
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

$successCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
$warningCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Warning" -or $_.Status -eq "Manual" -or $_.Status -eq "Pending" }).Count
$errorCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Error" }).Count
$skippedCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count

Write-Host "  Import complete" -ForegroundColor Green
Write-SummaryCard -Success $successCount -Warning $warningCount -Errors $errorCount -Skipped $skippedCount -Duration "$([math]::Round($duration.TotalMinutes, 1)) min"

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

# The only elevation path is the narrowly-scoped system helper. It starts only
# after all user-profile work has completed and restores power plus PrintBRM.
# TestMode must never show UAC or launch the helper.
$adminAuditPath = Join-Path $logsPath "AdminImportResult.json"
function Write-AdminHelperAudit {
    param([string]$Status, [string]$Detail)
    $audit = [PSCustomObject]@{ Timestamp = (Get-Date).ToString("o"); Status = $Status; Detail = $Detail; Source = "Import-LaptopData.ps1" }
    $audit | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $adminAuditPath -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $logsPath "AdminImportLog.txt") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Status] $Detail"
}

function Invoke-StandardSystemRestoreFallback {
    # Attempt system restoration that is allowed in the signed-in context and
    # turn policy/hardware rejections into explicit result entries.
    param([string]$HelperPath)

    # A complete .pow file is written only by an elevated export. A PrintBRM
    # package may also be present from that export. If UAC is unavailable on
    # the destination, give those artifacts one explicit standard-user try.
    # The helper records each result and retains the package on failure.
    if ($isAdmin) { return }
    $hasAdminExportArtifacts = (Test-Path -LiteralPath (Join-Path $scriptPath 'Settings\PowerScheme.pow')) -or
        (Test-Path -LiteralPath (Join-Path $scriptPath 'Printers\Printers.printerExport'))
    if (-not $hasAdminExportArtifacts) { return }

    try {
        Write-Host '  Trying non-administrator fallback for power settings and PrintBRM...' -ForegroundColor Cyan
        $fallbackProcess = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" -AllowStandardUser"
        if ($fallbackProcess.ExitCode -eq 0) {
            Write-Host '  Non-administrator fallback completed. See Logs\AdminImportLog.txt.' -ForegroundColor Green
            Write-AdminHelperAudit -Status 'FallbackCompleted' -Detail 'UAC was unavailable; standard-user power and PrintBRM fallback completed.'
        }
        else {
            Write-Host '  Non-administrator fallback could not complete all system tasks; packages were retained.' -ForegroundColor Yellow
            Write-AdminHelperAudit -Status 'FallbackPartial' -Detail "UAC was unavailable; standard-user fallback exited with code $($fallbackProcess.ExitCode). See AdminImportLog.txt."
        }
    }
    catch {
        Write-Host '  Non-administrator fallback could not start; system packages were retained.' -ForegroundColor Yellow
        Write-AdminHelperAudit -Status 'FallbackFailed' -Detail "Could not start standard-user fallback: $($_.Exception.Message)"
    }
}

if ($TestMode) {
    Write-AdminHelperAudit -Status "Skipped" -Detail "TestMode never launches the administrator helper."
}
elseif (-not $enableAdminHelper) {
    Write-AdminHelperAudit -Status "Skipped" -Detail "Optional administrator helper is disabled by package configuration."
}
else {
    $exportAdminState = 'unknown'
    try {
        $exportSettings = Get-Content -LiteralPath (Join-Path $scriptPath 'Settings\SystemSettings.json') -Raw | ConvertFrom-Json
        $exportAdminState = if ($exportSettings.ExportWasAdministrator) { 'with administrator rights' } else { 'without administrator rights' }
    } catch { }
    Write-Host "  System settings were exported $exportAdminState." -ForegroundColor DarkGray
    $adminChoice = Read-UserInput '  Run the optional elevated power/PrintBRM restore? (Y/N) [Y]'
    if ($adminChoice -match '^[Nn]') { $enableAdminHelper = $false }
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
            Write-Host "  Requesting administrator approval for power settings and PrintBRM..." -ForegroundColor Cyan
            $helperProcess = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`""
            if ($helperProcess.ExitCode -eq 0) {
                Write-Host "  Elevated power and printer restore completed. See Logs\\AdminImportLog.txt." -ForegroundColor Green
            }
            else {
                Write-Host "  Administrator helper reported an error; system tasks are deferred." -ForegroundColor Yellow
                Write-AdminHelperAudit -Status "Deferred" -Detail "Helper exited with code $($helperProcess.ExitCode)."
                Invoke-StandardSystemRestoreFallback -HelperPath $helperPath
            }
        }
        catch {
            Write-Host "  Administrator approval was cancelled or denied; system tasks are deferred." -ForegroundColor Yellow
            Write-AdminHelperAudit -Status "Cancelled" -Detail "UAC elevation was cancelled, denied, or could not start: $($_.Exception.Message)"
            Invoke-StandardSystemRestoreFallback -HelperPath $helperPath
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
param([switch]$AllowStandardUser)
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
    Write-Audit 'Running explicit non-administrator fallback; Windows may reject protected power or printer changes.' 'Warning'
}

$settingsFile = Join-Path $scriptPath 'Settings\SystemSettings.json'
$powerScheme = Join-Path $scriptPath 'Settings\PowerScheme.pow'
$settingsData = $null
if (Test-Path -LiteralPath $settingsFile) {
    try { $settingsData = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { $result.Errors += "Could not read SystemSettings.json: $($_.Exception.Message)" }
}

# Legacy packages have only a .pow file. New packages keep the managed plan
# and receive their captured AC/DC values one by one.
if ((Test-Path -LiteralPath $powerScheme) -and -not ($settingsData.PowerSettingValues -and @($settingsData.PowerSettingValues).Count)) {
    try {
        $guid = [guid]::NewGuid().ToString()
        $output = & powercfg /import $powerScheme $guid 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg /import exit ${LASTEXITCODE}: $(($output | Out-String).Trim())" }
        $output = & powercfg /setactive $guid 2>&1
        if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive exit ${LASTEXITCODE}: $(($output | Out-String).Trim())" }
        $result.Power += [PSCustomObject]@{ Item = 'Legacy power scheme'; Status = 'Success'; Detail = "Imported and activated $guid" }
        Write-Audit 'Legacy power scheme imported and activated.' 'Success'
    } catch { $result.Power += [PSCustomObject]@{ Item = 'Legacy power scheme'; Status = 'Failed'; Detail = $_.Exception.Message }; $result.Errors += $_.Exception.Message; Write-Audit "Power scheme failed: $_" 'Error' }
}
if ($settingsData.PowerSettingValues -and @($settingsData.PowerSettingValues).Count) {
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
if ($settingsData.LidClose -and $settingsData.LidClose.OnAC) {
    $map = @{ 'Do Nothing'=0; Sleep=1; Hibernate=2; 'Shut Down'=3 }
    foreach ($kind in @(@{ Command='/setacvalueindex'; Value=$map[$settingsData.LidClose.OnAC] }, @{ Command='/setdcvalueindex'; Value=$map[$settingsData.LidClose.OnBattery] })) {
        if ($null -ne $kind.Value) { & powercfg $kind.Command SCHEME_CURRENT SUB_BUTTONS LIDACTION $kind.Value 2>&1 | Out-Null }
    }
    & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
    $result.Power += [PSCustomObject]@{ Item = 'Lid actions'; Status = 'Attempted'; Detail = "AC: $($settingsData.LidClose.OnAC); DC: $($settingsData.LidClose.OnBattery)" }
}

$printerExport = Join-Path $scriptPath 'Printers\Printers.printerExport'
$printBrm = Join-Path $env:WINDIR 'System32\spool\tools\PrintBrm.exe'
$result.PrintBrm.PackagePresent = Test-Path -LiteralPath $printerExport
$result.PrintBrm.ToolPresent = Test-Path -LiteralPath $printBrm
if ($result.PrintBrm.PackagePresent -and $result.PrintBrm.ToolPresent) {
    try {
        $brmLog = Join-Path $logsPath 'printbrm_restore.log'
        & $printBrm -R -F $printerExport -O FORCE *>&1 | Tee-Object -LiteralPath $brmLog | Out-Null
        $result.PrintBrm.ExitCode = $LASTEXITCODE
        $result.PrintBrm.Status = if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Failed' }
        $result.PrinterStatus += [PSCustomObject]@{ Item='Local/direct-IP printers'; Status=$result.PrintBrm.Status; Detail="PrintBRM exit $LASTEXITCODE" }
        if ($LASTEXITCODE -eq 0 -and [bool]::Parse('{DELETE_PRINTBRM_AFTER_IMPORT}')) { Remove-Item -LiteralPath $printerExport -Force; Write-Audit 'PrintBRM succeeded; migration package deleted.' 'Success' }
        elseif ($LASTEXITCODE -ne 0) { Write-Audit "PrintBRM failed with exit $LASTEXITCODE; package retained." 'Warning' }
    } catch { $result.PrintBrm.Status='Failed'; $result.Errors += "PrintBRM error: $($_.Exception.Message)"; Write-Audit "PrintBRM error: $_; package retained." 'Error' }
} elseif ($result.PrintBrm.PackagePresent) { $result.PrintBrm.Status='Skipped'; $result.PrinterStatus += [PSCustomObject]@{ Item='Local/direct-IP printers'; Status='Skipped'; Detail='PrintBRM.exe not found' } }

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

