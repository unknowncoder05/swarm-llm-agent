#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up Ollama + a coding LLM on a university Windows machine and registers
    it with a central coordinator.

.EXAMPLE
    # Interactive wizard (recommended — auto-detects hardware, shows model menu):
    .\agent.ps1

    # Non-interactive (CI / scripted):
    .\agent.ps1 -Coordinator https://1.2.3.4:8443 -ApiKey abc123 -Model qwen2.5-coder:7b
#>
param(
    [string]$Coordinator = "",
    [string]$ApiKey      = "",
    [string]$Model       = "",
    [int]$OllamaPort     = 11434,
    [switch]$SkipModelPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Allow self-signed TLS (PS5 compatible — SkipCertificateCheck is PS6+ only)
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12

# ── console helpers ───────────────────────────────────────────────────────────

function Write-Step([string]$msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "[!] $msg" -ForegroundColor Red }

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ███████╗██╗    ██╗ █████╗ ██████╗ ███╗   ███╗    ██╗     ██╗     ███╗   ███╗" -ForegroundColor Cyan
    Write-Host "  ██╔════╝██║    ██║██╔══██╗██╔══██╗████╗ ████║    ██║     ██║     ████╗ ████║" -ForegroundColor Cyan
    Write-Host "  ███████╗██║ █╗ ██║███████║██████╔╝██╔████╔██║    ██║     ██║     ██╔████╔██║" -ForegroundColor Cyan
    Write-Host "  ╚════██║██║███╗██║██╔══██║██╔══██╗██║╚██╔╝██║    ██║     ██║     ██║╚██╔╝██║" -ForegroundColor Cyan
    Write-Host "  ███████║╚███╔███╔╝██║  ██║██║  ██║██║ ╚═╝ ██║    ███████╗███████╗██║ ╚═╝ ██║" -ForegroundColor Cyan
    Write-Host "  ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝    ╚══════╝╚══════╝╚═╝     ╚═╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  University Machine Agent  |  TLS ON  |  API Key Auth ON" -ForegroundColor DarkCyan
    Write-Host ""
}

# Arrow-key choice list. Returns the selected item.
function Show-ChoiceList([string]$prompt, [string[]]$items, [int]$defaultIndex = 0) {
    $selected = $defaultIndex
    $top = [Console]::CursorTop

    while ($true) {
        # Redraw
        [Console]::SetCursorPosition(0, $top)
        Write-Host "  $prompt" -ForegroundColor Yellow
        Write-Host ""
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($i -eq $selected) {
                Write-Host "   > $($items[$i])" -ForegroundColor White -BackgroundColor DarkBlue
            } else {
                Write-Host "     $($items[$i])" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "  [↑/↓] navigate   [Enter] select" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "UpArrow"   { if ($selected -gt 0)                { $selected-- } }
            "DownArrow" { if ($selected -lt $items.Count - 1) { $selected++ } }
            "Enter"     { Write-Host ""; return $items[$selected] }
            "Escape"    { throw "Cancelled" }
        }
    }
}

function Read-MaskedInput([string]$prompt) {
    Write-Host "  $prompt" -NoNewline -ForegroundColor Yellow
    $secure = Read-Host -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

# ── hardware detection ────────────────────────────────────────────────────────

function Get-HardwareQuick {
    $hw = @{ vram_gb = 0; ram_gb = 0; gpu_name = "none"; cpu_name = "unknown" }
    try {
        $smi = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $smi) {
            $parts = $smi -split ","
            $hw.gpu_name = $parts[0].Trim()
            $hw.vram_gb  = [math]::Round([double]$parts[1].Trim() / 1024, 1)
        }
    } catch { }
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $hw.ram_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
    } catch { }
    try {
        $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $hw.cpu_name = $cpu.Name.Trim()
    } catch { }
    return $hw
}

# Pick recommended model index based on VRAM
function Get-RecommendedModelIndex([double]$vramGb) {
    if     ($vramGb -ge 12) { return 4 }  # 14b
    elseif ($vramGb -ge 6)  { return 3 }  # 7b
    elseif ($vramGb -ge 3)  { return 2 }  # 3b
    elseif ($vramGb -ge 1)  { return 1 }  # 1.5b
    else                    { return 0 }  # 0.5b (CPU / unknown)
}

# ── system info (full, for registration) ──────────────────────────────────────

