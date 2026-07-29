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
    }
}
