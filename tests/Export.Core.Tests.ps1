. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'Destination safety' {
    It 'rejects the source profile and every child path' {
        Test-PathIsSameOrChild -Path 'C:\Users\Alex' -ParentPath 'C:\Users\Alex' | Should Be $true
        Test-PathIsSameOrChild -Path 'C:\Users\Alex\Desktop\Transfer' -ParentPath 'C:\Users\Alex' | Should Be $true
    }

    It 'does not reject a sibling profile with the same prefix' {
        Test-PathIsSameOrChild -Path 'C:\Users\Alexandra\Transfer' -ParentPath 'C:\Users\Alex' | Should Be $false
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
        $script:Config.Backup.UserData = $true
        $script:Config.Online.DownloadsCapGB = 0.001
        $script:Config.Online.OverrideDownloadsCap = $false
    }

    It 'excludes Downloads above the online cap unless explicitly overridden' {
        (Get-TransferPayloadEstimate).TotalBytes | Should Be 0
        $script:Config.Online.OverrideDownloadsCap = $true
        (Get-TransferPayloadEstimate).TotalBytes | Should BeGreaterThan 0
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

    It 'HTML-encodes untrusted result details in the report' {
        Add-Result -Category 'Test <Category>' -Item 'Test & Item' -Status 'Error' -Details '<script>alert(1)</script>'
        $reportPath = New-TransferReport -DestinationBase $script:Package
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $report | Should Match '>1<\/div>\s*<div class="label">Errors'
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
        @{ Shortcuts = @(@{ Name = 'Example.lnk'; Sha256 = 'synthetic'; Ordinal = 1 }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\DesktopLayout.json') -Encoding UTF8
        @{ Pins = @(@{ Name = 'Example.lnk'; TargetPath = 'C:\Missing\Example.exe'; Ordinal = 1 }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\TaskbarLayout.json') -Encoding UTF8
        @{ Associations = @(@{ Type = 'Protocol'; Name = 'https'; ProgId = 'SyntheticHTML' }) } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $script:Package 'Settings\DefaultApps.json') -Encoding UTF8
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
        Test-Path -LiteralPath $targetMarker | Should Be $false
        (Get-FileHash -LiteralPath $sourcePayload -Algorithm SHA256).Hash | Should Be $sourceHashBefore
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\AdminImportResult.json') | Should Be $true
        $comparisonPath = Join-Path $script:Package 'Logs\NetworkDriveComparison.txt'
        Test-Path -LiteralPath $comparisonPath | Should Be $true
        (Get-Content -LiteralPath $comparisonPath -Raw) | Should Match ([regex]::Escape('Z: \\test-server\transfer-share'))
        $output | Should Match 'OneDrive - Would enable'
        $output | Should Match 'Desktop layout - Would retain 1 transferred shortcut'
        $output | Should Match 'Taskbar layout - Would restore 1 source pin'
        Test-Path -LiteralPath (Join-Path $script:Package 'Logs\DefaultAppsRestoreGuide.txt') | Should Be $true
    }
}

Describe 'Layout and default-app implementation' {
    It 'ships all three independent toggles enabled by default' {
        $config = Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'src\00-development-config.psd1')
        $config.Backup.DesktopLayout | Should Be $true
        $config.Backup.TaskbarLayout | Should Be $true
        $config.Backup.DefaultApps | Should Be $true
    }

    It 'uses a hash-gated, shortcut-only OneDrive cleanup and avoids protected default-app writes' {
        $template = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\08-import-template.ps1') -Raw
        $template | Should Match "\.Extension -in @\('\.lnk', '\.url'\)"
        $template | Should Match 'Get-ShortcutHash \$cloudShortcut\.FullName'
        $template | Should Match 'SendToRecycleBin'
        $template | Should Match 'ms-settings:defaultapps'
        $template | Should Not Match 'Set-ItemProperty.+UserChoice'
    }

    It 'captures portable manifests rather than opaque Taskband registry data' {
        $settings = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\06-settings-printers.ps1') -Raw
        $settings | Should Match 'DesktopLayout\.json'
        $settings | Should Match 'TaskbarLayout\.json'
        $settings | Should Match 'DefaultApps\.json'
        $settings | Should Not Match 'Taskband\\Favorites'
    }
}

Describe 'Network drive and OneDrive implementation' {
    It 'writes an old-device mapped-drive snapshot and includes import comparison safeguards' {
        $settingsModule = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\06-settings-printers.ps1') -Raw
        $importTemplate = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'src\08-import-template.ps1') -Raw

        $settingsModule | Should Match 'MappedDrivesSnapshot\.json'
        $settingsModule | Should Match 'Sort-Object -Property Letter, Path -Unique'
        $importTemplate | Should Match 'function Write-NetworkDriveComparison'
        $importTemplate | Should Match 'NetworkDriveComparison\.txt'
        $importTemplate | Should Match 'function Enable-OneDriveAlwaysOnDevice'
        $importTemplate | Should Match 'attrib\.exe'
    }
}
