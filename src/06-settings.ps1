# SETTINGS CAPTURE
# ============================================================================

# This module captures settings as portable evidence or importable artifacts.
# Registry exports, text/JSON snapshots, shortcut metadata, application lists,
# and printer packages have different portability and privilege rules; each
# function keeps those rules explicit instead of treating the entire profile as
# a raw filesystem copy.

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

    # BitLocker state is a handoff prerequisite. Capture it without making an
    # unavailable management module an export-stopping condition.
    try {
        $bitLocker = @(Get-BitLockerVolume -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ MountPoint = $_.MountPoint; VolumeStatus = [string]$_.VolumeStatus; ProtectionStatus = [string]$_.ProtectionStatus; EncryptionPercentage = $_.EncryptionPercentage }
        })
        $settings.BitLocker = $bitLocker
        Add-Result -Category 'Settings' -Item 'BitLocker status' -Status 'Success' -Details (($bitLocker | ForEach-Object { "$($_.MountPoint): $($_.ProtectionStatus), $($_.VolumeStatus)" }) -join '; ')
    }
    catch {
        $settings.BitLocker = @()
        Add-Result -Category 'Settings' -Item 'BitLocker status' -Status 'Skipped' -Details 'Could not query BitLocker on this device'
    }
    
    # Power Settings
    try {
        Write-Log "Capturing power settings..." -Level Info
        
        $powerScheme = powercfg /getactivescheme
        $settings.PowerScheme = $powerScheme
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
        # rather than just the small lid-close subset parsed below.  Windows
        # requires an elevated process to export or import a plan.
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

        if ($Script:IsAdmin) {
            if (Test-Path -LiteralPath $powerExport) {
                Remove-Item -LiteralPath $powerExport -Force -ErrorAction Stop
            }

            $powerExportResult = & powercfg /export $powerExport $schemeGuid 2>&1
            $powerExportExitCode = $LASTEXITCODE
            $settings.PowerSchemeExported = ((Test-Path -LiteralPath $powerExport) -and ((Get-Item -LiteralPath $powerExport).Length -gt 0) -and $powerExportExitCode -eq 0)
            $settings.PowerSchemeExportExitCode = $powerExportExitCode
            $settings.PowerSettingsMirror = "PowerScheme.pow"

            if ($settings.PowerSchemeExported) {
                Write-Log "Complete power scheme exported successfully" -Level Success
            } else {
                $exportMessage = ($powerExportResult | Out-String).Trim()
                throw "Power-scheme export failed (exit $powerExportExitCode). $exportMessage"
            }
        } else {
            $settings.PowerSchemeExported = $false
            $settings.PowerSchemeExportExitCode = $null
            Write-Log "Complete power-scheme export skipped because the export is not elevated; individual values will still be restored" -Level Info
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
        Add-Result -Category "Settings" -Item "Power Configuration" -Status $(if ($settings.PowerSettingValueCount -gt 0) { "Success" } else { "Warning" }) -Details "$($settings.PowerSettingValueCount) individual AC/DC values captured$(if ($settings.PowerSchemeExported) { '; full plan also exported' }); lid: AC=$($settings.LidClose.OnAC), DC=$($settings.LidClose.OnBattery); power mode overlays captured"
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
        
        # Mouse Cursor Settings
        $cursors = Get-ItemProperty -Path "HKCU:\Control Panel\Cursors" -ErrorAction SilentlyContinue
        if ($cursors) {
            $personalization.CursorScheme = $cursors.'(default)'
            $personalization.CursorBaseSize = $cursors.CursorBaseSize
            $personalization.CursorSettings = @{}
            $cursors.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                $personalization.CursorSettings[$_.Name] = $_.Value
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
            "HKCU\Software\Microsoft\Accessibility"
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
        
        Write-Log "Personalization settings captured (colors, taskbar, display scale, cursors, text size)" -Level Success
        Add-Result -Category "Settings" -Item "Personalization" -Status "Success" -Details "Colors, taskbar, display scale, cursors, text size, and visual effects captured"
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

