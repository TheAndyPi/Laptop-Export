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

