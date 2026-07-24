@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Export-LaptopData.ps1"
set "TEMP_PATH=%SCRIPT_PATH%.download"
set "SCRIPT_URL=https://raw.githubusercontent.com/TheAndyPi/Laptop-Export/A1A2-Prototype/Export-LaptopData.ps1"

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
