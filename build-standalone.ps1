# Run this to rebuild agent-standalone.cmd from agent.ps1.
# The resulting .cmd file is a polyglot: double-clickable on Windows AND
# accepts all the same CLI flags as agent.ps1 (e.g. -SkipModelPull, -MediaModels).
#
# Usage:
#   .\build-standalone.ps1
#   → produces agent-standalone.cmd in the same directory

$here   = $PSScriptRoot
$source = Join-Path $here "agent.ps1"
$out    = Join-Path $here "agent-standalone.cmd"

if (-not (Test-Path $source)) {
    throw "agent.ps1 not found at $source"
}

$psCode = Get-Content $source -Raw

# Batch header — two-step approach so %* (CLI args) reach param() properly:
#   Step 1: extract PS content (everything from "#Requires" onward) into a temp .ps1
#   Step 2: run the temp file with PowerShell -File, which binds param() correctly
#   Step 3: delete the temp file
#
# This file's batch section is wrapped in a <# ... #> block comment so PowerShell
# ignores it when the file is dot-sourced or run directly as .ps1.

$header = '@echo off
set "_SF=%~f0" & set "_TP=%TEMP%\swarm_agent_%RANDOM%.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$c=[io.file]::ReadAllText($env:_SF); $i=$c.IndexOf(''#Requires -Version''); [io.file]::WriteAllText($env:_TP,$c.Substring($i))"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%_TP%" %*
del "%_TP%" 2>nul
exit /b
<# --- batch section above is a PowerShell block comment ---'

Set-Content -Path $out -Value ($header + "`n" + $psCode) -Encoding UTF8
Write-Host "Built: $out"
Write-Host "Distribute this single file — users double-click it, no other files needed."
Write-Host "CLI flags like -SkipModelPull and -MediaModels are forwarded correctly."
