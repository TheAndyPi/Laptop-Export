. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'Destination safety' {
    It 'rejects the source profile and every child path' {
        Test-PathIsSameOrChild -Path 'C:\Users\Alex' -ParentPath 'C:\Users\Alex' | Should Be $true
        Test-PathIsSameOrChild -Path 'C:\Users\Alex\Desktop\Transfer' -ParentPath 'C:\Users\Alex' | Should Be $true
    }

    It 'does not reject a sibling profile with the same prefix' {
        Test-PathIsSameOrChild -Path 'C:\Users\Alexandra\Transfer' -ParentPath 'C:\Users\Alex' | Should Be $false
    }

    It 'allows only AppData and AppData\\Exports inside the source profile' {
        $script:OriginalUserProfile = 'C:\Users\Alex'
        Test-DestinationIsWithinSourceProfile -Path 'C:\Users\Alex\AppData' | Should Be $false
        Test-DestinationIsWithinSourceProfile -Path 'C:\Users\Alex\AppData\Exports\Transfer' | Should Be $false
        Test-DestinationIsWithinSourceProfile -Path 'C:\Users\Alex\AppData\Local\Transfer' | Should Be $true
        Test-DestinationIsWithinSourceProfile -Path 'C:\Users\Alex\Documents\Transfer' | Should Be $true
    }
}

Describe 'Online payload estimation' {
    BeforeEach {
        $script:OriginalUserProfile = Join-Path $TestDrive 'Profile'
        $script:OriginalAppDataRoaming = Join-Path $script:OriginalUserProfile 'AppData\Roaming'
        $script:OriginalAppDataLocal = Join-Path $script:OriginalUserProfile 'AppData\Local'
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalUserProfile 'Downloads') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:OriginalUserProfile 'Downloads\large.bin'), (New-Object byte[] (2MB)))
        $script:Config.TransferMode = 'Online'
        $script:Config.UserFolders = @('Downloads')
        foreach ($key in @($script:Config.Backup.Keys)) { $script:Config.Backup[$key] = $false }
        $script:Config.Backup.Downloads = $true
        $script:Config.Online.DownloadsCapGB = 0.001
    }

    It 'includes the independent Downloads toggle in the Online size estimate' {
        (Get-TransferPayloadEstimate).TotalBytes | Should BeGreaterThan 0
        $script:Config.Backup.Downloads = $false
        (Get-TransferPayloadEstimate).TotalBytes | Should Be 0
    }

    It 'shows Downloads independently in the completed display estimate' {
        $downloadsPath = Join-Path $script:OriginalUserProfile 'Downloads'
        $script:FolderInventoryCache = @{
            ($downloadsPath.TrimEnd([char]92)) = [PSCustomObject]@{ FileCount = 1; Bytes = 2048 }
        }
        $script:Config.Backup.UserData = $false
        $script:Config.Backup.Downloads = $true
        $estimate = Get-TransferSizeDisplayEstimate
        $estimate.ItemBytes.Downloads | Should Be 2048
        $estimate.TotalBytes | Should Be 2048
    }

    It 'refreshes a partial display estimate after a settings change' {
        $downloadsPath = Join-Path $script:OriginalUserProfile 'Downloads'
        $script:FolderInventoryCache = @{
            ($downloadsPath.TrimEnd([char]92)) = [PSCustomObject]@{ FileCount = 1; Bytes = 2048 }
        }
        $script:StartupPayloadEstimate = $null
        $script:TransferSizeDisplayEstimate = Get-TransferSizeDisplayEstimate

        $script:Config.Backup.Downloads = $false
        Update-AdvancedPayloadEstimate

        $script:TransferSizeDisplayEstimate.TotalBytes | Should Be 0
        $script:StartupPayloadEstimate | Should BeNullOrEmpty
    }

    It 'retains the Downloads-cap override as a runtime setting' {
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $userData = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\05-user-data.ps1') -Raw
        $core | Should Match 'OverrideDownloadsCap'
        $userData | Should Match 'OverrideDownloadsCap'
    }
}

