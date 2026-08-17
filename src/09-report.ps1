# Report generation is deliberately last-mile: it reads the structured result
# ledger and substitutes escaped values into a static HTML template.  It does
# not infer success from console text or filesystem guesses.

function Get-TransferReportTemplate {
    # Cache the template after the first read because report generation may be
    # retried and the template is immutable for the lifetime of this process.
    if ($Script:TransferReportTemplate) { return $Script:TransferReportTemplate }
    $templatePath = Join-Path $PSScriptRoot 'TransferReport.template.html'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Transfer report template is missing: $templatePath" }
    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function New-TransferReport {
    # Freeze timing, classify actions, render manual handoff tasks, and write a
    # self-contained report.  HTML encoding is applied at every dynamic field
    # boundary so paths and user-controlled names cannot alter the markup.
    param([string]$DestinationBase)

    $Script:Results.EndTime = Get-Date
    $duration = $Script:Results.EndTime - $Script:Results.StartTime
    $resultCounts = Get-TransferResultCounts
    $successCount = $resultCounts.Success
    $warningCount = $resultCounts.Warning
    $errorCount = $resultCounts.Errors
    $skippedCount = $resultCounts.Skipped

    # Keep the handoff blockers visible: an otherwise successful item must not
    # bury a skipped, manual, warning, or failed action lower in the report.
    $actionPriority = {
        param($Action)
        switch -Regex ([string]$Action.Status) {
            'Error|NOT EXPORTED|Admin Required' { return 0 }
            'Warning' { return 1 }
            'Skipped|Manual|Pending' { return 2 }
            'Success' { return 4 }
            default { return 3 }
        }
    }
    $orderedActions = @($Script:Results.Actions | Sort-Object @{ Expression = { & $actionPriority $_ } }, @{ Expression = { $_.Timestamp } })
    $actionRows = foreach ($action in $orderedActions) {
        $statusClass = switch -Regex ($action.Status) {
            'Success' { 'status-success'; break }; 'Warning' { 'status-warning'; break }
            'Error|NOT EXPORTED|Admin Required' { 'status-error'; break }; 'Skipped' { 'status-skipped'; break }
            default { 'status-warning' }
        }
        "<tr><td>$(Out-HtmlEncoded $action.Category)</td><td>$(Out-HtmlEncoded $action.Item)</td><td><span class='status $statusClass'>$(Out-HtmlEncoded $action.Status)</span></td><td>$(Out-HtmlEncoded $action.Details)</td></tr>"
    }
    if (-not $actionRows) { $actionRows = '<tr><td colspan="4">No export actions were recorded.</td></tr>' }

    # Warnings emitted to the console are frequently contextual rather than a
    # single copy-stage result. Preserve them in the handoff report even when
    # the originating code did not also call Add-Result.
    $runtimeAlerts = @($Script:Results.RuntimeAlerts | Where-Object { $_.Level -in @('Warning', 'Error') })
    $runtimeAlertSection = if ($runtimeAlerts.Count) {
        $alertRows = foreach ($alert in $runtimeAlerts) {
            $class = if ($alert.Level -eq 'Error') { 'status-error' } else { 'status-warning' }
            "<tr><td>$(Out-HtmlEncoded $alert.Timestamp)</td><td><span class='status $class'>$(Out-HtmlEncoded $alert.Level)</span></td><td>$(Out-HtmlEncoded $alert.Message)</td></tr>"
        }
        "<details class='section' open><summary>Console warnings and errors<span>$($runtimeAlerts.Count) message(s), including warnings without an export-action row</span></summary><div class='section-content'><table><thead><tr><th>Time</th><th>Level</th><th>Message</th></tr></thead><tbody>$($alertRows -join "`n")</tbody></table></div></details>"
    }
    else { '' }

    $adminTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match 'admin|Administrator|privileges' })
    $adminBanner = ''
    if (-not $Script:IsAdmin -and $adminTasks.Count) {
        $adminRows = foreach ($task in $adminTasks) {
            "<div class='manual-task critical'><h4>$(Out-HtmlEncoded $task.Task)</h4><p><strong>Why not captured:</strong> $(Out-HtmlEncoded $task.Reason)</p><pre>$(Out-HtmlEncoded $task.Instructions)</pre></div>"
        }
        $adminBanner = "<section class='critical-warning'><h2>INCOMPLETE EXPORT - ADMIN RIGHTS REQUIRED</h2><p>$($adminTasks.Count) item(s) require manual capture before wiping the old laptop.</p></section><section class='section'><div class='section-header'>Not captured - manual action required</div><div class='section-content'>$($adminRows -join "`n")</div></section>"
    }
    elseif ($Script:IsAdmin) { $adminBanner = "<section class='admin-success'>Full export completed with administrator rights.</section>" }

    $otherTasks = if ($Script:IsAdmin) { @($Script:Results.ManualTasks) } else { @($Script:Results.ManualTasks | Where-Object { $_.Reason -notmatch 'admin|Administrator|privileges' }) }
    $manualTasks = if ($otherTasks.Count) {
        ($otherTasks | ForEach-Object { "<div class='manual-task'><h4>$(Out-HtmlEncoded $_.Task)</h4><p>$(Out-HtmlEncoded $_.Reason)</p><pre>$(Out-HtmlEncoded $_.Instructions)</pre></div>" }) -join "`n"
    } else { '<p class="success-text">No additional manual tasks required.</p>' }

    $html = Get-TransferReportTemplate
    $replacements = @{
        '{{USER}}' = Out-HtmlEncoded $Script:Results.UserName; '{{COMPUTER}}' = Out-HtmlEncoded $Script:Results.ComputerName
        '{{SOURCE_COMPUTER}}' = Out-HtmlEncoded $Script:Results.ComputerName; '{{DESTINATION_COMPUTER}}' = 'Pending import on new computer'
        '{{MODE}}' = Out-HtmlEncoded $Script:Config.TransferMode; '{{DATE}}' = (Get-Date -Format "MMMM dd, yyyy 'at' h:mm tt")
        '{{DURATION}}' = "$([math]::Round($duration.TotalMinutes, 1)) minutes"; '{{SUCCESS_COUNT}}' = $successCount
        '{{WARNING_COUNT}}' = $warningCount; '{{ERROR_COUNT}}' = $errorCount; '{{SKIPPED_COUNT}}' = $skippedCount
        '{{ADMIN_BANNER}}' = $adminBanner; '{{ACTION_ROWS}}' = ($actionRows -join "`n"); '{{RUNTIME_ALERTS}}' = $runtimeAlertSection; '{{MANUAL_TASKS}}' = $manualTasks
        '{{APP_MIGRATION_SECTION}}' = '<div class="app-summary"><h3>Comparison pending</h3><p>Run the import on the new computer to identify applications that still need installation.</p></div>'
        '{{VERSION}}' = $Script:Config.Version; '{{YEAR}}' = (Get-Date -Format 'yyyy')
    }
    foreach ($token in $replacements.Keys) { $html = $html.Replace($token, [string]$replacements[$token]) }
    $reportPath = Join-Path $DestinationBase 'TransferReport.html'
    # Use an explicit UTF-8 BOM. Windows PowerShell and PowerShell 7 otherwise
    # differ here, and some file associations decode a BOM-less local report as
    # the ANSI code page (shown as "Â·" / "âˆ’" in the supplied report).
    [System.IO.File]::WriteAllText($reportPath, $html, [System.Text.UTF8Encoding]::new($true))
    Write-Log 'Transfer report generated' -Level Success
    return $reportPath
}
