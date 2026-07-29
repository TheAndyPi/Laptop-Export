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

if (-not $Script:IsAdmin) {
    Write-Banner -Title "Administrator Privileges Recommended"
    Write-Host "  Some features (power scheme and a full PrintBRM package) require admin rights." -ForegroundColor Gray
    Write-Host "  PrintBRM is still attempted if you skip; its result is recorded in the package.`n" -ForegroundColor DarkGray
    
    $choice = if ($NonInteractive) {
        Write-Host "  Non-interactive mode: continuing without elevation." -ForegroundColor DarkGray
        "S"
    }
    else {
        Read-Host "  Run as Administrator? (Y/N, or S to skip)"
    }
    
    if ($choice -eq "Y" -or $choice -eq "y") {
        Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
        $scriptPath = $MyInvocation.MyCommand.Path
        
        # Pass the current user's profile info to the elevated script
        $elevatedArgs = "-ExecutionPolicy Bypass -File `"$scriptPath`" -TargetUserProfile `"$env:USERPROFILE`" -TargetUserName `"$env:USERNAME`" -TargetAppDataRoaming `"$env:APPDATA`" -TargetAppDataLocal `"$env:LOCALAPPDATA`""
        if ($TransferMode) { $elevatedArgs += " -TransferMode `"$TransferMode`"" }
        if ($DestinationPath) { $elevatedArgs += " -DestinationPath `"$DestinationPath`"" }
        if ($OnlineMaxTransferGB -gt 0) { $elevatedArgs += " -OnlineMaxTransferGB $OnlineMaxTransferGB" }
        
        try {
            $process = Start-Process PowerShell -Verb RunAs -ArgumentList $elevatedArgs -PassThru -ErrorAction Stop
            # If we get here, elevation was accepted - exit this non-admin instance
            exit
        }
        catch {
            Write-Host "`nCould not elevate to administrator. Continuing without admin rights..." -ForegroundColor Yellow
            Write-Host "Admin-required tasks will be added to the manual checklist.`n" -ForegroundColor Gray
            Start-Sleep -Seconds 2
        }
    }
    else {
        Write-Host "`nContinuing without administrator privileges..." -ForegroundColor Yellow
        Write-Host "Some tasks will be added to the manual checklist.`n" -ForegroundColor Gray
        Start-Sleep -Seconds 1
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

    # Online-mode trimming rules (only applied when TransferMode = "Online")
    Online = @{
        # Downloads is usually one of the two largest folders. Cap it: if it
        # exceeds this size, omit it entirely (per IT guidance) and log a manual task.
        DownloadsCapGB   = 5
        MaxTransferGB    = 5
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
        # Import defaults used only when the selected transfer mode is Online.
        Import = @{
            LotusNotes = $true
            DeletePrintBrmAfterImport = $true
            EnableAdminHelper = $false
        }
    }

    # These switches are supplied by src\00-development-config.psd1 at build
    # time and remain embedded in the single deployment script.
    Backup = @{
        UserData          = $true
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        Printers          = $true
        Chrome            = $true
        Firefox           = $true
        Edge              = $true
        OneDrive          = $true
        DesktopLayout     = $true
        TaskbarLayout     = $true
        DefaultApps       = $true
    }
    Import = @{
        LotusNotes = $true
        DeletePrintBrmAfterImport = $true
        EnableAdminHelper = $false
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

# Online transfer behavior has a nested import-default section. Keep its
# allowlist separate so config-file additions cannot alter unrelated settings.
if ($Script:DevelopmentConfig -is [hashtable] -and
    $Script:DevelopmentConfig.ContainsKey("Online") -and
    $Script:DevelopmentConfig.Online -is [hashtable]) {
    $developmentOnline = $Script:DevelopmentConfig.Online
    foreach ($switchName in @("CreateZipArchive", "StageNetworkTransfersLocally", "OverrideDownloadsCap")) {
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

function Apply-OnlineImportDefaults {
    if ($Script:Config.TransferMode -ne "Online") { return }

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
        @{ Section = "Backup"; Key = "UserData";          Label = "User data";          Detail = "Documents, Desktop, Downloads, and other user folders" }
        @{ Section = "Backup"; Key = "AppData";           Label = "AppData";            Detail = "Bluebeam, signatures, and Quick Access" }
        @{ Section = "Backup"; Key = "LotusNotes";        Label = "Lotus Notes";        Detail = "Local Lotus Notes data from AppData\\Local" }
        @{ Section = "Backup"; Key = "SystemSettings";    Label = "System settings";    Detail = "Power, drives, personalization, and related settings" }
        @{ Section = "Backup"; Key = "InstalledPrograms"; Label = "Installed programs"; Detail = "Installed-program inventory" }
        @{ Section = "Backup"; Key = "Printers";          Label = "Printers";           Detail = "PrintBRM package and printer connections" }
        @{ Section = "Backup"; Key = "Chrome";            Label = "Google Chrome";      Detail = "Bookmarks, profile archive, and password-export prompt" }
        @{ Section = "Backup"; Key = "Firefox";           Label = "Firefox";            Detail = "Firefox profile, bookmarks, logins, extensions, and settings" }
        @{ Section = "Backup"; Key = "Edge";              Label = "Microsoft Edge";     Detail = "Edge bookmarks and profile-specific favorites" }
        @{ Section = "Backup"; Key = "OneDrive";          Label = "OneDrive";           Detail = "Offline file availability check" }
        @{ Section = "Backup"; Key = "DesktopLayout";     Label = "Desktop layout";     Detail = "Shortcut layout manifest and safe OneDrive duplicate review" }
        @{ Section = "Backup"; Key = "TaskbarLayout";     Label = "Taskbar layout";     Detail = "Pinned app shortcuts and taskbar layout" }
        @{ Section = "Backup"; Key = "DefaultApps";       Label = "Default apps";       Detail = "File and protocol default-app inventory" }
        @{ Section = "Import"; Key = "LotusNotes";        Label = "Import Lotus Notes"; Detail = "Restore exported Lotus local data on the new laptop" }
        @{ Section = "Import"; Key = "DeletePrintBrmAfterImport"; Label = "Delete PrintBRM after import"; Detail = "Remove the printer package after a successful restore" }
        @{ Section = "Online"; Key = "MaxTransferGB"; Type = "Number"; Label = "Online payload limit"; Detail = "Warn before export when selected payload exceeds this many GB" }
        @{ Section = "Online"; Key = "OverrideDownloadsCap"; Label = "Override Downloads cap"; Detail = "Allow Downloads above the $($Script:Config.Online.DownloadsCapGB) GB Online cap" }
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
            if ($index -eq 10) {
                Write-Section "Generated import settings"
            }
            if ($index -eq 12) {
                Write-Section "Online transfer settings"
            }

            $number = ($index + 1).ToString().PadLeft(2)
            $isNumber = $setting.Type -eq "Number"
            $isEnabled = if ($isNumber) { $false } else { [bool]$Script:Config[$setting.Section][$setting.Key] }
            $state = if ($isNumber) { "$($Script:Config.Online.MaxTransferGB)GB" } elseif ($isEnabled) { "ON " } else { "OFF" }
            $color = if ($isNumber) { "Yellow" } elseif ($isEnabled) { "Green" } else { "DarkGray" }
            $sizeText = if ($setting.Section -eq "Backup") { "$(Format-FileSize ([long]$estimate.ItemBytes[$setting.Key]))" } else { "" }

            Write-Host "  [$number] " -ForegroundColor Cyan -NoNewline
            Write-Host "$state " -ForegroundColor $color -NoNewline
            Write-Host $setting.Label.PadRight(30) -ForegroundColor White -NoNewline
            if ($sizeText) { Write-Host "$($sizeText.PadLeft(10)) " -ForegroundColor DarkCyan -NoNewline }
            Write-Host $setting.Detail -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  Select a number to toggle it; select Online payload limit to enter a GB value." -ForegroundColor Gray
        Write-Host "  Chrome, Firefox, and Edge are independent backup toggles." -ForegroundColor DarkGray
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
            else { $Script:Config[$setting.Section][$setting.Key] = -not [bool]$Script:Config[$setting.Section][$setting.Key] }
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

