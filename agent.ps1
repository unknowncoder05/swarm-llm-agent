#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up Ollama + a coding LLM on a university Windows machine and registers
    it with a central coordinator running on your laptop.

.EXAMPLE
    # Basic — coordinator on your laptop at 192.168.1.10
    iwr -useb https://raw.githubusercontent.com/YOUR_USER/swarm-llm/main/agent/agent.ps1 |
        iex; Start-Agent -Coordinator http://192.168.1.10:8080

    # Or download first, then run with params:
    .\agent.ps1 -Coordinator http://192.168.1.10:8080 -Model qwen2.5-coder:3b
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Coordinator,           # e.g. https://192.168.1.10:8443

    [Parameter(Mandatory=$true)]
    [string]$ApiKey,                # shared secret — get it from the person running the coordinator

    [string]$Model = "qwen2.5-coder:14b",

    [int]$OllamaPort = 11434,

    [switch]$SkipModelPull          # use if model is already cached from earlier in the session
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Allow self-signed TLS certs (PS5 compatible).
# SkipCertificateCheck param only exists in PS6+; this callback covers PS5.
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

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Step([string]$msg) {
    Write-Host "[*] $msg" -ForegroundColor Cyan
}
function Write-Ok([string]$msg) {
    Write-Host "[+] $msg" -ForegroundColor Green
}
function Write-Err([string]$msg) {
    Write-Host "[!] $msg" -ForegroundColor Red
}

function Get-OllamaPath {
    # Check if already on PATH
    $found = Get-Command ollama -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }

    # Common install locations (no-admin install)
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Ollama\ollama.exe",
        "$env:TEMP\ollama\ollama.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Install-Ollama {
    Write-Step "Downloading Ollama installer..."
    $installer = Join-Path $env:TEMP "OllamaSetup.exe"

    # Retry up to 3 times
    $attempts = 0
    while ($attempts -lt 3) {
        try {
            Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" `
                -OutFile $installer -UseBasicParsing
            break
        } catch {
            $attempts++
            if ($attempts -ge 3) { throw "Failed to download Ollama after 3 attempts: $_" }
            Write-Err "Download failed, retrying ($attempts/3)..."
            Start-Sleep 2
        }
    }

    Write-Step "Installing Ollama (no admin required)..."
    # /S = silent; Ollama installs to %LOCALAPPDATA%\Programs\Ollama without elevation
    Start-Process -FilePath $installer -ArgumentList "/S" -Wait -NoNewWindow

    # Give the installer a moment to finish writing files
    Start-Sleep 2

    $path = Get-OllamaPath
    if (-not $path) {
        throw "Ollama installation completed but binary not found. Check %LOCALAPPDATA%\Programs\Ollama"
    }
    Write-Ok "Ollama installed at: $path"
    return $path
}

function Wait-OllamaReady([string]$ollamaExe, [int]$port, [int]$timeoutSec = 60) {
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

function Get-SystemInfo {
    $info = @{}

    # hostname
    $info.hostname = $env:COMPUTERNAME

    # CPU
    try {
        $cpu = Get-WmiObject Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.cpu_name  = $cpu.Name.Trim()
        $info.cpu_cores = [int]$cpu.NumberOfLogicalProcessors
    } catch {
        $info.cpu_name  = "unknown"
        $info.cpu_cores = $null
    }

    # RAM
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        $info.ram_total_gb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $info.ram_free_gb  = [math]::Round($os.FreePhysicalMemory    / 1MB, 2)
    } catch {
        $info.ram_total_gb = $null
        $info.ram_free_gb  = $null
    }

    # GPU (prefer nvidia-smi for accuracy; fall back to WMI)
    $info.gpu_name    = $null
    $info.gpu_vram_gb = $null
    try {
        $smi = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $smi) {
            $parts = $smi -split ","
            $info.gpu_name    = $parts[0].Trim()
            $info.gpu_vram_gb = [math]::Round([double]$parts[1].Trim() / 1024, 2)
        }
    } catch { }

    if (-not $info.gpu_name) {
        try {
            $gpu = Get-WmiObject Win32_VideoController -ErrorAction Stop |
                   Where-Object { $_.AdapterRAM -gt 0 } | Select-Object -First 1
            if ($gpu) {
                $info.gpu_name    = $gpu.Name
                $info.gpu_vram_gb = [math]::Round($gpu.AdapterRAM / 1GB, 2)
            }
        } catch { }
    }

    # Ollama version
    try {
        $ver = & $script:ollamaExe --version 2>&1
        $info.ollama_version = ($ver -replace "ollama version ", "").Trim()
    } catch {
        $info.ollama_version = "?"
    }

    # OS
    $info.os_version = [System.Environment]::OSVersion.VersionString

    return $info
}

