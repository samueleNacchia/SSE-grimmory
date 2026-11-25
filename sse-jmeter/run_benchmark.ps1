param(
    [string]$Phase = "baseline",
    [string[]]$TestType = @("all"),   # Valori: "all", oppure "load", "stress", "spike", "soak" (anche separati da virgola)
    [string[]]$ExcludeTestType = @(),  # Es: "load" per eseguire tutti tranne load
    [int]$Runs = 0,                    # 0 = usa i default per scenario (5 per load/stress/spike, 3 per soak)
    [int]$CooldownSeconds = 30,
    [int]$StartupTimeoutSeconds = 900,
    [int]$PollIntervalSeconds = 60,
    [string]$BaseUrl = "http://localhost:6060",
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ComposeFile = (Join-Path $PSScriptRoot "docker-compose.bench.yml"),
    [string]$SeedSqlPath = (Join-Path $PSScriptRoot "seed_book.sql"),
    [string]$PlansDir = (Join-Path $PSScriptRoot "plans"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results"),
    [string]$AnalyzeScript = (Join-Path $PSScriptRoot "analyze_results.py"),
    [string]$EnergiBridgeExe = "C:\Developing\energibridge\energibridge.exe",
    [string]$JMeterBat = "C:\Developing\JMeter\apache-jmeter-5.6.3\apache-jmeter-5.6.3\bin\jmeter.bat",
    [switch]$ResetDocker,
    [switch]$ForceRebuild,
    [switch]$ResetAndSeed,
    [switch]$CleanPhase,
    [switch]$SkipWarmup
)

$ErrorActionPreference = "Stop"
$env:JVM_ARGS = "--sun-misc-unsafe-memory-access=allow"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    throw "Esegui PowerShell come Amministratore: EnergiBridge (driver rapl) richiede privilegi elevati."
}

if ($Runs -lt 0) { throw "Runs non può essere negativo (usa 0 per i default per scenario)." }
if ($CooldownSeconds -lt 0) { throw "CooldownSeconds non può essere negativo." }
if ($StartupTimeoutSeconds -lt 1) { throw "StartupTimeoutSeconds deve essere almeno 1." }
if ($PollIntervalSeconds -lt 1) { throw "PollIntervalSeconds deve essere almeno 1." }

$defaultRunsByScenario = @{
    "load"   = 5
    "stress" = 5
    "spike"  = 5
    "soak"   = 3
}

foreach ($requiredPath in @($EnergiBridgeExe, $JMeterBat)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "File richiesto non trovato: '$requiredPath'."
    }
}

if (-not (Test-Path -LiteralPath $PlansDir -PathType Container)) {
    throw "Cartella piani JMeter non trovata: '$PlansDir'."
}

$allJmxFiles = Get-ChildItem -Path $PlansDir -Filter "*_books.jmx" -File | Sort-Object Name
if ($allJmxFiles.Count -eq 0) {
    throw "Nessun file *_books.jmx trovato in '$PlansDir'."
}

$normalizedTypes = @($TestType | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" })
$normalizedExcludes = @($ExcludeTestType | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne "" })

if ($normalizedTypes -contains "all") {
    $jmxFiles = $allJmxFiles
} else {
    $jmxFiles = @()
    foreach ($t in $normalizedTypes) {
        $planPath = Join-Path $PlansDir "${t}_books.jmx"
        if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
            throw "Piano JMeter non trovato per TestType='$t': '$planPath'."
        }
        $jmxFiles += Get-Item -LiteralPath $planPath
    }
}

if ($normalizedExcludes.Count -gt 0) {
    $jmxFiles = @($jmxFiles | Where-Object {
        $typeName = ($_.BaseName -replace "_books$", "").ToLower()
        $typeName -notin $normalizedExcludes
    })
}

if ($jmxFiles.Count -eq 0) {
    throw "Nessun piano JMeter rimasto da eseguire dopo l'applicazione dei filtri."
}

$selectedTestNames = @($jmxFiles | ForEach-Object { ($_.BaseName -replace "_books$", "").ToLower() })
$selectedTestsLabel = $selectedTestNames -join ", "

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

if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

if ($CleanPhase) {
    foreach ($tName in $selectedTestNames) {
        $cleanPattern = "*_${Phase}_${tName}_*"
        Write-Host "=== Pulizia vecchi file ($cleanPattern) ===" -ForegroundColor DarkGray
        Get-ChildItem -Path $ResultsDir -Filter $cleanPattern -File | Remove-Item -Force
    }
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

    # Avvia il servizio Windows di Docker (dato che benchmark.ps1 gira da Admin, riesce sempre)
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
        throw "Eseguibile Docker Desktop non trovato automaticamente. Percorsi controllati: $($candidates -join ', ')"
    }

    Write-Host "Avvio: $dockerExe" -ForegroundColor DarkGray
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$dockerExe`""

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

# Warm-up unico leggero (30s tramite load_books.jmx) prima di tutti gli scenari
if (-not $SkipWarmup) {
    $warmupPlan = Join-Path $PlansDir "load_books.jmx"
    if (-not (Test-Path -LiteralPath $warmupPlan -PathType Leaf)) {
        $warmupPlan = $jmxFiles[0].FullName
    }
    Write-Host "`n=== Warm-up unico JVM / DB ($(Split-Path -Leaf $warmupPlan)) ===" -ForegroundColor Yellow
    $warmupTimestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $warmupJtl = Join-Path $ResultsDir "warmup_${Phase}_${warmupTimestamp}.jtl"
    & $JMeterBat -n -t $warmupPlan "-Jjwt_token=$token" @jmeterTargetArgs -l $warmupJtl | Out-Null
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

