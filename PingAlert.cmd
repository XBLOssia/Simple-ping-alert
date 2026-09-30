@echo off
rem Double-click launcher for PingAlert.ps1 (keep both files in the same folder).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0PingAlert.ps1" %*
