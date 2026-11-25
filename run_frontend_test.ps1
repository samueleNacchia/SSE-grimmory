# ==============================================================================
# Avvio rapido ambiente completo per test UI (solo dev.docker-compose.yml)
# Uso: powershell -ExecutionPolicy Bypass -File .\run_frontend_test.ps1
# ==============================================================================
param(
    [switch]$ResetDb,      # Azzera solo il volume DB e re-inietta i 1000 libri (mantiene cache Gradle!)
    [switch]$ResetDocker,  # Forza il riavvio di Docker Desktop/WSL2 prima di iniziare
    [switch]$SkipSeed,     # Salta l'iniezione di seed_book.sql
    [string]$BaseUrl = "http://localhost:6060",
    [string]$FrontendUrl = "http://localhost:4200"
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$FrontendDir = Join-Path $RepoRoot "frontend"
$DevCompose = Join-Path $RepoRoot "dev.docker-compose.yml"
$SeedSqlPath = Join-Path $RepoRoot "sse-jmeter\seed_book.sql"

$AdminUser = "admin"
$AdminPassword = "AdminPassword123!"

# --- 0. Verifica e ripristino automatico Docker Desktop / WSL2 ---
function Test-DockerDaemonHealthy {
    $job = Start-Job -ScriptBlock {
        docker info --format "{{.ServerVersion}}" 2>$null
        return $LASTEXITCODE
    }
    $completed = Wait-Job -Job $job -Timeout 10
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return $false
    }
    $output = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return ($output -contains 0)
}

function Reset-DockerDesktop {
    Write-Host "=== Reset Docker Desktop e WSL2 in corso... ===" -ForegroundColor Yellow

    Get-Process -Name "Docker Desktop", "com.docker.backend", "com.docker.proxy", "wslrelay" -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    wsl --shutdown 2>$null | Out-Null
    $ErrorActionPreference = $prevErr

    Start-Sleep -Seconds 5

    # Avvia il servizio Windows di Docker se presente e fermo
    $dockerSvc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
    if ($dockerSvc -and $dockerSvc.Status -ne "Running") {
        Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $dockerCli = Get-Command docker.exe -ErrorAction SilentlyContinue
    $candidates = @(
        "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        "$env:LOCALAPPDATA\Programs\Docker\Docker\Docker Desktop.exe"
        "$env:ProgramW6432\Docker\Docker\Docker Desktop.exe"
    )
    if ($dockerCli) {
        $binDir = Split-Path -Parent $dockerCli.Source
        $candidates += (Join-Path (Split-Path -Parent (Split-Path -Parent $binDir)) "Docker Desktop.exe")
        $candidates += (Join-Path (Split-Path -Parent $binDir) "Docker Desktop.exe")
    }

    $dockerExe = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $dockerExe) {
        throw "Docker Desktop.exe non trovato. Percorsi controllati: $($candidates -join ', ')"
    }

    Write-Host "Avvio: $dockerExe" -ForegroundColor DarkGray
    # Avvio tramite explorer.exe per evitare l'ereditarietà dei privilegi Admin (che blocca Docker Desktop)
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$dockerExe`""

    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-DockerDaemonHealthy)) {
        if ((Get-Date) -ge $deadline) {
            throw "Docker Desktop non ripartito entro 180s."
        }
        Write-Host "Attesa motore Docker..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
    Write-Host "[OK] Docker Desktop pronto!" -ForegroundColor Green
}

if ($ResetDocker -or -not (Test-DockerDaemonHealthy)) {
    Reset-DockerDesktop
}

# --- 1. Creazione cartelle condivise locali + Avvio Backend e DB ---
Write-Host "=== [1/4] Preparazione cartelle e avvio Backend + MariaDB ===" -ForegroundColor Cyan
foreach ($dir in @("shared\data", "shared\books", "shared\bookdrop")) {
    $fullPath = Join-Path $RepoRoot $dir
    if (-not (Test-Path -LiteralPath $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
}

$prevErr = $ErrorActionPreference
$ErrorActionPreference = "Continue"
if ($ResetDb) {
    docker compose -f $DevCompose down
    docker volume rm grimmory-developing_backend_db 2>$null | Out-Null
}
docker compose -f $DevCompose up -d backend_db backend
$upExit = $LASTEXITCODE
$ErrorActionPreference = $prevErr
if ($upExit -ne 0) { throw "docker compose up fallito ($upExit)." }

Write-Host "Attesa /actuator/health su $BaseUrl (bootRun in corso)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds(900)
$ticks = 0
while ($true) {
    try {
        $null = Invoke-RestMethod -Uri "$BaseUrl/actuator/health" -TimeoutSec 5 -ErrorAction Stop
        Write-Host "`n[OK] Backend e MariaDB pronti!" -ForegroundColor Green
        break
    } catch {
        if ((Get-Date) -ge $deadline) { throw "Timeout attesa backend su $BaseUrl." }
        Start-Sleep -Seconds 3
        $ticks++
        Write-Host "." -NoNewline
        if ($ticks % 10 -eq 0) {
            $lastLog = docker compose -f $DevCompose logs --tail=1 backend 2>$null
            Write-Host "`n  [docker] $lastLog" -ForegroundColor DarkGray
        }
    }
}

