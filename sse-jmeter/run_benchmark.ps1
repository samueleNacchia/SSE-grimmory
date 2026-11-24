param(
    [string]$Phase = "baseline",
    [int]$Runs = 5,
    [int]$Threads = 5,
    [int]$Loops = 20,
    [int]$CooldownSeconds = 30,
    [int]$StartupTimeoutSeconds = 900,
    [int]$PollIntervalSeconds = 60,
    [int]$RampUpSeconds = 15,
    [string]$BaseUrl = "http://localhost:6060",
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ComposeFile = (Join-Path $PSScriptRoot "docker-compose.bench.yml"),
    [string]$SeedSqlPath = (Join-Path $PSScriptRoot "seed_book.sql"),
    [string]$JmxPath = (Join-Path $PSScriptRoot "baseline_books.jmx"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results"),
    [string]$AnalyzeScript = (Join-Path $PSScriptRoot "analyze_results.py"),
    [string]$EnergiBridgeExe = "C:\Users\Luigi Nacchia\GitHub\EnergiBridge\target\release\energibridge.exe",
    [string]$JMeterBat = "C:\Program Files\Apache\Jmeter\apache-jmeter-5.6.3\bin\jmeter.bat",
    [switch]$ResetDocker,
    [switch]$ForceRebuild,
    [switch]$ResetAndSeed,
    [switch]$CleanPhase,
    [switch]$SkipWarmup
)

$ErrorActionPreference = "Stop"
$env:JVM_ARGS = "--sun-misc-unsafe-memory-access=allow"

if ($Runs -lt 1) { throw "Runs deve essere almeno 1." }
if ($Threads -lt 1) { throw "Threads deve essere almeno 1." }
if ($Loops -lt 1) { throw "Loops deve essere almeno 1." }
if ($CooldownSeconds -lt 0) { throw "CooldownSeconds non può essere negativo." }
if ($StartupTimeoutSeconds -lt 1) { throw "StartupTimeoutSeconds deve essere almeno 1." }
if ($PollIntervalSeconds -lt 1) { throw "PollIntervalSeconds deve essere almeno 1." }
if ($RampUpSeconds -lt 0) { throw "RampUpSeconds non può essere negativo." }

foreach ($requiredPath in @($JmxPath, $EnergiBridgeExe, $JMeterBat)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "File richiesto non trovato: '$requiredPath'."
    }
}

$targetUri = $null
if (-not [System.Uri]::TryCreate($BaseUrl, [System.UriKind]::Absolute, [ref]$targetUri)) {
    throw "BaseUrl non valido: '$BaseUrl'."
}
if ($targetUri.Scheme -notin @("http", "https")) {
    throw "BaseUrl deve usare HTTP o HTTPS."
}
$BaseUrl = $BaseUrl.TrimEnd("/")
$jmeterTargetArgs = @(
    "-Jhost=$($targetUri.Host)"
    "-Jport=$($targetUri.Port)"
    "-Jprotocol=$($targetUri.Scheme)"
)
$jmeterLoadArgs = @(
    "-Jthreads=$Threads"
    "-Jloops=$Loops"
    "-Jramp_time=$RampUpSeconds"
)

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

if ($CleanPhase) {
    Write-Host "=== Pulizia vecchi file per la fase '$Phase' ===" -ForegroundColor DarkGray
    Get-ChildItem -Path $ResultsDir -Filter "*_${Phase}_*" -File | Remove-Item -Force
}

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
        throw "Eseguibile Docker Desktop non trovato automaticamente. Percorsi controllati: $($candidates -join ', ')"
    }

    Write-Host "Avvio: $dockerExe" -ForegroundColor DarkGray
    Start-Process -FilePath $dockerExe

    $deadline = (Get-Date).AddSeconds(180)
    while ($true) {
        if (Test-DockerDaemonHealthy) {
            Write-Host "Docker Desktop pronto!" -ForegroundColor Green
            break
        }
        if ((Get-Date) -ge $deadline) {
            throw "Docker Desktop non è ripartito entro 180 secondi."
        }
        Write-Host "Attesa avvio motore Docker Desktop..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
}

