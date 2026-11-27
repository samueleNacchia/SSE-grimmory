param(
    [string]$Phase = "baseline",
    [string[]]$TestType = @("all"),
    [string[]]$ExcludeTestType = @(),
    [int]$Runs = 0,
    [int]$CooldownSeconds = 20,
    [int]$StartupTimeoutSeconds = 900,
    [string]$BaseUrl = "http://localhost:6060",
    [string]$FrontendUrl = "http://localhost:4200",
    [string]$ComposeFile = (Join-Path (Split-Path -Parent $PSScriptRoot) "dev.docker-compose.yml"),
    [string]$SeedSqlPath = (Join-Path $PSScriptRoot "seed_book.sql"),
    [string]$PlansDir = (Join-Path $PSScriptRoot "plans"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results"),
    [string]$AnalyzeScript = (Join-Path $PSScriptRoot "analyze_results.py"),
    [string]$EnergiBridgeExe = "C:\Developing\energibridge\energibridge.exe",
    [string]$JMeterBat = "C:\Developing\JMeter\apache-jmeter-5.6.3\apache-jmeter-5.6.3\bin\jmeter.bat",
    [switch]$Frontend,
    [switch]$ForceRebuild,
    [switch]$ResetAndSeed,
    [switch]$CleanPhase,
    [switch]$SkipWarmup
)

$ErrorActionPreference = "Stop"
$env:JVM_ARGS = "--sun-misc-unsafe-memory-access=allow"
$normalizedPhase = $Phase.Trim().ToLower()
$BaseUrl = $BaseUrl.TrimEnd("/")
$FrontendUrl = $FrontendUrl.TrimEnd("/")

# I privilegi Admin servono solo per il driver rapl di EnergiBridge (non per la modalità UI)
if (-not $Frontend) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Esegui PowerShell come Amministratore (richiesto da EnergiBridge)." }

    foreach ($path in @($EnergiBridgeExe, $JMeterBat, $PlansDir)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Percorso non trovato: '$path'." }
    }
}

if (-not (Test-Path -LiteralPath $ComposeFile)) { throw "Compose file non trovato: '$ComposeFile'." }

# [0/4] Gestione Docker Compose (avvia sempre prima solo DB e Backend per evitare picchi di RAM)
function Test-BackendReady {
    try { $null = Invoke-RestMethod -Uri "$BaseUrl/actuator/health" -TimeoutSec 3; return $true } catch { return $false }
}

# [0/4] Gestione Docker Compose
if ($ForceRebuild) {
    Write-Host "=== [0/4] ForceRebuild: ricostruzione del solo backend ===" -ForegroundColor Cyan
    docker compose -f $ComposeFile stop backend
    docker compose -f $ComposeFile rm -f backend
    docker compose -f $ComposeFile build --no-cache backend
    if ($LASTEXITCODE -ne 0) { throw "Build del backend fallita durante ForceRebuild." }

    docker compose -f $ComposeFile up -d backend_db backend
    if ($LASTEXITCODE -ne 0) { throw "Avvio container fallito durante ForceRebuild." }
} elseif (-not (Test-BackendReady)) {
    Write-Host "=== [0/4] Avvio backend_db e backend ===" -ForegroundColor Cyan
    docker compose -f $ComposeFile up -d --build backend_db backend
    if ($LASTEXITCODE -ne 0) { throw "docker compose fallito durante l'avvio." }
} else {
    Write-Host "=== [0/4] Backend già attivo su $BaseUrl ===" -ForegroundColor Green
}

# Garantisce che il frontend sia spento prima dei test energetici
if (-not $Frontend) {
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker compose -f $ComposeFile stop frontend 2>&1 | Out-Null
    $ErrorActionPreference = $prevErr
}

# [1/4] Attesa avvio Backend
$deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
while (-not (Test-BackendReady)) {
    if ((Get-Date) -ge $deadline) { throw "Timeout avvio backend su $BaseUrl dopo ${StartupTimeoutSeconds}s." }
    $remaining = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
    Write-Host "In attesa di Spring Boot e MariaDB... (timeout tra ${remaining}s)" -ForegroundColor Yellow
    Start-Sleep -Seconds 60
}

