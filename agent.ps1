#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up Ollama + a coding LLM on a Windows machine and registers
    it with a swarm-llm coordinator.

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
    Write-Host "  swarm-llm Agent  |  TLS ON  |  API Key Auth ON" -ForegroundColor DarkCyan
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

function Measure-NetworkSpeed {
    # Downloads 5 MB from Cloudflare's speed test endpoint; returns MB/s or $null
    $testUrl = "https://speed.cloudflare.com/__down?bytes=5242880"
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        $wc = New-Object System.Net.WebClient
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $wc.DownloadFile($testUrl, $tmpFile)
        $sw.Stop()
        $bytes = (Get-Item $tmpFile).Length
        if ($sw.Elapsed.TotalSeconds -gt 0 -and $bytes -gt 0) {
            return [math]::Round($bytes / $sw.Elapsed.TotalSeconds / 1MB, 2)
        }
    } catch { }
    finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-HardwareQuick {
    $hw = @{ vram_gb = 0; ram_gb = 0; gpu_name = "none"; cpu_name = "unknown"; network_mbps = $null }
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
        network_mbps   = $hw.network_mbps
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
        port           = $port      # ip is derived server-side from the source address
        model          = $model
        hostname       = $sysInfo.hostname
        cpu_name       = $sysInfo.cpu_name
        cpu_cores      = $sysInfo.cpu_cores
        ram_total_gb   = $sysInfo.ram_total_gb
        ram_free_gb    = $sysInfo.ram_free_gb
        gpu_name       = $sysInfo.gpu_name
        gpu_vram_gb    = $sysInfo.gpu_vram_gb
        network_mbps   = $sysInfo.network_mbps
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

function Test-CoordinatorReachable([string]$coordinator, [string]$apiKey) {
    Write-Step "Pinging coordinator at $coordinator ..."
    try {
        $r = Invoke-WebRequest -Uri "$coordinator/healthz" `
            -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($r.StatusCode -eq 200) {
            Write-Ok "Coordinator is reachable."
            return $true
        }
    } catch { }
    Write-Err "Cannot reach coordinator at $coordinator"
    Write-Err "Check the URL and make sure the server is running before downloading the model."
    return $false
}

function Write-Status([string]$phase, [string]$detail = "") {
    $ts  = (Get-Date).ToString("HH:mm:ss")
    $msg = if ($detail) { "[$ts] $phase — $detail" } else { "[$ts] $phase" }
    Write-Host "  $msg" -ForegroundColor DarkCyan
    $msg | Out-File -FilePath "$env:TEMP\swarm-agent-status.txt" -Encoding UTF8

    # Report to coordinator if we already have credentials
    if ($script:Coordinator -and $script:ApiKey) {
        try {
            $body = @{
                phase    = $phase
                detail   = $detail
                hostname = $env:COMPUTERNAME
                model    = $script:Model
            } | ConvertTo-Json
            Invoke-RestMethod -Uri "$script:Coordinator/agent-status" `
                -Method Post -Body $body -ContentType "application/json" `
                -Headers @{ "X-API-Key" = $script:ApiKey } `
                -ErrorAction SilentlyContinue | Out-Null
        } catch { }  # never let status reporting crash the agent
    }
}

