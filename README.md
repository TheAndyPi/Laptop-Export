# Laptop Export

**STO Building Group – Laptop Transfer / Export Tool** (`Export-LaptopData.ps1`, v0.5)

A single-file PowerShell tool that automates the **data-collection phase** of a laptop refresh. An IT technician runs it on the **old** laptop (logged in as, or on behalf of, the user being transferred). It copies the user's data and settings into a self-contained transfer package on an external drive, then generates a matching **Import** script, a **QuickImport.bat**, and an **HTML report** to run on the new machine.

## Deploy / Run

Run on the **old** laptop, signed in as the user being transferred:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Export-LaptopData.ps1"
```

The script is interactive. It will prompt you to:

1. **Elevate to Administrator** (Y/N/Skip) — recommended. Accepting re-launches via UAC, preserving the original user's profile context.
2. **Choose a transfer mode** — `Local` or `Online` (see below).
3. **Select a target drive** — any removable or fixed drive except `C:`. It estimates the transfer size and warns if free space looks tight (~15% headroom required).

It then runs the export, saves everything to the drive, and opens the HTML report when finished.

## Requirements

- **Windows PowerShell 5.1+** (`#Requires -Version 5.1`)
- An **external/USB drive** (or second fixed drive) with enough free space
- **Administrator rights** — *optional but recommended*. Needed only for the power scheme and printer export; without admin, those items are added to the manual checklist instead. The script offers to self-elevate.

## Transfer modes

| Mode | Use case | Behavior |
|------|----------|----------|
| **Local** | USB / on-site | Full copy of everything. |
| **Online** | Slow / remote links | Trimmed: caps `Downloads` at 5 GB (omits if larger), skips Lotus Notes data, prompts on any folder over 10 GB, and skips OneDrive re-hydration. |

## What it captures

- **User folders** — Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites, loose profile files, and OCS Documents
- **AppData** — Bluebeam, Outlook email signatures, Quick Access pins, Lotus Notes
- **System settings** — power scheme, lid-close actions (AC/DC), mapped network drives, personalization (colors, dark mode, taskbar), wallpaper
- **Installed programs** — documented to a list
- **Printers** — PrintBRM package (network printers restore driverless / non-admin)
- **Browser data** — Chrome & Edge bookmarks (HTML), Firefox reminder
- **OneDrive** — sync-state handling

## Output package

Written to the target drive under `LaptopTransfer_<yyyyMMdd_HHmmss>\`:

```
LaptopTransfer_<timestamp>\
├── UserData\              # user folders + loose files
├── AppData\               # Bluebeam, signatures, Quick Access, Lotus
├── Settings\              # power, drives, personalization
├── BrowserData\           # bookmarks
├── Printers\              # PrintBRM package
├── Logs\                  # ExportLog.txt
├── Import-LaptopData.ps1  # run on the NEW machine to restore
├── QuickImport.bat        # double-click launcher (self-elevates)
└── TransferReport.html    # full report of everything captured
```

## On the new machine

Copy the transfer folder to the new laptop and restore with **either**:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Import-LaptopData.ps1"
```

...or double-click **`QuickImport.bat`** (it self-elevates). Add `-TestMode` to the Import command to preview actions without making changes.

## Command-line parameters

Normally you don't pass any — the script prompts for everything. These exist mainly so the tool can hand context to its own elevated relaunch:

| Parameter | Purpose |
|-----------|---------|
| `-TransferMode Local\|Online` | Skip the mode prompt. |
| `-TargetUserProfile`, `-TargetUserName`, `-TargetAppDataRoaming`, `-TargetAppDataLocal` | Preserve the original user's context when running elevated. Set automatically during self-elevation. |
