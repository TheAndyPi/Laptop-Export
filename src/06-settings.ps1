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