if ($ResetDocker -or -not (Test-DockerDaemonHealthy)) {
    if (-not $ResetDocker) {
        Write-Host "Demone Docker non reattivo o in deadlock: avvio ripristino automatico." -ForegroundColor Yellow
    }
    Reset-DockerDesktop
}

function Test-BackendReady {
    param([string]$Url)
    try {
        $null = Invoke-RestMethod -Uri "$Url/actuator/health" -TimeoutSec 5 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

$alreadyRunning = Test-BackendReady -Url $BaseUrl

if ($ForceRebuild) {
    Write-Host "=== [0/5] ForceRebuild: Arresto e ricostruzione backend_db e backend ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
        throw "Compose file non trovato: '$ComposeFile'."
    }
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker compose -f $ComposeFile down -v
    $downExit = $LASTEXITCODE
    if ($downExit -ne 0) { $ErrorActionPreference = $prevErr; throw "docker compose down fallito ($downExit)." }

    docker compose -f $ComposeFile up -d --build backend_db backend
    $upExit = $LASTEXITCODE
    $ErrorActionPreference = $prevErr
    if ($upExit -ne 0) { throw "docker compose up fallito ($upExit)." }
    $alreadyRunning = $false
} elseif ($alreadyRunning) {
    Write-Host "=== [0/5] Backend e Docker già attivi su $BaseUrl (riutilizzo istanza attiva) ===" -ForegroundColor Green
} else {
    Write-Host "=== [0/5] Backend non attivo: avvio solo backend_db e backend ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
        throw "Compose file non trovato: '$ComposeFile'."
    }
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker compose -f $ComposeFile up -d --build backend_db backend
    $upExit = $LASTEXITCODE
    $ErrorActionPreference = $prevErr
    if ($upExit -ne 0) { throw "docker compose up fallito ($upExit)." }
}

if (-not $alreadyRunning) {
    Write-Host "`n=== [1/5] Verifica disponibilità backend (e migrazioni DB) su $BaseUrl ===" -ForegroundColor Cyan
    $startupDeadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    $dnsRecoveries = 0

    while ($true) {
        try {
            $null = Invoke-RestMethod -Uri "$BaseUrl/actuator/health" -TimeoutSec 5 -ErrorAction Stop
            Write-Host "Backend e Database pronti!" -ForegroundColor Green
            break
        } catch {
            if ((Get-Date) -ge $startupDeadline) {
                throw "Backend non pronto entro $StartupTimeoutSeconds secondi su $BaseUrl. Ultimo errore: $($_.Exception.Message)"
            }
            $remaining = [math]::Round(($startupDeadline - (Get-Date)).TotalSeconds)
            Write-Host "`nIn attesa di Spring Boot e MariaDB... (timeout tra ${remaining}s)" -ForegroundColor Yellow

            $prevErr = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $recentLogs = docker compose -f $ComposeFile logs --tail=15 backend 2>$null
            $recentLogs | Select-Object -Last 2 | ForEach-Object {
                Write-Host "  [docker] $_" -ForegroundColor DarkGray
            }

            $dbRunning = docker compose -f $ComposeFile ps --status running --services 2>$null
            $hasDnsError = ($recentLogs -join "`n") -match "UnknownHostException:\s*backend_db|Socket fail to connect to backend_db"
            $dbDown = ($dbRunning -notcontains "backend_db")

            if (($hasDnsError -or $dbDown) -and $dnsRecoveries -lt 3) {
                $dnsRecoveries++
                Write-Host "Rilevata disconnessione DNS/rete con backend_db (tentativo $dnsRecoveries/3): riavvio rete Compose preservando la build..." -ForegroundColor Yellow
                docker compose -f $ComposeFile down | Out-Null
                docker compose -f $ComposeFile up -d backend_db backend | Out-Null
            }
            $ErrorActionPreference = $prevErr

            Start-Sleep -Seconds ([math]::Min($PollIntervalSeconds, [math]::Max(1, $remaining)))
        }
    }
}