# Seeding opzionale
if ($ResetAndSeed) {
    if (-not (Test-Path -LiteralPath $SeedSqlPath -PathType Leaf)) { throw "File SQL seed non trovato: '$SeedSqlPath'." }
    Write-Host "=== Popolamento Database (1.000 libri) ===" -ForegroundColor Cyan
    $count = docker compose -f $ComposeFile exec -T backend_db mariadb -h 127.0.0.1 -N -B -ugrimmory -pgrimmory grimmory -e "SELECT COUNT(*) FROM book WHERE id BETWEEN 1 AND 1000;" 2>$null
    if ($LASTEXITCODE -ne 0 -or [int]($count.Trim()) -ne 1000) {
        Get-Content -LiteralPath $SeedSqlPath -Raw | docker compose -f $ComposeFile exec -T backend_db mariadb -h 127.0.0.1 -ugrimmory -pgrimmory grimmory
        Start-Sleep -Seconds 10
    }
}

# [2/4] Setup Admin, Login e Smoke Test
Write-Host "=== [2/4] Setup e Login ===" -ForegroundColor Cyan
$creds = @{ username = "admin"; password = "AdminPassword123!"; name = "Administrator"; email = "admin@grimmory.local" } | ConvertTo-Json
try { $null = Invoke-RestMethod -Uri "$BaseUrl/api/v1/setup" -Method POST -ContentType "application/json" -Body $creds } catch {}

$loginBody = @{ username = "admin"; password = "AdminPassword123!" } | ConvertTo-Json
$token = (Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody).accessToken
if (-not $token) { throw "Token JWT non ottenuto." }

$smoke = Invoke-WebRequest -Uri "$BaseUrl/api/v1/books" -Headers @{ Authorization = "Bearer $token" }
Write-Host "Smoke test OK (Status $($smoke.StatusCode), Payload $([math]::Round($smoke.RawContentLength / 1KB, 2)) KB)" -ForegroundColor Green

# Modalità solo Frontend/UI: avvia Angular solo ora (a backend pronto), apre il browser ed esce
if ($Frontend) {
    Write-Host "`n=== Modalità UI (-Frontend): avvio frontend su $FrontendUrl ===" -ForegroundColor Cyan
    docker compose -f $ComposeFile up -d frontend
    if ($LASTEXITCODE -ne 0) { throw "Avvio container frontend fallito." }

    $feReady = $false
    $restarted = $false
    $feStart = Get-Date
    $feDeadline = $feStart.AddSeconds(300)

    while ((Get-Date) -lt $feDeadline) {
        try {
            $resp = Invoke-WebRequest -Uri $FrontendUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $feReady = $true
                break
            }
        } catch {
            # Se dopo 90s Vite è ancora bloccato sul bundling iniziale, riavvia il container una volta
            if (-not $restarted -and ((Get-Date) - $feStart).TotalSeconds -ge 90) {
                Write-Host "Bundling Vite lento: eseguo restart automatico del container frontend..." -ForegroundColor Yellow
                docker compose -f $ComposeFile restart frontend | Out-Null
                $restarted = $true
            }
            Start-Sleep -Seconds 3
        }
    }

    if (-not $feReady) { throw "Timeout avvio frontend su $FrontendUrl." }

    Write-Host "`n------------------------------------------------------------------" -ForegroundColor Green
    Write-Host " AMBIENTE UI PRONTO (benchmark energetici saltati):" -ForegroundColor Green
    Write-Host "   URL:      $FrontendUrl" -ForegroundColor White
    Write-Host "   Username: admin" -ForegroundColor White
    Write-Host "   Password: AdminPassword123!" -ForegroundColor White
    Write-Host "------------------------------------------------------------------`n" -ForegroundColor Green
    Start-Process $FrontendUrl
    exit 0
}

# Selezione piani JMeter
$defaultRuns = @{ "load" = 5; "stress" = 3; "spike" = 5; "soak" = 3 }
$normalizedTypes = @($TestType | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$normalizedExcludes = @($ExcludeTestType | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })

$jmxFiles = if ($normalizedTypes -contains "all") {
    Get-ChildItem -Path $PlansDir -Filter "*_books.jmx" -File | Sort-Object Name
} else {
    $normalizedTypes | ForEach-Object { Get-Item -LiteralPath (Join-Path $PlansDir "${_}_books.jmx") }
}