function Start-HeartbeatLoop([string]$coordinator, [string]$apiKey, [string]$ip, [int]$port) {
    $headers = @{ "X-API-Key" = $apiKey }
    Write-Status "RUNNING" "heartbeat every 15s — press Ctrl+C to disconnect"
    while ($true) {
        try {
            $body = @{ port = $port } | ConvertTo-Json
            Invoke-RestMethod -Uri "$coordinator/heartbeat" `
                -Method Post -Body $body -ContentType "application/json" `
                -Headers $headers | Out-Null
            Write-Status "HEARTBEAT" "OK"
        } catch {
            Write-Err "Heartbeat failed: $_ (coordinator unreachable)"
            Write-Status "HEARTBEAT_FAILED" "$_"
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
    $coordUrl = (Read-Host).Trim().TrimEnd("/")

    # API key (masked)
    $apiKey = Read-MaskedInput "API Key: "

    # Local Ollama port
    Write-Host ""
    $portChoices = @(
        "11434  (default)",
        "11435",
        "11436",
        "11437"
    )
    $portValues = @(11434, 11435, 11436, 11437)
    $portChosen = Show-ChoiceList "Local Ollama port (use a different one if 11434 is in use):" $portChoices 0
    $ollamaPort = $portValues[$portChoices.IndexOf($portChosen)]

    Write-Host ""
    # Expose credentials to Write-Status before returning so the first report fires
    $script:Coordinator = $coordUrl
    $script:ApiKey      = $apiKey
    $script:Model       = $chosenId
    return @{
        Model       = $chosenId
        Coordinator = $coordUrl
        ApiKey      = $apiKey
        OllamaPort  = $ollamaPort
        Hw          = $hw
    }
}

# ── main ──────────────────────────────────────────────────────────────────────

# If any required param is missing, run the wizard
$interactive = ($Coordinator -eq "" -or $ApiKey -eq "" -or $Model -eq "")

if ($interactive) {
    $cfg = Start-Wizard
    $Coordinator = $cfg.Coordinator
    $ApiKey      = $cfg.ApiKey
    $Model       = $cfg.Model
    $OllamaPort  = $cfg.OllamaPort
    $hw          = $cfg.Hw
} else {
    $hw = Get-HardwareQuick
    Show-Banner
    Write-Host "  Model: $Model  |  Coordinator: $Coordinator" -ForegroundColor Yellow
    Write-Host ""
}

# 1. Ping coordinator before doing anything else
Write-Status "CONNECTING"
if (-not (Test-CoordinatorReachable $Coordinator $ApiKey)) {
    exit 1
}

# 2. Ensure Ollama is present
$ollamaExe = Get-OllamaPath
if (-not $ollamaExe) {
    Write-Status "INSTALLING" "downloading Ollama"
    $ollamaExe = Install-Ollama
} else {
    Write-Ok "Ollama found at: $ollamaExe"
}

# 3. Kill any existing Ollama on this port
$existing = Get-NetTCPConnection -LocalPort $OllamaPort -State Listen -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Stopping existing Ollama on port $OllamaPort ..."
    $ownPid = (Get-NetTCPConnection -LocalPort $OllamaPort -State Listen).OwningProcess
    if ($ownPid) { Stop-Process -Id $ownPid -Force -ErrorAction SilentlyContinue }
    Start-Sleep 2
}

# 4. Start ollama serve (all interfaces)
Write-Status "STARTING" "Ollama server on port $OllamaPort"
$env:OLLAMA_HOST = "0.0.0.0:$OllamaPort"
$serverProc = Start-Process -FilePath $ollamaExe `
    -ArgumentList "serve" -PassThru -WindowStyle Hidden

Write-Step "Waiting for Ollama to be ready..."
if (-not (Wait-OllamaReady $OllamaPort 60)) {
    throw "Ollama did not start within 60 seconds"
}
Write-Ok "Ollama up (PID $($serverProc.Id))"

# 5. Network speed test — run before pull so coordinator stores the result
Write-Step "Measuring network speed (5 MB test)..."
$hw.network_mbps = Measure-NetworkSpeed
if ($hw.network_mbps) {
    Write-Ok "Network speed: $($hw.network_mbps) MB/s"
} else {
    Write-Step "Speed test failed — skipping"
}

# 6. Pull model — stream progress back to coordinator every 5 s
if (-not $SkipModelPull) {
    $speedTag = if ($hw.network_mbps) { "$($hw.network_mbps) MB/s  |  " } else { "" }
    Write-Status "DOWNLOADING" "${speedTag}starting pull — $Model"
    Write-Step "Pulling '$Model' (instant if already cached)..."

    $lastReport = [DateTime]::MinValue
    & $ollamaExe pull $Model 2>&1 | ForEach-Object {
        $line = ($_ -replace '\r','').Trim()
        Write-Host $line
        # Ollama lines with progress look like: "pulling abc123...  42% ▕████▏ 2.1 GB/4.7 GB  15 MB/s  3m45s"
        if ($line -match '(\d+)%' -and ([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 5) {
            $pct   = $Matches[1]
            $speed = if ($line -match '([\d.]+ [MG]B/s)') { "  $($Matches[1])" } else { "" }
            Write-Status "DOWNLOADING" "${pct}%${speed} — $Model"
            $lastReport = [DateTime]::UtcNow
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull model '$Model'" }
    Write-Ok "Model ready."
}

# 7. Register
Write-Status "REGISTERING" ""
$myIp = Register-WithCoordinator $Coordinator $ApiKey $OllamaPort $Model $hw

# 8. Heartbeat (keeps terminal open)
Start-HeartbeatLoop $Coordinator $ApiKey $myIp $OllamaPort