if ($ResetAndSeed) {
    Write-Host "`n=== [1b/5] Verifica e Popolamento Database (1.000 libri) ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $SeedSqlPath -PathType Leaf)) {
        throw "File SQL seed non trovato: '$SeedSqlPath'."
    }

    $prevErrorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $existingCount = docker compose -f $ComposeFile exec -T backend_db mariadb -h 127.0.0.1 -N -B -ugrimmory -pgrimmory grimmory -e "SELECT COUNT(*) FROM book WHERE id BETWEEN 1 AND 1000;" 2>$null
        if ($LASTEXITCODE -eq 0 -and $existingCount -and [int]($existingCount.Trim()) -eq 1000) {
            Write-Host "Database già popolato con 1.000 libri. Salto l'iniezione SQL." -ForegroundColor Green
        } else {
            Write-Host "Iniezione seed SQL da '$SeedSqlPath'..." -ForegroundColor Yellow
            Get-Content -LiteralPath $SeedSqlPath -Raw | docker compose -f $ComposeFile exec -T backend_db mariadb -h 127.0.0.1 -ugrimmory -pgrimmory grimmory
            if ($LASTEXITCODE -ne 0) { throw "Errore durante l'esecuzione di $SeedSqlPath." }

            $countOut = docker compose -f $ComposeFile exec -T backend_db mariadb -h 127.0.0.1 -N -B -ugrimmory -pgrimmory grimmory -e "SELECT COUNT(*) FROM book WHERE id BETWEEN 1 AND 1000;"
            if ($LASTEXITCODE -ne 0 -or [int]($countOut.Trim()) -ne 1000) {
                throw "Popolamento incompleto: trovati '$($countOut.Trim())' libri invece di 1000."
            }
            Write-Host "Database popolato con 1.000 libri! Attesa 15s per flush InnoDB..." -ForegroundColor Green
            Start-Sleep -Seconds 15
        }
    } finally {
        $ErrorActionPreference = $prevErrorPref
    }
}

Write-Host "`n=== [2/5] Setup utente admin ===" -ForegroundColor Cyan
$setupBody = @{
    username = "admin"
    password = "AdminPassword123!"
    name     = "Administrator"
    email    = "admin@grimmory.local"
} | ConvertTo-Json

try {
    $null = Invoke-RestMethod -Uri "$BaseUrl/api/v1/setup" -Method POST -ContentType "application/json" -Body $setupBody
    Write-Host "Utente admin creato." -ForegroundColor Green
} catch {
    Write-Host "Setup non riuscito ($($_.Exception.Message)); verifico l'accesso con il login." -ForegroundColor DarkGray
}

Write-Host "`n=== [3/5] Login e acquisizione JWT ===" -ForegroundColor Cyan
$loginBody = @{
    username = "admin"
    password = "AdminPassword123!"
} | ConvertTo-Json

$loginResponse = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody
$token = $loginResponse.accessToken
if (-not $token) { throw "Token JWT non trovato nella risposta di login!" }
Write-Host "Token JWT acquisito con successo." -ForegroundColor Green

Write-Host "`n=== [4/5] Smoke test GET /api/v1/books ===" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$testRes = Invoke-WebRequest -Uri "$BaseUrl/api/v1/books" -Method GET -Headers @{ Authorization = "Bearer $token" }
$sw.Stop()

$books = $testRes.Content | ConvertFrom-Json
$payloadKb = [math]::Round($testRes.RawContentLength / 1KB, 2)
Write-Host "Status: $($testRes.StatusCode) | Libri: $($books.Count) | Payload: $payloadKb KB | Latenza singola: $($sw.ElapsedMilliseconds) ms" -ForegroundColor Green

Write-Host "`n=== [5/5] Esecuzione Benchmark ($Phase - $Runs run | $Threads thread x $Loops loop) ===" -ForegroundColor Cyan

