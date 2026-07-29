<#
.SYNOPSIS
    Runs the non-destructive regression suite for Laptop Export.

.DESCRIPTION
    Tests build output in a temporary folder and exercises only synthetic
    package data. It never invokes Start-LaptopExport. The generated importer
    is run only with -TestMode in a separate non-interactive process.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$testsPath = Join-Path $repoRoot 'tests'

if (-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)) {
    throw 'Pester is required to run the test suite. Install it with: Install-Module Pester -Scope CurrentUser'
}

if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
    throw "Test directory not found: $testsPath"
}

$result = Invoke-Pester -Script $testsPath -PassThru
if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) test(s) failed."
}

Write-Host "All $($result.PassedCount) Laptop Export tests passed." -ForegroundColor Green
