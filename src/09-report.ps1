function New-TransferReport {
    param(
        [string]$DestinationBase
    )
    
    $Script:Results.EndTime = Get-Date
    $duration = $Script:Results.EndTime - $Script:Results.StartTime
    
    $successCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Success" }).Count
    $warningCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Warning" }).Count
    $errorCount = @($Script:Results.Actions | Where-Object {
        $_.Status -eq "Error" -or $_.Status -like "NOT EXPORTED*"
    }).Count
    $skippedCount = ($Script:Results.Actions | Where-Object { $_.Status -eq "Skipped" }).Count
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Laptop Transfer Report - $($Script:Results.UserName)</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { 
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #e0e0e0;
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1000px; margin: 0 auto; }
        
        header {
            background: linear-gradient(135deg, #0f3460 0%, #16213e 100%);
            border-radius: 16px;
            padding: 30px;
            margin-bottom: 20px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
            border: 1px solid #0f3460;
        }
        header h1 { 
            font-size: 28px; 
            margin-bottom: 10px;
            background: linear-gradient(90deg, #00d4ff, #7c3aed);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .meta { color: #888; font-size: 14px; }
        .meta span { margin-right: 20px; }
        
        .stats {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 15px;
            margin-bottom: 20px;
        }
        .stat-card {
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 20px;
            text-align: center;
            border: 1px solid rgba(255,255,255,0.1);
        }
        .stat-card .number {
            font-size: 36px;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .stat-card .label { color: #888; font-size: 12px; text-transform: uppercase; }
        .stat-success .number { color: #10b981; }
        .stat-warning .number { color: #f59e0b; }
        .stat-error .number { color: #ef4444; }
        .stat-skipped .number { color: #6b7280; }
        
        .section {
            background: rgba(255,255,255,0.03);
            border-radius: 12px;
            margin-bottom: 20px;
            border: 1px solid rgba(255,255,255,0.1);
            overflow: hidden;
        }
        .section-header {
            background: rgba(255,255,255,0.05);
            padding: 15px 20px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .section-header .icon { font-size: 20px; }
        .section-content { padding: 20px; }
        
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid rgba(255,255,255,0.1); }
        th { color: #888; font-weight: 500; font-size: 12px; text-transform: uppercase; }
        tr:last-child td { border-bottom: none; }
        tr:hover { background: rgba(255,255,255,0.02); }
        
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 500;
        }
        .status-success { background: rgba(16, 185, 129, 0.2); color: #10b981; }
        .status-warning { background: rgba(245, 158, 11, 0.2); color: #f59e0b; }
        .status-error { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
        .status-skipped { background: rgba(107, 114, 128, 0.2); color: #9ca3af; }
        .status-manual { background: rgba(139, 92, 246, 0.2); color: #a78bfa; }
        .status-partial { background: rgba(239, 68, 68, 0.2); color: #ef4444; }
        
        .critical-warning {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.15) 0%, rgba(220, 38, 38, 0.1) 100%);
            border: 2px solid #ef4444;
            border-radius: 12px;
            padding: 25px;
            margin-bottom: 25px;
            text-align: center;
        }
        .critical-warning h2 {
            color: #ef4444;
            font-size: 22px;
            margin-bottom: 15px;
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 10px;
        }
        .critical-warning p {
            color: #fca5a5;
            margin-bottom: 10px;
            font-size: 15px;
        }
        .critical-warning .reason {
            color: #888;
            font-size: 13px;
        }
        
        .not-captured-section {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.1) 0%, rgba(220, 38, 38, 0.05) 100%);
            border: 1px solid rgba(239, 68, 68, 0.3);
        }
        .not-captured-section .section-header {
            background: rgba(239, 68, 68, 0.15);
            color: #fca5a5;
        }
        .not-captured-item {
            background: rgba(239, 68, 68, 0.1);
            border-left: 4px solid #ef4444;
            padding: 20px;
            margin-bottom: 15px;
            border-radius: 0 8px 8px 0;
        }
        .not-captured-item h4 { 
            color: #fca5a5; 
            margin-bottom: 8px;
            font-size: 16px;
        }
        .not-captured-item .why { 
            color: #f87171; 
            font-size: 13px; 
            margin-bottom: 10px;
            font-style: italic;
        }
        .not-captured-item .instructions { 
            color: #e0e0e0; 
            font-size: 14px;
            line-height: 1.6;
        }
        .not-captured-item pre { 
            background: rgba(0,0,0,0.4); 
            padding: 15px; 
            margin-top: 12px; 
            border-radius: 6px;
            font-size: 13px;
            white-space: pre-wrap;
            color: #fca5a5;
            border: 1px solid rgba(239, 68, 68, 0.2);
        }
        
        .manual-task {
            background: rgba(139, 92, 246, 0.1);
            border-left: 3px solid #7c3aed;
            padding: 15px;
            margin-bottom: 10px;
            border-radius: 0 8px 8px 0;
        }
        .manual-task h4 { color: #a78bfa; margin-bottom: 5px; }
        .manual-task p { color: #888; font-size: 14px; }
        .manual-task pre { 
            background: rgba(0,0,0,0.3); 
            padding: 10px; 
            margin-top: 10px; 
            border-radius: 6px;
            font-size: 13px;
            white-space: pre-wrap;
        }
        
        .checklist {
            list-style: none;
        }
        .checklist li {
            padding: 10px 15px;
            border-bottom: 1px solid rgba(255,255,255,0.05);
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .checklist li:last-child { border-bottom: none; }
        .checkbox {
            width: 20px;
            height: 20px;
            border: 2px solid #444;
            border-radius: 4px;
            display: inline-block;
        }
        
        footer {
            text-align: center;
            padding: 20px;
            color: #666;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>STO Laptop Transfer Report</h1>
            <div class="meta">
                <span>User: $($Script:Results.UserName)</span>
                <span>Computer: $($Script:Results.ComputerName)</span>
                <span>Mode: $(Out-HtmlEncoded $Script:Config.TransferMode)</span>
                <span>Date: $(Get-Date -Format "MMMM dd, yyyy 'at' h:mm tt")</span>
                <span>Duration: $([math]::Round($duration.TotalMinutes, 1)) minutes</span>
            </div>
        </header>
"@

    # Only mark the export incomplete when a recorded task actually needs
    # elevation. A standard-user export can otherwise be complete.
    $adminRequiredTasks = @($Script:Results.ManualTasks | Where-Object { $_.Reason -match "admin|Administrator|privileges" })
    $adminTaskCount = $adminRequiredTasks.Count
    if (-not $Script:IsAdmin -and $adminTaskCount -gt 0) {
        
        $html += @"
        
        <div style="background: linear-gradient(135deg, rgba(220, 38, 38, 0.2) 0%, rgba(185, 28, 28, 0.15) 100%); border: 3px solid #dc2626; border-radius: 16px; padding: 30px; margin-bottom: 25px; text-align: center;">
            <h2 style="color: #fca5a5; font-size: 26px; margin-bottom: 15px;">&#9888; INCOMPLETE EXPORT - ADMIN RIGHTS REQUIRED &#9888;</h2>
            <p style="color: #fecaca; font-size: 18px; margin-bottom: 15px;"><strong>This export was run WITHOUT administrator privileges.</strong></p>
            <p style="color: #fca5a5; font-size: 16px; margin-bottom: 20px;">$adminTaskCount item(s) could <strong>NOT</strong> be automatically captured and <strong>MUST be manually copied BEFORE wiping the old laptop!</strong></p>
            <p style="color: #f87171; font-size: 14px;">To capture everything automatically, re-run Export-LaptopData.ps1 and select <strong>"Y"</strong> when prompted for administrator rights.</p>
        </div>
        
        <div style="background: rgba(220, 38, 38, 0.1); border: 2px solid #dc2626; border-radius: 12px; margin-bottom: 25px; overflow: hidden;">
            <div style="background: rgba(220, 38, 38, 0.2); padding: 18px 25px; font-weight: 700; font-size: 18px; color: #fca5a5; display: flex; align-items: center; gap: 12px;">
                <span style="font-size: 24px;">&#10060;</span>
                NOT CAPTURED - MUST MANUALLY COPY BEFORE WIPING OLD LAPTOP
            </div>
            <div style="padding: 25px;">
"@
        foreach ($task in $adminRequiredTasks) {
            $html += @"
                <div style="background: rgba(220, 38, 38, 0.1); border-left: 5px solid #dc2626; padding: 20px; margin-bottom: 18px; border-radius: 0 10px 10px 0;">
                    <h4 style="color: #fca5a5; font-size: 17px; margin-bottom: 10px; font-weight: 600;">$(Out-HtmlEncoded $task.Task)</h4>
                    <p style="color: #f87171; font-size: 13px; margin-bottom: 12px; font-style: italic;"><strong>Why not captured:</strong> $(Out-HtmlEncoded $task.Reason)</p>
                    <p style="color: #e0e0e0; font-size: 14px; margin-bottom: 8px;"><strong>What you MUST do:</strong></p>
                    $(if ($task.Instructions) { "<pre style='background: rgba(0,0,0,0.5); padding: 15px; border-radius: 8px; font-size: 13px; white-space: pre-wrap; color: #fecaca; border: 1px solid rgba(220, 38, 38, 0.3); margin-top: 8px;'>$(Out-HtmlEncoded $task.Instructions)</pre>" })
                </div>
"@
        }
        $html += @"
            </div>
        </div>
"@
    }
    elseif ($Script:IsAdmin) {
        # Admin mode - show green success banner
        $html += @"
        
        <div style="background: linear-gradient(135deg, rgba(16, 185, 129, 0.15) 0%, rgba(5, 150, 105, 0.1) 100%); border: 2px solid #10b981; border-radius: 12px; padding: 20px; margin-bottom: 25px; text-align: center;">
            <h3 style="color: #6ee7b7; font-size: 18px; margin-bottom: 8px;">&#10003; Full Export Completed with Administrator Rights</h3>
            <p style="color: #a7f3d0; font-size: 14px;">All settings including power schemes were successfully captured.</p>
        </div>
"@
    }

    $html += @"
        
        <div class="stats">
            <div class="stat-card stat-success">
                <div class="number">$successCount</div>
                <div class="label">Successful</div>
            </div>
            <div class="stat-card stat-warning">
                <div class="number">$warningCount</div>
                <div class="label">Warnings</div>
            </div>
            <div class="stat-card stat-error">
                <div class="number">$errorCount</div>
                <div class="label">Errors</div>
            </div>
            <div class="stat-card stat-skipped">
                <div class="number">$skippedCount</div>
                <div class="label">Skipped</div>
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#10003;</span>
                Export Actions
            </div>
            <div class="section-content">
                <table>
                    <thead>
                        <tr>
                            <th>Category</th>
                            <th>Item</th>
                            <th>Status</th>
                            <th>Details</th>
                        </tr>
                    </thead>
                    <tbody>
"@

    foreach ($action in $Script:Results.Actions) {
        $statusClass = switch -Regex ($action.Status) {
            "Success" { "status-success" }
            "Warning" { "status-warning" }
            "Error" { "status-error" }
            "Skipped" { "status-skipped" }
            "NOT EXPORTED|Admin Required" { "status-error" }
            default { "status-warning" }
        }
        $html += @"
                        <tr>
                            <td>$(Out-HtmlEncoded $action.Category)</td>
                            <td>$(Out-HtmlEncoded $action.Item)</td>
                            <td><span class="status $statusClass">$($action.Status)</span></td>
                            <td>$(Out-HtmlEncoded $action.Details)</td>
                        </tr>
"@
    }

    # Get non-admin related manual tasks (admin ones are shown in the big red box above)
    $otherManualTasks = if (-not $Script:IsAdmin) {
        $Script:Results.ManualTasks | Where-Object { $_.Reason -notmatch "admin|Administrator|privileges" }
    } else {
        $Script:Results.ManualTasks
    }

    $html += @"
                    </tbody>
                </table>
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#128203;</span>
                Other Manual Tasks
            </div>
            <div class="section-content">
"@

    if ($otherManualTasks -and ($otherManualTasks | Measure-Object).Count -gt 0) {
        foreach ($task in $otherManualTasks) {
            $html += @"
                <div class="manual-task">
                    <h4>$(Out-HtmlEncoded $task.Task)</h4>
                    <p>$(Out-HtmlEncoded $task.Reason)</p>
                    $(if ($task.Instructions) { "<pre>$(Out-HtmlEncoded $task.Instructions)</pre>" })
                </div>
"@
        }
    }
    else {
        $html += @"
                <p style="color: #10b981; padding: 15px;">&#10003; No additional manual tasks required.</p>
"@
    }

    $html += @"
            </div>
        </div>
        
        <div class="section">
            <div class="section-header">
                <span class="icon">&#9776;</span>
                New Machine Checklist
            </div>
            <div class="section-content">
                <ul class="checklist">
                    <li><span class="checkbox"></span> Run Import-LaptopData.ps1</li>
                    <li><span class="checkbox"></span> Verify/Resolve Imaging Errors</li>
                    <li><span class="checkbox"></span> Run Lenovo System Update</li>
                    <li><span class="checkbox"></span> Uninstall Lenovo System Update</li>
                    <li><span class="checkbox"></span> Check for Windows Updates</li>
                    <li><span class="checkbox"></span> Verify BitLocker is enabled</li>
                    <li><span class="checkbox"></span> Restart Computer</li>
                    <li><span class="checkbox"></span> Login as User</li>
                    <li><span class="checkbox"></span> Configure & Test Lotus Notes</li>
                    <li><span class="checkbox"></span> Configure Office 365</li>
                    <li><span class="checkbox"></span> Sign in to OneDrive and Teams</li>
                    <li><span class="checkbox"></span> Test Teams incl. Camera</li>
                    <li><span class="checkbox"></span> Configure Adobe / Bluebeam Revu</li>
                    <li><span class="checkbox"></span> Test run all other Applications</li>
                    <li><span class="checkbox"></span> Verify printers restored (test page) - add any missing local printers</li>
                    <li><span class="checkbox"></span> Unpin Store from taskbar</li>
                    <li><span class="checkbox"></span> Verify printers and shared drives match</li>
                    <li><span class="checkbox"></span> Verify Power Settings match</li>
                    <li><span class="checkbox"></span> Verify Default Browser</li>
                    <li><span class="checkbox"></span> Outlook Signature and Plug-Ins</li>
                    <li><span class="checkbox"></span> Check for manual drive mappings</li>
                    <li><span class="checkbox"></span> Connect to STOBG Network Wi-Fi</li>
                </ul>
            </div>
        </div>
        
        <footer>
            Generated by STO Laptop Transfer Tool v$($Script:Config.Version) | $(Get-Date -Format "yyyy")
        </footer>
    </div>
</body>
</html>
"@

    $reportPath = Join-Path $DestinationBase "TransferReport.html"
    $html | Out-File $reportPath -Encoding UTF8
    
    Write-Log "Transfer report generated" -Level Success
    
    return $reportPath
}