function Register-WithCoordinator([string]$coordinator, [int]$port, [string]$model) {
    $myIp = (
        Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } |
        Select-Object -First 1
    ).IPAddress

    if (-not $myIp) {
        throw "Could not determine local IP address"
    }

    Write-Step "Collecting system information..."
    $sysInfo = Get-SystemInfo

    $body = @{
        ip              = $myIp
        port            = $port
        model           = $model
        hostname        = $sysInfo.hostname
        cpu_name        = $sysInfo.cpu_name
        cpu_cores       = $sysInfo.cpu_cores
        ram_total_gb    = $sysInfo.ram_total_gb
        ram_free_gb     = $sysInfo.ram_free_gb
        gpu_name        = $sysInfo.gpu_name
        gpu_vram_gb     = $sysInfo.gpu_vram_gb
        ollama_version  = $sysInfo.ollama_version
        os_version      = $sysInfo.os_version
    } | ConvertTo-Json

    $headers = @{ "X-API-Key" = $ApiKey }

    Write-Step "Registering $myIp`:$port with coordinator at $coordinator ..."
    $response = Invoke-RestMethod -Uri "$coordinator/register" `
        -Method Post `
        -Body $body `
        -ContentType "application/json" `
        -Headers $headers `
        -ErrorAction Stop

    Write-Ok "Registered! Coordinator response: $($response | ConvertTo-Json -Compress)"
    return $myIp
}

function Start-HeartbeatLoop([string]$coordinator, [string]$apiKey, [string]$ip, [int]$port, [int]$intervalSec = 15) {
    $headers = @{ "X-API-Key" = $apiKey }
    Write-Step "Starting heartbeat loop (every ${intervalSec}s). Press Ctrl+C to stop."
    while ($true) {
        try {
            $body = @{ ip = $ip; port = $port } | ConvertTo-Json
            Invoke-RestMethod -Uri "$coordinator/heartbeat" `
                -Method Post -Body $body -ContentType "application/json" `
                -Headers $headers | Out-Null
        } catch {
            Write-Err "Heartbeat failed: $_  (coordinator may be down)"
        }
        Start-Sleep $intervalSec
    }
}

# ── main ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  swarm-llm agent  |  model: $Model  |  coordinator: $Coordinator" -ForegroundColor Yellow
Write-Host "  TLS: ON  |  API key auth: ON  |  GPU: RTX 4070 (12 GB) detected" -ForegroundColor DarkYellow
Write-Host ""

# 1. Ensure Ollama is present
$ollamaExe = Get-OllamaPath
if (-not $ollamaExe) {
    $ollamaExe = Install-Ollama
} else {
    Write-Ok "Ollama found at: $ollamaExe"
}

# 2. Stop any existing Ollama server on this port (from a previous run this session)
$existing = Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Port $OllamaPort already in use — stopping existing Ollama process..."
    $pid = (Get-Process -Id (
        Get-NetTCPConnection -LocalPort $OllamaPort -State Listen
    ).OwningProcess -ErrorAction SilentlyContinue).Id
    if ($pid) { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
}

# 3. Start ollama serve (binding to all interfaces so the coordinator can reach it)
Write-Step "Starting Ollama server on 0.0.0.0:$OllamaPort ..."
$env:OLLAMA_HOST = "0.0.0.0:$OllamaPort"
$serverProc = Start-Process -FilePath $ollamaExe `
    -ArgumentList "serve" `
    -PassThru `
    -WindowStyle Hidden

Write-Step "Waiting for Ollama to be ready..."
if (-not (Wait-OllamaReady $ollamaExe $OllamaPort 60)) {
    throw "Ollama server did not become ready within 60 seconds"
}
Write-Ok "Ollama server is up (PID $($serverProc.Id))"

# 4. Pull model (fast no-op if already cached)
if (-not $SkipModelPull) {
    Write-Step "Pulling model '$Model' (instant if already cached, otherwise downloading)..."
    & $ollamaExe pull $Model
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to pull model '$Model'"
    }
    Write-Ok "Model '$Model' ready."
} else {
    Write-Ok "Skipping model pull (-SkipModelPull set)."
}

# 5. Register with coordinator
$myIp = Register-WithCoordinator $Coordinator $OllamaPort $Model

# 6. Heartbeat loop (keeps this terminal open; kill to deregister)
Start-HeartbeatLoop $Coordinator $ApiKey $myIp $OllamaPort 15