if ($normalizedExcludes.Count -gt 0) {
    $jmxFiles = @($jmxFiles | Where-Object { ($_.BaseName -replace "_books$", "").ToLower() -notin $normalizedExcludes })
}
if ($jmxFiles.Count -eq 0) { throw "Nessun piano JMeter selezionato." }

$targetUri = [System.Uri]$BaseUrl
$jmeterTargetArgs = @("-Jhost=$($targetUri.Host)", "-Jport=$($targetUri.Port)", "-Jprotocol=$($targetUri.Scheme)")

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
if ($CleanPhase) {
    $jmxFiles | ForEach-Object {
        $tName = ($_.BaseName -replace "_books$", "").ToLower()
        Get-ChildItem -Path $ResultsDir -Filter "*_${normalizedPhase}_${tName}_*" -File | Remove-Item -Force
    }
}

# Warm-up opzionale
if (-not $SkipWarmup) {
    $warmupPlan = if (Test-Path (Join-Path $PlansDir "load_books.jmx")) { Join-Path $PlansDir "load_books.jmx" } else { $jmxFiles[0].FullName }
    Write-Host "=== Warm-up ($(Split-Path -Leaf $warmupPlan)) ===" -ForegroundColor Yellow
    $warmupJtl = Join-Path $ResultsDir "warmup_${normalizedPhase}_$(Get-Date -Format 'yyyyMMdd_HHmmss').jtl"
    & $JMeterBat -n -t $warmupPlan "-Jjwt_token=$token" @jmeterTargetArgs -l $warmupJtl | Out-Null
    Start-Sleep -Seconds $CooldownSeconds
}

# [3/4] Esecuzione Benchmark con EnergiBridge
sc.exe start rapl 2>$null | Out-Null
Start-Sleep -Seconds 2

try {
    foreach ($jmx in $jmxFiles) {
        $testName = ($jmx.BaseName -replace "_books$", "").ToLower()
        $totalRuns = if ($Runs -gt 0) { $Runs } elseif ($defaultRuns.ContainsKey($testName)) { $defaultRuns[$testName] } else { 5 }

        Write-Host "`n=== [3/4] Benchmark [$normalizedPhase | $testName] ($totalRuns run) ===" -ForegroundColor Cyan
        for ($i = 1; $i -le $totalRuns; $i++) {
            $token = (Invoke-RestMethod -Uri "$BaseUrl/api/v1/auth/login" -Method POST -ContentType "application/json" -Body $loginBody).accessToken
            $ts = Get-Date -Format "yyyyMMdd_HHmmss_fff"
            $ebCsv = Join-Path $ResultsDir "eb_${normalizedPhase}_${testName}_run${i}_${ts}.csv"
            $jmJtl = Join-Path $ResultsDir "jm_${normalizedPhase}_${testName}_run${i}_${ts}.jtl"

            Write-Host "--- Run $i/$totalRuns [$normalizedPhase | $testName] ---" -ForegroundColor Magenta
            & $EnergiBridgeExe --interval 200 --output $ebCsv --summary `
                $JMeterBat -n -t $jmx.FullName "-Jjwt_token=$token" @jmeterTargetArgs -l $jmJtl

            if ($LASTEXITCODE -ne 0) { throw "Errore nella run $i di $testName." }
            if ($i -lt $totalRuns) { Start-Sleep -Seconds $CooldownSeconds }
        }
        if ($jmx -ne $jmxFiles[-1]) { Start-Sleep -Seconds $CooldownSeconds }
    }
} finally {
    sc.exe stop rapl 2>$null | Out-Null
}

# [4/4] Analisi Python
Write-Host "`n=== [4/4] Avvio analisi risultati ===" -ForegroundColor Green
$venvPython = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
$pythonCmd = if (Test-Path $venvPython) { $venvPython } else { "python" }

if (Test-Path $AnalyzeScript) {
    & $pythonCmd $AnalyzeScript
    if ($LASTEXITCODE -eq 0) {
        Remove-Item -Path (Join-Path $ResultsDir "*") -Force
    }
}