# Allineamento automatico percorso driver rapl + avvio servizio
$driverPath = Join-Path (Split-Path -Parent $EnergiBridgeExe) "LibreHardwareMonitor.sys"
if (Test-Path -LiteralPath $driverPath -PathType Leaf) {
    sc.exe config rapl binPath= "$driverPath" | Out-Null
}

$raplSvc = Get-Service -Name "rapl" -ErrorAction SilentlyContinue
if (-not $raplSvc) {
    throw "Il servizio 'rapl' di EnergiBridge non è installato."
}

$raplSvc.Refresh()
if ($raplSvc.Status -ne "Running") {
    Write-Host "Avvio servizio EnergyBridge (rapl)..." -ForegroundColor Cyan
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $scOut = sc.exe start rapl 2>&1
    $scExit = $LASTEXITCODE
    $ErrorActionPreference = $prevErr

    if ($scExit -ne 0 -and $scExit -ne 1056) {
        throw "Impossibile avviare il servizio driver 'rapl' (exit $scExit): $($scOut -join ' ')"
    }
    Start-Sleep -Seconds 2
}

try {
    foreach ($jmx in $jmxFiles) {
        $currentTestType = ($jmx.BaseName -replace "_books$", "").ToLower()
        $currentJmxPath = $jmx.FullName
        $scenarioRuns = if ($Runs -gt 0) {
            $Runs
        } elseif ($defaultRunsByScenario.ContainsKey($currentTestType)) {
            $defaultRunsByScenario[$currentTestType]
        } else {
            5
        }

        Write-Host "`n==================================================================" -ForegroundColor Cyan
        Write-Host "=== [5/5] Esecuzione Benchmark [$Phase | $currentTestType] ($scenarioRuns run) ===" -ForegroundColor Cyan
        Write-Host "==================================================================" -ForegroundColor Cyan

        for ($i = 1; $i -le $scenarioRuns; $i++) {
            $loginResponse = Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody
            $token = $loginResponse.accessToken

            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
            $ebCsv = Join-Path $ResultsDir "eb_${Phase}_${currentTestType}_run${i}_${timestamp}.csv"
            $jmJtl = Join-Path $ResultsDir "jm_${Phase}_${currentTestType}_run${i}_${timestamp}.jtl"

            Write-Host "`n--- Run $i di $scenarioRuns [$Phase | $currentTestType] ---" -ForegroundColor Magenta
            Write-Host "Output EnergiBridge: $ebCsv"
            Write-Host "Output JMeter:       $jmJtl"

            & $EnergiBridgeExe --interval 200 --output $ebCsv --summary `
                $JMeterBat -n -t $currentJmxPath "-Jjwt_token=$token" @jmeterTargetArgs -l $jmJtl
            $benchmarkExitCode = $LASTEXITCODE
            if ($benchmarkExitCode -ne 0) {
                throw "EnergiBridge/JMeter fallito nella run $i [$currentTestType] con exit code $benchmarkExitCode. Output parziali mantenuti in $ResultsDir."
            }
            foreach ($outputPath in @($ebCsv, $jmJtl)) {
                if (-not (Test-Path -LiteralPath $outputPath) -or (Get-Item -LiteralPath $outputPath).Length -eq 0) {
                    throw "Run $i [$currentTestType] incompleta: file mancante o vuoto '$outputPath'. Output parziali mantenuti in $ResultsDir."
                }
            }

            if ($i -lt $scenarioRuns) {
                Write-Host "Cooldown di $CooldownSeconds secondi prima della prossima run..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $CooldownSeconds
            }
        }

        if ($jmx -ne $jmxFiles[-1]) {
            Write-Host "`nCooldown tra scenari di test ($CooldownSeconds s)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $CooldownSeconds
        }
    }
} finally {
    Write-Host "`nArresto servizio EnergyBridge (rapl)..." -ForegroundColor DarkGray
    sc.exe stop rapl | Out-Null
    $svc = Get-Service -Name "rapl" -ErrorAction SilentlyContinue
    if ($svc) {
        try { $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(10)) } catch {}
    }
}

Write-Host "`n=== Benchmark '$Phase' ($selectedTestsLabel) completato! Avvio configurazione ambiente Python... ===" -ForegroundColor Green

$VenvPath = Join-Path $PSScriptRoot ".venv"

if (-not (Test-Path -LiteralPath $VenvPath -PathType Container)) {
    Write-Host "`n[1/4] Creazione ambiente virtuale Python..." -ForegroundColor Cyan
    python -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRORE: impossibile creare il virtual environment." -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n[2/4] Attivazione ambiente virtuale..." -ForegroundColor Cyan
$ActivateScript = Join-Path $VenvPath "Scripts\Activate.ps1"
. $ActivateScript

Write-Host "`n[3/4] Aggiornamento pip e installazione dipendenze..." -ForegroundColor Cyan
python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante l'aggiornamento di pip." -ForegroundColor Red
    exit 1
}

python -m pip install pandas numpy
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERRORE durante l'installazione delle dipendenze." -ForegroundColor Red
    exit 1
}

Write-Host "`n[4/4] Avvio analisi automatica..." -ForegroundColor Green
if (Test-Path -LiteralPath $AnalyzeScript -PathType Leaf) {
    python $AnalyzeScript
    if ($LASTEXITCODE -eq 0) {
        Remove-Item -Path (Join-Path $ResultsDir "*") -Force
    }
} else {
    Write-Host "ERRORE: script di analisi non trovato: $AnalyzeScript" -ForegroundColor Red
    exit 1
}