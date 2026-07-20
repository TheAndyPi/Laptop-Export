<#
.SYNOPSIS
    Builds the single-file laptop-transfer deployment script from src modules.

.DESCRIPTION
    Edit files in src\ during development, then run this script. The output is
    the self-contained Export-LaptopData.ps1 file used on technician devices.
    No module files are required beside the generated deployment artifact.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "Export-LaptopData.ps1")
)

$ErrorActionPreference = "Stop"
$sourceRoot = Join-Path $PSScriptRoot "src"
$moduleOrder = @(
    "01-bootstrap.ps1",
    "02-ui.ps1",
    "03-core.ps1",
    "04-destination.ps1",
    "05-user-data.ps1",
    "06-settings-printers.ps1",
    "07-browsers-onedrive.ps1",
    "08-import-template.ps1",
    "09-report.ps1",
    "10-main.ps1"
)

if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "Source directory not found: $sourceRoot"
}

$modulePaths = foreach ($module in $moduleOrder) {
    $path = Join-Path $sourceRoot $module
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required source module not found: $path"
    }
    $path
}

# Catch syntax errors before replacing the deployment artifact.
$sourceText = (($modulePaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "")
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($sourceText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object { "$($_.Message) at line $($_.Extent.StartLineNumber), column $($_.Extent.StartColumnNumber)" }
    throw "Build stopped because the combined source has PowerShell syntax errors:`n$($details -join "`n")"
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$preamble = @"
# ---------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT DIRECTLY
# Source modules: src\\01-bootstrap.ps1 through src\\10-main.ps1
# Build command: powershell -ExecutionPolicy Bypass -File .\\Build-Deployment.ps1
# ---------------------------------------------------------------------------

"@

$deploymentText = $preamble + $sourceText.TrimEnd("`r", "`n")
Set-Content -LiteralPath $OutputPath -Value $deploymentText -Encoding UTF8
Write-Host "Built single-file deployment script: $OutputPath" -ForegroundColor Green