function Get-SystemInfo([hashtable]$hw) {
    $info = @{
        hostname       = $env:COMPUTERNAME
        cpu_name       = $hw.cpu_name
        cpu_cores      = $null
        ram_total_gb   = $hw.ram_gb
        ram_free_gb    = $null
        gpu_name       = if ($hw.gpu_name -ne "none") { $hw.gpu_name } else { $null }
        gpu_vram_gb    = if ($hw.vram_gb -gt 0)       { $hw.vram_gb }  else { $null }
        ollama_version = "?"
        os_version     = [System.Environment]::OSVersion.VersionString
    }
    try {
        $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.cpu_cores = [int]$cpu.NumberOfLogicalProcessors
    } catch { }
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $info.ram_free_gb = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    } catch { }
    try {
        $ver = & $script:ollamaExe --version 2>&1
        $info.ollama_version = ($ver -replace "ollama version ", "").Trim()
    } catch { }
    return $info
}

# ── ollama helpers ────────────────────────────────────────────────────────────

function Get-OllamaPath {
    $found = Get-Command ollama -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Ollama\ollama.exe",
        "$env:TEMP\ollama\ollama.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

function Install-Ollama {
    Write-Step "Downloading Ollama installer..."
    $installer = Join-Path $env:TEMP "OllamaSetup.exe"
    $attempts = 0
    while ($attempts -lt 3) {
        try {
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" `
                -OutFile $installer -UseBasicParsing
            break
        } catch {
            $attempts++
            if ($attempts -ge 3) { throw "Download failed after 3 attempts: $_" }
            Write-Err "Retrying ($attempts/3)..."
            Start-Sleep 2
        }
    }
    Write-Step "Installing Ollama (no admin required)..."
    Start-Process -FilePath $installer -ArgumentList "/S" -Wait -NoNewWindow
    Start-Sleep 2
    $path = Get-OllamaPath
    if (-not $path) { throw "Ollama not found after install. Check %LOCALAPPDATA%\Programs\Ollama" }
    Write-Ok "Ollama installed at: $path"
    return $path
}

function Wait-OllamaReady([int]$port, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$port/api/tags" `
                -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
        Start-Sleep 1
    }
    return $false
}

# ── coordinator comms ─────────────────────────────────────────────────────────

function Register-WithCoordinator([string]$coordinator, [string]$apiKey, [int]$port, [string]$model, [hashtable]$hw) {
    $myIp = (
        Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1
    ).IPAddress
    if (-not $myIp) { throw "Could not determine local IP" }

    Write-Step "Collecting system info..."
    $sysInfo = Get-SystemInfo $hw

    $body = @{
        ip             = $myIp
        port           = $port
        model          = $model
        hostname       = $sysInfo.hostname
        cpu_name       = $sysInfo.cpu_name
        cpu_cores      = $sysInfo.cpu_cores
        ram_total_gb   = $sysInfo.ram_total_gb
        ram_free_gb    = $sysInfo.ram_free_gb
        gpu_name       = $sysInfo.gpu_name
        gpu_vram_gb    = $sysInfo.gpu_vram_gb
        ollama_version = $sysInfo.ollama_version
        os_version     = $sysInfo.os_version
    } | ConvertTo-Json

    $headers = @{ "X-API-Key" = $apiKey }
    Write-Step "Registering $myIp`:$port with $coordinator ..."
    $resp = Invoke-RestMethod -Uri "$coordinator/register" `
        -Method Post -Body $body -ContentType "application/json" `
        -Headers $headers -ErrorAction Stop
    Write-Ok "Registered. Total machines: $($resp.machines_total)"
    return $myIp
}

function Start-HeartbeatLoop([string]$coordinator, [string]$apiKey, [string]$ip, [int]$port) {
    $headers = @{ "X-API-Key" = $apiKey }
    Write-Step "Running — heartbeat every 15s. Press Ctrl+C to disconnect."
    while ($true) {
        try {
            $body = @{ ip = $ip; port = $port } | ConvertTo-Json
            Invoke-RestMethod -Uri "$coordinator/heartbeat" `
                -Method Post -Body $body -ContentType "application/json" `
                -Headers $headers | Out-Null
        } catch {
            Write-Err "Heartbeat failed: $_ (coordinator unreachable)"
        }
        Start-Sleep 15
    }
}

# ── interactive wizard ────────────────────────────────────────────────────────

