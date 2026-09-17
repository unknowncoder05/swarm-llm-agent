# Run this on any machine to produce agent-standalone.cmd —
# a single file that works on Windows by double-click, no companion files needed.
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

# The polyglot header runs as batch on double-click:
#   1. Sets %~f0 (this file's path) into env var Z
#   2. Launches PowerShell with ExecutionPolicy Bypass, reads and executes itself
#   3. Exits the batch process
#
# PowerShell ignores the header because it is wrapped in a <# ... #> block comment.

$header = @"
@(set "Z=%~f0")& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "iex([io.file]::ReadAllText(`$env:Z))" & exit /b
<# --- batch header above is a PowerShell block comment --- begin PS1 ---
"@

$footer = "`n#>"

Set-Content -Path $out -Value ($header + "`n" + $psCode + $footer) -Encoding UTF8
Write-Host "Built: $out"
Write-Host "Distribute this single file — users double-click it, no other files needed."