Describe 'Online performance controls' {
    It 'ships lean browser and review defaults with opt-in advanced controls' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $config.Online.IncludeChromeProfileArchive | Should Be $false
        $config.Online.IncludeAdditionalUserFolders | Should Be $false
        $config.Online.IncludeOcsDocuments | Should Be $false
        $config.Online.DetailedAppDataCandidateInventory | Should Be $false
        $config.Online.AdditionalFolderCapGB | Should Be 1
    }

    It 'implements the advanced controls in the export paths' {
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $browser = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\07-browsers-onedrive.ps1') -Raw
        $userData = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\05-user-data.ps1') -Raw
        $main = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\10-main.ps1') -Raw
        $core | Should Match 'Show-OnlineAdvancedSettingsMenu'
        $browser | Should Match "Backup.Chrome -eq 'FullProfile'"
        $userData | Should Match 'IncludeAdditionalUserFolders'
        $userData | Should Match 'IncludeOcsDocuments'
        $main | Should Match 'Show-BackupOverview'
    }
}

Describe 'Chrome bookmark restoration' {
    It 'ships native bookmark stores for automatic Chrome restoration and retains HTML fallback files' {
        $browser = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\07-browsers-onedrive.ps1') -Raw
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $browser | Should Match 'Chrome\\ProfileBookmarks'
        $browser | Should Match 'available for automatic restore'
        $template | Should Match 'Chrome\\ProfileBookmarks'
        $template | Should Match 'Restore-ChromiumProfileBookmarks -BrowserName "Google Chrome"'
        $template | Should Match 'fallback HTML file\(s\) available'
    }
}

Describe 'Robocopy progress monitoring' {
    It 'uses a runspace-safe spinner instead of rescanning or async callbacks' {
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $core | Should Match 'Copying \$totalFiles files'
        $core | Should Not Match 'BeginOutputReadLine'
        $core | Should Not Match '\.add_OutputDataReceived'
        $core | Should Not Match 'Get-ChildItem \$Destination -Recurse -File'
        $template | Should Match 'Copying \$totalFiles files'
        $template | Should Not Match 'BeginOutputReadLine'
        $template | Should Not Match '\.add_OutputDataReceived'
        $template | Should Not Match 'Get-ChildItem \$Destination -Recurse -File'
    }
}

Describe 'Settings presets and additional AppData' {
    BeforeEach {
        Reset-LaptopExportResults
        $script:SelectedAdditionalAppData = @([PSCustomObject]@{ Area = 'Roaming'; RelativePath = 'OldSelection'; FullPath = 'C:\missing'; SizeBytes = 0 })
    }

    It 'Basic disables both advanced options and clears selected AppData' {
        Set-SettingsPreset -Name Basic
        $script:Config.Backup.EntireUserProfile | Should Be $false
        $script:Config.Backup.AdditionalAppData | Should Be $false
        $script:SelectedAdditionalAppData.Count | Should Be 0
        $script:SettingsPreset | Should Be 'Basic'
        $script:Config.Export.RequestAdministratorPrivileges | Should Be $false
    }

    It 'Advanced enables both advanced options' {
        Set-SettingsPreset -Name Advanced
        $script:Config.Backup.EntireUserProfile | Should Be $true
        $script:Config.Backup.AdditionalAppData | Should Be $true
        $script:SettingsPreset | Should Be 'Advanced'
        $script:Config.Export.RequestAdministratorPrivileges | Should Be $false
    }

    It 'keeps only non-curated Local and Roaming folders as selectable candidates' {
        $script:OriginalAppDataRoaming = Join-Path $TestDrive 'Roaming'
        $script:OriginalAppDataLocal = Join-Path $TestDrive 'Local'
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalAppDataRoaming 'UsefulRoaming') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalAppDataRoaming 'Microsoft') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalAppDataLocal 'UsefulLocal') -Force | Out-Null

        $candidates = @(Get-AdditionalAppDataCandidates)
        ($candidates.RelativePath -contains 'UsefulRoaming') | Should Be $true
        ($candidates.RelativePath -contains 'UsefulLocal') | Should Be $true
        ($candidates.RelativePath -contains 'Microsoft') | Should Be $false
    }

    It 'records a skipped result when a selected source folder disappears' {
        $script:SelectedAdditionalAppData = @([PSCustomObject]@{ Area = 'Local'; RelativePath = 'Gone'; FullPath = (Join-Path $TestDrive 'Gone'); SizeBytes = 0 })
        Copy-SelectedAdditionalAppData -DestinationBase $TestDrive
        ($script:Results.Actions | Where-Object { $_.Item -eq 'Local\Gone' }).Status | Should Be 'Skipped'
    }

    It 'includes full-profile and selected additional AppData sizes in the estimate' {
        $script:OriginalUserProfile = Join-Path $TestDrive 'Profile'
        $script:OriginalAppDataRoaming = Join-Path $script:OriginalUserProfile 'AppData\Roaming'
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalUserProfile 'Documents') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:OriginalUserProfile 'Extra') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:OriginalUserProfile 'Extra\profile.bin'), (New-Object byte[] 1024))
        $script:Config.UserFolders = @('Documents')
        foreach ($key in @($script:Config.Backup.Keys)) { $script:Config.Backup[$key] = $false }
        $script:Config.Backup.EntireUserProfile = $true
        $script:Config.Backup.AdditionalAppData = $true
        $script:SelectedAdditionalAppData = @([PSCustomObject]@{ Area = 'Local'; RelativePath = 'Selected'; FullPath = (Join-Path $TestDrive 'Selected'); SizeBytes = 2048 })

        $estimate = Get-TransferPayloadEstimate
        $estimate.ItemBytes.EntireUserProfile | Should BeGreaterThan 0
        $estimate.ItemBytes.AdditionalAppData | Should Be 2048
    }
}

