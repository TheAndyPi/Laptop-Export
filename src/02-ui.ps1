function Get-VisibleLength {
    # Length of a string ignoring ANSI escape sequences (for correct padding)
    param([string]$Text)
    return ([regex]::Replace($Text, "$([char]27)\[[0-9;]*m", "")).Length
}

function Out-HtmlEncoded {
    # Encode a value for safe insertion into HTML. Folder names, details, and
    # bookmark titles routinely contain & < > which otherwise break rendering.
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Convert-ToGradient {
    # Returns a string with per-character 24-bit color from AccentFrom -> AccentTo
    param([string]$Text, [int[]]$From = $Script:Theme.AccentFrom, [int[]]$To = $Script:Theme.AccentTo)
    if (-not $Script:AnsiEnabled) { return $Text }
    $e = $Script:Theme.Esc
    $len = $Text.Length
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $len; $i++) {
        $t = if ($len -le 1) { 0 } else { $i / ($len - 1) }
        $r = [int]($From[0] + ($To[0] - $From[0]) * $t)
        $g = [int]($From[1] + ($To[1] - $From[1]) * $t)
        $b = [int]($From[2] + ($To[2] - $From[2]) * $t)
        [void]$sb.Append("$e[38;2;$r;$g;${b}m$($Text[$i])")
    }
    [void]$sb.Append("$e[0m")
    return $sb.ToString()
}

function Write-Banner {
    # Draws a gradient-bordered box with centered, gradient title text
    param([string]$Title, [string]$Subtitle = "", [int]$Width = $Script:Theme.Width)
    $b = $Script:Theme.Box
    $inner = $Width - 2
    $top = "$($b.TL)$([string]$b.H * $inner)$($b.TR)"
    $bot = "$($b.BL)$([string]$b.H * $inner)$($b.BR)"

    $titlePad = [math]::Max(0, ($inner - $Title.Length))
    $tLeft = [math]::Floor($titlePad / 2)
    $tRight = $titlePad - $tLeft
    $titleLine = "$($b.V)$(' ' * $tLeft)$(Convert-ToGradient $Title)$(' ' * $tRight)$($b.V)"

    Write-Host ""
    Write-Host (Convert-ToGradient $top)
    Write-Host $titleLine
    if ($Subtitle) {
        $sPad = [math]::Max(0, ($inner - $Subtitle.Length))
        $sLeft = [math]::Floor($sPad / 2)
        $sRight = $sPad - $sLeft
        Write-Host "$($b.V)$(' ' * $sLeft)" -NoNewline
        Write-Host $Subtitle -ForegroundColor DarkGray -NoNewline
        Write-Host "$(' ' * $sRight)$($b.V)"
    }
    Write-Host (Convert-ToGradient $bot)
    Write-Host ""
}

function Write-Section {
    # A lightweight section header: accent arrow + gradient rule
    param([string]$Title, [int]$Width = $Script:Theme.Width)
    $rule = [string]$Script:Theme.Box.H * [math]::Max(4, ($Width - $Title.Length - 4))
    Write-Host ""
    Write-Host "$($Script:Theme.Glyphs.ARROW) " -ForegroundColor Cyan -NoNewline
    Write-Host $Title -ForegroundColor White -NoNewline
    Write-Host "  $(Convert-ToGradient $rule)"
}

function Write-Status {
    # Aligned status line: glyph + padded label + dimmed detail
    param(
        [string]$Label,
        [ValidateSet("OK","WARN","FAIL","INFO","SKIP")][string]$Status,
        [string]$Detail = "",
        [int]$LabelWidth = 34
    )
    $glyph = $Script:Theme.Glyphs[$Status]
    $color = @{ OK="Green"; WARN="Yellow"; FAIL="Red"; INFO="Cyan"; SKIP="DarkGray" }[$Status]
    $padded = if ($Label.Length -gt $LabelWidth) { $Label.Substring(0, $LabelWidth) } else { $Label.PadRight($LabelWidth) }
    Write-Host "  $glyph " -ForegroundColor $color -NoNewline
    Write-Host $padded -ForegroundColor White -NoNewline
    if ($Detail) { Write-Host " $Detail" -ForegroundColor DarkGray } else { Write-Host "" }
}

function Write-KeyValue {
    param([string]$Key, [string]$Value, [int]$KeyWidth = 18)
    Write-Host "    $($Key.PadRight($KeyWidth))" -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor White
}

function Write-SummaryCard {
    # Bordered receipt-style summary at the end of a run
    param([int]$Success, [int]$Warning, [int]$Errors, [int]$Skipped, [string]$Duration, [int]$Width = $Script:Theme.Width)
    $b = $Script:Theme.Box
    $inner = $Width - 2
    Write-Host ""
    Write-Host (Convert-ToGradient "$($b.TL)$([string]$b.H * $inner)$($b.TR)")
    $rows = @(
        @{ L="Successful"; V=$Success;  C="Green" }
        @{ L="Warnings";   V=$Warning;  C="Yellow" }
        @{ L="Errors";     V=$Errors;   C="Red" }
        @{ L="Skipped";    V=$Skipped;  C="DarkGray" }
    )
    foreach ($r in $rows) {
        $line = "  $($Script:Theme.Glyphs.ARROW) $($r.L)"
        $val = "$($r.V)"
        $pad = $inner - $line.Length - $val.Length - 2
        Write-Host "$($b.V)" -NoNewline
        Write-Host $line -ForegroundColor $r.C -NoNewline
        Write-Host "$(' ' * [math]::Max(1,$pad))$val  " -ForegroundColor $r.C -NoNewline
        Write-Host "$($b.V)"
    }
    Write-Host "$($b.V)$(' ' * $inner)$($b.V)"
    $durLine = "  Duration: $Duration"
    Write-Host "$($b.V)" -NoNewline
    Write-Host $durLine -ForegroundColor DarkGray -NoNewline
    Write-Host "$(' ' * [math]::Max(0, $inner - $durLine.Length))$($b.V)"
    Write-Host (Convert-ToGradient "$($b.BL)$([string]$b.H * $inner)$($b.BR)")
    Write-Host ""
}

function Write-StoLogo {
    # Compact Unicode wordmark, gradient-accented
    $l = @(
        "  ___ _____ ___    ",
        " / __|_   _/ _ \   ",
        " \__ \ | || (_) |  ",
        " |___/ |_| \___/   "
    )
    Write-Host ""
    foreach ($line in $l) { Write-Host (Convert-ToGradient $line) }
    Write-Host "  BUILDING GROUP" -ForegroundColor DarkGray
    Write-Host ""
}

function Clear-StoScreen {
    # Clear-Host accesses RawUI, which is unavailable when the script runs
    # through a redirected, remoted, or log-capturing host. The UI is still
    # readable without clearing, so never let this cosmetic action stop work.
    try { Clear-Host -ErrorAction Stop } catch { }
}

function Read-UserInput {
    param([string]$Prompt)
    Write-Host $Prompt
    return Read-Host "  >"
}