# --- 2. Popolamento Database con i 1.000 libri ---
if (-not $SkipSeed -and (Test-Path -LiteralPath $SeedSqlPath -PathType Leaf)) {
    Write-Host "`n=== [2/4] Verifica e Popolamento 1.000 Libri ===" -ForegroundColor Cyan
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $existingCount = docker compose -f $DevCompose exec -T backend_db mariadb -h 127.0.0.1 -N -B -ugrimmory -pgrimmory grimmory -e "SELECT COUNT(*) FROM book WHERE id BETWEEN 1 AND 1000;" 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingCount -and [int]($existingCount.Trim()) -eq 1000) {
            Write-Host "[OK] Database già popolato con 1.000 libri." -ForegroundColor Green
        } else {
            Write-Host "Iniezione seed SQL da '$SeedSqlPath'..." -ForegroundColor Yellow
            Get-Content -LiteralPath $SeedSqlPath -Raw | docker compose -f $DevCompose exec -T backend_db mariadb -h 127.0.0.1 -ugrimmory -pgrimmory grimmory
            if ($LASTEXITCODE -ne 0) { throw "Errore iniezione SQL." }
            Write-Host "[OK] 1.000 libri inseriti con successo!" -ForegroundColor Green
        }
    } finally {
        $ErrorActionPreference = $prevErr
    }
}

# --- 3. Creazione automatica utente Admin + Smoke Test API ---
Write-Host "`n=== [3/4] Configurazione automatica utente Admin ===" -ForegroundColor Cyan
$setupBody = @{
    username = $AdminUser
    password = $AdminPassword
    name     = "Administrator"
    email    = "admin@grimmory.local"
} | ConvertTo-Json

try {
    $null = Invoke-RestMethod -Uri "$BaseUrl/api/v1/setup" -Method POST -ContentType "application/json" -Body $setupBody
    Write-Host "[OK] Utente admin creato." -ForegroundColor Green
} catch {
    Write-Host "[INFO] Utente admin già presente." -ForegroundColor DarkGray
}

$loginBody = @{ username = $AdminUser; password = $AdminPassword } | ConvertTo-Json
$loginResp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody
$booksResp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/books" -Method GET -Headers @{ Authorization = "Bearer $($loginResp.accessToken)" }
Write-Host "[OK] Smoke test superato: $($booksResp.Count) libri restituiti dall'API." -ForegroundColor Green

# --- 4. Avvio Frontend Nativo + Apertura Browser ---
Write-Host "`n=== [4/4] Avvio Frontend Angular su $FrontendUrl ===" -ForegroundColor Cyan
Set-Location $FrontendDir

if (-not (Test-Path (Join-Path $FrontendDir "node_modules"))) {
    Write-Host "Installazione dipendenze npm (--legacy-peer-deps)..." -ForegroundColor Yellow
    npm.cmd install --legacy-peer-deps
}

Write-Host "`n------------------------------------------------------------------" -ForegroundColor Green
Write-Host " CREDENZIALI DI ACCESSO PRONTE:" -ForegroundColor Green
Write-Host "   URL:      $FrontendUrl" -ForegroundColor White
Write-Host "   Username: $AdminUser" -ForegroundColor White
Write-Host "   Password: $AdminPassword" -ForegroundColor White
Write-Host " Premi Ctrl + C nel terminale quando hai finito per chiudere tutto." -ForegroundColor Yellow
Write-Host "------------------------------------------------------------------`n" -ForegroundColor Green

# Attende che Angular risponda su $FrontendUrl prima di aprire il browser
Start-Job -ScriptBlock {
    param($url)
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Start-Process $url
                break
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
} -ArgumentList $FrontendUrl | Out-Null

try {
    npm.cmd start
} finally {
    Write-Host "`n=== Spegnimento container Docker ===" -ForegroundColor Cyan
    Set-Location $RepoRoot
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker compose -f $DevCompose down
    $ErrorActionPreference = $prevErr
    Write-Host "[OK] Ambiente chiuso." -ForegroundColor Green
}