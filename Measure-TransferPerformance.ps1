<#
.SYNOPSIS
    Benchmarks the former and current local transfer paths on a browser-like workload.

.DESCRIPTION
    Creates a dedicated, disposable C: test folder with many small files, then
    measures the former robocopy settings and recursive progress scan against
    the current parallel-copy, zero-rescan implementation. All test data is
    removed when the run completes; the CSV result is retained beside this script.
#>

[CmdletBinding()]
param(
    [int]$FileCount = 12000,
    [int]$FileSizeKB = 32,
    [string]$TestRoot = 'C:\LaptopTransferPerformanceTest'
)

$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $PSScriptRoot 'transfer-performance-results.csv'

if (Test-Path -LiteralPath $TestRoot) {
    throw "Test root already exists: $TestRoot. Remove or rename it before benchmarking."
}

function Invoke-RobocopyBenchmark {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Destination,
        [string[]]$Arguments,
        [switch]$RescanDestination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = 'robocopy.exe'
    $pinfo.Arguments = "`"$Source`" `"$Destination`" $($Arguments -join ' ')"
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $pinfo
    $started = Get-Date
    $scanMilliseconds = 0L
    $scanCount = 0
    if (-not $process.Start()) { throw "Could not start robocopy for $Name." }

    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 750
        if ($RescanDestination) {
            $scanStarted = [System.Diagnostics.Stopwatch]::StartNew()
            # This is the former progress implementation's expensive action.
            [void](Get-ChildItem -LiteralPath $Destination -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum)
            $scanStarted.Stop()
            $scanMilliseconds += $scanStarted.ElapsedMilliseconds
            $scanCount++
        }
    }
    $elapsed = (Get-Date) - $started
    if ($process.ExitCode -ge 8) { throw "$Name robocopy failed with exit code $($process.ExitCode)." }

    [PSCustomObject]@{
        Approach = $Name
        DurationSeconds = [math]::Round($elapsed.TotalSeconds, 3)
        ProgressScanCount = $scanCount
        ProgressScanSeconds = [math]::Round($scanMilliseconds / 1000, 3)
        ExitCode = $process.ExitCode
    }
}

try {
    $source = Join-Path $TestRoot 'source'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    $payload = New-Object byte[] ($FileSizeKB * 1KB)
    [System.Random]::new(42).NextBytes($payload)
    Write-Host "Creating $FileCount browser-like files ($FileSizeKB KB each) on C:..." -ForegroundColor Cyan
    for ($index = 0; $index -lt $FileCount; $index++) {
        $bucket = Join-Path $source ('Profile_{0:D2}\Cache_{1:D3}' -f ($index % 8), ($index % 128))
        if (-not (Test-Path -LiteralPath $bucket)) { New-Item -ItemType Directory -Path $bucket -Force | Out-Null }
        [System.IO.File]::WriteAllBytes((Join-Path $bucket ('entry_{0:D5}.bin' -f $index)), $payload)
    }

    $oldArgs = @('/E', '/Z', '/R:2', '/W:3', '/MT:8', '/NP', '/NDL', '/NFL', '/NJH', '/NJS')
    $newArgs = @('/E', '/R:2', '/W:3', '/MT:16', '/NP', '/NDL', '/NFL', '/NJH', '/NJS')
    $results = @(
        Invoke-RobocopyBenchmark -Name 'Old: /Z /MT:8 + recursive progress scans' -Source $source -Destination (Join-Path $TestRoot 'old-destination') -Arguments $oldArgs -RescanDestination
        Invoke-RobocopyBenchmark -Name 'New: /MT:16 + zero-I/O progress monitor' -Source $source -Destination (Join-Path $TestRoot 'new-destination') -Arguments $newArgs
    )
    $results | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding UTF8
    $oldSeconds = $results[0].DurationSeconds
    $newSeconds = $results[1].DurationSeconds
    $improvement = if ($oldSeconds -gt 0) { [math]::Round((($oldSeconds - $newSeconds) / $oldSeconds) * 100, 1) } else { 0 }
    $results | Format-Table -AutoSize
    Write-Host "New approach completed $improvement% faster. Results: $resultPath" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