function Start-Wizard {
    Show-Banner

    Write-Host "  Detecting hardware..." -ForegroundColor DarkCyan
    $hw = Get-HardwareQuick

    # Show detected specs
    Write-Host ""
    Write-Host "  Detected hardware:" -ForegroundColor Yellow
    Write-Host "    CPU  : $($hw.cpu_name)"
    Write-Host "    RAM  : $($hw.ram_gb) GB"
    if ($hw.vram_gb -gt 0) {
        Write-Host "    GPU  : $($hw.gpu_name) ($($hw.vram_gb) GB VRAM)" -ForegroundColor Green
    } else {
        Write-Host "    GPU  : none detected  (CPU inference)" -ForegroundColor DarkYellow
    }
    Write-Host ""

    # Model selection
    $models = @(
        "qwen2.5-coder:0.5b  (~400 MB)  CPU-safe, for testing only",
        "qwen2.5-coder:1.5b  (~1.0 GB)  CPU-safe, fast",
        "qwen2.5-coder:3b    (~2.0 GB)  CPU / 4+ GB VRAM",
        "qwen2.5-coder:7b    (~4.7 GB)  6+ GB VRAM",
        "qwen2.5-coder:14b   (~9.0 GB)  8+ GB VRAM  ★ best quality",
        "deepseek-r1:14b     (~9.0 GB)  8+ GB VRAM  + reasoning"
    )
    $modelIds = @(
        "qwen2.5-coder:0.5b",
        "qwen2.5-coder:1.5b",
        "qwen2.5-coder:3b",
        "qwen2.5-coder:7b",
        "qwen2.5-coder:14b",
        "deepseek-r1:14b"
    )
    $recIdx = Get-RecommendedModelIndex $hw.vram_gb

    # Mark recommended
    $models[$recIdx] = $models[$recIdx] + "  ← recommended"

    $chosen = Show-ChoiceList "Select model:" $models $recIdx
    $chosenId = $modelIds[$models.IndexOf($chosen)]

    # Coordinator URL
    Write-Host ""
    Write-Host "  Coordinator URL (e.g. https://1.2.3.4:8443): " -NoNewline -ForegroundColor Yellow
    $coordUrl = Read-Host
    $coordUrl = $coordUrl.Trim().TrimEnd("/")

    # API key (masked)
    $apiKey = Read-MaskedInput "API Key: "

    Write-Host ""
    return @{ Model = $chosenId; Coordinator = $coordUrl; ApiKey = $apiKey; Hw = $hw }
}

# ── main ──────────────────────────────────────────────────────────────────────

# If any required param is missing, run the wizard
$interactive = ($Coordinator -eq "" -or $ApiKey -eq "" -or $Model -eq "")

if ($interactive) {
    $cfg = Start-Wizard
    $Coordinator = $cfg.Coordinator
    $ApiKey      = $cfg.ApiKey
    $Model       = $cfg.Model
    $hw          = $cfg.Hw
} else {
    $hw = Get-HardwareQuick
    Show-Banner
    Write-Host "  Model: $Model  |  Coordinator: $Coordinator" -ForegroundColor Yellow
    Write-Host ""
}

# 1. Ensure Ollama is present
$ollamaExe = Get-OllamaPath
if (-not $ollamaExe) {
    $ollamaExe = Install-Ollama
} else {
    Write-Ok "Ollama found at: $ollamaExe"
}

# 2. Kill any existing Ollama on this port
$existing = Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Stopping existing Ollama on port $OllamaPort ..."
    $ownPid = (Get-NetTCPConnection -LocalPort $OllamaPort -State Listen).OwningProcess
    if ($ownPid) { Stop-Process -Id $ownPid -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
}

# 3. Start ollama serve (all interfaces)
Write-Step "Starting Ollama server on 0.0.0.0:$OllamaPort ..."
$env:OLLAMA_HOST = "0.0.0.0:$OllamaPort"
$serverProc = Start-Process -FilePath $ollamaExe `
    -ArgumentList "serve" -PassThru -WindowStyle Hidden

Write-Step "Waiting for Ollama to be ready..."
if (-not (Wait-OllamaReady $OllamaPort 60)) {
    throw "Ollama did not start within 60 seconds"
}
Write-Ok "Ollama up (PID $($serverProc.Id))"

# 4. Pull model
if (-not $SkipModelPull) {
    Write-Step "Pulling '$Model' (instant if already cached)..."
    & $ollamaExe pull $Model
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull model '$Model'" }
    Write-Ok "Model ready."
}

# 5. Register
$myIp = Register-WithCoordinator $Coordinator $ApiKey $OllamaPort $Model $hw

# 6. Heartbeat (keeps terminal open)
Start-HeartbeatLoop $Coordinator $ApiKey $myIp $OllamaPort
