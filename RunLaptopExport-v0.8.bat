:: This batch file downloads the latest version of Export-LaptopData.ps1 from the GitHub repository and runs it. It is intended for use in a Windows environment with PowerShell installed.
:: The script will attempt to download the latest version of Export-LaptopData.ps1 from the specified GitHub URL. If the download is successful, it will replace the existing script in the local directory and execute it. If the download fails, it will not run the existing script and will exit with an error code.

@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Export-LaptopData-v0.8.ps1"
set "TEMP_PATH=%SCRIPT_PATH%.download"
set "SCRIPT_URL=https://raw.githubusercontent.com/TheAndyPi/Laptop-Export/main/Export-LaptopData.ps1"

echo Downloading the latest Export-LaptopData.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing -Uri '%SCRIPT_URL%' -OutFile '%TEMP_PATH%' -ErrorAction Stop; Move-Item -LiteralPath '%TEMP_PATH%' -Destination '%SCRIPT_PATH%' -Force -ErrorAction Stop } catch { Write-Error $_; exit 1 }"
if errorlevel 1 (
    echo.
    echo Update failed. The existing Export-LaptopData.ps1 was not run.
    if exist "%TEMP_PATH%" del /q "%TEMP_PATH%"
    exit /b 1
)

echo Running Export-LaptopData.ps1...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
exit /b %errorlevel%
