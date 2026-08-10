. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

Describe 'Deployment build' {
    It 'builds a self-contained script that parses successfully' {
        $output = Join-Path $TestDrive 'Export-LaptopData.ps1'
        & (Join-Path $script:RepoRoot 'Build-Deployment.ps1') -OutputPath $output

        Test-Path -LiteralPath $output -PathType Leaf | Should Be $true
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($output, [ref]$tokens, [ref]$errors)
        $errors.Count | Should Be 0
        (Get-Content -LiteralPath $output -Raw) | Should Match '\$Script:DevelopmentConfig\s*='
        (Get-Content -LiteralPath $output -Raw) | Should Match '\$Script:TransferReportTemplate\s*='
        (Get-Content -LiteralPath $output -Raw) | Should Match 'Start-LaptopExport'
    }

    It 'preserves UTF-8 glyphs when building under Windows PowerShell' {
        $output = Join-Path $TestDrive 'Export-LaptopData-utf8.ps1'
        & (Join-Path $script:RepoRoot 'Build-Deployment.ps1') -OutputPath $output
        $content = Get-Content -LiteralPath $output -Raw -Encoding UTF8
        $content.Contains(('STO ' + [char]0x00B7 + ' laptop handoff')) | Should Be $true
        $content.Contains(('STO ' + [char]0x00C2)) | Should Be $false
    }
}
