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

    # Elevation is opt-in from the Transfer Settings screen. This keeps the
    # initial mode selection uninterrupted while retaining full export support.
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
    # /Z (restartable mode) writes extra recovery state and is noticeably
    # slower for normal local/USB copies. A failed copy can be rerun safely,
    # so favor throughput with parallel file copies. (/J remains in use for
    # the one-file ZIP upload, where unbuffered I/O is beneficial.)
    RobocopyArgs = @("/E", "/R:2", "/W:3", "/MT:16", "/NP", "/NDL", "/NFL", "/NJH", "/NJS")

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
            EnableAdminHelper = $false
            AppComparison = $true
            AppDataReview = $true
        }
    }

    # These switches are supplied by src\00-development-config.psd1 at build
    # time and remain embedded in the single deployment script.
    Backup = @{
        UserData          = $true
        EntireUserProfile = $false
        AdditionalAppData = $false
        AppData           = $true
        LotusNotes        = $true
        SystemSettings    = $true
        InstalledPrograms = $true
        AppDataCandidateInventory = $true
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
        AppComparison = $true
        AppDataReview = $true
    }
}

# Apply only known Boolean development switches so invalid additions cannot
# unexpectedly change the behavior of a technician deployment.
foreach ($sectionName in @("Backup", "Import", "Export")) {
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
    foreach ($switchName in @("CreateZipArchive", "StageNetworkTransfersLocally", "OverrideDownloadsCap", "IncludeChromeProfileArchive", "IncludeAdditionalUserFolders", "IncludeOcsDocuments", "DetailedAppDataCandidateInventory")) {
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
        foreach ($settingName in @('OverrideDownloadsCap', 'CreateZipArchive', 'StageNetworkTransfersLocally', 'IncludeChromeProfileArchive', 'IncludeAdditionalUserFolders', 'IncludeOcsDocuments', 'DetailedAppDataCandidateInventory')) {
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

function Apply-OnlineImportDefaults {
    if ($Script:Config.TransferMode -ne "Online") { return }

    foreach ($switchName in $Script:Config.Online.Import.Keys) {
        $Script:Config.Import[$switchName] = $Script:Config.Online.Import[$switchName]
    }
}

function Set-SettingsPreset {
    param([ValidateSet('Basic', 'Advanced')][string]$Name)

    $Script:Config.Backup.EntireUserProfile = ($Name -eq 'Advanced')
    $Script:Config.Backup.AdditionalAppData = ($Name -eq 'Advanced')
    if ($Name -eq 'Basic') { $Script:SelectedAdditionalAppData = @() }
    $Script:SettingsPreset = $Name
}

function Resolve-ExportUserFolderPath {
    param([string]$Folder)
    if ($Folder -eq 'Start Menu') {
        return (Join-Path $Script:OriginalAppDataRoaming 'Microsoft\Windows\Start Menu')
    }
    return (Join-Path $Script:OriginalUserProfile $Folder)
}

function Start-TransferSizeEstimateJob {
    # Run the initial inventory out-of-process so Transfer Settings remains
    # responsive while large profiles are being scanned.
    # Keep large profile-related payloads near the end and normal user folders
    # last. This avoids Documents/Desktop/Downloads competing with the more
    # useful early estimates while the background job is still running.
    $normalPaths = @((Join-Path $Script:OriginalAppDataLocal 'Microsoft\Edge\User Data'))
    $heavyPaths = @($Script:OriginalUserProfile)
    $heavyPaths += @($Script:Config.BluebeamPaths | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
    $heavyPaths += @($Script:Config.AppDataRoaming.Values | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
    $heavyPaths += @(
        (Join-Path $Script:OriginalAppDataLocal 'Lotus'),
        (Join-Path $Script:OriginalAppDataLocal 'Google\Chrome\User Data'),
        (Join-Path $Script:OriginalAppDataRoaming 'Mozilla\Firefox'),
        (Join-Path $Script:OriginalAppDataLocal 'Mozilla\Firefox')
    )
    $userDataPaths = @($Script:Config.UserFolders | ForEach-Object { Resolve-ExportUserFolderPath $_ })
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
                    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) })
                    $sum = ($files | Measure-Object -Property Length -Sum).Sum
                    $bytes = [long]$(if ($null -eq $sum) { 0 } else { $sum }); $count = $files.Count
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
    foreach ($key in @('UserData', 'EntireUserProfile', 'AdditionalAppData', 'AppData', 'LotusNotes', 'Chrome', 'Firefox', 'Edge')) {
        if ($Script:Config.Backup[$key]) { $sizes[$key] = $null }
    }
    if ($Script:Config.Backup.UserData) { $sizes.UserData = Get-CachedFolderSizeSum -Paths @($Script:Config.UserFolders | ForEach-Object { Resolve-ExportUserFolderPath $_ }) }
    if ($Script:Config.Backup.AppData) {
        $appDataPaths = @($Script:Config.BluebeamPaths | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ }) + @($Script:Config.AppDataRoaming.Values | ForEach-Object { Join-Path $Script:OriginalAppDataRoaming $_ })
        $sizes.AppData = Get-CachedFolderSizeSum -Paths $appDataPaths
    }
    if ($Script:Config.Backup.LotusNotes) { $sizes.LotusNotes = Get-CachedFolderSizeBytes -Path (Join-Path $Script:OriginalAppDataLocal 'Lotus') }
    if ($Script:Config.Backup.Chrome) { $sizes.Chrome = Get-CachedFolderSizeBytes -Path (Join-Path $Script:OriginalAppDataLocal 'Google\Chrome\User Data') }
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
        $Script:StartupPayloadEstimate = Get-TransferPayloadEstimate
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
    param([string]$Prompt, [scriptblock]$Poll)
    try {
        $rawUi = $Host.UI.RawUI
        [void]$rawUi.KeyAvailable
    }
    catch { return (Read-Host $Prompt).Trim() }
    $buffer = ''
    while ($true) {
        if (& $Poll) { Write-Host ''; return '__MENU_AUTO_REFRESH__' }
        if ($rawUi.KeyAvailable) {
            $key = $rawUi.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.VirtualKeyCode -eq 13) { Write-Host ''; return $buffer.Trim() }
            if ($key.VirtualKeyCode -eq 8) { if ($buffer.Length) { $buffer = $buffer.Substring(0, $buffer.Length - 1); Write-Host "`b `b" -NoNewline }; continue }
            if ($key.Character -and -not [char]::IsControl($key.Character)) { $buffer += $key.Character; Write-Host $key.Character -NoNewline }
        }
        Start-Sleep -Milliseconds 120
    }
}