Describe 'Startup presentation and size placeholders' {
    It 'shows the STO export title before mode selection and draws settings before sizes populate' {
        $main = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\10-main.ps1') -Raw
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $main | Should Match 'Write-StoLogo\s*\r?\n\s*Write-Banner -Title ''Laptop Transfer  -  Export Tool'''
        $destination = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\04-destination.ps1') -Raw
        $destination | Should Not Match 'function Select-TargetDrive \{\s*Write-StoLogo'
        $destination | Should Not Match 'function Select-TargetDestination \{\s*Write-StoLogo'
        $main | Should Match 'Show-BackupOverview'
        $core | Should Match 'calculating\.\.\.'
        $core | Should Match 'Start-TransferSizeEstimateJob'
        $core | Should Match 'Calculating folder sizes in the background'
        $core | Should Match '\$normalPaths \+ \$heavyPaths \+ \$userDataPaths'
        $core | Should Match '\$Script:StartupPayloadEstimate = Get-TransferSizeDisplayEstimate'
        $core | Should Not Match '\$Script:StartupPayloadEstimate = Get-TransferPayloadEstimate'
        $core | Should Match "default \{ @\{ Foreground = 'Cyan'; Background = 'DarkBlue' \} \}"
        $core | Should Match 'Receive-TransferSizeEstimateJob'
        $core | Should Match 'Get-TransferSizeDisplayEstimate'
        $core | Should Match 'Read-MenuInputWithBackgroundRefresh'
        $core | Should Match '__MENU_AUTO_REFRESH__'
        $core | Should Match 'Receive-Job -Job \$Script:TransferSizeEstimateJob'
    }
}

Describe 'Start Menu migration and transfer timing' {
    It 'copies the canonical per-user Start Menu and starts the clock after settings confirmation' {
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $userData = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\05-user-data.ps1') -Raw
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $main = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\10-main.ps1') -Raw
        $core | Should Match '"Start Menu"'
        $core | Should Match 'function Resolve-ExportUserFolderPath'
        $core | Should Match 'Microsoft\\Windows\\Start Menu'
        $core | Should Match 'TransferStartedAt'
        $userData | Should Match 'Resolve-ExportUserFolderPath \$folder'
        $template | Should Match '"Start Menu"'
        $template | Should Match "\$folder -eq 'Start Menu'"
        $main | Should Match 'Show-BackupOverview'
        $main | Should Match 'Transfer clock started after settings confirmation'
    }
}

Describe 'Advanced AppData size selection' {
    It 'draws the selection menu before background sizing so the technician can continue immediately' {
        $settings = Get-LaptopExportSourceText -Group Settings
        $destination = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\04-destination.ps1') -Raw
        $settings | Should Match 'Get-AdditionalAppDataCandidates -IncludeSizes \$false'
        $settings | Should Match 'Start-AdditionalAppDataSizeJob'
        $settings | Should Match 'Press R to refresh; the menu refreshes automatically when finished'
        $settings | Should Match 'Receive-AdditionalAppDataSizeJob'
        $settings | Should Match 'Read-MenuInputWithBackgroundRefresh'
        $settings | Should Match 'Receive-Job -Job \$Job'
    }
}