if (-not $SkipWarmup) {
    Write-Host "Esecuzione warm-up JMeter (non misurato da EnergiBridge)..." -ForegroundColor Yellow
    $warmupTimestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $warmupJtl = Join-Path $ResultsDir "warmup_${Phase}_${warmupTimestamp}.jtl"
    & $JMeterBat -n -t $JmxPath "-Jjwt_token=$token" @jmeterTargetArgs @jmeterLoadArgs -l $warmupJtl | Out-Null
    $warmupExitCode = $LASTEXITCODE
    if ($warmupExitCode -ne 0) {
        throw "Warm-up JMeter fallito con exit code $warmupExitCode."
    }
    if (-not (Test-Path -LiteralPath $warmupJtl) -or (Get-Item -LiteralPath $warmupJtl).Length -eq 0) {
        throw "Warm-up JMeter terminato senza produrre un JTL valido: '$warmupJtl'."
    }
    Write-Host "Warm-up completato. Attesa cooldown ($CooldownSeconds s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds $CooldownSeconds
}

if (-not (Get-Service -Name "rapl" -ErrorAction SilentlyContinue)) {
    Write-Warning "Il servizio 'rapl' di energibridge non è installato. Script interrotto."
    exit 1
}
Write-Host "Starting EnergyBridge service (rapl)"
sc.exe start rapl

for ($i = 1; $i -le $Runs; $i++) {
    $loginResponse = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody
    $token = $loginResponse.accessToken

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $ebCsv = Join-Path $ResultsDir "eb_${Phase}_run${i}_${timestamp}.csv"
    $jmJtl = Join-Path $ResultsDir "jm_${Phase}_run${i}_${timestamp}.jtl"

    Write-Host "`n--- Run $i di $Runs [$Phase] ---" -ForegroundColor Magenta
    Write-Host "Output EnergiBridge: $ebCsv"
    Write-Host "Output JMeter:       $jmJtl"



    & $EnergiBridgeExe --interval 200 --output $ebCsv --summary `
        $JMeterBat -n -t $JmxPath "-Jjwt_token=$token" @jmeterTargetArgs @jmeterLoadArgs -l $jmJtl
    $benchmarkExitCode = $LASTEXITCODE
    if ($benchmarkExitCode -ne 0) {
        throw "EnergiBridge/JMeter fallito nella run $i con exit code $benchmarkExitCode. Output parziali mantenuti in $ResultsDir."
    }
    foreach ($outputPath in @($ebCsv, $jmJtl)) {
        if (-not (Test-Path -LiteralPath $outputPath) -or (Get-Item -LiteralPath $outputPath).Length -eq 0) {
            throw "Run $i incompleta: file mancante o vuoto '$outputPath'. Output parziali mantenuti in $ResultsDir."
        }
    }

    if ($i -lt $Runs) {
        Write-Host "Cooldown di $CooldownSeconds secondi prima della prossima run..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $CooldownSeconds
    }
}


Write-Host "`n=== Benchmark '$Phase' completato! Avvio configurazione ambiente Python... ===" -ForegroundColor Green

# Directory dell'ambiente virtuale locale
$VenvPath = Join-Path $PSScriptRoot ".venv"

# Creazione ambiente virtuale se non esiste
if (-not (Test-Path -LiteralPath $VenvPath -PathType Container)) {
    Write-Host "`n[1/4] Creazione ambiente virtuale Python..." -ForegroundColor Cyan
    python -m venv $VenvPath

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRORE: impossibile creare il virtual environment." -ForegroundColor Red
        exit 1
    }
}

# Attivazione ambiente virtuale
Write-Host "`n[2/4] Attivazione ambiente virtuale..." -ForegroundColor Cyan

$ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
. $ActivateScript

# Aggiornamento pip
Write-Host "`n[3/4] Aggiornamento pip e installazione dipendenze..." -ForegroundColor Cyan

python -m pip install --upgrade pip

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante l'aggiornamento di pip." -ForegroundColor Red
    exit 1
}

# Installazione dipendenze
python -m pip install pandas numpy

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante l'installazione delle dipendenze." -ForegroundColor Red
    exit 1
}

# Esecuzione script di analisi
Write-Host "`n[4/4] Avvio analisi automatica..." -ForegroundColor Green

if (Test-Path -LiteralPath $AnalyzeScript -PathType Leaf) {
    python $AnalyzeScript
    Remove-Item -Path ".\results\*"

}
else {
    Write-Host "ERRORE: script di analisi non trovato: $AnalyzeScript" -ForegroundColor Red
    exit 1
}
