:: agent.cmd — double-click this on any Windows machine.
:: Bypasses execution policy for this process only (no admin, no machine changes).
:: Requires agent.ps1 in the same folder.
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent.ps1" %*