Describe 'Deferred administrator elevation' {
    It 'keeps export user-context capture separate from the scoped elevated helper and makes system capture opt-in' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\03-core.ps1') -Raw
        $main = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\10-main.ps1') -Raw
        $printers = Get-LaptopExportSourceText -Group Settings
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $config.Export.RequestAdministratorPrivileges | Should Be $false
        $config.Import.EnableAdminHelper | Should Be $true
        $core | Should Match 'ALPHA: UAC printer \+ power export'
        $core | Should Match 'OFF by default'
        $core | Should Match 'Do not relaunch the whole exporter'
        $main | Should Match 'Start-ElevatedSystemExport'
        $main | Should Match 'New-AdminImportScript -DestinationBase \$transferBase'
        $main | Should Match 'Import package verification'
        $printers | Should Match 'function Start-ElevatedSystemExport'
        $printers | Should Match 'PrintBRM and full power-plan capture'
        $printers | Should Match 'SystemExport\.json'
        $printers | Should Match 'Publish-Artifact'
        $printers | Should Match 'AdminExportResult\.json'
        $printers | Should Match 'Administrator export is recommended, optional'
        $printers | Should Match 'function Test-UacElevationCancelled'
        $printers | Should Match 'ERROR_CANCELLED \(1223\)'
        $printers | Should Match 'UAC elevation was cancelled\. The export will continue'
        $template | Should Match 'function Write-SystemExportProvenanceSummary'
        $template | Should Match 'captured with administrator rights'
        $template | Should Match 'Administrator printer and power restore is an Alpha feature'
        $template | Should Match 'Retry printers and power settings with administrator rights'
        $template | Should Match 'Retry printers only with administrator rights'
        $template | Should Match 'Retry power settings only with administrator rights'
        $template | Should Match 'function Invoke-StandardSystemRestoreFallback'
        $template | Should Match 'function Test-AdminHelperElevationCancelled'
        $template | Should Match 'Administrator \$scopeLabel import was requested, but UAC elevation was cancelled\. The import will continue'
        $template | Should Match 'Add-Result -Category ''System Restore'' -Item "Elevated \$scopeLabel" -Status ''Error'''
        $template | Should Match 'AllowStandardUser'
        $template | Should Match "ValidateSet\('Both', 'Printers', 'Power'\)"
        $template | Should Match 'power settings remain deferred'
    }

    It 'writes independent, durable provenance for standard and elevated artifact attempts' {
        Reset-LaptopExportResults
        $script:IsAdmin = $false
        $script:Config.Export.RequestAdministratorPrivileges = $false
        $package = Join-Path $TestDrive 'ProvenancePackage'
        New-Item -ItemType Directory -Path $package -Force | Out-Null

        Set-SystemExportProvenance -DestinationBase $package -Artifact Power -Attempted $true -CapturedWithAdministratorRights $false -Status Succeeded -Detail 'Standard-user power export succeeded.'
        Set-SystemExportProvenance -DestinationBase $package -Artifact PrintBrm -Attempted $true -CapturedWithAdministratorRights $true -Status Succeeded -Detail 'Elevated PrintBRM export succeeded.'

        $provenancePath = Join-Path $package 'Settings\SystemExport.json'
        Test-Path -LiteralPath $provenancePath | Should Be $true
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
        $provenance.Power.Status | Should Be 'Succeeded'
        $provenance.Power.CapturedWithAdministratorRights | Should Be $false
        $provenance.PrintBrm.Status | Should Be 'Succeeded'
        $provenance.PrintBrm.CapturedWithAdministratorRights | Should Be $true
    }

    It 'recognizes a cancelled requested UAC elevation for non-terminating error reporting' {
        Test-UacElevationCancelled -Exception ([System.Exception]::new('The operation was canceled by the user.')) | Should Be $true
        Test-UacElevationCancelled -Exception ([System.Exception]::new('PrintBRM helper exited with code 1.')) | Should Be $false
    }
}

Describe 'Windows Settings power mode' {
    It 'captures and restores the Power & battery Power mode through PowrProf' {
        $settings = Get-LaptopExportSourceText -Group Settings
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $settings | Should Match 'function Get-WindowsPowerMode'
        $settings | Should Match 'PowerGetActualOverlayScheme'
        $settings | Should Match 'RequestedOverlayGuid'
        $template | Should Match 'PowerSetActiveOverlayScheme\(Guid overlaySchemeGuid\)'
        $template | Should Match 'PowerGetEffectiveOverlayScheme'
        $template | Should Match 'Windows power mode'
    }
}

