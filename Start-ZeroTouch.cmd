@echo off
rem ZeroTouch launcher for technicians: double-click it from a USB stick or a network share.
rem It asks for administrator rights if needed, then shows the department menu.
setlocal
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-ZeroTouch.ps1"
set "ZT_EXIT=%errorlevel%"
echo.
if "%ZT_EXIT%"=="3010" echo Provisioning finished. Restart the computer to complete it.
pause
exit /b %ZT_EXIT%