function Start-ElevatedExport {
    if ($Script:IsAdmin -or -not $Script:Config.Export.RequestAdministratorPrivileges) { return $true }

    Write-Host "`n  Requesting administrator approval for the export..." -ForegroundColor Cyan
    $scriptPath = $PSCommandPath
    $elevatedArgs = "-ExecutionPolicy Bypass -File `"$scriptPath`" -TargetUserProfile `"$env:USERPROFILE`" -TargetUserName `"$env:USERNAME`" -TargetAppDataRoaming `"$env:APPDATA`" -TargetAppDataLocal `"$env:LOCALAPPDATA`""
    if ($TransferMode) { $elevatedArgs += " -TransferMode `"$TransferMode`"" }
    if ($DestinationPath) { $elevatedArgs += " -DestinationPath `"$DestinationPath`"" }
    if ($OnlineMaxTransferGB -gt 0) { $elevatedArgs += " -OnlineMaxTransferGB $OnlineMaxTransferGB" }
    $settingsToPreserve = [ordered]@{
        Backup = $Script:Config.Backup
        Import = $Script:Config.Import
        Export = $Script:Config.Export
        Online = $Script:Config.Online
        AdditionalAppData = @($Script:SelectedAdditionalAppData)
        TransferStartedAt = if ($Script:Results.StartTime) { $Script:Results.StartTime.ToString('o') } else { $null }
    }
    $encodedSettings = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($settingsToPreserve | ConvertTo-Json -Depth 5 -Compress)))
    $elevatedArgs += " -RuntimeSettings `"$encodedSettings`" -ElevatedFromSettings"

    try {
        Start-Process PowerShell -Verb RunAs -ArgumentList $elevatedArgs -ErrorAction Stop | Out-Null
        # The elevated process owns the transfer; stop this standard-user run.
        return $false
    }
    catch {
        Write-Host "  Administrator approval was cancelled or unavailable; continuing without it." -ForegroundColor Yellow
        Write-Host "  Admin-only tasks will be included in the manual checklist.`n" -ForegroundColor Gray
        $Script:Config.Export.RequestAdministratorPrivileges = $false
        return $true
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

