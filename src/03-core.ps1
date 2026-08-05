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
    Version = "0.8"
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
    Transfer = @{
        # ZIP creation is available for Local and Online transfers. Local
        # transfers default to a folder-only package.
        CreateZipArchive = $false
    }
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
        # Online transfers create a portable ZIP by default.
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
foreach ($sectionName in @("Backup", "Import", "Transfer")) {
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
    $Script:Config.Transfer.CreateZipArchive = $Script:Config.Online.CreateZipArchive
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

# Payload sizing can take a while on large profiles.  Keep it in a separate
# process so the technician can continue through the menus while it runs.
$Script:PayloadEstimateJob = $null
$Script:PayloadEstimate = $null

function Start-TransferPayloadEstimate {
    if ($Script:PayloadEstimateJob) {
        try {
            if ($Script:PayloadEstimateJob.State -eq "Running") { Stop-Job -Job $Script:PayloadEstimateJob -ErrorAction SilentlyContinue }
            Remove-Job -Job $Script:PayloadEstimateJob -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    $Script:PayloadEstimate = $null
    $snapshot = @{
        UserProfile = $Script:OriginalUserProfile
        AppDataRoaming = $Script:OriginalAppDataRoaming
        AppDataLocal = $Script:OriginalAppDataLocal
        UserFolders = @($Script:Config.UserFolders)
        BluebeamPaths = @($Script:Config.BluebeamPaths)
        AppDataRoamingPaths = @($Script:Config.AppDataRoaming.Values)
        Backup = @{}
        TransferMode = $Script:Config.TransferMode
        SkipLotusNotes = [bool]$Script:Config.Online.SkipLotusNotes
    }
    foreach ($key in $Script:Config.Backup.Keys) { $snapshot.Backup[$key] = $Script:Config.Backup[$key] }

    $Script:PayloadEstimateJob = Start-Job -ArgumentList $snapshot -ScriptBlock {
        param($Config)
        function Get-Size([string]$Path) {
            if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
            $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
                Measure-Object -Property Length -Sum).Sum
            if ($null -eq $sum) { return [long]0 }
            return [long]$sum
        }

        $sizes = @{}
        foreach ($key in @("UserData","Downloads","AppData","LotusNotes","SystemSettings","InstalledPrograms","Printers","Chrome","Firefox","Edge","OneDrive")) { $sizes[$key] = [long]0 }
        if ($Config.Backup.UserData) {
            foreach ($folder in $Config.UserFolders) {
                if ($folder -ne "Downloads") { $sizes.UserData += Get-Size (Join-Path $Config.UserProfile $folder) }
            }
        }
        if ($Config.Backup.Downloads) { $sizes.Downloads = Get-Size (Join-Path $Config.UserProfile "Downloads") }
        if ($Config.Backup.AppData) {
            foreach ($path in $Config.BluebeamPaths) {
                $candidate = Join-Path $Config.AppDataRoaming $path
                if (Test-Path -LiteralPath $candidate) { $sizes.AppData += Get-Size $candidate; break }
            }
            foreach ($path in $Config.AppDataRoamingPaths) { $sizes.AppData += Get-Size (Join-Path $Config.AppDataRoaming $path) }
        }
        if ($Config.Backup.LotusNotes -and $Config.Backup.AppData -and -not ($Config.TransferMode -eq "Online" -and $Config.SkipLotusNotes)) { $sizes.LotusNotes = Get-Size (Join-Path $Config.AppDataLocal "Lotus") }
        if ($Config.Backup.Chrome -eq "FullProfile") { $sizes.Chrome = Get-Size (Join-Path $Config.AppDataLocal "Google\Chrome\User Data") }
        elseif ($Config.Backup.Chrome -eq "BookmarksAndPasswords") {
            $root = Join-Path $Config.AppDataLocal "Google\Chrome\User Data"
            $sizes.Chrome = [long]((Get-ChildItem -LiteralPath $root -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
        }
        if ($Config.Backup.Firefox) { $sizes.Firefox = (Get-Size (Join-Path $Config.AppDataRoaming "Mozilla\Firefox")) + (Get-Size (Join-Path $Config.AppDataLocal "Mozilla\Firefox")) }
        if ($Config.Backup.Edge) {
            $root = Join-Path $Config.AppDataLocal "Microsoft\Edge\User Data"
            $sizes.Edge = [long]((Get-ChildItem -LiteralPath $root -Recurse -File -Filter "Bookmarks" -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
        }
        [PSCustomObject]@{ ItemBytes = $sizes; TotalBytes = [long](($sizes.Values | Measure-Object -Sum).Sum) }
    }
}

function Update-TransferPayloadEstimate {
    if (-not $Script:PayloadEstimateJob -or $Script:PayloadEstimate) { return $false }
    if ($Script:PayloadEstimateJob.State -notin @("Completed", "Failed", "Stopped")) { return $false }
    try {
        $result = Receive-Job -Job $Script:PayloadEstimateJob -ErrorAction Stop
        if ($result) {
            $Script:PayloadEstimate = @{ ItemBytes = @{}; TotalBytes = [long]$result.TotalBytes }
            foreach ($key in $result.ItemBytes.Keys) { $Script:PayloadEstimate.ItemBytes[$key] = [long]$result.ItemBytes[$key] }
        }
    }
    catch { Write-Log "Background size estimate failed; it will be recalculated before export: $_" -Level Warning }
    finally {
        Remove-Job -Job $Script:PayloadEstimateJob -Force -ErrorAction SilentlyContinue
        $Script:PayloadEstimateJob = $null
    }
    return ($null -ne $Script:PayloadEstimate)
}

function Wait-TransferPayloadEstimate {
    while (-not $Script:PayloadEstimate) {
        if (Update-TransferPayloadEstimate) { break }
        if (-not $Script:PayloadEstimateJob) {
            Write-Log "Using foreground size calculation after the background estimate did not complete." -Level Warning
            return Get-TransferPayloadEstimate
        }
        Start-Sleep -Milliseconds 150
    }
    return $Script:PayloadEstimate
}

function Read-MenuChoiceWhileEstimating {
    param([string]$Prompt)
    Write-Host $Prompt
    Write-Host "  > " -NoNewline
    try {
        $input = [System.Text.StringBuilder]::new()
        while ($true) {
            if (Update-TransferPayloadEstimate) { return @{ Choice = $input.ToString(); EstimateUpdated = $true } }
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ""; return @{ Choice = $input.ToString(); EstimateUpdated = $false } }
                if ($key.Key -eq [ConsoleKey]::Backspace -and $input.Length -gt 0) { [void]$input.Remove($input.Length - 1, 1); Write-Host "`b `b" -NoNewline; continue }
                if (-not [char]::IsControl($key.KeyChar)) { [void]$input.Append($key.KeyChar); Write-Host $key.KeyChar -NoNewline }
            }
            Start-Sleep -Milliseconds 75
        }
    }
    catch {
        return @{ Choice = (Read-Host "").Trim(); EstimateUpdated = $false }
    }
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
        @{ Section = "Transfer"; Key = "CreateZipArchive";  Label = "Create ZIP archive"; Detail = "Create a ZIP beside the package (off by default for Local)" }
        @{ Section = "Online"; Key = "StageNetworkTransfersLocally"; Label = "Stage network transfers locally"; Detail = "Build locally, then upload one ZIP to a network destination" }
    )

    while ($true) {
        Clear-StoScreen
        Write-Banner -Title "Transfer Settings" -Subtitle "$($Script:Config.TransferMode) transfer - changes apply to this transfer only"
        Write-Section "Backup settings"
        Update-TransferPayloadEstimate | Out-Null
        $estimate = $Script:PayloadEstimate

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
            $sizeText = if ($setting.Section -eq "Backup" -and $estimate) { "$(Format-FileSize ([long]$estimate.ItemBytes[$setting.Key]))" } elseif ($setting.Section -eq "Backup") { "calculating" } else { "" }

            Write-Host "  [$number] " -ForegroundColor Cyan -NoNewline
            Write-Host "$state " -ForegroundColor $color -NoNewline
            Write-Host $setting.Label.PadRight(30) -ForegroundColor White -NoNewline
            if ($sizeText) { Write-Host "$($sizeText.PadLeft(10)) " -ForegroundColor DarkCyan -NoNewline }
            Write-Host $setting.Detail -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "  Select a number to toggle it; select Chrome to cycle its backup mode." -ForegroundColor Gray
        Write-Host "  Chrome can export bookmarks and passwords without copying its full profile." -ForegroundColor DarkGray
        Write-Host "  ZIP archive can be created for either mode; it is off by default for Local transfers." -ForegroundColor DarkGray
        Write-Host "  Import settings are written into the transfer package's generated import script." -ForegroundColor DarkGray
        $menuInput = Read-MenuChoiceWhileEstimating -Prompt "  [S] Start transfer  [Q] Cancel"
        if ($menuInput.EstimateUpdated) { continue }
        $selection = $menuInput.Choice.Trim()

        if ($selection -match "^[Ss]$") { return $true }
        if ($selection -match "^[Qq]$") { return $false }

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
            elseif ($setting.Type -eq "ChromeMode") {
                $Script:Config.Backup.Chrome = switch ($Script:Config.Backup.Chrome) {
                    "Off" { "BookmarksAndPasswords" }
                    "BookmarksAndPasswords" { "FullProfile" }
                    default { "Off" }
                }
            }
            else { $Script:Config[$setting.Section][$setting.Key] = -not [bool]$Script:Config[$setting.Section][$setting.Key] }
            Start-TransferPayloadEstimate
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
        Update-TransferPayloadEstimate | Out-Null
        $estimate = $Script:PayloadEstimate
        Write-KeyValue "Transfer mode" $Script:Config.TransferMode
        Write-KeyValue "Estimated size" $(if ($estimate) { Format-FileSize $estimate.TotalBytes } else { "Calculating in background..." })
        Write-Host ""
        $menuInput = Read-MenuChoiceWhileEstimating -Prompt "  [1] Start transfer  [2] Change settings  [3] Cancel"
        if ($menuInput.EstimateUpdated) { continue }
        $choice = $menuInput.Choice.Trim()

        if ($choice -eq "1") { return $true }
        if ($choice -eq "3") { return $false }
        if ($choice -eq "2") {
            if (-not (Show-TransferSettingsMenu)) { return $false }
            continue
        }
        Write-Host "  Enter 1, 2, or 3." -ForegroundColor Yellow
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

