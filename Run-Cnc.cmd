@echo off
setlocal
"%~dp0..\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Cnc.ps1" %*
exit /b %errorlevel%
