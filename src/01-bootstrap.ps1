<#
.SYNOPSIS
    STO Building Group Laptop Transfer - Export Script
    Captures user data, settings, and generates import script for new machine.

.DESCRIPTION
    This script automates the data collection phase of laptop transfers:
    - Copies user folders (Documents, Desktop, Downloads, etc.)
    - Captures AppData (Bluebeam, Signatures, Quick Access)
    - Documents installed programs
    - Captures system settings (power, lid, mapped drives)
    - Generates an Import script for the new machine
    - Creates an HTML report of all actions

.PARAMETER TargetUserProfile
    The user profile path to export. Used when running elevated to preserve original user context.

.PARAMETER TargetUserName
    The username to export. Used when running elevated to preserve original user context.

.NOTES
    Version: 0.6
    Author: STO IT
    Run as: The user being transferred (IT admin logged in as user)
#>

#Requires -Version 5.1

# Bootstrap runs first.  It defines command-line inputs and process-wide
# presentation state before any feature module is loaded.  Nothing here copies
# user data; it establishes the environment in which the later modules run.

param(
    [string]$TargetUserProfile = "",
    [string]$TargetUserName = "",
    [string]$TargetAppDataRoaming = "",
    [string]$TargetAppDataLocal = "",
    [ValidateSet("", "Local", "Online")]
    [string]$TransferMode = "",
    # Parent folder for the transfer package. When omitted, Windows displays a
    # folder picker after the transfer mode is selected.
    [string]$DestinationPath = "",
    # Optional override for the Online payload ceiling in GB (default: 5).
    [double]$OnlineMaxTransferGB = 0,
    # Internal: preserves choices made in Transfer Settings across the UAC
    # relaunch. Technicians do not need to supply either parameter.
    [string]$RuntimeSettings = "",
    [switch]$ElevatedFromSettings,
    # Intended for logged/automated validation. It keeps normal technician
    # runs unchanged, skips prompts, and does not open the HTML report.
    [switch]$NonInteractive
)

# ============================================================================
# CONSOLE ENCODING & ANSI SETUP
# ============================================================================
# Enable UTF-8 output so box-drawing, glyphs, and gradient accents render
# correctly. This also underpins correct symbol output in the HTML report.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}
catch { }

# Try to enable ANSI (virtual terminal) processing so 24-bit color works in
# legacy conhost. Windows Terminal / PowerShell 7 already support it.
$Script:AnsiEnabled = $false
try {
    if ($Host.UI.SupportsVirtualTerminal) {
        $Script:AnsiEnabled = $true
    }
    else {
        # Attempt to flip the console mode flag for legacy conhost (Win10+)
        $sig = @'
using System;
using System.Runtime.InteropServices;
public static class VT {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@
        if (-not ("VT" -as [type])) { Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue }
        $h = [VT]::GetStdHandle(-11)
        $mode = 0
        if ([VT]::GetConsoleMode($h, [ref]$mode)) {
            if ([VT]::SetConsoleMode($h, $mode -bor 0x0004)) { $Script:AnsiEnabled = $true }
        }
    }
}
catch { $Script:AnsiEnabled = $false }

# ============================================================================
# CONSOLE UI / THEME
# ============================================================================
# A small, centralized styling layer so every screen looks consistent. Brand
# accent runs cyan (#00d4ff) -> purple (#7c3aed), matching the HTML report.

$Script:Theme = @{
    Esc        = [char]27
    AccentFrom = @(0, 212, 255)    # #00d4ff cyan
    AccentTo   = @(124, 58, 237)   # #7c3aed purple
    Width      = 60
    Glyphs     = @{ OK = [char]0x2713; WARN = [char]0x26A0; FAIL = [char]0x2717; INFO = [char]0x2139; SKIP = [char]0x2022; ARROW = [char]0x25B8 }
    Box        = @{ TL=[char]0x2554; TR=[char]0x2557; BL=[char]0x255A; BR=[char]0x255D; H=[char]0x2550; V=[char]0x2551; ML=[char]0x2560; MR=[char]0x2563 }
    Bar        = @{ Full=[char]0x2588; Light=[char]0x2591 }
    Spinner    = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)
}

