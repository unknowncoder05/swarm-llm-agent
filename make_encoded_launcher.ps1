# Run this on YOUR machine to generate an encoded one-liner for locked-down PCs.
# Output a .cmd file that runs from cmd.exe even with AllSigned policy.

param(
    [Parameter(Mandatory=$true)][string]$Coordinator,
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [string]$Model = "qwen2.5-coder:1.5b",
    [string]$OutputCmd = "run_agent.cmd"
)

$scriptUrl = "https://raw.githubusercontent.com/YOUR_USER/swarm-llm/main/agent/agent.ps1"

# Inline loader: downloads agent.ps1 to memory and dot-sources it
$loader = @"
`$ErrorActionPreference='Stop'
`$c = (New-Object Net.WebClient).DownloadString('$scriptUrl')
`$sb = [ScriptBlock]::Create(`$c)
& `$sb -Coordinator '$Coordinator' -ApiKey '$ApiKey' -Model '$Model'
"@

$bytes   = [System.Text.Encoding]::Unicode.GetBytes($loader)
$encoded = [Convert]::ToBase64String($bytes)

$cmd = "@echo off`r`npowershell -EncodedCommand $encoded`r`n"
Set-Content -Path $OutputCmd -Value $cmd -Encoding ASCII

Write-Host "Generated: $OutputCmd"
Write-Host "Copy this file to the target machine and double-click it."
