function Get-TransferReportTemplate {
    if ($Script:TransferReportTemplate) { return $Script:TransferReportTemplate }
    $templatePath = Join-Path $PSScriptRoot 'TransferReport.template.html'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Transfer report template is missing: $templatePath" }
    return Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
}

function New-TransferReport {
    param([string]$DestinationBase)

    $Script:Results.EndTime = Get-Date
    $duration = $Script:Results.EndTime - $Script:Results.StartTime
    $successCount = @($Script:Results.Actions | Where-Object { $_.Status -eq 'Success' }).Count
    $warningCount = @($Script:Results.Actions | Where-Object { $_.Status -eq 'Warning' }).Count
    $errorCount = @($Script:Results.Actions | Where-Object { $_.Status -eq 'Error' -or $_.Status -like 'NOT EXPORTED*' }).Count
    $skippedCount = @($Script:Results.Actions | Where-Object { $_.Status -eq 'Skipped' }).Count

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
        '{{ADMIN_BANNER}}' = $adminBanner; '{{ACTION_ROWS}}' = ($actionRows -join "`n"); '{{MANUAL_TASKS}}' = $manualTasks
        '{{APP_MIGRATION_SECTION}}' = '<div class="app-summary"><h3>Comparison pending</h3><p>Run the import on the new computer to identify applications that still need installation.</p></div>'
        '{{VERSION}}' = $Script:Config.Version; '{{YEAR}}' = (Get-Date -Format 'yyyy')
    }
    foreach ($token in $replacements.Keys) { $html = $html.Replace($token, [string]$replacements[$token]) }
    $reportPath = Join-Path $DestinationBase 'TransferReport.html'
    Set-Content -LiteralPath $reportPath -Value $html -Encoding UTF8
    Write-Log 'Transfer report generated' -Level Success
    return $reportPath
}