function Show-OnlineAdvancedSettingsMenu {
    while ($true) {
        Clear-StoScreen
        Write-Banner -Title "Advanced Online Controls" -Subtitle "These choices affect this transfer only"
        $chromePath = Join-Path $Script:OriginalAppDataLocal "Google\Chrome\User Data"
        $chromeArchiveEstimate = Get-FolderSizeBytes -Path $chromePath
        $archiveState = if ($Script:Config.Online.IncludeChromeProfileArchive) { "ON " } else { "OFF" }
        $archiveColor = if ($Script:Config.Online.IncludeChromeProfileArchive) { "Green" } else { "DarkGray" }

        Write-Host "  [1] $archiveState " -ForegroundColor Cyan -NoNewline
        Write-Host "Chrome full profile archive" -ForegroundColor $archiveColor -NoNewline
        Write-Host "  up to $(Format-FileSize $chromeArchiveEstimate); OFF = bookmarks + password export only" -ForegroundColor DarkGray
        foreach ($setting in @(
            @{ Number = 2; Key = 'IncludeAdditionalUserFolders'; Label = 'Include additional user folders'; Detail = 'OFF skips unlisted profile folders in Online mode' }
            @{ Number = 3; Key = 'IncludeOcsDocuments'; Label = 'Include C:\\OCS Documents'; Detail = 'OFF skips this optional project folder in Online mode' }
            @{ Number = 4; Key = 'DetailedAppDataCandidateInventory'; Label = 'Detailed AppData candidate sizes'; Detail = 'OFF records names only and avoids recursive sizing' }
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
        $selection = (Read-Host "  Select 1-5, [B] Back").Trim()
        if ($selection -match '^[Bb]$') { return }
        if ($selection -eq '5') {
            $value = 0.0; $entered = Read-Host "  Enter additional-folder cap in GB (current: $($Script:Config.Online.AdditionalFolderCapGB))"
            if ([double]::TryParse($entered, [ref]$value) -and $value -gt 0) { $Script:Config.Online.AdditionalFolderCapGB = $value }
            continue
        }
        $index = 0
        if ([int]::TryParse($selection, [ref]$index) -and $index -ge 1 -and $index -le 4) {
            $key = @('IncludeChromeProfileArchive', 'IncludeAdditionalUserFolders', 'IncludeOcsDocuments', 'DetailedAppDataCandidateInventory')[$index - 1]
            $Script:Config.Online[$key] = -not [bool]$Script:Config.Online[$key]
            $Script:SettingsPreset = 'Custom'
        }
    }
}

function Show-TransferSettingsMenu {
    # These are the runtime counterparts of the switches in
    # src\00-development-config.psd1.  Values start with the compiled
    # defaults, but any changes made here apply only to the current transfer.
    $settings = @(
        @{ Section = "Backup"; Key = "UserData";          Label = "User data";          Detail = "Documents, Desktop, Downloads, and other user folders" }
        @{ Section = "Backup"; Key = "EntireUserProfile"; Label = "Entire user profile"; Detail = "Copy remaining profile folders; excludes data captured by other stages" }
        @{ Section = "Backup"; Key = "AdditionalAppData"; Label = "Additional AppData folders"; Detail = "Choose extra Local/Roaming folders with size estimates" }
        @{ Section = "Backup"; Key = "AppData";           Label = "AppData";            Detail = "Bluebeam, signatures, and Quick Access" }
        @{ Section = "Backup"; Key = "LotusNotes";        Label = "Lotus Notes";        Detail = "Local Lotus Notes data from AppData\\Local" }
        @{ Section = "Backup"; Key = "SystemSettings";    Label = "System settings";    Detail = "Power, drives, personalization, and related settings" }
        @{ Section = "Backup"; Key = "InstalledPrograms"; Label = "Installed programs"; Detail = "Installed-program inventory" }
        @{ Section = "Backup"; Key = "AppDataCandidateInventory"; Label = "AppData candidates"; Detail = "Review-only inventory of non-system application folders" }
        @{ Section = "Backup"; Key = "Printers";          Label = "Printers";           Detail = "PrintBRM package and printer connections" }
        @{ Section = "Backup"; Key = "Chrome";            Label = "Google Chrome";      Detail = "Bookmarks, profile archive, and password-export prompt" }
        @{ Section = "Backup"; Key = "Firefox";           Label = "Firefox";            Detail = "Firefox profile, bookmarks, logins, extensions, and settings" }
        @{ Section = "Backup"; Key = "Edge";              Label = "Microsoft Edge";     Detail = "Edge bookmarks and profile-specific favorites" }
        @{ Section = "Backup"; Key = "OneDrive";          Label = "OneDrive";           Detail = "Offline file availability check" }
        @{ Section = "Backup"; Key = "DesktopLayout";     Label = "Desktop layout";     Detail = "Shortcut layout manifest and safe OneDrive duplicate review" }
        @{ Section = "Backup"; Key = "TaskbarLayout";     Label = "Taskbar layout";     Detail = "Pinned app shortcuts and taskbar layout" }
        @{ Section = "Backup"; Key = "DefaultApps";       Label = "Default apps";       Detail = "File and protocol default-app inventory" }
        @{ Section = "Export"; Key = "RequestAdministratorPrivileges"; Label = "Run export as administrator"; Detail = "Request UAC approval after you start the transfer" }
        @{ Section = "Import"; Key = "LotusNotes";        Label = "Import Lotus Notes"; Detail = "Restore exported Lotus local data on the new laptop" }
        @{ Section = "Import"; Key = "DeletePrintBrmAfterImport"; Label = "Delete PrintBRM after import"; Detail = "Remove the printer package after a successful restore" }
        @{ Section = "Import"; Key = "AppComparison"; Label = "Compare installed apps"; Detail = "Compare old and new PC installed-program inventories" }
        @{ Section = "Import"; Key = "AppDataReview"; Label = "Review AppData candidates"; Detail = "Include source AppData candidates in the technician review" }
        @{ Section = "Online"; Key = "MaxTransferGB"; Type = "Number"; Label = "Online payload limit"; Detail = "Warn before export when selected payload exceeds this many GB" }
        @{ Section = "Online"; Key = "OverrideDownloadsCap"; Label = "Override Downloads cap"; Detail = "Allow Downloads above the $($Script:Config.Online.DownloadsCapGB) GB Online cap" }
        @{ Section = "Online"; Key = "CreateZipArchive";  Label = "Create ZIP archive"; Detail = "Create a ZIP beside the package (Online transfers only)" }
        @{ Section = "Online"; Key = "StageNetworkTransfersLocally"; Label = "Stage network transfers locally"; Detail = "Build locally, then upload one ZIP to a network destination" }
    )
    $Script:TransferSettingsMenuItems = $settings

    # Render the settings screen first, then calculate once and redraw it with
    # populated sizes. Later toggles reuse the cached inventory.
    $estimate = if ($Script:StartupPayloadEstimate) { $Script:StartupPayloadEstimate } else { $Script:TransferSizeDisplayEstimate }
    if ($null -eq $estimate -and -not $Script:TransferSizeEstimateJob) { $Script:TransferSizeEstimateJob = Start-TransferSizeEstimateJob }

    while ($true) {
        if (Receive-TransferSizeEstimateJob) { $estimate = if ($Script:StartupPayloadEstimate) { $Script:StartupPayloadEstimate } else { $Script:TransferSizeDisplayEstimate } }
        Clear-StoScreen
        Write-Banner -Title "Transfer Settings" -Subtitle "$($Script:Config.TransferMode) transfer - changes apply to this transfer only"
        Write-Section "Backup settings"

        for ($index = 0; $index -lt $settings.Count; $index++) {
            $setting = $settings[$index]
            if ($index -eq 16) {
                Write-Section "Export settings"
            }
            if ($index -eq 17) {
                Write-Section "Generated import settings"
            }
            if ($index -eq 22) {
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
            $isEnabled = if ($isNumber) { $false } else { [bool]$Script:Config[$setting.Section][$setting.Key] }
            $state = if ($isNumber) { "$($Script:Config.Online.MaxTransferGB)GB" } elseif ($isEnabled) { "ON " } else { "OFF" }
            $color = if ($isNumber) { "Yellow" } elseif ($isEnabled) { "Green" } else { "DarkGray" }
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
        Write-Host "  Select a number to toggle it; [B] Basic; [V] Advanced; [R] Refresh; select Online payload limit to enter a GB value." -ForegroundColor Gray
        if ($Script:Config.TransferMode -eq 'Online') { Write-Host "  [A] Advanced Online Controls" -ForegroundColor Cyan }
        Write-Host "  Chrome, Firefox, and Edge are independent backup toggles." -ForegroundColor DarkGray
        Write-Host "  Administrator mode is requested only after you choose Start transfer." -ForegroundColor DarkGray
        Write-Host "  ZIP archive is ignored for Local transfers." -ForegroundColor DarkGray
        Write-Host "  Import settings are written into the transfer package's generated import script." -ForegroundColor DarkGray

        if ($Script:TransferSizeEstimateJob) { Write-Host '  Calculating folder sizes in the background. Press R to refresh; the menu refreshes automatically when finished.' -ForegroundColor Cyan }
        $selection = Read-MenuInputWithBackgroundRefresh -Prompt '  [S] Start transfer  [Q] Cancel  [R] Refresh' -Poll {
            $wasRunning = [bool]$Script:TransferSizeEstimateJob
            [void](Receive-TransferSizeEstimateJob)
            return ($wasRunning -and -not $Script:TransferSizeEstimateJob)
        }

        if ($selection -eq '__MENU_AUTO_REFRESH__' -or $selection -match '^[Rr]$') { continue }
        if ($selection -match "^[Ss]$") { return $true }
        if ($selection -match "^[Qq]$") { return $false }
        if ($selection -match "^[Bb]$") { Set-SettingsPreset -Name Basic; Update-AdvancedPayloadEstimate; continue }
        if ($selection -match "^[Vv]$") { Set-SettingsPreset -Name Advanced; $Script:SelectedAdditionalAppData = Select-AdditionalAppData; $Script:SkipAdditionalAppDataSizing = $false; Update-AdvancedPayloadEstimate; continue }
        if ($selection -match "^[Aa]$" -and $Script:Config.TransferMode -eq 'Online') { Show-OnlineAdvancedSettingsMenu; continue }

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
            else {
                $Script:Config[$setting.Section][$setting.Key] = -not [bool]$Script:Config[$setting.Section][$setting.Key]
                $Script:SettingsPreset = 'Custom'
                if ($setting.Section -eq 'Backup' -and $setting.Key -eq 'AdditionalAppData') {
                    if ($Script:Config.Backup.AdditionalAppData) { $Script:SelectedAdditionalAppData = Select-AdditionalAppData; $Script:SkipAdditionalAppDataSizing = $false }
                    else { $Script:SelectedAdditionalAppData = @() }
                    Update-AdvancedPayloadEstimate
                }
                elseif ($setting.Section -eq 'Backup' -and $setting.Key -eq 'EntireUserProfile') {
                    Update-AdvancedPayloadEstimate
                }
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
    
    # Do not recursively enumerate the destination while robocopy is writing.
    # Browser profiles commonly contain tens of thousands of cache files; the
    # previous 750 ms rescan saturated the same disk and network link as the
    # transfer. Keep cancellation responsive with a zero-I/O spinner instead.
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
        
        # Advance spinner without inspecting the destination tree.
        $spin = $Script:Theme.Spinner[$spinIndex % $Script:Theme.Spinner.Count]
        $spinIndex++
        $elapsed = (Get-Date) - $startTime
        $statusLine = "    $spin Copying $(Format-FileSize $totalSize) / $totalFiles files  elapsed $([math]::Round($elapsed.TotalSeconds, 0)) sec   "
        Write-Host "`r$statusLine" -NoNewline
    }
    
    $exitCode = $process.ExitCode
    
    $elapsed = (Get-Date) - $startTime
    $copiedSize = $totalSize
    $copiedFiles = $totalFiles
    
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

    $progressBar = [string]$Script:Theme.Bar.Full * 34
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

