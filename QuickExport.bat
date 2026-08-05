:: Runs the Export-LaptopData.ps1 script in the local directory with the ExecutionPolicy set to Bypass. This allows the script to run without being blocked by the system's execution policy settings.
:: This does not download or install any files; it simply executes the PowerShell script in the current directory.

@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0Export-LaptopData.ps1"