Describe 'Archive cancellation' {
    BeforeEach {
        Reset-LaptopExportResults
        $script:Config.TransferMode = 'Online'
        $package = Join-Path $TestDrive 'LaptopTransfer_Test'
        New-Item -ItemType Directory -Path $package -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $package 'payload.bin'), (New-Object byte[] 2048))
        $script:TestPackage = $package
        Mock Test-ArchiveAbortRequested { $true }
    }

    It 'removes an incomplete archive and retains the transfer folder' {
        New-TransferArchive -TransferBase $script:TestPackage | Should Be $null
        Test-Path -LiteralPath $script:TestPackage -PathType Container | Should Be $true
        Test-Path -LiteralPath "$($script:TestPackage).zip" | Should Be $false
        ($script:Results.Actions | Where-Object { $_.Item -eq 'LaptopTransfer_Test.zip' }).Status | Should Be 'Skipped'
    }
}

Describe 'Local archive creation' {
    BeforeEach {
        Reset-LaptopExportResults
        $script:Config.TransferMode = 'Local'
        $script:TestPackage = Join-Path $TestDrive 'LaptopTransfer_LocalZip'
        New-Item -ItemType Directory -Path $script:TestPackage -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:TestPackage 'payload.bin'), (New-Object byte[] 512))
        Mock Test-ArchiveAbortRequested { $false }
    }

    It 'creates a ZIP when Local archive creation is enabled' {
        $archive = New-TransferArchive -TransferBase $script:TestPackage
        Test-Path -LiteralPath $archive -PathType Leaf | Should Be $true
        ($script:Results.Actions | Where-Object { $_.Item -eq 'LaptopTransfer_LocalZip.zip' }).Status | Should Be 'Success'
    }
}

Describe 'Generated package artifacts' {
    BeforeEach {
        Reset-LaptopExportResults
        $script:IsAdmin = $false
        $script:Config.TransferMode = 'Local'
        $script:Package = Join-Path $TestDrive 'Package'
        New-Item -ItemType Directory -Path $script:Package -Force | Out-Null
    }

    It 'generates an import script that parses successfully' {
        New-ImportScript -DestinationBase $script:Package -Settings @{}
        $importPath = Join-Path $script:Package 'Import-LaptopData.ps1'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($importPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }

    It 'generates an administrator import helper that parses successfully' {
        New-AdminImportScript -DestinationBase $script:Package
        $helperPath = Join-Path $script:Package 'Import-SystemSettings.ps1'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }

    It 'always creates the administrator helper, including settings-free packages' {
        $originalSystemSettings = $script:Config.Backup.SystemSettings
        $originalPrinters = $script:Config.Backup.Printers
        try {
            $script:Config.Backup.SystemSettings = $false
            $script:Config.Backup.Printers = $false
            New-AdminImportScript -DestinationBase $script:Package
            Test-Path -LiteralPath (Join-Path $script:Package 'Import-SystemSettings.ps1') -PathType Leaf | Should Be $true
        }
        finally {
            $script:Config.Backup.SystemSettings = $originalSystemSettings
            $script:Config.Backup.Printers = $originalPrinters
        }
    }

    It 'keeps the generated export helper syntactically valid after placeholder replacement' {
        $printerSource = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\06-printers.ps1') -Raw
        $startToken = "`$helperScript = @'"
        $start = $printerSource.IndexOf($startToken, [StringComparison]::Ordinal)
        $start | Should BeGreaterThan -1
        $helperStart = $start + $startToken.Length
        if ($printerSource.Substring($helperStart, 2) -eq "`r`n") { $helperStart += 2 } elseif ($printerSource[$helperStart] -eq "`n") { $helperStart++ }
        $end = $printerSource.IndexOf("'@", $helperStart, [StringComparison]::Ordinal)
        $end | Should BeGreaterThan $helperStart
        $helperText = $printerSource.Substring($helperStart, $end - $helperStart) -replace '\{INCLUDE_DRIVERS\}', 'true'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($helperText, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
    }

    It 'HTML-encodes untrusted result details in the report' {
        Add-Result -Category 'Test' -Item 'Completed first' -Status 'Success' -Details 'Completed'
        Add-Result -Category 'Test' -Item 'Skipped second' -Status 'Skipped' -Details 'Needs review'
        Add-Result -Category 'Test <Category>' -Item 'Test & Item' -Status 'Error' -Details '<script>alert(1)</script>'
        [void]$script:Results.RuntimeAlerts.Add([PSCustomObject]@{ Timestamp = '10:34:30'; Level = 'Warning'; Message = 'Plaintext <CSV> excluded from ZIP' })
        $reportPath = New-TransferReport -DestinationBase $script:Package
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $report | Should Match '>1<\/div>\s*<div class="label">Errors'
        $report.IndexOf('Test &lt;Category&gt;') | Should BeLessThan $report.IndexOf('Completed first')
        $report | Should Match 'Pending import on new computer'
        $report | Should Match 'Console warnings and errors'
        $report | Should Match 'Plaintext &lt;CSV&gt; excluded from ZIP'
        $reportBytes = [System.IO.File]::ReadAllBytes($reportPath)
        @($reportBytes[0..2]) | Should Be @(0xEF, 0xBB, 0xBF)
    }

    It 'uses the same status classification for terminal and HTML summaries' {
        Add-Result -Category 'Test' -Item 'Empty payload' -Status 'Empty'
        Add-Result -Category 'Test' -Item 'Elevation' -Status 'Admin Required'
        $counts = Get-TransferResultCounts
        $counts.Skipped | Should Be 1
        $counts.Errors | Should Be 1
        $report = Get-Content -LiteralPath (New-TransferReport -DestinationBase $script:Package) -Raw
        $report | Should Match '>1<\/div>\s*<div class="label">Errors'
        $report | Should Match '>1<\/div>\s*<div class="label">Skipped'
    }

    It 'loads the standalone report template during development' {
        $template = Join-Path $script:RepoRoot 'src\TransferReport.template.html'
        Test-Path -LiteralPath $template -PathType Leaf | Should Be $true
        (Get-Content -LiteralPath $template -Raw) | Should Match '{{ACTION_ROWS}}'
        (Get-Content -LiteralPath $template -Raw) | Should Match '<details class="section">'
        (Get-Content -LiteralPath $template -Raw) | Should Match '{{APP_MIGRATION_SECTION}}'
        (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\09-report.ps1') -Raw) | Should Match 'Get-TransferReportTemplate'
    }

    It 'keeps import report counts and attention rows on the same importer ledger' {
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $reportTemplate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\TransferReport.template.html') -Raw
        $template | Should Match 'function Get-ImportResultCounts'
        $template | Should Match 'function Get-ImportAttentionActions'
        $template | Should Match "-Marker 'TRANSFER_SUMMARY'"
        $template | Should Match 'Post-transfer items needing attention'
        $template | Should Match '\$attention = Get-ImportAttentionActions'
        $reportTemplate | Should Match '<!-- TRANSFER_SUMMARY -->'
    }
}

Describe 'Generated importer TestMode' {
    BeforeEach {
        Reset-LaptopExportResults
        $script:Config.TransferMode = 'Local'
        $script:Package = Join-Path $TestDrive 'ImportTestPackage'
        $script:MarkerName = "__LaptopExport_Pester_$([guid]::NewGuid().ToString('N')).txt"
        New-Item -ItemType Directory -Path (Join-Path $script:Package 'UserData\Documents') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Package "UserData\Documents\$script:MarkerName") -Value 'Synthetic test payload' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:Package 'Logs') -Force | Out-Null
        New-ImportScript -DestinationBase $script:Package -Settings @{}
        New-Item -ItemType Directory -Path (Join-Path $script:Package 'Settings') -Force | Out-Null
        @{ MappedDrives = @(@{ Letter = 'Z'; Path = '\\test-server\transfer-share' }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\SystemSettings.json') -Encoding UTF8
        @{
            SchemaVersion = 1
            Power = @{ Attempted = $true; CapturedWithAdministratorRights = $false; Status = 'Succeeded'; Detail = 'Standard-user power export succeeded.' }
            PrintBrm = @{ Attempted = $true; CapturedWithAdministratorRights = $true; Status = 'Succeeded'; Detail = 'Elevated PrintBRM export succeeded.' }
        } |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\SystemExport.json') -Encoding UTF8
        @{ Pins = @(@{ Name = 'Example.lnk'; TargetPath = 'C:\Missing\Example.exe'; Ordinal = 1 }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\TaskbarLayout.json') -Encoding UTF8
        @{ Associations = @(@{ Type = 'Protocol'; Name = 'https'; ProgId = 'SyntheticHTML' }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\DefaultApps.json') -Encoding UTF8
        @(
            @{ DisplayName = 'Synthetic Required App'; DisplayVersion = '1.0'; Publisher = 'Test Publisher'; MatchKey = 'synthetic required app|test publisher' },
            @{ DisplayName = 'Synthetic Required App Two'; DisplayVersion = '2.0'; Publisher = 'Test Publisher'; MatchKey = 'synthetic required app two|test publisher' }
        ) |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\InstalledPrograms.json') -Encoding UTF8
        @(@{ Area = 'Roaming'; RelativePath = 'SyntheticApp'; SizeBytes = 123; CoveredByCuratedBackup = $false; AssociationHint = 'syntheticapp' }) |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\AppDataCandidates.json') -Encoding UTF8
    }

    It 'runs non-interactively without restoring synthetic package data' {
        $importPath = Join-Path $script:Package 'Import-LaptopData.ps1'
        $targetMarker = Join-Path $env:USERPROFILE "Documents\$script:MarkerName"
        $sourcePayload = Join-Path $script:Package "UserData\Documents\$script:MarkerName"
        $sourceHashBefore = (Get-FileHash -LiteralPath $sourcePayload -Algorithm SHA256).Hash

        Test-Path -LiteralPath $targetMarker | Should Be $false
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $importPath -TestMode 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'TEST MODE - No changes will be made'
        $output | Should Match 'Full power plan: captured without administrator rights'
        $output | Should Match 'PrintBRM printer package: captured with administrator rights'
        $output | Should Match 'Administrator printer and power restore is an Alpha feature'
        Test-Path -LiteralPath $targetMarker | Should Be $false
        (Get-FileHash -LiteralPath $sourcePayload -Algorithm SHA256).Hash | Should Be $sourceHashBefore
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\AdminImportResult.json') | Should Be $true
        $comparisonPath = Join-Path $script:Package 'Logs\NetworkDriveComparison.txt'
        Test-Path -LiteralPath $comparisonPath | Should Be $true
        (Get-Content -LiteralPath $comparisonPath -Raw) | Should Match ([regex]::Escape('Z: \\test-server\transfer-share'))
        $output | Should Match 'OneDrive - Would enable'
        $output | Should Match 'Taskbar layout - Would replace destination pins with 1 source pin'
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\DefaultAppsRestoreGuide.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\AppMigrationComparison.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\AppMigrationReview.html') | Should Be $true
        $appComparison = Get-Content -LiteralPath (Join-Path $script:Package 'Logs\AppMigrationComparison.json') -Raw | ConvertFrom-Json
        @($appComparison.Missing | Where-Object { $_.DisplayName -like 'Synthetic Required App*' }).Count | Should Be 2
    }
}

Describe 'Taskbar and default-app implementation' {
    It 'ships both independent toggles enabled by default' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $config.Backup.TaskbarLayout | Should Be $true
        $config.Backup.DefaultApps | Should Be $true
    }

    It 'avoids protected default-app writes' {
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $template | Should Match 'ms-settings:defaultapps'
        $template | Should Not Match 'Set-ItemProperty.+UserChoice'
    }

    It 'captures and restores source taskbar order while always excluding Microsoft Store' {
        $settings = Get-LaptopExportSourceText -Group Settings
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $settings | Should Match 'TaskbarLayout\.json'
        $settings | Should Match 'DefaultApps\.json'
        $settings | Should Match 'Taskband'
        $template | Should Match 'Remove-MicrosoftStoreTaskbarPin'
        $template | Should Match 'Remove-NonSourceTaskbarPins'
        $template | Should Match 'Test-SourceTaskbarPin'
        $template | Should Match 'destination pin\(s\) removed'
        $template | Should Match 'TaskbandValues'
        $template | Should Match 'Source app unavailable on destination'
        $template | Should Match 'Pin was reintroduced after removal'
    }
}

Describe 'Application migration review implementation' {
    It 'ships app comparison and AppData review toggles enabled by default' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $config.Backup.AppDataCandidateInventory | Should Be $true
        $config.Import.AppComparison | Should Be $true
        $config.Import.AppDataReview | Should Be $true
    }

    It 'generates the app review implementation with safe source artifacts and TestMode support' {
        $settings = Get-LaptopExportSourceText -Group Settings
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $settings | Should Match 'AppDataCandidates\.json'
        $settings | Should Match 'Get-ProgramMatchKey'
        $template | Should Match 'AppMigrationComparison\.json'
        $template | Should Match 'AppMigrationReview\.html'
        $template | Should Match 'Update-TransferReportFromImport'
        $template | Should Match 'Update-TransferReportFromImport -State Unavailable'
        $template | Should Match 'Application comparison unavailable'
        $template | Should Match 'Test-UserFacingProgram'
        $template | Should Match 'AppComparisonExcludePatterns'
        $template | Should Match '\$publisher -match \$individualPattern'
        $template | Should Match 'Please confirm which apps you would like to install on the new device\.'
        $template | Should Match 'Windows-related AppData folders are excluded from this review'
        $template | Should Match 'FilteredAppDataCandidates'
        $template | Should Match '& \$encode \(\[string\]\$_\.DisplayName\)'
        $template | Should Match 'DESTINATION_COMPUTER'
        $template | Should Match 'IMPORT_APP_COMPARISON'
        $template | Should Match 'AppDataCandidates = @\(\)'
        $template | Should Match 'AppData migration review'
        $template | Should Not Match "Start-Process \(Join-Path \$logsPath 'AppMigrationReview\\.html'\)"
    }

    It 'excludes managed application families from the post-transfer apps list' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $patterns = $config.Import.AppComparisonExcludePatterns -join "`n"
        $patterns | Should Match '\\bAdobe\\b'
        $patterns | Should Match '\\bClickShare\\b'
        $patterns | Should Match '\\bLenovo\\b'
        $patterns | Should Match '\\bMicrosoft\\b'
        $patterns | Should Match '\\bWindows\\b'
        $template | Should Match '\\b\(\?:Adobe\|ClickShare\|Lenovo\|Microsoft\|Windows\)\\b'
        $template | Should Match 'app\(s\) need installation'
        $template | Should Match 'Please confirm which apps you would like to install on the new device\.'
    }
}

Describe 'Power replication implementation' {
    It 'captures overlay power mode and attempts lid restore without automatic elevation' {
        $settings = Get-LaptopExportSourceText -Group Settings
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $settings | Should Match 'ActiveOverlayAcPowerScheme'
        $settings | Should Match 'ActiveOverlayDcPowerScheme'
        $template | Should Match 'PowerSetActiveOverlayScheme'
        $template | Should Match 'function Set-ImportedPowerOverlay'
        $template | Should Match "Item 'Lid actions'"
        $template | Should Match 'LidClose -and \$settingsData\.LidClose\.OnAC'
        $template | Should Match 'Individual failures are summarized below'
        $template | Should Match 'settings rejected or unsupported'
        $template | Should Match 'Update-TransferReportImportOutcomes'
    }
}

Describe 'Post-import handoff launcher' {
    It 'keeps the report-first launcher and handoff apps configurable' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $template = Get-LaptopExportSourceText -Group ImportTemplate
        $config.Import.PostImportLaunch.Enabled | Should Be $true
        ($config.Import.PostImportLaunch.Targets.Name -contains 'Classic Outlook') | Should Be $true
        ($config.Import.PostImportLaunch.Targets.Name -contains 'Microsoft Teams') | Should Be $true
        ($config.Import.PostImportLaunch.Targets.Name -contains 'Freshservice') | Should Be $true
        $template | Should Match 'function Start-PostImportHandoff'
        $template | Should Match 'Open the standard handoff applications too'
        $template | Should Match 'POST_IMPORT_LAUNCH_CONFIG_BASE64'
        ($config.Import.PostImportLaunch.Targets[0].Alternatives.Name -contains 'Adobe Acrobat') | Should Be $true
        ($config.Import.PostImportLaunch.Targets[0].Alternatives.Name -contains 'Bluebeam Revu') | Should Be $true
    }
}

Describe 'Network drive and OneDrive implementation' {
    It 'writes an old-device mapped-drive snapshot and includes import comparison safeguards' {
        $settingsModule = Get-LaptopExportSourceText -Group Settings
        $importTemplate = Get-LaptopExportSourceText -Group ImportTemplate

        $settingsModule | Should Match 'MappedDrivesSnapshot\.json'
        $settingsModule | Should Match 'Sort-Object -Property Letter, Path -Unique'
        $importTemplate | Should Match 'function Write-NetworkDriveComparison'
        $importTemplate | Should Match 'NetworkDriveComparison\.txt'
        $importTemplate | Should Match 'function Enable-OneDriveAlwaysOnDevice'
        $importTemplate | Should Match 'attrib\.exe'
    }
}
